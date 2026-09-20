#!/usr/bin/env python3
"""grafana-apply.py [--dry-run]

Apply the repository's Grafana objects to Grafana Cloud: every dashboard under
grafana/dashboards/, every alert rule group under grafana/rules/, and one Synthetic Monitoring
check per public endpoint derived by vps/shared/public-endpoints.py (#24) -- every Traefik
router here, plus the hand-typed `off_platform:` names that something else serves
(booking-system's Vercel frontends, #37), which may set their own probes and frequency --
plus the contact points and notification policy in grafana/alerting/notifications.yml. The files are the
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

Contact points and the policy are sent with X-Disable-Provenance, so they stay editable in
the UI. Also deliberate, and the opposite trade: mid-incident someone may need to add a
destination or route around a broken one, and waiting on a deploy to do it is worse than the
drift. The next apply puts the file's version back.

Any ${VAR} in notifications.yml is substituted from the environment and must be set -- a
contact point with a blank webhook is accepted by Grafana and then delivers nothing. A Discord
webhook URL is a credential and this repository is public, so they live in .env: infra in
DISCORD_WEBHOOK_URL, one channel per app beside it (DISCORD_BOOKING_WEBHOOK_URL). --dry-run
never resolves them, so none can be printed by accident.

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
ENV_VAR = re.compile(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}")
NOTIFICATIONS = "grafana/alerting/notifications.yml"
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
        # Grafana's own limit, and it is enforced on the PUT: a group whose first rules are
        # fine and whose fourth is too long is rejected whole, after the earlier groups in the
        # same run have already been written. Caught here so --dry-run catches it too.
        if len(rule["uid"]) > 40:
            raise ValueError(f"group {name}: rule uid {rule['uid']!r} is "
                             f"{len(rule['uid'])} characters -- Grafana's limit is 40")
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
    """derived endpoint {hostname, host, url} -> Synthetic Monitoring HTTP check body

    An off_platform endpoint (grafana/synthetic/endpoints.yml, #37) may carry `probe_ids` and
    `frequency` of its own -- fewer probes buy free-tier headroom for a name whose alert is
    "read the provider's status page" rather than "ssh the host". Everything derived from a
    Traefik router takes the file-wide values, and grafana/rules/endpoints.yml's 2-minute
    window assumes the 60s default: see that file's budget note before overriding frequency.
    """
    return {
        "job": endpoint["hostname"], "target": endpoint["url"],
        "frequency": seconds(endpoint.get("frequency") or SM_FREQUENCY) * 1000,
        "timeout": seconds(SM_TIMEOUT) * 1000,
        "enabled": True, "probes": list(endpoint.get("probe_ids") or probes),
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


def substitute(value, where):
    """Replace ${VAR} from the environment. An unset one is fatal, like render-ci.py:
    a contact point with a blank webhook is accepted by Grafana and then silently
    delivers nothing, which is the failure this whole spec exists to prevent."""
    def sub(m):
        got = os.environ.get(m.group(1))
        if not got:
            sys.exit(f"{where}: ${{{m.group(1)}}} is not set -- `set -a; . ./.env; set +a` first")
        return got
    return ENV_VAR.sub(sub, value) if isinstance(value, str) else value


def notifications(doc, resolve=True):
    """notifications.yml -> (contact points, policy tree). resolve=False leaves ${VAR}
    unexpanded so --dry-run can print the plan without reading, or printing, a secret."""
    points = []
    for cp in doc.get("contact_points") or []:
        where = f"grafana/alerting/notifications.yml: contact point {cp.get('name')}"
        settings = {k: (substitute(v, where) if resolve else v)
                    for k, v in (cp.get("settings") or {}).items()}
        points.append({"name": cp["name"], "type": cp["type"], "settings": settings,
                       "disableResolveMessage": bool(cp.get("disable_resolve_message"))})

    def route(r):
        out = {"receiver": r["receiver"],
               "object_matchers": [list(m) for m in r.get("matchers") or []]}
        for k in ("group_wait", "group_interval", "repeat_interval"):
            if r.get(k):
                out[k] = r[k]
        if r.get("routes"):
            out["routes"] = [route(x) for x in r["routes"]]
        return out

    pol = doc.get("policy") or {}
    tree = {"receiver": pol["receiver"], "group_by": pol.get("group_by") or []}
    if pol.get("routes"):
        tree["routes"] = [route(r) for r in pol["routes"]]
    return points, tree


def dashboard(doc, folder):
    """dashboard JSON -> POST /api/dashboards/db body"""
    return {"dashboard": {**doc, "id": None}, "folderUid": folder, "overwrite": True,
            "message": "applied from Blueprint-Agency/infrastructure by scripts/grafana-apply.py"}


class Grafana:
    def __init__(self, url, token):
        self.url, self.token = url.rstrip("/"), token

    def call(self, method, path, body=None, ok404=False, provenance=True):
        headers = {"Authorization": f"Bearer {self.token}", "Content-Type": "application/json",
                   "Accept": "application/json", "User-Agent": "blueprint-grafana-apply"}
        if not provenance:
            # Without this the object is marked provisioned and the UI refuses to edit it.
            # Rule groups SHOULD be locked; contact points and the policy should not, so that
            # someone can add a silence or a destination mid-incident without a deploy.
            headers["X-Disable-Provenance"] = "true"
        req = urllib.request.Request(
            self.url + path, method=method,
            data=None if body is None else json.dumps(body).encode(), headers=headers)
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
    notif = load_yaml(ROOT / NOTIFICATIONS)
    if dry:
        for g in groups:
            print(json.dumps(rule_group(g), indent=2))
        for d in dashboards:
            print(f"dashboard {d['uid']}: {len(d.get('panels') or [])} panels -> {folder_uid(DASHBOARD_FOLDER)}")
        for e in endpoints:
            where = "off-platform" if e.get("off_platform") else f"host {e['host']}"
            print(f"synthetic check {e['hostname']}: {e['url']} ({where}, label host={e['host']}) "
                  f"every {e.get('frequency') or SM_FREQUENCY} "
                  f"from {', '.join(e.get('probes') or probe_names)}")
        # resolve=False: never print a webhook URL, which is a credential.
        points, tree = notifications(notif, resolve=False)
        for p in points:
            print(f"contact point {p['name']}: {p['type']}")
        print(f"notification policy: default -> {tree['receiver']}, "
              f"{len(tree.get('routes') or [])} route(s), group_by {tree['group_by']}")
        return 0

    missing = [v for v in ("GRAFANA_URL", "GRAFANA_SA_TOKEN", "GRAFANA_SM_URL", "GRAFANA_SM_TOKEN")
               if not os.environ.get(v)]
    if missing:
        sys.exit(f"{', '.join(missing)} not set -- `set -a; . ./.env; set +a` first")
    api = Grafana(os.environ["GRAFANA_URL"], os.environ["GRAFANA_SA_TOKEN"])
    sm = Grafana(os.environ["GRAFANA_SM_URL"].rstrip("/") + "/api/v1", os.environ["GRAFANA_SM_TOKEN"])
    # Resolve probes before touching anything, so a bad name changes nothing -- the file-wide
    # list, and then any per-endpoint override, so a typo in one off_platform entry fails the
    # run before a single check, rule or dashboard has been written.
    try:
        available = sm.call("GET", "/probe/list")
        probes = probe_ids(probe_names, available)
        for e in endpoints:
            if e.get("probes"):
                e["probe_ids"] = probe_ids(e["probes"], available)
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
    # Contact points and the policy before the checks: a check that starts failing should
    # already have somewhere to report it. X-Disable-Provenance keeps them editable in the
    # UI for an emergency silence -- unlike the rule groups, which are deliberately locked.
    points, tree = notifications(notif)
    existing = {c["name"]: c for c in api.call("GET", "/api/v1/provisioning/contact-points") or []}
    for p in points:
        if p["name"] in existing:
            api.call("PUT", f"/api/v1/provisioning/contact-points/{existing[p['name']]['uid']}",
                     {**p, "uid": existing[p["name"]]["uid"]}, provenance=False)
            print(f"contact point {p['name']}: updated")
        else:
            api.call("POST", "/api/v1/provisioning/contact-points", p, provenance=False)
            print(f"contact point {p['name']}: created")
    api.call("PUT", "/api/v1/provisioning/policies", tree, provenance=False)
    print(f"notification policy: default -> {tree['receiver']}, "
          f"{len(tree.get('routes') or [])} route(s)")

    add, update, delete = sm_plan(endpoints, probes, sm.call("GET", "/check/list") or [])
    for body in add:
        sm.call("POST", "/check/add", body)
        print(f"synthetic check {body['job']}: created")
    for body in update:
        sm.call("POST", "/check/update", body)
        print(f"synthetic check {body['job']}: updated")
    for check in delete:
        sm.call("DELETE", f"/check/delete/{check['id']}")
        print(f"synthetic check {check['job']}: deleted -- no router serves it and no "
              "off_platform entry declares it any more")
    return 0


if __name__ == "__main__":
    sys.exit(main())
