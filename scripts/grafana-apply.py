#!/usr/bin/env python3
"""grafana-apply.py [--dry-run]

Apply the repository's Grafana objects to Grafana Cloud: every dashboard under
grafana/dashboards/, every alert rule group under grafana/rules/, and one Synthetic Monitoring
check per public endpoint derived by vps/shared/public-endpoints.py (#24). The files are the
copy of record (#22) -- a dashboard or rule that exists only in the web UI has no history and no
review, and anything edited there is overwritten by the next apply.

    set -a; . ./.env; set +a
    python scripts/grafana-apply.py --dry-run     # translate and print, send nothing
    python scripts/grafana-apply.py

Needs GRAFANA_URL (https://<stack>.grafana.net) and GRAFANA_SA_TOKEN, a service-account
token with the Editor role, plus GRAFANA_SM_URL (the Synthetic Monitoring "backend address",
https://synthetic-monitoring-api-<region>.grafana.net) and GRAFANA_SM_TOKEN (Synthetics ->
Config), from .env. Idempotent: dashboards are saved with overwrite, folders and rule groups are
addressed by uid, checks by job (= hostname), so running it twice changes nothing. A check
labelled managed_by=infrastructure whose name no router serves any more is deleted; a check
made by hand is never touched.

Rule groups go through the provisioning API, which marks them as provisioned: the UI shows
them read-only. That is deliberate. To change a rule, change the file.

Tested by scripts/test_grafana_apply.py (the translation; no request is made).
"""
import importlib.util
import json
import os
import pathlib
import re
import sys
import urllib.error
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parents[1]
UNITS = {"s": 1, "m": 60, "h": 3600}
# Every dashboard is saved into this folder -- the same one the alert rules name.
DASHBOARD_FOLDER = "Monitoring"
# Synthetic checks. Every minute from each probe: grafana/rules/endpoints.yml's window assumes it.
SM_FREQUENCY, SM_TIMEOUT = "60s", "10s"
SM_MANAGED_BY = "infrastructure"


def load_json(path):
    return json.loads(pathlib.Path(path).read_text(encoding="utf-8"))


def load_yaml(path):
    import yaml
    return yaml.safe_load(pathlib.Path(path).read_text(encoding="utf-8")) or {}


def seconds(duration):
    m = re.fullmatch(r"([0-9]+)([smh])", str(duration))
    if not m:
        raise ValueError(f"duration {duration!r}: expected e.g. 30s, 1m, 2h")
    return int(m.group(1)) * UNITS[m.group(2)]


def folder_uid(title):
    return re.sub(r"[^a-z0-9]+", "-", title.lower()).strip("-")


def rule_group(group):
    """provisioning-file group -> (folder uid, group name, PUT rule-groups body)"""
    folder, name = folder_uid(group["folder"]), group["name"]
    rules = []
    for rule in group.get("rules") or []:
        if not rule.get("uid"):
            raise ValueError(f"group {name}: rule {rule.get('title')!r} has no uid -- "
                             "without one every apply creates a duplicate")
        rules.append({**rule, "folderUID": folder, "ruleGroup": name, "orgID": group.get("orgId", 1)})
    return folder, name, {"title": name, "folderUid": folder,
                          "interval": seconds(group["interval"]), "rules": rules}


def probe_ids(names, probes):
    """probe names from endpoints.yml -> SM probe ids, in the same order. An unknown name is
    an error, not a skip: a check quietly running from fewer probes is a weaker check."""
    by_name = {p["name"]: p["id"] for p in probes}
    unknown = [n for n in names if n not in by_name]
    if unknown:
        raise ValueError(f"unknown probe(s) {', '.join(unknown)} -- available: {', '.join(sorted(by_name))}")
    return [by_name[n] for n in names]


def sm_check(endpoint, probes):
    """derived endpoint {hostname, host, url} -> Synthetic Monitoring HTTP check body"""
    return {
        "job": endpoint["hostname"], "target": endpoint["url"],
        "frequency": seconds(SM_FREQUENCY) * 1000, "timeout": seconds(SM_TIMEOUT) * 1000,
        "enabled": True, "probes": list(probes),
        "labels": [{"name": "host", "value": endpoint["host"]},
                   {"name": "managed_by", "value": SM_MANAGED_BY}],
        # The TLS and success metrics the rules and dashboard read are all basic metrics.
        "basicMetricsOnly": True,
        # Alerting is grafana/rules/endpoints.yml, one path -- not SM's own sensitivity alerts.
        "alertSensitivity": "none",
        "settings": {"http": {"method": "GET", "ipVersion": "V4", "noFollowRedirects": False,
                              "failIfSSL": False, "failIfNotSSL": True}},
    }


def sm_plan(endpoints, probes, existing):
    """-> (bodies to add, bodies to update, existing checks to delete). Matched on job, which is
    the hostname. Only checks labelled managed_by=infrastructure are ever deleted."""
    by_job = {c["job"]: c for c in existing}
    add, update = [], []
    for e in endpoints:
        body = sm_check(e, probes)
        old = by_job.get(e["hostname"])
        if old:
            update.append({**body, "id": old["id"], "tenantId": old["tenantId"]})
        else:
            add.append(body)
    wanted = {e["hostname"] for e in endpoints}
    managed = {"name": "managed_by", "value": SM_MANAGED_BY}
    delete = [c for c in existing if c["job"] not in wanted and managed in (c.get("labels") or [])]
    return add, update, delete


def load_endpoints():
    """-> (checks, probe names) from vps/shared/public-endpoints.py and endpoints.yml"""
    spec = importlib.util.spec_from_file_location("public_endpoints", ROOT / "vps/shared/public-endpoints.py")
    pe = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(pe)
    cwd = os.getcwd()
    os.chdir(ROOT)
    try:
        problems = []
        checks = pe.derive(problems)
    finally:
        os.chdir(cwd)
    if problems:
        sys.exit("\n".join(problems + ["run vps/shared/public-endpoints.py and fix these first"]))
    names = load_yaml(ROOT / "grafana/synthetic/endpoints.yml").get("probes") or []
    if not names:
        sys.exit("grafana/synthetic/endpoints.yml: probes: lists no probe")
    return checks, names


def dashboard(doc, folder):
    """dashboard JSON -> POST /api/dashboards/db body"""
    return {"dashboard": {**doc, "id": None}, "folderUid": folder, "overwrite": True,
            "message": "applied from Blueprint-Agency/infrastructure by scripts/grafana-apply.py"}


class Grafana:
    def __init__(self, url, token):
        self.url, self.token = url.rstrip("/"), token

    def call(self, method, path, body=None, ok404=False):
        req = urllib.request.Request(
            self.url + path, method=method,
            data=None if body is None else json.dumps(body).encode(),
            headers={"Authorization": f"Bearer {self.token}", "Content-Type": "application/json",
                     "Accept": "application/json", "User-Agent": "blueprint-grafana-apply"})
        try:
            with urllib.request.urlopen(req, timeout=60) as resp:
                return json.loads(resp.read() or b"null")
        except urllib.error.HTTPError as exc:
            if ok404 and exc.code == 404:
                return None
            sys.exit(f"{method} {path}: HTTP {exc.code}: {exc.read().decode(errors='replace')[:500]}")

    def ensure_folder(self, uid, title):
        if self.call("GET", f"/api/folders/{uid}", ok404=True) is None:
            self.call("POST", "/api/folders", {"uid": uid, "title": title})
            print(f"folder {title} ({uid}): created")


def main():
    dry = "--dry-run" in sys.argv[1:]
    groups = [g for p in sorted((ROOT / "grafana" / "rules").glob("*.y*ml"))
              for g in load_yaml(p).get("groups") or []]
    dashboards = [load_json(p) for p in sorted((ROOT / "grafana" / "dashboards").glob("*.json"))]
    endpoints, probe_names = load_endpoints()
    if dry:
        for g in groups:
            print(json.dumps(rule_group(g), indent=2))
        for d in dashboards:
            print(f"dashboard {d['uid']}: {len(d.get('panels') or [])} panels -> {folder_uid(DASHBOARD_FOLDER)}")
        for e in endpoints:
            print(f"synthetic check {e['hostname']}: {e['url']} (host {e['host']}) from {', '.join(probe_names)}")
        return 0

    missing = [v for v in ("GRAFANA_URL", "GRAFANA_SA_TOKEN", "GRAFANA_SM_URL", "GRAFANA_SM_TOKEN")
               if not os.environ.get(v)]
    if missing:
        sys.exit(f"{', '.join(missing)} not set -- `set -a; . ./.env; set +a` first")
    api = Grafana(os.environ["GRAFANA_URL"], os.environ["GRAFANA_SA_TOKEN"])
    sm = Grafana(os.environ["GRAFANA_SM_URL"].rstrip("/") + "/api/v1", os.environ["GRAFANA_SM_TOKEN"])
    # Resolve probes before touching anything, so a bad name changes nothing.
    try:
        probes = probe_ids(probe_names, sm.call("GET", "/probe/list"))
    except ValueError as exc:
        sys.exit(f"grafana/synthetic/endpoints.yml: {exc}")

    titles = {folder_uid(g["folder"]): g["folder"] for g in groups}
    titles[folder_uid(DASHBOARD_FOLDER)] = DASHBOARD_FOLDER
    for uid, title in titles.items():
        api.ensure_folder(uid, title)
    for g in groups:
        folder, name, body = rule_group(g)
        api.call("PUT", f"/api/v1/provisioning/folder/{folder}/rule-groups/{name}", body)
        print(f"rule group {folder}/{name}: {len(body['rules'])} rule(s) applied")
    for d in dashboards:
        api.call("POST", "/api/dashboards/db", dashboard(d, folder_uid(DASHBOARD_FOLDER)))
        print(f"dashboard {d['uid']}: applied")
    add, update, delete = sm_plan(endpoints, probes, sm.call("GET", "/check/list") or [])
    for body in add:
        sm.call("POST", "/check/add", body)
        print(f"synthetic check {body['job']}: created")
    for body in update:
        sm.call("POST", "/check/update", body)
        print(f"synthetic check {body['job']}: updated")
    for check in delete:
        sm.call("DELETE", f"/check/delete/{check['id']}")
        print(f"synthetic check {check['job']}: deleted -- no router serves it any more")
    return 0


if __name__ == "__main__":
    sys.exit(main())
