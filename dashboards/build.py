"""Generate the Claude Code Grafana dashboards.

Run:  python3 dashboards/build.py
Writes rootfs/etc/grafana/dashboards/*.json (commit the output).

Data model (created by the OpenTelemetry Collector's ClickHouse exporter):
  otel.otel_metrics_sum  delta counters (claude_code.cost.usage, ...): sum(Value)
  otel.otel_logs         Claude Code events; helper columns SessionId, PromptId,
                         Event, UserEmail, UserId are added by schema-tune.sh
"""
import json
import pathlib

OUT = pathlib.Path(__file__).resolve().parent.parent / "rootfs/etc/grafana/dashboards"
DS = {"type": "grafana-clickhouse-datasource", "uid": "clickhouse"}
SERVICES = "('claude-code', 'claude-code-desktop')"

# --- SQL building blocks --------------------------------------------------------
# Identity: e-mail when Claude Code knows it, otherwise the anonymous user.id.
M_USER = ("if(Attributes['user.email'] != '', Attributes['user.email'], "
          "if(ResourceAttributes['user.email'] != '', ResourceAttributes['user.email'], "
          "Attributes['user.id']))")
L_USER = "if(UserEmail != '', UserEmail, UserId)"
M_SESSION = "Attributes['session.id']"


# Claude Code sends delta counters by default, so each row is an increment and
# sum(Value) is the total. Rows from a client switched to cumulative temporality
# (AggregationTemporality = 2) are running totals and would inflate every sum.
DELTA = "AggregationTemporality = 1"


def metric_where(name):
    return (f"MetricName = '{name}' AND {DELTA} AND ServiceName IN {SERVICES} AND $__timeFilter(TimeUnix) "
            f"AND ('${{user}}' = '__all__' OR {M_USER} = '${{user}}')")


LOG_WHERE = (f"ServiceName IN {SERVICES} AND $__timeFilter(Timestamp) "
             f"AND ('${{user}}' = '__all__' OR {L_USER} = '${{user}}')")


# Startup bookkeeping events that would drown the interesting ones in a session timeline.
TIMELINE_FILTER = ("Event NOT IN ('hook_registered', 'hook_execution_start', 'plugin_loaded', "
                   "'managed_settings_resolved', 'retention_sweep', 'feedback_survey') "
                   "AND NOT (Event = 'mcp_server_connection' AND LogAttributes['error'] = '' "
                   "AND LogAttributes['error_code'] = '')")


def num(key):
    return f"toFloat64OrZero(LogAttributes['{key}'])"


# --- Panel helpers --------------------------------------------------------------
class Grid:
    """Places panels left-to-right, wrapping at 24 columns."""

    def __init__(self):
        self.x = 0
        self.y = 0
        self.row_h = 0
        self.next_id = 1

    def place(self, panel, w, h):
        if self.x + w > 24:
            self.x = 0
            self.y += self.row_h
            self.row_h = 0
        panel["gridPos"] = {"x": self.x, "y": self.y, "w": w, "h": h}
        panel["id"] = self.next_id
        self.next_id += 1
        self.x += w
        self.row_h = max(self.row_h, h)
        return panel

    def newline(self):
        if self.x:
            self.x = 0
            self.y += self.row_h
            self.row_h = 0


def target(sql, fmt="table"):
    fmt_code = {"timeseries": 0, "table": 1, "logs": 2}[fmt]
    return {"refId": "A", "datasource": DS, "editorType": "sql", "format": fmt_code,
            "queryType": fmt if fmt != "timeseries" else "timeseries", "rawSql": " ".join(sql.split())}


def stat(title, sql, unit="short", decimals=None, description=""):
    p = {"type": "stat", "title": title, "description": description, "datasource": DS,
         "targets": [target(sql)],
         "options": {"reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False},
                     "colorMode": "none", "graphMode": "none", "textMode": "value", "justifyMode": "center"},
         "fieldConfig": {"defaults": {"unit": unit, "noValue": "0"}, "overrides": []}}
    if decimals is not None:
        p["fieldConfig"]["defaults"]["decimals"] = decimals
    if unit == "string":
        # Text values are not "numeric fields"; tell the stat panel to show any field.
        p["options"]["reduceOptions"]["fields"] = "/.*/"
        p["options"]["textMode"] = "value"
        p["options"]["wideLayout"] = True
    return p


def timeseries(title, sql, unit="short", stack=True, bars=False, description="", label=None):
    p = {"type": "timeseries", "title": title, "description": description, "datasource": DS,
            "targets": [target(sql, "timeseries")],
            "options": {"legend": {"displayMode": "list", "placement": "bottom", "showLegend": True},
                        "tooltip": {"mode": "multi", "sort": "desc"}},
            "fieldConfig": {"defaults": {
                "unit": unit,
                "custom": {"drawStyle": "bars" if bars else "line", "fillOpacity": 60 if bars else 15,
                           "lineWidth": 1, "stacking": {"mode": "normal" if stack else "none"},
                           "showPoints": "never", "spanNulls": False}},
                "overrides": []}}
    if label:
        # Series are split by the string column `label`; show only its value in the legend.
        p["fieldConfig"]["defaults"]["displayName"] = "${__field.labels." + label + "}"
    return p


def table(title, sql, overrides=None, description="", sort=None):
    p = {"type": "table", "title": title, "description": description, "datasource": DS,
         "targets": [target(sql)],
         "options": {"showHeader": True, "cellHeight": "sm", "footer": {"show": False}},
         "fieldConfig": {"defaults": {"custom": {"align": "auto", "filterable": True}}, "overrides": overrides or []}}
    if sort:
        p["options"]["sortBy"] = [{"displayName": sort, "desc": True}]
    return p


def bars(title, sql, unit="short", description=""):
    return {"type": "barchart", "title": title, "description": description, "datasource": DS,
            "targets": [target(sql)],
            "options": {"orientation": "horizontal", "showValue": "auto", "legend": {"showLegend": False},
                        "xTickLabelRotation": 0, "barWidth": 0.8},
            "fieldConfig": {"defaults": {"unit": unit, "color": {"mode": "palette-classic"}}, "overrides": []}}


def pie(title, sql, unit="short"):
    return {"type": "piechart", "title": title, "datasource": DS, "targets": [target(sql)],
            "options": {"reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": True},
                        "pieType": "donut", "legend": {"displayMode": "table", "placement": "bottom",
                                                       "values": ["value", "percent"], "showLegend": True}},
            "fieldConfig": {"defaults": {"unit": unit}, "overrides": []}}


def unit_override(field, unit, decimals=None):
    props = [{"id": "unit", "value": unit}]
    if decimals is not None:
        props.append({"id": "decimals", "value": decimals})
    return {"matcher": {"id": "byName", "options": field}, "properties": props}


def link_override(field, title, url):
    return {"matcher": {"id": "byName", "options": field},
            "properties": [{"id": "links", "value": [{"title": title, "url": url}]}]}


def width_override(field, width):
    return {"matcher": {"id": "byName", "options": field},
            "properties": [{"id": "custom.width", "value": width}]}


USER_VAR = {
    "name": "user", "label": "User", "type": "query", "datasource": DS,
    "query": (f"SELECT DISTINCT {L_USER} FROM otel.otel_logs WHERE ServiceName IN {SERVICES} "
              f"AND $__timeFilter(Timestamp) AND {L_USER} != '' ORDER BY 1"),
    "includeAll": True, "allValue": "__all__", "multi": False, "refresh": 2, "sort": 1,
    "current": {"text": "All", "value": "$__all"},
}

SESSION_LINK = "/d/claude-code-session-detail?var-session=${__value.raw}&${__url_time_range}"
DASH_LINKS = [{"title": "Claude Code", "type": "dashboards", "tags": ["claude-code"],
               "asDropdown": False, "includeVars": True, "keepTime": True}]


def dashboard(uid, title, description, panels, variables, time_from="now-7d"):
    return {
        "uid": uid, "title": title, "description": description, "tags": ["claude-code"],
        "editable": False, "graphTooltip": 1, "schemaVersion": 41, "version": 1,
        "time": {"from": time_from, "to": "now"}, "refresh": "1m",
        "timepicker": {}, "timezone": "browser", "links": DASH_LINKS,
        "templating": {"list": variables}, "annotations": {"list": []},
        "panels": panels,
    }


# --- Overview ---------------------------------------------------------------------
def overview():
    g = Grid()
    cost = metric_where("claude_code.cost.usage")
    tokens = metric_where("claude_code.token.usage")
    p = [
        g.place(stat("Total cost", f"SELECT sum(Value) FROM otel.otel_metrics_sum WHERE {cost}",
                     "currencyUSD", 2), 4, 4),
        g.place(stat("Tokens", f"SELECT sum(Value) FROM otel.otel_metrics_sum WHERE {tokens}"), 4, 4),
        g.place(stat("Sessions", f"SELECT uniqExact(SessionId) FROM otel.otel_logs WHERE {LOG_WHERE} AND SessionId != ''"),
                4, 4),
        g.place(stat("Active users", f"SELECT uniqExact({L_USER}) FROM otel.otel_logs WHERE {LOG_WHERE} AND {L_USER} != ''"),
                4, 4),
        g.place(stat("Cache hit rate",
                     f"SELECT sumIf(Value, Attributes['type'] = 'cacheRead') / nullIf(sumIf(Value, Attributes['type'] IN "
                     f"('input', 'cacheRead', 'cacheCreation')), 0) FROM otel.otel_metrics_sum WHERE {tokens}",
                     "percentunit", 1,
                     "Share of input tokens served from the prompt cache (cacheRead / (input + cacheRead + cacheCreation))."),
                4, 4),
        g.place(stat("API errors", f"SELECT countIf(Event = 'api_error') FROM otel.otel_logs WHERE {LOG_WHERE}"), 4, 4),
    ]
    g.newline()
    p += [
        g.place(timeseries("Cost by model",
                           f"SELECT $__timeInterval(TimeUnix) AS time, Attributes['model'] AS model, sum(Value) AS cost "
                           f"FROM otel.otel_metrics_sum WHERE {cost} GROUP BY time, model ORDER BY time",
                           "currencyUSD", bars=True, label="model"), 12, 9),
        g.place(timeseries("Tokens by type",
                           f"SELECT $__timeInterval(TimeUnix) AS time, Attributes['type'] AS type, sum(Value) AS tokens "
                           f"FROM otel.otel_metrics_sum WHERE {tokens} GROUP BY time, type ORDER BY time",
                           bars=True, label="type"), 12, 9),
    ]
    g.newline()
    p += [
        g.place(pie("Cost by model",
                    f"SELECT Attributes['model'] AS model, sum(Value) AS cost FROM otel.otel_metrics_sum "
                    f"WHERE {cost} GROUP BY model ORDER BY cost DESC", "currencyUSD"), 8, 9),
        g.place(pie("Cost by source",
                    f"SELECT if(Attributes['query_source'] != '', Attributes['query_source'], 'main') AS source, "
                    f"sum(Value) AS cost FROM otel.otel_metrics_sum WHERE {cost} GROUP BY source ORDER BY cost DESC",
                    "currencyUSD"), 8, 9),
        g.place(bars("Cost by user",
                     f"SELECT {M_USER} AS user, sum(Value) AS cost FROM otel.otel_metrics_sum WHERE {cost} "
                     f"GROUP BY user ORDER BY cost DESC LIMIT 15", "currencyUSD"), 8, 9),
    ]
    g.newline()
    p.append(g.place(table(
        "Most expensive sessions",
        f"SELECT SessionId AS session, any({L_USER}) AS user, min(Timestamp) AS started, "
        f"sumIf({num('cost_usd')}, Event = 'api_request') AS cost_usd, countIf(Event = 'user_prompt') AS prompts, "
        f"countIf(Event = 'tool_result') AS tool_calls FROM otel.otel_logs WHERE {LOG_WHERE} AND SessionId != '' "
        f"GROUP BY SessionId ORDER BY cost_usd DESC LIMIT 10",
        [unit_override("cost_usd", "currencyUSD", 2), link_override("session", "Open session", SESSION_LINK)]),
        24, 9))
    return dashboard("claude-code-overview", "Claude Code — Overview",
                     "Spend, token use and activity across all Claude Code sessions.", p, [USER_VAR])


# --- Sessions ---------------------------------------------------------------------
def sessions():
    g = Grid()
    sql = (
        f"SELECT SessionId AS session, any({L_USER}) AS user, min(Timestamp) AS started, "
        f"dateDiff('second', min(Timestamp), max(Timestamp)) AS duration, "
        f"sumIf({num('cost_usd')}, Event = 'api_request') AS cost_usd, "
        f"sumIf({num('input_tokens')} + {num('output_tokens')} + {num('cache_read_tokens')} + "
        f"{num('cache_creation_tokens')}, Event = 'api_request') AS tokens, "
        f"countIf(Event = 'user_prompt') AS prompts, countIf(Event = 'api_request') AS api_calls, "
        f"countIf(Event = 'tool_result') AS tool_calls, "
        f"countIf(Event = 'api_error' OR (Event = 'tool_result' AND LogAttributes['success'] = 'false')) AS errors, "
        f"countIf(Event = 'tool_decision' AND LogAttributes['decision'] = 'reject') AS rejected, "
        f"anyIf(LogAttributes['model'], Event = 'api_request' AND LogAttributes['query_source'] IN ('main', '')) AS model, "
        f"any(ResourceAttributes['service.version']) AS version "
        f"FROM otel.otel_logs WHERE {LOG_WHERE} AND SessionId != '' "
        f"GROUP BY SessionId ORDER BY started DESC LIMIT 1000")
    p = [
        g.place(stat("Sessions", f"SELECT uniqExact(SessionId) FROM otel.otel_logs WHERE {LOG_WHERE} AND SessionId != ''"),
                6, 4),
        g.place(stat("Prompts", f"SELECT countIf(Event = 'user_prompt') FROM otel.otel_logs WHERE {LOG_WHERE}"), 6, 4),
        g.place(stat("Avg cost per session",
                     f"SELECT sumIf({num('cost_usd')}, Event = 'api_request') / nullIf(uniqExactIf(SessionId, SessionId != ''), 0) "
                     f"FROM otel.otel_logs WHERE {LOG_WHERE}", "currencyUSD", 2), 6, 4),
        g.place(stat("Tool calls", f"SELECT countIf(Event = 'tool_result') FROM otel.otel_logs WHERE {LOG_WHERE}"), 6, 4),
    ]
    g.newline()
    p.append(g.place(table("Sessions", sql, [
        link_override("session", "Open session", SESSION_LINK),
        unit_override("cost_usd", "currencyUSD", 3),
        unit_override("duration", "s"),
        width_override("session", 300),
        width_override("started", 190),
    ], "One row per session. Click a session id for its timeline.", sort="started"), 24, 20))
    return dashboard("claude-code-sessions", "Claude Code — Sessions",
                     "Every Claude Code session with its cost, activity and errors.", p, [USER_VAR])


# --- Session detail -----------------------------------------------------------
def session_detail():
    g = Grid()
    where = f"ServiceName IN {SERVICES} AND SessionId = '${{session}}'"
    session_var = {
        "name": "session", "label": "Session", "type": "query", "datasource": DS,
        "query": (f"SELECT SessionId FROM otel.otel_logs WHERE ServiceName IN {SERVICES} AND SessionId != '' "
                  f"AND $__timeFilter(Timestamp) GROUP BY SessionId ORDER BY max(Timestamp) DESC LIMIT 300"),
        "includeAll": False, "multi": False, "refresh": 2, "sort": 0,
        "current": {}, "options": [],
    }
    p = [
        g.place(stat("User", f"SELECT any({L_USER}) FROM otel.otel_logs WHERE {where}", "string"), 6, 4),
        g.place(stat("Cost", f"SELECT sumIf({num('cost_usd')}, Event = 'api_request') FROM otel.otel_logs WHERE {where}",
                     "currencyUSD", 2), 3, 4),
        g.place(stat("Duration", f"SELECT dateDiff('second', min(Timestamp), max(Timestamp)) FROM otel.otel_logs WHERE {where}",
                     "s"), 3, 4),
        g.place(stat("Prompts", f"SELECT countIf(Event = 'user_prompt') FROM otel.otel_logs WHERE {where}"), 3, 4),
        g.place(stat("API calls", f"SELECT countIf(Event = 'api_request') FROM otel.otel_logs WHERE {where}"), 3, 4),
        g.place(stat("Tool calls", f"SELECT countIf(Event = 'tool_result') FROM otel.otel_logs WHERE {where}"), 3, 4),
        g.place(stat("Errors",
                     f"SELECT countIf(Event = 'api_error' OR (Event = 'tool_result' AND LogAttributes['success'] = 'false')) "
                     f"FROM otel.otel_logs WHERE {where}"), 3, 4),
    ]
    g.newline()
    p.append(g.place(table(
        "Prompts in this session",
        f"SELECT PromptId AS prompt, min(Timestamp) AS started, "
        f"dateDiff('millisecond', min(Timestamp), max(Timestamp)) / 1000 AS duration, "
        f"nullIf(anyIf(LogAttributes['prompt'], Event = 'user_prompt'), '<REDACTED>') AS prompt_text, "
        f"maxIf({num('prompt_length')}, Event = 'user_prompt') AS prompt_length, "
        f"countIf(Event = 'api_request') AS api_calls, countIf(Event = 'tool_result') AS tool_calls, "
        f"sumIf({num('cost_usd')}, Event = 'api_request') AS cost_usd, "
        f"countIf(Event = 'api_error' OR (Event = 'tool_result' AND LogAttributes['success'] = 'false')) AS errors "
        f"FROM otel.otel_logs WHERE {where} AND PromptId != '' GROUP BY PromptId ORDER BY started",
        [unit_override("cost_usd", "currencyUSD", 3), unit_override("duration", "s"), width_override("prompt", 120)],
        "Grouped by prompt.id. prompt_text is only filled when developers enable OTEL_LOG_USER_PROMPTS=1."), 24, 9))
    p.append(g.place(table(
        "Timeline",
        f"SELECT Timestamp AS time, substring(PromptId, 1, 8) AS prompt, replaceOne(Event, 'claude_code.', '') AS event, "
        f"LogAttributes['tool_name'] AS tool, LogAttributes['model'] AS model, "
        f"if(LogAttributes['duration_ms'] != '', {num('duration_ms')}, NULL) AS duration_ms, "
        f"if(Event = 'api_request', {num('cost_usd')}, NULL) AS cost_usd, "
        f"multiIf(Event = 'tool_result', if(LogAttributes['success'] = 'true', 'ok', 'failed'), "
        f"Event = 'tool_decision', LogAttributes['decision'], Event = 'api_error', LogAttributes['status_code'], '') AS status, "
        f"multiIf(LogAttributes['error'] != '', LogAttributes['error'], "
        f"Event = 'tool_decision', LogAttributes['source'], "
        f"Event = 'api_request', concat(toString({num('input_tokens')} + {num('cache_read_tokens')} + "
        f"{num('cache_creation_tokens')}), ' in / ', LogAttributes['output_tokens'], ' out'), "
        f"Event = 'user_prompt' AND LogAttributes['prompt'] != '<REDACTED>', LogAttributes['prompt'], "
        f"Event = 'hook_execution_complete', LogAttributes['hook_event'], '') AS details "
        f"FROM otel.otel_logs WHERE {where} AND {TIMELINE_FILTER} "
        f"ORDER BY Timestamp, toUInt64OrZero(LogAttributes['event.sequence']) LIMIT 5000",
        [unit_override("cost_usd", "currencyUSD", 4), unit_override("duration_ms", "ms"),
         width_override("time", 190), width_override("prompt", 90), width_override("event", 200),
         width_override("tool", 120), width_override("model", 170)],
        "Events of the session in order. Startup bookkeeping (hook/plugin registration, MCP connections "
        "that succeeded, settings resolution) is hidden."), 24, 16))
    g.newline()
    p += [
        g.place(bars("Time spent per tool",
                     f"SELECT LogAttributes['tool_name'] AS tool, sum({num('duration_ms')}) AS total_ms "
                     f"FROM otel.otel_logs WHERE {where} AND Event = 'tool_result' GROUP BY tool ORDER BY total_ms DESC",
                     "ms"), 12, 9),
        g.place(bars("Cost per model",
                     f"SELECT LogAttributes['model'] AS model, sum({num('cost_usd')}) AS cost "
                     f"FROM otel.otel_logs WHERE {where} AND Event = 'api_request' GROUP BY model ORDER BY cost DESC",
                     "currencyUSD"), 12, 9),
    ]
    return dashboard("claude-code-session-detail", "Claude Code — Session Detail",
                     "The full timeline of one Claude Code session, grouped by prompt.", p, [session_var],
                     time_from="now-30d")


# --- Team -----------------------------------------------------------------------
def team():
    g = Grid()
    cost = metric_where("claude_code.cost.usage")
    per_user = (
        f"SELECT u AS user, cost_usd, tokens, sessions, active_hours, lines_added, commits, pull_requests FROM ("
        f"SELECT {M_USER} AS u, "
        f"sumIf(Value, MetricName = 'claude_code.cost.usage') AS cost_usd, "
        f"sumIf(Value, MetricName = 'claude_code.token.usage') AS tokens, "
        f"uniqExactIf({M_SESSION}, {M_SESSION} != '') AS sessions, "
        f"sumIf(Value, MetricName = 'claude_code.active_time.total') / 3600 AS active_hours, "
        f"sumIf(Value, MetricName = 'claude_code.lines_of_code.count' AND Attributes['type'] = 'added') AS lines_added, "
        f"sumIf(Value, MetricName = 'claude_code.commit.count') AS commits, "
        f"sumIf(Value, MetricName = 'claude_code.pull_request.count') AS pull_requests "
        f"FROM otel.otel_metrics_sum WHERE ServiceName IN {SERVICES} AND {DELTA} AND $__timeFilter(TimeUnix) "
        f"AND MetricName LIKE 'claude_code.%' GROUP BY u) WHERE u != '' "
        f"AND ('${{user}}' = '__all__' OR user = '${{user}}') ORDER BY cost_usd DESC")
    p = [
        g.place(table("Per user", per_user, [unit_override("cost_usd", "currencyUSD", 2),
                                             unit_override("active_hours", "h", 1)],
                      "Totals for the selected time range.", sort="cost_usd"), 24, 10),
    ]
    g.newline()
    p += [
        g.place(timeseries("Cost per user",
                           f"SELECT $__timeInterval(TimeUnix) AS time, {M_USER} AS user, sum(Value) AS cost "
                           f"FROM otel.otel_metrics_sum WHERE {cost} GROUP BY time, user ORDER BY time",
                           "currencyUSD", bars=True, label="user"), 12, 9),
        g.place(timeseries("Active time per user",
                           f"SELECT $__timeInterval(TimeUnix) AS time, {M_USER} AS user, sum(Value) AS seconds "
                           f"FROM otel.otel_metrics_sum WHERE {metric_where('claude_code.active_time.total')} "
                           f"GROUP BY time, user ORDER BY time", "s", bars=True, label="user"), 12, 9),
    ]
    g.newline()
    p += [
        g.place(bars("Sessions per user",
                     f"SELECT {L_USER} AS user, uniqExact(SessionId) AS sessions FROM otel.otel_logs "
                     f"WHERE {LOG_WHERE} AND SessionId != '' GROUP BY user ORDER BY sessions DESC LIMIT 20"), 12, 9),
        g.place(bars("Tokens per user",
                     f"SELECT {M_USER} AS user, sum(Value) AS tokens FROM otel.otel_metrics_sum "
                     f"WHERE {metric_where('claude_code.token.usage')} GROUP BY user ORDER BY tokens DESC LIMIT 20"),
                12, 9),
    ]
    return dashboard("claude-code-team", "Claude Code — Team",
                     "Compare Claude Code usage and cost across developers.", p, [USER_VAR], time_from="now-30d")


# --- Productivity ---------------------------------------------------------------
def productivity():
    g = Grid()
    loc = metric_where("claude_code.lines_of_code.count")
    p = [
        g.place(stat("Lines added", f"SELECT sumIf(Value, Attributes['type'] = 'added') FROM otel.otel_metrics_sum WHERE {loc}"),
                4, 4),
        g.place(stat("Lines removed",
                     f"SELECT sumIf(Value, Attributes['type'] = 'removed') FROM otel.otel_metrics_sum WHERE {loc}"), 4, 4),
        g.place(stat("Commits", f"SELECT sum(Value) FROM otel.otel_metrics_sum WHERE {metric_where('claude_code.commit.count')}"),
                4, 4),
        g.place(stat("Pull requests",
                     f"SELECT sum(Value) FROM otel.otel_metrics_sum WHERE {metric_where('claude_code.pull_request.count')}"),
                4, 4),
        g.place(stat("Your time",
                     f"SELECT sumIf(Value, Attributes['type'] = 'user') FROM otel.otel_metrics_sum "
                     f"WHERE {metric_where('claude_code.active_time.total')}", "s",
                     description="Time developers were actively interacting (typing, reading)."), 4, 4),
        g.place(stat("Claude time",
                     f"SELECT sumIf(Value, Attributes['type'] = 'cli') FROM otel.otel_metrics_sum "
                     f"WHERE {metric_where('claude_code.active_time.total')}", "s",
                     description="Time Claude Code was working (tool runs, model responses)."), 4, 4),
    ]
    g.newline()
    p += [
        g.place(timeseries("Lines of code",
                           f"SELECT $__timeInterval(TimeUnix) AS time, Attributes['type'] AS type, sum(Value) AS lines "
                           f"FROM otel.otel_metrics_sum WHERE {loc} GROUP BY time, type ORDER BY time",
                           bars=True, stack=False, label="type"), 12, 9),
        g.place(timeseries("Commits and pull requests",
                           f"SELECT $__timeInterval(TimeUnix) AS time, replaceOne(replaceOne(MetricName, 'claude_code.', ''), "
                           f"'.count', '') AS kind, sum(Value) AS count FROM otel.otel_metrics_sum "
                           f"WHERE MetricName IN ('claude_code.commit.count', 'claude_code.pull_request.count') AND {DELTA} "
                           f"AND ServiceName IN {SERVICES} AND $__timeFilter(TimeUnix) "
                           f"AND ('${{user}}' = '__all__' OR {M_USER} = '${{user}}') "
                           f"GROUP BY time, kind ORDER BY time", bars=True, stack=False, label="kind"), 12, 9),
    ]
    g.newline()
    p += [
        g.place(table("Edit suggestions accepted vs rejected",
                      f"SELECT if(Attributes['language'] != '', Attributes['language'], 'unknown') AS language, "
                      f"Attributes['tool_name'] AS tool, sumIf(Value, Attributes['decision'] = 'accept') AS accepted, "
                      f"sumIf(Value, Attributes['decision'] = 'reject') AS rejected, "
                      f"accepted / nullIf(accepted + rejected, 0) AS accept_rate FROM otel.otel_metrics_sum "
                      f"WHERE {metric_where('claude_code.code_edit_tool.decision')} GROUP BY language, tool "
                      f"ORDER BY accepted + rejected DESC",
                      [unit_override("accept_rate", "percentunit", 0)],
                      "Edit / Write / NotebookEdit permission decisions, by file language.", sort="accepted"), 12, 10),
        g.place(bars("Lines added per user",
                     f"SELECT {M_USER} AS user, sumIf(Value, Attributes['type'] = 'added') AS added, "
                     f"sumIf(Value, Attributes['type'] = 'removed') AS removed FROM otel.otel_metrics_sum "
                     f"WHERE {loc} GROUP BY user ORDER BY added DESC LIMIT 20"), 12, 10),
    ]
    return dashboard("claude-code-productivity", "Claude Code — Productivity",
                     "Code output and time saved with Claude Code.", p, [USER_VAR], time_from="now-30d")


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    for build in (overview, sessions, session_detail, team, productivity):
        d = build()
        path = OUT / f"{d['uid']}.json"
        path.write_text(json.dumps(d, indent=2, ensure_ascii=False) + "\n")
        print(f"wrote {path.relative_to(OUT.parents[3])}")


if __name__ == "__main__":
    main()
