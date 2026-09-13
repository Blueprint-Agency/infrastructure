#!/usr/bin/env python3
"""grafana-apply.py [--dry-run]

Apply the repository's Grafana objects to Grafana Cloud: every dashboard under
grafana/dashboards/ and every alert rule group under grafana/rules/. The files are the copy
of record (#22) -- a dashboard or rule that exists only in the web UI has no history and no
review, and anything edited there is overwritten by the next apply.

    set -a; . ./.env; set +a
    python scripts/grafana-apply.py --dry-run     # translate and print, send nothing
    python scripts/grafana-apply.py

Needs GRAFANA_URL (https://<stack>.grafana.net) and GRAFANA_SA_TOKEN, a service-account
token with the Editor role, from .env. Idempotent: dashboards are saved with overwrite,
folders and rule groups are addressed by uid, so running it twice changes nothing.

Rule groups go through the provisioning API, which marks them as provisioned: the UI shows
them read-only. That is deliberate. To change a rule, change the file.

Tested by scripts/test_grafana_apply.py (the translation; no request is made).
"""
import json
import os
import pathlib
import re
import sys
import urllib.error
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parents[1]
UNITS = {"s": 1, "m": 60, "h": 3600}


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
    # Dashboards live beside the rules, in the one folder the rules name first.
    home = groups[0]["folder"] if groups else "Monitoring"

    if dry:
        for g in groups:
            print(json.dumps(rule_group(g), indent=2))
        for d in dashboards:
            print(f"dashboard {d['uid']}: {len(d.get('panels') or [])} panels -> {folder_uid(home)}")
        return 0

    missing = [v for v in ("GRAFANA_URL", "GRAFANA_SA_TOKEN") if not os.environ.get(v)]
    if missing:
        sys.exit(f"{', '.join(missing)} not set -- `set -a; . ./.env; set +a` first")
    api = Grafana(os.environ["GRAFANA_URL"], os.environ["GRAFANA_SA_TOKEN"])

    titles = {folder_uid(g["folder"]): g["folder"] for g in groups} or {folder_uid(home): home}
    for uid, title in titles.items():
        api.ensure_folder(uid, title)
    for g in groups:
        folder, name, body = rule_group(g)
        api.call("PUT", f"/api/v1/provisioning/folder/{folder}/rule-groups/{name}", body)
        print(f"rule group {folder}/{name}: {len(body['rules'])} rule(s) applied")
    for d in dashboards:
        api.call("POST", "/api/dashboards/db", dashboard(d, folder_uid(home)))
        print(f"dashboard {d['uid']}: applied")
    return 0


if __name__ == "__main__":
    sys.exit(main())
