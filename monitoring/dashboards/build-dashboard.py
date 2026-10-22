#!/usr/bin/env python3
"""Builds monitoring/dashboards/aip-platform-overview.json (Grafana dashboard as code).

Edit the panels here, run `python3 monitoring/dashboards/build-dashboard.py`, and commit both files.
Queries use the dashboard variables: $env (sit-01 or sit-02), $prometheus and $loki (data sources),
and $applicationId (free text for the cross-log panel).
"""
import json
from pathlib import Path

PROM = {"type": "prometheus", "uid": "${prometheus}"}
LOKI = {"type": "loki", "uid": "${loki}"}

AUDIT = '{namespace="$env-api", container="aip-audit-service"}'
API = '{namespace="$env-api", container="aip-api"}'
CHAT = '{namespace="$env-api", container="aip-chat-api"}'
BEYLA = 'k8s_namespace_name=~"$env-(dip|api)"'
K8S = 'namespace=~"$env-.*"'

panels = []
next_id = 1
y = 0


def add(panel, w, h, x):
    global next_id
    panel["id"] = next_id
    next_id += 1
    panel["gridPos"] = {"h": h, "w": w, "x": x, "y": y}
    panels.append(panel)


def row(title):
    global y
    add({"type": "row", "title": title, "collapsed": False, "panels": []}, 24, 1, 0)
    y += 1


def target(ds, expr, legend="", instant=False, query_type=None):
    t = {"datasource": ds, "expr": expr, "refId": "A"}
    if legend:
        t["legendFormat"] = legend
    if instant:
        t["instant"] = True
        t["range"] = False
    if query_type:
        t["queryType"] = query_type
    return t


def stat(title, ds, expr, description, unit="none", thresholds=None, instant=True):
    steps = thresholds or [{"color": "blue", "value": None}]
    return {
        "type": "stat", "title": title, "description": description, "datasource": ds,
        "targets": [target(ds, expr, instant=instant, query_type="instant" if ds is LOKI else None)],
        "fieldConfig": {"defaults": {"unit": unit, "noValue": "0",
                                     "thresholds": {"mode": "absolute", "steps": steps}},
                        "overrides": []},
        "options": {"reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False},
                    "colorMode": "background", "graphMode": "none", "textMode": "value"},
    }


def timeseries(title, ds, expr, legend, description, unit="none", stack=False):
    return {
        "type": "timeseries", "title": title, "description": description, "datasource": ds,
        "targets": [target(ds, expr, legend=legend, query_type="range" if ds is LOKI else None)],
        "fieldConfig": {"defaults": {"unit": unit,
                                     "custom": {"drawStyle": "line", "lineWidth": 2, "fillOpacity": 15,
                                                "stacking": {"mode": "normal" if stack else "none"}}},
                        "overrides": []},
        "options": {"legend": {"displayMode": "list", "placement": "bottom"}, "tooltip": {"mode": "multi"}},
    }


def bars(title, ds, expr, legend, description, unit="none"):
    return {
        "type": "bargauge", "title": title, "description": description, "datasource": ds,
        "targets": [target(ds, expr, legend=legend, instant=True, query_type="instant" if ds is LOKI else None)],
        "fieldConfig": {"defaults": {"unit": unit, "min": 0,
                                     "thresholds": {"mode": "absolute", "steps": [{"color": "blue", "value": None}]}},
                        "overrides": []},
        "options": {"orientation": "horizontal", "displayMode": "gradient", "showUnfilled": True,
                    "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False}},
    }


def logs(title, expr, description):
    return {
        "type": "logs", "title": title, "description": description, "datasource": LOKI,
        "targets": [target(LOKI, expr, query_type="range")],
        "options": {"showTime": True, "wrapLogMessage": True, "sortOrder": "Descending",
                    "enableLogDetails": True, "prettifyLogMessage": False},
    }


RED = [{"color": "green", "value": None}, {"color": "red", "value": 1}]
AMBER = [{"color": "green", "value": None}, {"color": "orange", "value": 1}]

# --- Mortgage decisions, from the audit service's logs (one line per audited Kafka event) ---
row("Mortgage decisions (audit service logs)")
add(stat("Decisions audited", LOKI,
         f'sum(count_over_time({AUDIT} |= "Audited" [$__range]))',
         "AipDecisionMade events stored in the audit trail in the selected time range."), 4, 5, 0)
add(stat("Duplicates ignored", LOKI,
         f'sum(count_over_time({AUDIT} |= "Duplicate event" [$__range]))',
         "Events Kafka delivered again and the audit service stored only once (at-least-once delivery working).",
         thresholds=AMBER), 4, 5, 4)
add(stat("Dead-lettered", LOKI,
         f'sum(count_over_time({AUDIT} |= "dead-letter topic" [$__range]))',
         "Events that broke the contract and went to aip.decisions.dlq. Should be 0.", thresholds=RED), 4, 5, 8)
add(stat("Not saved or published", LOKI,
         f'sum(count_over_time({API} |~ "was not (saved|published)" [$__range]))',
         "Decisions aip-api could not save to MongoDB or publish to Kafka. Should be 0.", thresholds=RED), 4, 5, 12)
add(bars("Decisions by outcome", LOKI,
         f'sum by (decision) (count_over_time({AUDIT} |= "Audited" | regexp "\\((?P<decision>Accepted|Referred|Declined)\\)" [$__range]))',
         "{{decision}}", "Accepted, Referred and Declined, read from the audit log message (works with text or JSON logs)."), 8, 5, 16)
y += 5
add(timeseries("Decisions over time", LOKI,
               f'sum by (decision) (count_over_time({AUDIT} |= "Audited" | regexp "\\((?P<decision>Accepted|Referred|Declined)\\)" [$__auto]))',
               "{{decision}}", "Audited decisions per interval, by outcome.", stack=True), 24, 7, 0)
y += 7

# --- Chatbot, from aip-chat-api's logs (intent and confidence only, never the customer's words) ---
row("Chatbot (aip-chat-api logs)")
add(stat("Questions", LOKI,
         f'sum(count_over_time({CHAT} |= "Chat intent" [$__range]))',
         "Chat messages answered in the selected time range."), 4, 6, 0)
add(stat("Fallback rate", LOKI,
         f'sum(count_over_time({CHAT} |= "Chat intent" | regexp "Chat intent (?P<intent>[a-z_]+)" | intent="fallback" [$__range]))'
         f' / sum(count_over_time({CHAT} |= "Chat intent" [$__range]))',
         "Share of questions the bot could not match to an intent. A rising rate means new training data is needed.",
         unit="percentunit",
         thresholds=[{"color": "green", "value": None}, {"color": "orange", "value": 0.2},
                     {"color": "red", "value": 0.4}]), 4, 6, 4)
add(stat("Personal data blocked", LOKI,
         f'sum(count_over_time({CHAT} |= "Chat intent" | regexp "Chat intent (?P<intent>[a-z_]+)" | intent="personal_data_blocked" [$__range]))',
         "Messages with card, account, sort code or National Insurance numbers, blocked by the guardrail.",
         thresholds=AMBER), 4, 6, 8)
add(bars("Questions by intent", LOKI,
         f'sum by (intent) (count_over_time({CHAT} |= "Chat intent" | regexp "Chat intent (?P<intent>[a-z_]+)" [$__range]))',
         "{{intent}}", "What customers ask about, including handovers (speak_to_advisor, complaint)."), 12, 6, 12)
y += 6

# --- Services, from Beyla (eBPF, no code changes) ---
row("Services (Beyla automatic instrumentation)")
add(timeseries("Requests per second", PROM,
               f'sum by (service_name) (rate(http_server_request_duration_seconds_count{{{BEYLA}}}[$__rate_interval]))',
               "{{service_name}}", "HTTP requests handled by each service.", unit="reqps"), 8, 7, 0)
add(timeseries("Server errors (5xx)", PROM,
               f'sum by (service_name) (rate(http_server_request_duration_seconds_count{{{BEYLA}, http_response_status_code=~"5.."}}[$__rate_interval]))'
               f' / sum by (service_name) (rate(http_server_request_duration_seconds_count{{{BEYLA}}}[$__rate_interval]))',
               "{{service_name}}", "Share of requests that failed with a 5xx status.", unit="percentunit"), 8, 7, 8)
add(timeseries("Response time p95", PROM,
               f'histogram_quantile(0.95, sum by (le, service_name) (rate(http_server_request_duration_seconds_bucket{{{BEYLA}}}[$__rate_interval])))',
               "{{service_name}}", "95% of requests finish within this time.", unit="s"), 8, 7, 16)
y += 7

# --- Kubernetes health ---
row("Kubernetes")
add(bars("Restarts", PROM,
         f'sum by (container) (increase(kube_pod_container_status_restarts_total{{{K8S}}}[$__range]))',
         "{{container}}", "Container restarts in the selected time range."), 8, 7, 0)
add(stat("OOMKilled containers", PROM,
         f'sum(kube_pod_container_status_last_terminated_reason{{{K8S}, reason="OOMKilled"}}) or vector(0)',
         "Containers whose last restart was caused by running out of memory.", thresholds=RED), 4, 7, 8)
add(timeseries("Memory by container", PROM,
               f'sum by (container) (container_memory_working_set_bytes{{{K8S}, container!=""}})',
               "{{container}}", "Working set memory, compared against the 512Mi limits.", unit="bytes"), 12, 7, 12)
y += 7

# --- Logs ---
row("Logs")
add(logs("Warnings and errors", '{namespace=~"$env-(dip|api)"} | json | __error__="" | LogLevel=~"Warning|Error|Critical"',
         "Warning and error logs from the .NET services (JSON logs)."), 12, 10, 0)
add(logs("Logs for one application ID", '{namespace=~"$env-.*"} |= "$applicationId"',
         "Cross-log view: type an application ID (e.g. AIP-20261021-1A2B3C4D) in the box at the top."), 12, 10, 12)
y += 10

dashboard = {
    "uid": "aip-platform-overview",
    "title": "AIP Platform Overview",
    "description": "Mortgage decisions, chatbot, service health (Beyla) and Kubernetes for the AIP platform.",
    "tags": ["aip", "kubernetes", "kafka"],
    "timezone": "browser",
    "schemaVersion": 39,
    "version": 1,
    "editable": True,
    "refresh": "1m",
    "time": {"from": "now-1h", "to": "now"},
    "templating": {"list": [
        {"name": "prometheus", "label": "Metrics", "type": "datasource", "query": "prometheus",
         "regex": "/grafanacloud-.*-prom$/", "current": {}, "hide": 0},
        {"name": "loki", "label": "Logs", "type": "datasource", "query": "loki", "regex": "/grafanacloud-.*-logs$/", "current": {}, "hide": 0},
        {"name": "env", "label": "Environment", "type": "custom", "query": "sit-01,sit-02",
         "current": {"text": "sit-01", "value": "sit-01"},
         "options": [{"text": "sit-01", "value": "sit-01", "selected": True},
                     {"text": "sit-02", "value": "sit-02", "selected": False}], "hide": 0},
        {"name": "applicationId", "label": "Application ID", "type": "textbox", "query": "AIP-",
         "current": {"text": "AIP-", "value": "AIP-"}, "hide": 0},
    ]},
    "annotations": {"list": []},
    "panels": panels,
}

out = Path(__file__).with_name("aip-platform-overview.json")
out.write_text(json.dumps(dashboard, indent=2) + "\n")
print(f"Wrote {out} ({len(panels)} panels)")
