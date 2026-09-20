#!/usr/bin/env python3
"""Self-check for grafana-apply.py.  Run: python3 scripts/test_grafana_apply.py

Covers the pure half: turning the repo's provisioning-format files into the bodies Grafana's
HTTP API takes. No request is made. The half that talks to Grafana Cloud is proved by
running it once against the account and reading the result back (docs/monitoring.md).
"""
import importlib.util
import pathlib

HERE = pathlib.Path(__file__).parent
spec = importlib.util.spec_from_file_location("grafana_apply", HERE / "grafana-apply.py")
ga = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ga)

# Durations: the provisioning file says "1m", the rule-group API wants seconds.
assert ga.seconds("1m") == 60 and ga.seconds("30s") == 30 and ga.seconds("2h") == 7200
for bad in ("", "1d", "m", "60"):
    try:
        ga.seconds(bad)
    except ValueError:
        pass
    else:
        raise AssertionError(f"seconds({bad!r}) should fail")

# A folder's uid is derived from its title, the same way every time, so a re-apply updates
# rather than duplicates.
assert ga.folder_uid("Monitoring") == "monitoring"
assert ga.folder_uid("Mail & DNS") == "mail-dns"

group = {"orgId": 1, "name": "containers", "folder": "Monitoring", "interval": "1m",
         "rules": [{"uid": "container-down-h1", "title": "Container down", "condition": "C",
                    "data": [{"refId": "A", "datasourceUid": "grafanacloud-prom",
                              "model": {"expr": "up"}}],
                    "noDataState": "OK", "execErrState": "Error", "for": "1m",
                    "labels": {"severity": "critical"}, "annotations": {"summary": "x"}}]}
folder, name, body = ga.rule_group(group)
assert (folder, name) == ("monitoring", "containers")
assert body["title"] == "containers" and body["folderUid"] == "monitoring" and body["interval"] == 60
rule = body["rules"][0]
# The API needs each rule to name its own folder and group, which the file leaves implicit.
assert rule["folderUID"] == "monitoring" and rule["ruleGroup"] == "containers" and rule["orgID"] == 1
assert rule["uid"] == "container-down-h1" and rule["for"] == "1m" and rule["data"][0]["model"] == {"expr": "up"}
# The input is not mutated -- the same file can be applied twice in one run.
assert "folderUID" not in group["rules"][0]

# A rule without a uid would be created anew on every apply: refuse it.
try:
    ga.rule_group({**group, "rules": [{k: v for k, v in group["rules"][0].items() if k != "uid"}]})
except ValueError as e:
    assert "uid" in str(e)
else:
    raise AssertionError("a rule without uid should be refused")

dash = {"uid": "bp-hosts", "title": "Hosts", "id": 7, "panels": []}
body = ga.dashboard(dash, "monitoring")
assert body["overwrite"] is True and body["folderUid"] == "monitoring"
# id is the numeric id of ONE Grafana instance; sending another instance's id fails the save.
assert body["dashboard"]["id"] is None and body["dashboard"]["uid"] == "bp-hosts"
assert dash["id"] == 7

# Synthetic checks: a derived endpoint (vps/shared/public-endpoints.py) -> an SM check body.
probes = [{"id": 7, "name": "Singapore"}, {"id": 9, "name": "Tokyo"}, {"id": 3, "name": "Paris"}]
assert ga.probe_ids(["Tokyo", "Singapore"], probes) == [9, 7]
try:
    ga.probe_ids(["Singapore", "Atlantis"], probes)
except ValueError as e:
    assert "Atlantis" in str(e) and "Paris" in str(e)  # names the unknown one, lists the real ones
else:
    raise AssertionError("an unknown probe name should be refused, not dropped")

endpoint = {"hostname": "api.example.com", "host": "h1", "url": "https://api.example.com/health"}
body = ga.sm_check(endpoint, [7, 9])
assert body["job"] == "api.example.com" and body["target"] == "https://api.example.com/health"
# The API takes milliseconds.
assert body["frequency"] == 60000 and body["timeout"] == 10000
assert body["enabled"] is True and body["probes"] == [7, 9]
# `host` is what the endpoint rules name in the alert; managed_by is what lets an apply delete
# a check whose router is gone without touching a check someone made by hand.
assert {"name": "host", "value": "h1"} in body["labels"]
assert {"name": "managed_by", "value": "infrastructure"} in body["labels"]
http = body["settings"]["http"]
# A plain-HTTP answer is a failure: every name here is served over TLS, and the TLS metrics
# are the certificate check. Redirects are followed, so / -> /en is judged on the final page.
assert http["failIfNotSSL"] is True and http["noFollowRedirects"] is False and http["method"] == "GET"
assert "id" not in body and "tenantId" not in body

existing = [
    {"id": 1, "tenantId": 42, "job": "api.example.com", "target": "https://api.example.com/",
     "labels": [{"name": "host", "value": "h1"}, {"name": "managed_by", "value": "infrastructure"}]},
    {"id": 2, "tenantId": 42, "job": "gone.example.com", "target": "https://gone.example.com/",
     "labels": [{"name": "managed_by", "value": "infrastructure"}]},
    {"id": 3, "tenantId": 42, "job": "handmade", "target": "https://example.net/", "labels": []},
]
new = {"hostname": "new.example.com", "host": "h1", "url": "https://new.example.com/"}
add, update, delete = ga.sm_plan([endpoint, new], [7], existing)
assert [b["job"] for b in add] == ["new.example.com"]
# Matched by job: an update carries the existing id and tenantId, and the new target.
assert [(b["id"], b["tenantId"], b["target"]) for b in update] == [(1, 42, "https://api.example.com/health")]
# Only a managed check with no endpoint is deleted; the hand-made one is left alone.
assert [c["id"] for c in delete] == [2]

# Notifications. The cases that matter are the two that fail closed: an unset ${VAR}, and
# --dry-run never resolving one. A contact point with a blank webhook is accepted by Grafana
# and then silently delivers nothing, which is the failure the whole spec exists to prevent.
import os

DOC = {"contact_points": [{"name": "discord", "type": "discord",
                           "settings": {"url": "${TEST_HOOK}", "title": "x"}}],
       "policy": {"receiver": "discord", "group_by": ["alertname", "host"],
                  "routes": [{"receiver": "discord", "matchers": [["severity", "=", "critical"]],
                              "group_wait": "10s", "repeat_interval": "1h"}]}}

os.environ["TEST_HOOK"] = "https://example.invalid/hook"
points, tree = ga.notifications(DOC)
assert points[0]["settings"]["url"] == "https://example.invalid/hook"
assert points[0]["disableResolveMessage"] is False
# matchers -> object_matchers, and only the intervals that were set are sent.
assert tree["routes"][0]["object_matchers"] == [["severity", "=", "critical"]]
assert tree["routes"][0]["group_wait"] == "10s"
assert "group_interval" not in tree["routes"][0]

# --dry-run must not resolve: the plan is printed, and a webhook URL is a credential.
unresolved, _ = ga.notifications(DOC, resolve=False)
assert unresolved[0]["settings"]["url"] == "${TEST_HOOK}"

del os.environ["TEST_HOOK"]
try:
    ga.notifications(DOC)
except SystemExit as exc:
    assert "TEST_HOOK" in str(exc), exc
else:
    raise AssertionError("an unset ${VAR} must fail the run, not send a blank webhook")

# A nested route translates too: an app's parent route carries the severity tiers under it.
NESTED = {"contact_points": [{"name": "a", "type": "discord", "settings": {}},
                             {"name": "b", "type": "discord", "settings": {}}],
          "policy": {"receiver": "a", "group_by": ["alertname"],
                     "routes": [{"receiver": "b", "matchers": [["app", "=", "x"]],
                                 "routes": [{"receiver": "b", "matchers": [["severity", "=", "critical"]],
                                             "group_wait": "10s"}]}]}}
_, nested = ga.notifications(NESTED, resolve=False)
child = nested["routes"][0]["routes"][0]
assert child["object_matchers"] == [["severity", "=", "critical"]] and child["group_wait"] == "10s"

# The repository's own notifications file translates, and names a receiver that exists --
# at every depth, since the app routes nest their severity tiers.
doc = ga.load_yaml(HERE.parent / ga.NOTIFICATIONS)
names = {cp["name"] for cp in doc["contact_points"]}
_, real = ga.notifications(doc, resolve=False)
assert real["receiver"] in names, f"default route names an unknown receiver: {real['receiver']}"


def check_receivers(route):
    assert route["receiver"] in names, f"route names an unknown receiver: {route['receiver']}"
    for kid in route.get("routes") or []:
        check_receivers(kid)


for r in real.get("routes") or []:
    check_receivers(r)

# Each Discord channel is its own credential: two contact points must never share one ${VAR},
# which would deliver both apps' alerts to the same channel while looking correct in review.
urls = [cp["settings"]["url"] for cp in doc["contact_points"] if cp["type"] == "discord"]
assert len(urls) == len(set(urls)), f"two Discord contact points share a webhook: {urls}"

# ⚠️ Ordering. Matching stops at the first matching sibling, and every app alert also carries a
# `severity` -- so a route that matches only `severity` shadows every app route below it, and
# that app's channel stays silent with nothing in the config looking wrong. The app routes must
# come first. docs/research/grafana-multi-app-alert-routing.md, §2a.
seen_severity_only = None
for r in real.get("routes") or []:
    keys = {m[0] for m in r["object_matchers"]}
    if keys == {"severity"}:
        seen_severity_only = r["object_matchers"]
    elif "app" in keys:
        assert seen_severity_only is None, (
            f"route {r['object_matchers']} is unreachable: {seen_severity_only} matches first")

# The repository's own files translate.
for path in sorted((HERE.parent / "grafana" / "rules").glob("*.yml")):
    for g in ga.load_yaml(path)["groups"]:
        ga.rule_group(g)
for path in sorted((HERE.parent / "grafana" / "dashboards").glob("*.json")):
    ga.dashboard(ga.load_json(path), "monitoring")

print("grafana-apply.py: all checks passed")
