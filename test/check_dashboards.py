"""Check that every provisioned Claude Code dashboard exists and that every
panel query runs without error against the live ClickHouse datasource.

Grafana's frontend normally substitutes dashboard variables before sending a
query; this script does the same with each variable's "All" value (or its
default), then sends the SQL through /api/ds/query so the ClickHouse plugin's
backend expands the $__ macros exactly as it would for a browser.

Usage: python3 check_dashboards.py http://127.0.0.1:18080 admin <password> [uid:Panel title=value ...]
Each optional expectation checks that panel's first row: a number is compared
(within 1%) with the first numeric column, anything else with the first column as text.
Exit code 0 only when all expected dashboards exist and all queries succeed.
"""
import base64
import json
import re
import sys
import urllib.error
import urllib.request

EXPECTED = {
    "claude-code-overview",
    "claude-code-sessions",
    "claude-code-session-detail",
    "claude-code-team",
    "claude-code-productivity",
}


def request(base, auth, path, body=None):
    req = urllib.request.Request(base + path, method="POST" if body else "GET")
    req.add_header("Authorization", "Basic " + auth)
    if body is not None:
        req.add_header("Content-Type", "application/json")
        req.data = json.dumps(body).encode()
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            return resp.status, json.loads(resp.read() or b"null")
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read() or b"null")


def iter_panels(panels):
    for p in panels:
        yield p
        yield from iter_panels(p.get("panels", []))


def all_values(dashboard):
    return {v["name"]: (v.get("allValue") or "__all__")
            for v in dashboard.get("templating", {}).get("list", []) if v.get("includeAll")}


def variable_values(dashboard):
    values = {}
    for var in dashboard.get("templating", {}).get("list", []):
        if var.get("includeAll"):
            value = var.get("allValue") or "__all__"
        else:
            current = var.get("current", {}).get("value")
            value = current if isinstance(current, str) else var.get("query", "")
        values[var["name"]] = value
    return values


def first_value(base, auth, sql):
    body = {"from": "now-7d", "to": "now", "queries": [{
        "refId": "A", "datasource": {"type": "grafana-clickhouse-datasource", "uid": "clickhouse"},
        "rawSql": sql, "format": 1, "queryType": "table", "editorType": "sql"}]}
    _, result = request(base, auth, "/api/ds/query", body)
    try:
        frame = result["results"]["A"]["frames"][0]
        return str(frame["data"]["values"][0][0])
    except (KeyError, IndexError, TypeError):
        return None


def substitute(sql, values, all_values):
    """Mimic Grafana: a custom "All" value is inserted as-is; otherwise the
    :sqlstring format quotes the value and doubles any single quote."""
    for name, value in values.items():
        def fmt(m, value=value, name=name):
            if value == all_values.get(name) or m.group(1) != ":sqlstring":
                return value
            return "'" + value.replace("'", "''") + "'"
        sql = re.sub(r"\$\{" + re.escape(name) + r"(:[a-z]+)?\}", fmt, sql)
        sql = re.sub(r"\$" + re.escape(name) + r"\b", lambda m, v=value: v, sql)
    return sql


def first_row(result):
    try:
        return [col[0] for col in result["results"]["A"]["frames"][0]["data"]["values"]]
    except (KeyError, IndexError, TypeError):
        return None


def first_number(row):
    for v in row or []:
        if isinstance(v, (int, float)) and not isinstance(v, bool):
            return float(v)
    return None


def as_number(text):
    try:
        return float(text)
    except ValueError:
        return None


def main(base, user, password, *expectations):
    expected = {}
    overrides = {}
    for e in expectations:
        if e.startswith("var:"):  # var:name=value forces a variable's value everywhere
            name, value = e[4:].split("=", 1)
            overrides[name] = value
            continue
        key, value = e.split("=", 1)
        expected[key] = value
    auth = base64.b64encode(f"{user}:{password}".encode()).decode()
    status, found = request(base, auth, "/api/search?type=dash-db&folderUIDs=claude-code")
    if status != 200:
        print(f"  search failed: HTTP {status}")
        return 1
    uids = {d["uid"] for d in found}
    missing = EXPECTED - uids
    errors = 0
    if missing:
        print(f"  missing dashboards: {sorted(missing)}")
        errors += 1

    for uid in sorted(EXPECTED & uids):
        _, payload = request(base, auth, f"/api/dashboards/uid/{uid}")
        dash = payload["dashboard"]
        values = variable_values(dash)
        alls = all_values(dash)
        queries = []
        for var in dash.get("templating", {}).get("list", []):
            if var.get("type") == "query":
                sql = var["query"] if isinstance(var["query"], str) else var["query"].get("rawSql", "")
                queries.append((f"variable {var['name']}", {"rawSql": sql, "format": 1}))
                if not var.get("includeAll"):
                    # Like Grafana: a variable without "All" defaults to its first option.
                    values[var["name"]] = first_value(base, auth, sql) or "none"
        for name, value in overrides.items():
            if name in values:
                values[name] = value
        for panel in iter_panels(dash.get("panels", [])):
            for target in panel.get("targets", []):
                if target.get("rawSql"):
                    queries.append((f"panel '{panel.get('title')}' {target.get('refId')}", target))
        if not queries:
            print(f"  {uid}: no queries")
            errors += 1
        for label, target in queries:
            panel_title = label.split("'")[1] if label.startswith("panel '") else None
            body = {
                "from": "now-7d",
                "to": "now",
                "queries": [{
                    "refId": "A",
                    "datasource": {"type": "grafana-clickhouse-datasource", "uid": "clickhouse"},
                    "rawSql": substitute(target["rawSql"], values, alls),
                    "format": target.get("format", 1),
                    "queryType": target.get("queryType", "table"),
                    "editorType": "sql",
                    "intervalMs": 60000,
                    "maxDataPoints": 500,
                }],
            }
            status, result = request(base, auth, "/api/ds/query", body)
            res = (result or {}).get("results", {}).get("A", {})
            if status != 200 or res.get("error"):
                print(f"  {uid}: {label}: HTTP {status}: {res.get('error') or result}")
                errors += 1
                continue
            key = f"{uid}:{panel_title}"
            if key in expected:
                want = expected.pop(key)
                row = first_row(result)
                if as_number(want) is not None:
                    got = first_number(row)
                    ok = got is not None and abs(got - float(want)) <= max(abs(float(want)) * 0.01, 1e-9)
                else:
                    got = row[0] if row else None
                    ok = got == want
                if not ok:
                    print(f"  {uid}: {label}: expected {want}, got {got} (row: {row})")
                    errors += 1
        print(f"  {uid}: {len(queries)} queries checked")
    for key in expected:
        print(f"  expectation for unknown panel: {key}")
        errors += 1
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main(*sys.argv[1:]))
