#!/usr/bin/env python3
"""Self-check for grafana-apply.py.  Run: python3 scripts/test_grafana_apply.py

Covers the pure half: turning the repo's provisioning-format files into the bodies Grafana's
HTTP API takes. No request is made. The half that talks to Grafana Cloud is proved by
running it once against the account and reading the result back (docs/monitoring.md).
"""
import importlib.util
import pathlib
import re

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

# An off_platform endpoint (#37) may buy free-tier headroom with its own probes and frequency.
# Everything derived from a router keeps the file-wide values, which is the case above.
off = {"hostname": "www.vendor.example", "host": "vercel", "off_platform": True,
       "url": "https://www.vendor.example/", "probes": ["Singapore"], "frequency": "300s"}
body = ga.sm_check({**off, "probe_ids": [7]}, [7, 9, 3])
assert body["probes"] == [7] and body["frequency"] == 300000
# The label is the platform, so the alert reads "... on vercel" rather than naming a VPS.
assert {"name": "host", "value": "vercel"} in body["labels"]
# Names, not ids, are what the file holds: an endpoint whose probes were never resolved falls
# back to the file-wide list rather than sending Grafana a list of strings.
assert ga.sm_check(off, [7, 9, 3])["probes"] == [7, 9, 3]

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

# ── The cadences in use and the rules that cover them must agree (#42) ───────────────────────
# This is the part of #42 most likely to go wrong, and to go wrong SILENTLY: a check running
# every 15 minutes whose endpoint-down rule still reads max_over_time(probe_success[2m]) has an
# empty window at most evaluations, so the alert flickers on staleness instead of firing on
# failure -- and a check whose cadence no rule matches at all is probed forever and alerted on
# by nothing. Both look exactly like a healthy check. So: every cadence used by a derived or
# off_platform endpoint has a rule, every rule's cadence is one somebody uses, and every window
# is 2 x the interval + 1m of Synthetic Monitoring push lag.
import os  # noqa: E402  -- only this section needs it

pe_spec = importlib.util.spec_from_file_location(
    "public_endpoints", HERE.parent / "vps/shared/public-endpoints.py")
pe = importlib.util.module_from_spec(pe_spec)
pe_spec.loader.exec_module(pe)

cwd = os.getcwd()
os.chdir(HERE.parent)
try:
    problems = []
    endpoints = pe.derive(problems)
finally:
    os.chdir(cwd)
assert not problems, "public-endpoints.py: " + "; ".join(problems)

used = {e["frequency"] for e in endpoints}
rules = {r["uid"]: r for g in ga.load_yaml(HERE.parent / "grafana/rules/endpoints.yml")["groups"]
         for r in g["rules"]}
covered = {uid[len("endpoint-down-"):] for uid in rules if uid.startswith("endpoint-down-")}
assert used == covered, (
    f"cadences in grafana/synthetic/endpoints.yml are {sorted(used)} but grafana/rules/"
    f"endpoints.yml covers {sorted(covered)} -- a cadence with no rule is never alerted on")

WINDOW = re.compile(r"probe_success\[([0-9]+[smh])\]")
# Deliberately NOT a look-behind: a positional pattern reports "no match" -- which reads as
# "nothing wrong" -- for the very regression it exists to catch. Instead every legitimate
# occurrence is deleted and whatever is left is a bare one.
WRAPPED_INFO = re.compile(r"last_over_time\(sm_check_info")
windows = {}
for cad in sorted(covered):
    rule = rules[f"endpoint-down-{cad}"]
    expr = "\n".join(d["model"].get("expr", "") for d in rule["data"])
    found = set(WINDOW.findall(expr))
    assert len(found) == 1, f"endpoint-down-{cad}: probe_success windows {sorted(found)} -- want one"
    window = found.pop()
    windows[cad] = ga.seconds(window)
    assert windows[cad] == 2 * ga.seconds(cad) + 60, (
        f"endpoint-down-{cad}: window {window} -- must be 2 x {cad} + 1m of push lag "
        f"({2 * ga.seconds(cad) + 60}s), or the alert flickers on staleness")
    # sm_check_info is pushed per run, so at any cadence over ~5m the bare selector is stale for
    # Prometheus's 5-minute instant lookback and every join silently returns nothing.
    assert "sm_check_info" in expr, f"endpoint-down-{cad}: joins no sm_check_info at all"
    assert "sm_check_info" not in WRAPPED_INFO.sub("", expr), (
        f"endpoint-down-{cad}: joins sm_check_info instantly somewhere -- every one of them "
        f"must be last_over_time(sm_check_info...[{window}])")
    assert f'cadence="{cad}"' in expr, f"endpoint-down-{cad}: does not match cadence=\"{cad}\""

# tls-expiry is one rule for every cadence -- a 21-day threshold does not care how old the
# number is -- but it still has to survive the SLOWEST one's staleness.
tls = "\n".join(d["model"].get("expr", "") for d in rules["tls-expiry"]["data"])
slowest = max(windows.values())
for expr_window in re.findall(r"\[([0-9]+[smh])\]", tls):
    assert ga.seconds(expr_window) >= slowest, (
        f"tls-expiry: window {expr_window} is shorter than the slowest cadence's {slowest}s -- "
        "probe_ssl_earliest_cert_expiry and sm_check_info are both stale between runs")
assert "min_over_time(probe_ssl_earliest_cert_expiry" in tls, (
    "tls-expiry: reads probe_ssl_earliest_cert_expiry instantly -- stale between runs")

# The Endpoints dashboard reads the same probe_* series and has the same staleness problem, with
# no rule-shaped guard of its own: a window narrower than the slowest cadence's draws gaps on a
# perfectly healthy check, which is worse than useless on a panel people glance at.
endpoints_dash = ga.load_json(HERE.parent / "grafana/dashboards/endpoints.json")
for panel in endpoints_dash["panels"]:
    for target in panel.get("targets") or []:
        expr = target.get("expr", "")
        for w in re.findall(r"\[([0-9]+[smh])\]", expr):
            assert ga.seconds(w) >= slowest, (
                f"dashboard panel {panel['title']!r}: window {w} is shorter than the slowest "
                f"cadence's {slowest}s -- healthy checks would read as gaps")
        assert "_over_time(probe_" in expr, (
            f"dashboard panel {panel['title']!r}: reads a probe_* series instantly -- at a "
            "15-minute cadence it is stale for Prometheus's 5-minute lookback most of the time")

# Every rule's query window must fit inside its own relativeTimeRange, or Grafana hands the
# datasource less data than the query asks for and the range is silently truncated.
for uid, rule in sorted(rules.items()):
    for d in rule["data"]:
        longest = max((ga.seconds(w) for w in re.findall(r"\[([0-9]+[smh])\]",
                                                         d["model"].get("expr", ""))), default=0)
        assert d["relativeTimeRange"]["from"] >= longest, (
            f"{uid}/{d['refId']}: relativeTimeRange from={d['relativeTimeRange']['from']}s is "
            f"shorter than its own {longest}s window")

# Two rules in one group may not share a title: Grafana keys rules on (org, folder, title) and
# rejects the whole PUT, part-way through an apply that has already written earlier groups.
dup = {**group, "rules": [group["rules"][0], {**group["rules"][0], "uid": "container-down-h2"}]}
try:
    ga.rule_group(dup)
except ValueError as exc:
    assert "title" in str(exc), exc
else:
    raise AssertionError("two rules sharing a title must fail, not be sent to Grafana")

# The repository's own files translate.
for path in sorted((HERE.parent / "grafana" / "rules").glob("*.yml")):
    for g in ga.load_yaml(path)["groups"]:
        ga.rule_group(g)

# ...and titles are unique across the whole FOLDER, not only within a group -- which is the
# scope Grafana actually enforces, and which rule_group() alone cannot see.
by_folder = {}
for path in sorted((HERE.parent / "grafana" / "rules").glob("*.yml")):
    for g in ga.load_yaml(path)["groups"]:
        for r in g["rules"]:
            owner = by_folder.setdefault((ga.folder_uid(g["folder"]), r["title"]), r["uid"])
            assert owner == r["uid"], (
                f"{owner} and {r['uid']} share the title {r['title']!r} in folder {g['folder']} "
                "-- Grafana requires it unique per folder")
for path in sorted((HERE.parent / "grafana" / "dashboards").glob("*.json")):
    ga.dashboard(ga.load_json(path), "monitoring")

print("grafana-apply.py: all checks passed")
