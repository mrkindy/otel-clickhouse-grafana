"""Check that every provisioned Claude Code dashboard exists and that every
panel query runs without error against the live ClickHouse datasource.

Grafana's frontend normally substitutes dashboard variables before sending a
query; this script does the same with each variable's "All" value (or its
default), then sends the SQL through /api/ds/query so the ClickHouse plugin's
backend expands the $__ macros exactly as it would for a browser.

Usage: python3 check_dashboards.py http://127.0.0.1:18080 admin <password> [uid:Panel title=value ...]
Each optional expectation asserts the first value returned by that panel (within 1%).
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


def substitute(sql, values):
    for name, value in values.items():
        sql = re.sub(r"\$\{" + re.escape(name) + r"(:[a-z]+)?\}", value, sql)
        sql = re.sub(r"\$" + re.escape(name) + r"\b", value, sql)
    return sql


def first_number(result):
    try:
        values = result["results"]["A"]["frames"][0]["data"]["values"]
        return float(values[-1][0])
    except (KeyError, IndexError, TypeError, ValueError):
        return None


def main(base, user, password, *expectations):
    expected = {}
    for e in expectations:
        key, value = e.rsplit("=", 1)
        expected[key] = float(value)
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
        queries = []
        for var in dash.get("templating", {}).get("list", []):
            if var.get("type") == "query":
                sql = var["query"] if isinstance(var["query"], str) else var["query"].get("rawSql", "")
                queries.append((f"variable {var['name']}", {"rawSql": sql, "format": 1}))
                if not var.get("includeAll"):
                    # Like Grafana: a variable without "All" defaults to its first option.
                    values[var["name"]] = first_value(base, auth, sql) or "none"
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
                    "rawSql": substitute(target["rawSql"], values),
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
                got = first_number(result)
                want = expected.pop(key)
                if got is None or abs(got - want) > max(abs(want) * 0.01, 1e-9):
                    print(f"  {uid}: {label}: expected {want}, got {got}")
                    errors += 1
        print(f"  {uid}: {len(queries)} queries checked")
    for key in expected:
        print(f"  expectation for unknown panel: {key}")
        errors += 1
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main(*sys.argv[1:]))
