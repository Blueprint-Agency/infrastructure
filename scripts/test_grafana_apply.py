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

# The repository's own files translate.
for path in sorted((HERE.parent / "grafana" / "rules").glob("*.yml")):
    for g in ga.load_yaml(path)["groups"]:
        ga.rule_group(g)
for path in sorted((HERE.parent / "grafana" / "dashboards").glob("*.json")):
    ga.dashboard(ga.load_json(path), "monitoring")

print("grafana-apply.py: all checks passed")
