# Monitoring

Host and container metrics plus container logs, shipped by one Grafana Alloy agent per host to
Grafana Cloud, with dashboards and alert rules kept in this repository (#22).

**Coverage today:** the agent runs on **bpvps2 only** (#23) — the canary; bpvps1 is #25.
**External endpoint and TLS checks cover every public name on both hosts** (#24) — they need no
agent. The textfile seam (#24) reads on bpvps2. The three Teeko hosts are out of scope by
decision (#22).

## The pieces

| | Where |
|---|---|
| Agent | `vps/bpvps2/stacks/monitoring/` — container `alloy`, deployed by `deploy-infra.yml` like any stack |
| Alloy version | the `FROM` line of that stack's `Dockerfile`, exact tag. CI validates `config.alloy` against it |
| What metrics ship | `metrics.allowlist` in the stack — one metric name per line, **keep** only those |
| What logs ship | `loki.process "select"` in `config.alloy` — every container, minus Traefik access logs |
| Dashboards | `grafana/dashboards/*.json` |
| Alert rules | `grafana/rules/*.yml` (Grafana file-provisioning format) |
| External checks | one Grafana Synthetic Monitoring HTTP check per public name — the list derived by `vps/shared/public-endpoints.py`, exceptions in `grafana/synthetic/endpoints.yml` |
| Textfile seam | the `monitoring_textfile` volume, read at `/textfile` — contract in [`textfile-metrics.md`](textfile-metrics.md) |
| Applying them | `scripts/grafana-apply.py` — the files are the copy of record; UI edits are overwritten |
| Drift check | `vps/shared/check-monitoring.py` and `vps/shared/public-endpoints.py`, run in CI's `monitoring-drift` job on every push |

## Grafana Cloud entitlements

> ⚠️ **Not yet confirmed at the account.** #22 requires reading these off the account itself —
> published summaries disagree on retention. Fill this table from the Grafana Cloud portal
> (**My Account → Usage / Billing**), with the date, before trusting any figure below.

| | Documented (#22) | Confirmed at the account |
|---|---|---|
| Active metric series | 10,000 | _pending_ |
| Logs ingested / month | 50 GB | _pending_ |
| Metric retention | 13 months (some summaries say 14 days) | _pending_ |
| Log retention | 30 days (some summaries say 14 days) | _pending_ |
| Users | 3 | _pending_ |

## Budget

**Series.** 93 series per scrape on bpvps2 after the allowlist, counted on 2026-09-13 against
the real exporter output on the host (9 containers at the time, including two throwaway test
containers). Roughly 1% of a 10k ceiling. Each new container adds about 7 container series,
more if it sits on several networks (network series are per interface).

**Log volume.** _pending — measure a week after deploy_ (#25 records the two-host figure).

**Agent overhead** on bpvps2 (1 vCPU / 4 GB), measured in a smoke run on 2026-09-13 with the
real config and mounts: **~69 MiB memory, ~1% CPU**. The compose caps it at 0.5 CPU / 384 MiB.
_Re-measure after a week of real shipping and record it here._

## Labels

Every metric and log line carries:

| Label | Value |
|---|---|
| `host` | `MONITORING_HOST` in the stack's compose — the `vps/hosts.json` key, `bpvps2`. Not the kernel hostname; CI checks it matches the key the rules use |
| `container` | `booking-be-staging`, `booking-db-prod`, `traefik`, … |
| `compose_project` | the **stack directory** on the host — `booking-staging` vs `booking-prod` |
| `compose_service` | the compose service key — `booking-be`, `db-booking`, … |

> **booking-staging and booking-prod are one compose file deployed twice.** Their service keys
> are identical; only `container` and `compose_project` tell them apart. Filter on one of those,
> never on `compose_service` alone — `booking-staging` is the instance with the real data.

## Metrics: the allowlist

Only names in `metrics.allowlist` leave the host. A metric family costs nothing until it is
listed. **Adding a metric is a line in the allowlist plus the panel or rule that reads it**, in
the same commit. CI fails:

- an allowlisted name that no panel or rule under `grafana/` reads — budget spent on nothing;
- a `node_*` / `container_*` / `machine_*` name a panel or rule reads that is not allowlisted —
  the agent drops it, so the panel is empty or the rule never fires;
- any allowlist line that is not a bare metric name. Alloy joins the lines with `|` into one
  regex; a comment or a `(` would silently change it.

What bpvps2 collects today: host CPU, memory, disk and network (`node_*`), and per-container
CPU, memory, disk I/O and network plus `container_last_seen` (`container_*`, from the cadvisor
built into Alloy). Container **disk** is I/O bytes, not usage: cadvisor's usage figure walks
each container's filesystem, which is not a cost to put on a 1 vCPU host.

## Logs: what is shipped

Every container's stdout/stderr, labelled as above, **except Traefik access logs**.

> **Decision (#23): Traefik access logs are excluded, not sampled.** A busy proxy's access log
> can spend the whole monthly log allowance, and neither Traefik incident in this repo's history
> was diagnosed from it — the 13-minute `Host()` outage and the ten-week VPS1 404 were both in
> Traefik's own error/router log, which is kept. bpvps2's Traefik does not enable `--accesslog`
> today; the drop rule matches both the common-log and JSON formats, so turning it on later does
> not quietly become the biggest line on the bill. If access logs are ever needed, sample them
> in `loki.process` rather than removing the drop.

Search in Grafana Cloud → **Explore → grafanacloud-logs**:

```logql
{host="bpvps2", container="booking-be-staging"} |= "some text"
```

## External checks

The ten-week VPS1 outage had every container healthy and every domain answering 404. Nothing on
the host can see that. **Grafana's own probes, outside our network, request every public name
every minute** — from Singapore, Tokyo and Mumbai (`probes:` in `grafana/synthetic/endpoints.yml`).

**The list of names is derived, never typed.** `vps/shared/public-endpoints.py` reads every
Traefik router on bpvps1 and bpvps2 — compose labels, fanout per destination, and the file
provider's `dynamic/*.yml` — and checks it against `apps/registry.yml`. A new router is a new check
with no other edit. CI fails when:

- a registry domain on bpvps1/bpvps2 is served by **no router** on that host (registry drift — how
  `bookingapi.teeko.ai` sat in the registry until 2026-08-31);
- a router's `${VAR}` has no value under `vars:` in `endpoints.yml`. Those values live in host
  `.env` files; read them with `docker inspect <container>` and its `traefik.*.rule` label;
- a registry domain is `skip`ped, a skip has no reason, or an entry names no router.

```bash
python vps/shared/public-endpoints.py        # the names, the host each is on, the URL probed
```

Each check: `GET https://<name>/`, redirects followed, **fail on plain HTTP**, 10 s timeout,
labels `host` and `managed_by=infrastructure`. The job name is the hostname. `grafana-apply.py`
creates, updates, and deletes a managed check whose router is gone; a hand-made check is never
touched.

**Skipped:** `traefik-bpvps1.teeko.ai` and `traefik-bpvps2.teeko.ai` — the dashboard routers exist
but neither name has a DNS record (2026-09-14), so nothing outside can reach them.

**Who renews each certificate** — where to look when `tls-expiry` fires:

| Names | Certificate from |
|---|---|
| `kaiteki.my`, `www.`, `staging.`, `blog.kaiteki.my` | Cloudflare's edge (proxied) — the probe sees Cloudflare's cert, renewed by Cloudflare |
| `mail.`/`webmail.` `kaiteki.my` and `blueprintdigital.my` | `vps/bpvps1/stacks/stalwart/renew-cert.sh` (acme.sh, DNS-01) |
| `webmail.reservetoday.app` | bpvps1 Traefik, `le-tls` (TLS-ALPN-01) — the record must stay DNS-only on Vercel |
| `api.reservetoday.app`, `api.dev.reservetoday.app` | bpvps2 Traefik, `le-tls` (TLS-ALPN-01) — [`tls-wildcard-constraint.md`](tls-wildcard-constraint.md) |

## Alerts

| Rule | Fires when | Resolves when |
|---|---|---|
| `container-down-bpvps2` | a declared container has reported no metrics for 3 min, held 1 min | its metrics return |
| `endpoint-down` | **every** probe failed a name at least two runs in a row (2 min window, no `for`). Names the host | any probe succeeds |
| `tls-expiry` | a name's served certificate has < 21 days left, held 10 min | a renewed cert is served |
| `backup-stale-bpvps2` | a backup target's last success is > 26 h old, or no backup heartbeat at all for 15 min; held 5 min | the next successful snapshot |
| `textfile-unreadable-bpvps2` | a `*.prom` file cannot be parsed, held 5 min | the producer writes a valid file |
| `textfile-canary-stale-bpvps2` | only during the seam test: `canary.prom` older than 5 min | the canary is refreshed or deleted |

**Endpoint alerts are per name.** If every name on one host fires together, it is Traefik or the
host, not eleven outages: `ssh bp-<host> 'docker ps; docker logs --tail 50 traefik'`.

The rule **names every container** on the host (`absent_over_time` per container). A rule over
all containers at once cannot work: a stopped container's series just stops, and Grafana treats
a vanished series as resolved. CI fails when a compose file on the host defines a container the
rule does not name, or a selector lacks `host="bpvps2"`. The agent's own container is exempt.

**If every container on a host fires at once**, it is the agent or the host that is down, not
six services. Check `ssh bp-bpvps2 'docker ps; docker logs --tail 50 alloy'`.

Contact points (email + phone push) are set in the Grafana Cloud console against the operator's
own addresses. **No address is committed here** — this repository is public.

## Operating it

### First-time setup (once per Grafana Cloud stack)

1. In the portal, create an **access policy** with scopes `metrics:write` and `logs:write`, and a
   token under it. From the stack's **Details** page take the Prometheus remote-write URL and
   user (instance ID) and the Loki push URL and user.
2. Put them in the host's **GitHub Environment** (`bpvps2`) on `Blueprint-Agency/infrastructure`,
   per the `provision` skill — not org level, where every other repo in the org could read the
   token. Variables `GRAFANA_CLOUD_PROM_URL`, `GRAFANA_CLOUD_PROM_USER`,
   `GRAFANA_CLOUD_LOKI_URL`, `GRAFANA_CLOUD_LOKI_USER` (endpoints and instance IDs, not
   secret); secret `GRAFANA_CLOUD_API_TOKEN`. bpvps1 (#25) gets the same five in its own
   Environment. An unset one fails the deploy by design.
3. Create a **service account** (Editor) and token for `grafana-apply.py`; put `GRAFANA_URL` and
   `GRAFANA_SA_TOKEN` in the local `.env`.
4. Open **Testing & synthetics → Synthetics** once, which initialises Synthetic Monitoring on the
   stack. Under its **Config** page take the **backend address** and generate an **access token**;
   put them in `.env` as `GRAFANA_SM_URL` (`https://` + the address) and `GRAFANA_SM_TOKEN`.
5. Configure alert delivery in the console — **Grafana's own paths only** (#22: no second
   alerting vendor, so no Telegram, ntfy or Pushover):
   - contact point **email**, to the operator's address;
   - contact point **phone**: the **Grafana IRM** mobile app, signed in as the operator;
   - notification policy: `severity=critical` → phone + email, **group wait 10s** (the
     `endpoint-down` timing in `grafana/rules/endpoints.yml` needs it — the default 30 s puts the
     five-minute headline test too close to call); `severity=warning` → email;
     `severity=info` → email only (the textfile canary must never page).

   The headline test below is how you know the phone path works.

### Applying dashboards and rules

```bash
set -a; . ./.env; set +a
python scripts/grafana-apply.py --dry-run
python scripts/grafana-apply.py
```

CI does **not** apply them, and `grafana/` changes do not trigger a deploy — apply after merging.
The drift check runs on the next deploy of any `vps/` change.

### Silencing during planned work

Grafana Cloud → **Alerts & IRM → Alerting → Silences → New silence**, matcher `host=bpvps2`
(and `container=<name>` to narrow it), with an end time. Never pause the rule itself — a paused
rule is easy to forget; a silence expires.

## Canary tests (bpvps2)

bpvps2 is not a staging box: it serves the booking API and `booking-staging` holds real studio
data. Each test runs in a **short, announced window** agreed in advance, and is recorded here.

| Test | How | Result |
|---|---|---|
| Metrics arrive | Dashboard **Hosts** shows bpvps2 host and container panels | _pending deploy_ |
| Log search | `docker exec backup sh -c 'echo monitoring-canary-<uuid> > /proc/1/fd/1'`, then find the string in Explore with `{host="bpvps2", container="backup"}` | _pending deploy_ |
| Container down | Announced window. `docker stop backup` — serves no public path, runs only at 03:30. Alert fires within ~5 min; `docker start backup`; alert resolves | _pending deploy_ |
| Agent overhead | `docker stats --no-stream alloy` over a week | _pending deploy_ |
| **Traefik stopped → phone alert (#24, the headline test)** | Announced window — interrupts the booking API. Silence nothing. `ssh bp-bpvps2 'docker stop traefik'`, note the time. Pass: `endpoint-down` for `api.reservetoday.app` and `api.dev.reservetoday.app` reaches the **phone** within 5 min, naming **bpvps2**. Then `ssh bp-bpvps2 'docker start traefik'` at once, and confirm it resolves. `container-down-bpvps2` for `traefik` fires too — expected | _pending Grafana Cloud setup + an agreed window_ |
| Textfile seam | [`textfile-metrics.md`](textfile-metrics.md), "Testing the seam" — no window needed. Pass: value queryable within a minute; `textfile-canary-stale-bpvps2` fires when left, resolves when refreshed | _pending deploy_ |
| Backup heartbeat (#27) | Blocked on the seam; run right after it. [`backup-restore.md`](backup-restore.md) | _pending deploy_ |
| TLS days vs `openssl` | Dashboard **Endpoints** → *TLS days left* for `api.reservetoday.app`, against `echo \| openssl s_client -servername api.reservetoday.app -connect api.reservetoday.app:443 2>/dev/null \| openssl x509 -noout -enddate`. Pass: same day count. `openssl` side on 2026-09-14: `notAfter=Nov 7 15:40:49 2026 GMT` (≈54 days) | _pending Grafana Cloud setup_ |
| Every name has a check | `python vps/shared/public-endpoints.py` lists 11 names; **Synthetics → Checks** shows the same 11 after apply | repo side: 11 names, all answering on 2026-09-14. Account side _pending_ |
