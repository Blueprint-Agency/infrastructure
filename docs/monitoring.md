# Monitoring

Host and container metrics plus container logs, shipped by one Grafana Alloy agent per host to
Grafana Cloud, with dashboards and alert rules kept in this repository (#22).

**Coverage today: bpvps2 only** (#23) — the canary. bpvps1 is #25; external endpoint and TLS
checks and the textfile seam are #24. The three Teeko hosts are out of scope by decision (#22).

## The pieces

| | Where |
|---|---|
| Agent | `vps/bpvps2/stacks/monitoring/` — container `alloy`, deployed by `deploy-infra.yml` like any stack |
| Alloy version | the `FROM` line of that stack's `Dockerfile`, exact tag. CI validates `config.alloy` against it |
| What metrics ship | `metrics.allowlist` in the stack — one metric name per line, **keep** only those |
| What logs ship | `loki.process "select"` in `config.alloy` — every container, minus Traefik access logs |
| Dashboards | `grafana/dashboards/*.json` |
| Alert rules | `grafana/rules/*.yml` (Grafana file-provisioning format) |
| Applying them | `scripts/grafana-apply.py` — the files are the copy of record; UI edits are overwritten |
| Drift check | `vps/shared/check-monitoring.py`, run in CI |

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

## Alerts

| Rule | Fires when | Resolves when |
|---|---|---|
| `container-down-bpvps2` | a declared container has reported no metrics for 3 min, held 1 min | its metrics return |

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
4. Configure contact points and the default notification policy in the console.

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
