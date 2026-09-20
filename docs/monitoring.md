# Monitoring

Host and container metrics plus container logs, shipped by one Grafana Alloy agent per host to
Grafana Cloud, with dashboards and alert rules kept in this repository (#22).

**Coverage:** the agent and the textfile probes run on **bpvps1 and bpvps2** (#23, #25) — every
host in scope. **External endpoint and TLS checks cover every public name on both** (#24).
The three Teeko hosts are **out of scope by decision** (#22): each carries
`no_monitoring: <reason>` in `vps/hosts.json`, and `check-monitoring.py` prints those reasons on
every run. Nothing on vps1-staging, vps2-prod or vps3-prod is watched.

> **Live since 2026-09-14.** Grafana Cloud stack `blueprintdigital`, region
> `prod-ap-southeast-1`. Both hosts run `alloy` and `probes` and are shipping metrics and logs;
> 11 Synthetic checks probe every public name from Singapore, Tokyo and Mumbai; alerts deliver
> to Discord. What remains _pending_ below is **testing**, not deployment — and the two that
> matter most, the Traefik stop (#24) and a real backup heartbeat going stale and recovering,
> have not been run. Deployed is not the same as proven.

> ⚠️ **The account is on a trial that ends 2026-09-27.** Limits today are Pro, not free, so any
> usage figure read before then is not the one you will live with. The `series-budget` rule
> hardcodes 8000 = 80% of the free tier's 10,000. Revisit both when the trial ends.

## The pieces

| | Where |
|---|---|
| Agent | `vps/<host>/stacks/monitoring/` — container `alloy`, deployed by `deploy-infra.yml` like any stack |
| Textfile probes | same stack, container `probes` — restart counts, Postgres connections, Tailscale key expiry, mail ports. `probes/bin/probe.sh` |
| Database Observability | bpvps2 only: `vps/bpvps2/stacks/db-observability/`, container `db-observability` — a second Alloy on the booking networks. See its section |
| One implementation | everything in that stack **except `docker-compose.yml` and `ci/`** is an identical copy on both hosts. CI fails if the copies drift: change both in one commit |
| Alloy version | the `FROM` line of the stack's `Dockerfile`, exact tag. CI validates `config.alloy` against it |
| What metrics ship | `metrics.allowlist` — one metric name per line, **keep** only those |
| What logs ship | `loki.process "select"` in `config.alloy` — every container, minus Traefik access logs |
| Dashboards | `grafana/dashboards/*.json` |
| Alert rules | `grafana/rules/*.yml` (Grafana file-provisioning format) |
| External checks | one Synthetic Monitoring HTTP check per public name — derived by `vps/shared/public-endpoints.py`, exceptions in `grafana/synthetic/endpoints.yml` |
| Textfile seam | the `monitoring_textfile` volume, read at `/textfile` — contract in [`textfile-metrics.md`](textfile-metrics.md) |
| Applying them | `scripts/grafana-apply.py` — the files are the copy of record; UI edits are overwritten |
| Drift check | `vps/shared/check-monitoring.py`, `vps/shared/public-endpoints.py`, `scripts/test_probes_lib.sh`, in CI's `monitoring-drift` job on every push |

## Grafana Cloud entitlements

> ⚠️ **Not yet confirmed at the account.** #22 requires reading these off the account itself —
> published summaries disagree on retention. Fill this table from the Grafana Cloud portal
> (**My Account → Usage / Billing**), with the date, before trusting any figure below. The
> `series-budget` rule hardcodes 8000 = 80% of 10,000: change it with the confirmed figure.

| | Documented (#22) | Confirmed at the account |
|---|---|---|
| Active metric series | 10,000 | _pending_ |
| Logs ingested / month | 50 GB | _pending_ |
| Metric retention | 13 months (some summaries say 14 days) | _pending_ |
| Log retention | 30 days (some summaries say 14 days) | _pending_ |
| Users | 3 | _pending_ |

## Budget

#25 asked for this measured after a week of real data. **Measured in Grafana Cloud on
2026-09-15, after one day** — not seven. Recorded anyway, because the number settles almost
immediately: active series is a function of how many containers and metric families are
collected, not of elapsed time, and at **16% of the ceiling** a further six days cannot change
the conclusion. Re-read it if a stack is added.

> ⚠️ Read on a **trial** (ends 2026-09-27), so the *limits* in force today are Pro, not free.
> The usage figures below are real; the ceiling they are measured against is the free-tier one
> the `series-budget` rule assumes, which is the right thing to plan for.

| | bpvps1 | bpvps2 | Both | Ceiling | Headroom |
|---|---|---|---|---|---|
| Series, exporters after the allowlist — **measured** | 88 (8 containers) | 66 (6 containers) | 154 | | |
| Series, estimated once deployed (+ `alloy`, `probes`, bpvps1's `backup`, and the textfile series) | ~136 | ~106 | **~242** | 10,000 | **~97.6%** |
| Synthetic Monitoring series (11 checks × 3 probes) | | | _pending — read `grafanacloud_instance_active_series` after apply_ | | |
| Container logs, bytes in the last 24 h — **measured** | 2.0 MB (wordpress 1.6 MB, stalwart 0.36 MB) | 7 KB | ~2 MB/day ≈ **60 MB/month** | 50 GB | **~99.9%** |
| **Measured in Grafana Cloud, 2026-09-15** (1 day, see above) | 154 | 128 | **1,569 total**, incl. Synthetics and Grafana's own series | 10,000 | **84.3%** |
| Database Observability (#166), **estimated** — see its section | | ~1,100 | ~1,100 | | _re-read after deploy_ |

The estimate above was ~242 for the two hosts; the hosts themselves came in at **282**, close
enough. The rest of the 1,569 is Synthetic Monitoring and Grafana Cloud's own bookkeeping
series, which the estimate did not attempt. `Active series over 80% of the ceiling` is
`inactive`, with room for roughly five more hosts before it is not.

How the source figures were taken: series — the real exporter config run briefly on each host
and its output filtered through `metrics.allowlist` (root cgroup dropped, as `config.alloy` does);
logs — `docker logs --since 24h <c> | wc -c` for every running container.

Per container, expect ~7 series (more if it sits on several networks), plus 1 restart-count
series. Per backup target 2, per Postgres 2, per mail port 1.

**After a week** (the acceptance figure): Explore → `grafanacloud-usage` →
`grafanacloud_instance_active_series` and `grafanacloud_logs_instance_bytes_received_per_second`
(× 86400 for a day). Record both here with the date and the headroom against the **confirmed**
ceiling.

> **First deploy replays old logs once.** With no saved read positions, Alloy's Docker log
> source reads each container's whole log. On bpvps1 on 2026-09-14 that was ~42,000 WordPress
> lines in the first minute (seven weeks of Apache access log). One-time, a few tens of MB; Loki
> may refuse the oldest lines as too old, which Alloy logs as warnings for a few minutes.
> `monitoring_alloy_data` keeps positions afterwards — do not delete it casually.

**Agent overhead**, smoke runs with the real config: bpvps2 (1 vCPU / 4 GB) ~69 MiB, ~1% CPU
(2026-09-13); bpvps1 (2 vCPU / 8 GB) ~68 MiB, <1% CPU (2026-09-14). Caps: 0.5 CPU / 384 MiB for
`alloy`, 0.1 CPU / 64 MiB for `probes`. _Re-measure after a week of real shipping._

## Labels

Every metric and log line carries:

| Label | Value |
|---|---|
| `host` | `MONITORING_HOST` in the stack's compose — the `vps/hosts.json` key, `bpvps1`/`bpvps2`. Not the kernel hostname; CI checks it matches the key the rules use |
| `container` | `booking-be-staging`, `stalwart`, `traefik`, … |
| `compose_project` | the **stack directory** on the host — `booking-staging` vs `booking-prod` |
| `compose_service` | the compose service key — `booking-be`, `db-booking`, … |

One more, **on logs only, and only on `booking-be`**: `level`, the Pino level of each JSON line
(`trace` … `fatal`). The backend's other fields — `requestId`, `tenantId`, `actorId`, `job`,
`webhook`, `outcome` — are **never labels**: the first three are unbounded (a stream per request,
Tenant or user), and all six are read at query time with `| json`. A Tenant is always its id,
never a studio's name, in every query and rule.

```logql
sum by (container) (count_over_time({container="booking-be-staging", level="error"} [5m]))
{container="booking-be-staging", level="error"} | json | webhook="stripe"
sum(count_over_time({container="booking-be-staging"} | json | job="<job>" | outcome="ok" [25h]))
```

Probe heartbeats carry `probe` (`docker`, `postgres`, `mail`, `tailscale`) — **never `job`**, which
the agent's scrape owns and would rename to `exported_job`.

> **booking-staging and booking-prod are one compose file deployed twice.** Their service keys
> are identical; only `container` and `compose_project` tell them apart. Filter on one of those,
> never on `compose_service` alone — `booking-staging` is the instance with the real data.

## Metrics: the allowlist

Only names in `metrics.allowlist` leave the host. A metric family costs nothing until it is
listed. **Adding a metric is a line in the allowlist plus the panel or rule that reads it**, in
the same commit. CI fails:

- an allowlisted name that no panel or rule under `grafana/` reads — budget spent on nothing;
- a `node_*` / `container_*` / textfile-producer name a panel or rule reads that is not
  allowlisted — the agent drops it, so the panel is empty or the rule never fires;
- any allowlist line that is not a bare metric name. Alloy joins the lines with `|` into one
  regex; a comment or a `(` would silently change it.

Collected on both hosts: host CPU, memory, disk and network (`node_*`); per-container CPU, memory,
disk I/O and network plus `container_last_seen` (`container_*`, cadvisor built into Alloy); and
the textfile producers' metrics. Container **disk** is I/O bytes, not usage: cadvisor's usage
figure walks each container's filesystem, which is not a cost to put on a 1 vCPU host.

## Logs: what is shipped

Every container's stdout/stderr, labelled as above, **except Traefik access logs**.

> **Decision (#23): Traefik access logs are excluded, not sampled.** A busy proxy's access log
> can spend the whole monthly log allowance, and neither Traefik incident in this repo's history
> was diagnosed from it — the 13-minute `Host()` outage and the ten-week VPS1 404 were both in
> Traefik's own error/router log, which is kept. Neither host's Traefik enables `--accesslog`
> today; the drop rule matches both the common-log and JSON formats, so turning it on later does
> not quietly become the biggest line on the bill. WordPress's own Apache access log on bpvps1
> **is** shipped — 1.6 MB/day, measured.

**bpvps1's root-owned stacks are read like any other.** The agent reads logs through the Docker
socket, not the stack directories, so `root:root` on stalwart/traefik/wordpress does not matter.
Confirmed on the host on 2026-09-14 rather than assumed: every container's log driver is
`json-file`, and a smoke run's log tailer attached to all eight containers with no error.

> **No root step was needed to create bpvps1's stack dir.** #25 expected one; on 2026-09-14
> `/root/stacks` on bpvps1 is `deploy:deploy`, so CI's `mkdir -p /root/stacks/monitoring` creates
> it `deploy`-owned on the first deploy. `ci/post-sync.sh` refuses the deploy if anything in it is
> ever not `deploy`-owned. If `/root/stacks` is ever re-owned by root, the fix is once, as root:
> `install -d -o deploy -g deploy /root/stacks/monitoring`.

Search in Grafana Cloud → **Explore → grafanacloud-logs**:

```logql
{host="bpvps1", container="stalwart"} |= "some text"
```

**Log caps on the host (#166).** Every service in the booking compose carries `logging:` json-file,
`max-size: 10m`, `max-file: 3` — at most 30 MB of local log per container, whatever a crash-loop
writes. Loki is the durable copy; rotation only drops the host-local tail. The booking compose is an
`app_stack`, so the caps take effect when booking-system's deploy next recreates the containers
(or `docker compose up -d` by hand in `/root/stacks/booking-{staging,prod}`). Check with
`docker inspect booking-be-staging --format '{{json .HostConfig.LogConfig}}'`.

## Database Observability (#166)

Grafana Cloud's **Database Observability** — query statistics, query samples with wait events, and
schema details — for **both booking Postgres instances**, from its own stack on bpvps2:
`vps/bpvps2/stacks/db-observability/`, container `db-observability`.

| | |
|---|---|
| Why a separate stack | the `alloy` agent is on the host network and neither Postgres publishes a port; this one joins `booking-staging-network` and `booking-prod-network` and dials `booking-db-staging` / `booking-db-prod`. And the monitoring stack is one implementation on both hosts; only bpvps2 has these databases |
| Postgres side | the booking compose's `command:` preloads `pg_stat_statements` with `compute_query_id=on`, `pg_stat_statements.track=all`, `track_activity_query_size=4096` — startup settings, so the next booking deploy restarts each Postgres once |
| Monitoring role | `db-o11y`, `pg_monitor` only, `NOBYPASSRLS`, connection limit 10, a different password per instance (hygiene — blast radius and independent rotation; no Grafana or Postgres document requires it). **It cannot read a row of booking data** — no `SELECT`, no `pg_read_all_data`. Created by hand once per instance with `setup-db-o11y.sql` (below) |
| Collectors | `query_details`, `query_samples` (literals redacted — the default, keep it), `schema_details`, and the exporter's `stat_statements`, `database`, `stat_database`. **`explain_plans` is off**: `EXPLAIN` needs `SELECT` on every table it plans. Grafana's alternative grant `pg_read_all_data` does **not** set `BYPASSRLS`, and booking-system's migration `0033` `FORCE`s row-level security on every `tenant_id` table — so it would read those back *empty*. What it would expose is what `0033` leaves outside RLS: the `tenants` / `tenant_settings` rows (each Tenant's identity, premises and branding copy) and any table with no `tenant_id`. That is the reason to refuse it |
| Object grants skipped | Grafana's setup page also asks for `GRANT SELECT ON ALL TABLES` (or `pg_read_all_data`) "for detailed data". Skipped, and the schema tab still fills — but **only because Alloy v1.19.2's `schema_details` reads `pg_catalog`, never `information_schema`**. This is version-coupled: re-read that collector before the stack's `Dockerfile` tag moves |
| Labels | `job="integrations/db-o11y"` (what Database Observability looks for), `instance` = `booking-staging` / `booking-prod`, `host` |
| Budget | a keep-list in its `config.alloy` (`prometheus.relabel "keep"`). ~290 series per instance measured against a local Postgres; `stat_statements { limit = 100 }` bounds it near 540 each, **~1,100 for both**. Query samples and schema details are Loki lines, not series |
| Not collected | Postgres's own server log (the `logs` collector wants `log_line_prefix` changed and a file to tail; its container log already reaches Loki through `alloy`) |

### Turning it on — once, in this order

1. **Two passwords, before merging**, hex so they need no URL escaping: `openssl rand -hex 24`,
   twice. Store them as **secrets** `DB_O11Y_STAGING_PASSWORD` and `DB_O11Y_PROD_PASSWORD` in the
   **bpvps2** GitHub Environment on `Blueprint-Agency/infrastructure`. An unset one fails the deploy
   by design — and the merge deploys this stack.
2. **Merge.** CI deploys `db-observability` (it logs `failed to ping database` and retries until
   step 4 — expected), redeploys `alloy` on both hosts, and syncs the booking compose without
   starting it (booking is an `app_stack`).
3. **Restart each booking Postgres onto the new settings**: booking-system's next deploy does it, or
   `docker compose up -d` in each `/root/stacks/booking-*` — a few seconds of database downtime
   each; it also applies the log caps. Confirm:
   `docker exec booking-db-staging sh -c 'psql -U "$POSTGRES_USER" -d postgres -tAc "show shared_preload_libraries"'`
   prints `pg_stat_statements`.
4. **Create the role** on each instance, from `/root/stacks/db-observability` on bpvps2, where CI put
   the SQL. The script refuses to run before step 3:
   ```bash
   read -rs PW   # the staging password from step 1
   docker exec -i -e PW="$PW" booking-db-staging sh -c \
     'psql -X -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d postgres -v pw="$PW" -v booking_db="$POSTGRES_DB"' \
     < setup-db-o11y.sql
   # then the same with the prod password and booking-db-prod
   ```
   Pass: all four privilege columns `t` — `has_pg_monitor`, `has_pg_read_all_stats`,
   `password_is_scram`, `no_redacted_query_text` — plus `compute_query_id = on`,
   `pg_stat_statements_track = all`, `track_activity_query_size = 4096`. (The old check,
   `count(*) > 0 FROM pg_stat_statements`, proved nothing: the extension grants that view to
   `PUBLIC`, so it passed even when `GRANT pg_monitor` had not taken.)
5. **Verify**: `ssh bp-bpvps2 'docker logs --tail 50 db-observability'` shows no `failed to ping
   database`; Grafana Cloud → **Database Observability → Configuration → Telemetry status** passes
   for `booking-staging` and `booking-prod`; **Queries overview** lists queries within a few minutes.

   Also check the connection limit, which is a guess and not a measurement:
   ```bash
   ssh bp-bpvps2 "docker logs db-observability 2>&1 | grep -i 'too many connections'"
   ```
   `CONNECTION LIMIT 10` on the role is unvalidated: the exporter's autodiscovery scrapes every
   database, and `schema_details` opens a **separate connection per discovered database**, on top
   of the component's own pool. With two databases (`postgres` and the booking one) 10 should
   hold. If that grep matches, raise it —
   `ALTER ROLE "db-o11y" CONNECTION LIMIT 20;` on that instance — and say so here.

If a Database Observability view stays empty while telemetry status passes, the keep-list is the
first suspect: it names what leaves the host, and a newer Database Observability may read a metric
it does not keep.

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

## Mail ports: probed from bpvps2

HTTPS checks cannot see SMTP or IMAP, so bpvps1's mail ports **25, 465 and 993** are probed by the
`probes` container on **bpvps2** (`MAIL_PROBE_TARGET` in bpvps2's monitoring compose), every minute,
as `mail.blueprintdigital.my`.

- **Never from bpvps1 itself** — a probe from the mail host never leaves the box. **Never from a
  laptop** — home ISPs block outbound 25, so it reads BLOCKED on a healthy server. With the Teeko
  hosts out of scope, bpvps2 is the only prober left.
- **Addresses, not names.** `probe.sh` resolves the target and refuses to probe when any of its
  addresses is one of this host's own. Proven on 2026-09-14: pointed at `mail.blueprintdigital.my`
  on bpvps1, it refused with "this host IS mail.blueprintdigital.my (187.127.122.41)".
- **Polite, so bpvps2 never gets banned.** It waits for the greeting (`220` / `* OK`), then sends
  one `QUIT` / `a LOGOUT`. It never talks first (an SMTP "early talker" is a spam signal) and never
  hangs up silently (loitering). 465 and 993 are full TLS handshakes. If `mail-port-down` ever
  fires for every port while mail works for users, check for a Stalwart ban on 187.127.207.82 and
  add it as an `x:AllowedIp` entry (`vps/bpvps1/stacks/stalwart/README.md`).
- **Two in a row** is counted by the prober itself, so it does not depend on scrape timing. #29's
  nightly mail-store snapshot stops Stalwart at 04:30 — 4 s measured, so one failure at most. Its
  worst case (~13 min, `docs/backup-restore.md`) **does** fire this and `container-down-bpvps1`,
  and should: mail is down. Check `docker logs backup` first.

## Alerts

The policy is deliberately short: a handful of rules, each meaning one thing a person must act on.

| Rule | Severity | Fires when |
|---|---|---|
| `container-down-<host>` | critical | a declared container has reported no metrics for 3 min, held 1 min |
| `container-restarting` | critical | a container restarted more than twice in 15 min (Docker's restart policy) |
| `disk-warning` / `disk-critical` | warning / critical | a real disk over 80% / 90%, held 5 min |
| `memory-high` | warning | memory over 90%, held 15 min |
| `postgres-connections` | warning | a Postgres over 80% of `max_connections`, held 5 min |
| `mail-port-down` | critical | bpvps1's port 25, 465 or 993 failed two probes in a row from bpvps2 |
| `endpoint-down` | critical | **every** probe failed a public name two runs in a row |
| `tls-expiry` | warning | a served certificate has < 21 days left, held 10 min |
| `backup-stale-<host>` | critical | a backup target's last success > 26 h old, or no heartbeat at all |
| `tailscale-key-expiry` | warning | a node's `Self.KeyExpiry` is present |
| `probes-stale-<host>` | warning | a textfile probe has not completed within its own max age, or no probe heartbeat at all |
| `textfile-unreadable` | warning | a `*.prom` file cannot be parsed, held 5 min |
| `series-budget` | warning | active series > 80% of the ceiling, held 1 h |
| `textfile-canary-stale` | info | only during the seam test |

**Why some rules are per host.** A rule that fires on a value that is present and too high
(disk, memory, restarts) is written once for every host. A rule that must notice **silence** —
a container gone, a heartbeat gone — has to name the host in `absent_over_time`, so
`container-down-`, `backup-stale-` and `probes-stale-` exist once per host. CI requires them for
every monitored host, and every selector in them must carry that host's `host=` matcher.

**How a rule's annotations are written.** `summary` names *what* is checked and nothing about
its state (`Disk / on bpvps2`); `value` says what is wrong (`93% full`); `description` is the
first action. Grafana re-renders annotations at the moment an alert resolves, so a summary
written as "X is broken" arrives in Discord under ✅ RESOLVED still saying it is broken. The
Discord template in `grafana/alerting/notifications.yml` prints `value` only under **Firing**.
Why, with sources: `docs/research/grafana-discord-alert-format.md`.

`container-down-<host>` **names every container** on the host. A rule over all containers at once
cannot work: a stopped container's series just stops, and Grafana treats a vanished series as
resolved. CI fails when a compose file on the host defines a container the rule does not name.
The monitoring stack's own containers are exempt — an agent cannot report its own absence.

### Where an alert lands

Two Discord channels, one routing tree. The rule's **`app` label** decides, and nothing else:

| A rule labelled | goes to contact point | because |
|---|---|---|
| no `app` label | `discord` | it is infrastructure — a host, a container, a certificate |
| `app: booking` | `discord-booking` | booking-system's own alerts, in their own room |

Severity only sets the pace (10s / 1m / 5m group wait), never the destination — both channels run
the same three tiers, written once in `grafana/alerting/notifications.yml` and merged into both.

**The label is the contract, not the folder.** A booking rule filed in the `Apps` folder but
missing `app: booking` is not silent — it arrives in the infra channel, which is the wrong room
and harder to notice than silence. Every rule in `grafana/rules/booking.yml` carries
`app: booking` in its static `labels:`, beside `severity`.

**Order in the tree is load-bearing.** Grafana stops at the first matching sibling policy, and
every app alert also carries a `severity`, so the `app` routes sit *above* the severity routes; an
app route placed below them would never be reached. `scripts/test_grafana_apply.py` fails the
build if that order is ever inverted. Why, with citations:
`docs/research/grafana-multi-app-alert-routing.md`.

Adding the next app is four things and no redesign — see `docs/grafana-organization.md`, "A new
app = a webhook, a contact point, a route, a label".

### What each alert means, and the first three things to check

Replace `<host>` with the alert's `host` label. Every alert names it.

**`container-down-<host>`** — a container is gone: stopped, removed, or crash-looping too fast to
report.
1. **Is it every container on the host at once?** Then it is the agent or the host, not N
   outages: `ssh bp-<host> 'docker ps; docker logs --tail 50 alloy'`. No SSH at all → the host or
   the tailnet (Hostinger console).
2. `ssh bp-<host> 'docker ps -a --filter name=<container>; docker logs --tail 100 <container>'`.
3. A deploy in progress? `docker compose up` recreates containers; a few minutes of absence during
   a deploy fires this. Silence deploys you plan.

**`container-restarting`** — a container is crash-looping; it is up often enough that
`container-down` stays quiet.
1. `ssh bp-<host> 'docker logs --tail 100 <container>'` — the reason it dies is usually the last
   lines before each start.
2. Did its image or `.env` just change? `docker inspect <container> --format '{{.Created}} {{.Config.Image}}'`.
3. Does a dependency answer (its database, `unbound` for stalwart)? `docker ps` on the same host.

**`disk-warning` / `disk-critical`** — a real filesystem is filling.
1. `ssh bp-<host> 'df -h; docker system df'`.
2. Old images: `docker image prune -af` is what every deploy already runs; build cache:
   `docker builder prune -f`. Container logs: `docker ps -q | xargs docker inspect --format '{{.LogPath}}'`
   (size them as root).
3. On bpvps1, the mail store (`stalwart_stalwart-data`, 7.3 GB on 2026-09-14) and backup cache
   (`backup_restic_cache`) are the large volumes: `docker system df -v`.

**`memory-high`** — sustained, not a spike.
1. Hosts dashboard → "Memory by container" for the last hour: which one grew?
2. `ssh bp-<host> 'free -m; docker stats --no-stream'`.
3. bpvps2 has 4 GB and two booking instances; a leak in `booking-be-*` is the usual suspect. A
   restart of the grown container buys time, not a fix.

**`postgres-connections`** — near the point where new connections are refused.
1. `ssh bp-bpvps2 'docker exec <container> psql -U "${POSTGRES_USER:-postgres}" -d postgres -c "select usename, application_name, state, count(*) from pg_stat_activity group by 1,2,3 order by 4 desc"'` — read only.
2. Many `idle` from one app: its pool is leaking or oversized. `idle in transaction`: a stuck request.
3. Did a deploy just double the pools (old and new containers both up)? That resolves on its own.

**`mail-port-down`** — bpvps1 is not answering mail on that port, as seen from bpvps2.
1. `ssh bp-bpvps1 'docker ps --filter name=stalwart; docker logs --tail 50 stalwart'`.
2. `scripts/verify-mail.sh blueprintdigital.my` — the full mail check, inbound leg via another host.
3. Every port at once and Stalwart looks healthy: the Hostinger firewall group 319466 (shared with
   bpvps2), or a Stalwart ban on bpvps2's address — see "Mail ports" above.

**`endpoint-down`** — a public name fails from every Grafana probe.
1. **Every name on the host at once?** Traefik or the host: `ssh bp-<host> 'docker ps; docker logs --tail 50 traefik'`.
   A multi-argument `Host()` kills a router silently — it is in that log.
2. One name: its container (`container-down` alongside?), its router rule, its DNS record.
3. `curl -sv https://<name>/ -o /dev/null` from anywhere but the host.

**`tls-expiry`** — a certificate has not renewed in over a week of trying.
1. Which renewer owns the name: the table under "External checks".
2. acme.sh names: `vps/bpvps1/stacks/stalwart/README.md`. `le-tls` names: `docker logs traefik | grep -i acme`
   on that host; the record must be DNS-only.
3. `echo | openssl s_client -servername <name> -connect <name>:443 2>/dev/null | openssl x509 -noout -enddate`.

**`backup-stale-<host>`** — a backup target has not succeeded for a night. Runbook:
[`backup-restore.md`](backup-restore.md).
1. `ssh bp-<host> 'docker logs --tail 100 backup'`.
2. `docker exec backup /app/bin/backup.sh` runs it now, with output.
3. No target label at all: `backup.prom` is gone or the agent cannot read it — `textfile-unreadable`
   or `container-down` alongside says which.

**`tailscale-key-expiry`** — a node will drop off the tailnet on the date shown, and with port 22
closed that means console-only recovery.
1. Tailscale admin console → **Machines** → the host → **⋯ → Disable key expiry**.
2. `ssh bp-<host> 'docker exec probes /app/bin/probe.sh tailscale'` — rewrites the file now; the
   alert resolves on the next evaluation.
3. A tag does **not** disable expiry on its own. If the node was re-authenticated, check the other hosts too.

**`probes-stale-<host>`** — a probe job stopped, so the alert it feeds is blind. The `probe` label
says which (`docker` → `container-restarting`, `postgres` → `postgres-connections`, `mail` →
`mail-port-down`, `tailscale` → `tailscale-key-expiry`).
1. `ssh bp-<host> 'docker ps --filter name=probes; docker logs --tail 50 probes'` — a failing job logs why.
2. Run it by hand: `docker exec probes /app/bin/probe.sh <probe>`; the exit status and message are the answer.
3. `probe=mail` on bpvps1: someone set `MAIL_PROBE_TARGET` there. It refuses by design; unset it.
   No `probe` label at all: the `probes` container is gone.

**`textfile-unreadable`** — a `*.prom` file is malformed, so that producer's metrics stopped.
1. `ssh bp-<host> 'docker logs --tail 50 alloy'` names the file.
2. The usual cause is a producer writing in place instead of `tmp` + `mv`.
3. Contract: [`textfile-metrics.md`](textfile-metrics.md).

**`series-budget`** — something new is expensive.
1. Explore → `grafanacloud-prom`: `topk(10, count by (__name__) ({__name__=~".+"}))`.
2. The last change to a `metrics.allowlist`, or a new container on several networks.
3. The Synthetic Monitoring checks count too: 11 names × 3 probes.

**`textfile-canary-stale`** — only expected during the seam test. Delete `canary.prom`.

### Tune or delete

> **Any alert that fires twice without a real problem is tuned or deleted the same week.**

This is the rule that keeps the system trusted. An alert people have learnt to ignore is worse than
no alert: it trains the reflex that dismisses the real one. So when an alert fires and nothing was
wrong, write it down (date, rule, why it was not real) in the issue tracker. On the second one:
change the threshold, the `for`, or the query — or delete the rule — in a commit that says which
false alarms it answers. "Leave it and see" is not an option; a silence is not a tune.

Contact points (email + phone push) are set in the Grafana Cloud console against the operator's
own addresses. **No address is committed here** — this repository is public.

## Operating it

### First-time setup (once per Grafana Cloud stack)

1. In the portal, create an **access policy** with scopes `metrics:write` and `logs:write`, and a
   token under it. From the stack's **Details** page take the Prometheus remote-write URL and
   user (instance ID) and the Loki push URL and user.
2. Put them in **each host's GitHub Environment** (`bpvps1` and `bpvps2`) on
   `Blueprint-Agency/infrastructure`, per the `provision` skill — not org level, where every other
   repo in the org could read the token. Variables `GRAFANA_CLOUD_PROM_URL`,
   `GRAFANA_CLOUD_PROM_USER`, `GRAFANA_CLOUD_LOKI_URL`, `GRAFANA_CLOUD_LOKI_USER` (endpoints and
   instance IDs, not secret); secret `GRAFANA_CLOUD_API_TOKEN`. An unset one fails the deploy by design.
   bpvps2 also needs secrets `DB_O11Y_STAGING_PASSWORD` and `DB_O11Y_PROD_PASSWORD` for its
   `db-observability` stack — see "Database Observability" for the order.
3. Create a **service account** (Editor) and token for `grafana-apply.py`; put `GRAFANA_URL` and
   `GRAFANA_SA_TOKEN` in the local `.env`.
4. Open **Testing & synthetics → Synthetics** once, which initialises Synthetic Monitoring on the
   stack. Under its **Config** page take the **backend address** and generate an **access token**;
   put them in `.env` as `GRAFANA_SM_URL` (`https://` + the address) and `GRAFANA_SM_TOKEN`.
5. Configure alert delivery in the console — **Grafana's own paths only** (#22: no second
   alerting vendor, so no Telegram, ntfy or Pushover):
   **Contact points and the routing tree are a file** — `grafana/alerting/notifications.yml`,
   applied by `grafana-apply.py` like the dashboards and rules. The only manual part is
   creating each Discord webhook (Server Settings → Integrations → Webhooks → New Webhook) and
   putting its URL in `.env` — `DISCORD_WEBHOOK_URL` for infrastructure,
   `DISCORD_BOOKING_WEBHOOK_URL` for booking-system's own alerts. They are credentials and this
   repository is public, so they never go in the yaml; an unset one fails the apply rather than
   creating a contact point that silently delivers nothing.

   As configured on 2026-09-14, extended 2026-09-20: two contact points, `discord` (infra) and
   `discord-booking`, identical in format and differing only in webhook. Both run the same three
   severity tiers: `critical` → 10s group wait (the `endpoint-down` timing in
   `grafana/rules/endpoints.yml` needs it), `warning` → 1m, `info` → 5m and a day between
   repeats, because `info` is the textfile canary and it is *meant* to fire during the seam test.

   > ⚠️ **Discord will not reliably wake anyone at 2am** — phone Do Not Disturb silences it.
   > Set that server to "All Messages" and add it to the DND exceptions, or accept that an
   > overnight critical is read in the morning. Email is **not** configured yet; when it is,
   > `critical` should gain an email integration beside the Discord one.

### Applying dashboards and rules

```bash
set -a; . ./.env; set +a
python scripts/grafana-apply.py --dry-run
python scripts/grafana-apply.py
```

CI does **not** apply them — apply after merging. A `grafana/` change triggers only the drift job.

### Silencing during planned work

Grafana Cloud → **Alerts & IRM → Alerting → Silences → New silence**, matcher `host=<host>`
(and `container=<name>` to narrow it), with an end time. `mail-port-down` carries `host=bpvps1` —
the mail host, not the prober — so a bpvps1 silence covers it. Never pause the rule itself — a
paused rule is easy to forget; a silence expires.

### Adding a host

In the same commit (the `provision` skill onboards the host into CI first):

1. Copy `vps/bpvps2/stacks/monitoring/` to `vps/<host>/stacks/monitoring/` — **everything**. Then
   in the new `docker-compose.yml` set `MONITORING_HOST: <host>` (the `vps/hosts.json` key), size
   the `cpus`/`mem_limit` for the host, and remove `MAIL_PROBE_TARGET` unless this host is the mail
   prober. If the host has root-owned stacks, use bpvps1's `ci/post-sync.sh`, which refuses a dir
   not owned by `deploy`.
2. `grafana/rules/containers.yml`: a `container-down-<host>` rule naming every container — run
   `python vps/shared/check-monitoring.py`, it lists the missing ones.
3. `grafana/rules/textfile.yml`: `probes-stale-<host>`, and `backup-stale-<host>` if it runs the
   backup job — copies of bpvps1's with the host swapped. The generic rules need nothing.
4. If a named volume appears, the host's backup `targets.yml` needs a skip for
   `monitoring_alloy_data` (copy bpvps1's reason).
5. The five `GRAFANA_CLOUD_*` values in the host's GitHub Environment.
6. Or the opposite decision: `no_monitoring: <reason naming what goes unwatched>` in `vps/hosts.json`.

A host with neither a monitoring stack nor `no_monitoring` fails CI.

### Adding an endpoint check

Nothing to add — a new Traefik router on bpvps1/bpvps2 **is** a new check. If its rule uses a
`${VAR}`, give the value under `vars:` in `grafana/synthetic/endpoints.yml`; if it must not be
checked, a `skip:` with a reason there. Then `python scripts/grafana-apply.py`. See "External checks".

### Adding a textfile metric

The producer checklist is in [`textfile-metrics.md`](textfile-metrics.md), "Adding a producer". If
the signal can be read from the host with a `docker` command, a `curl`, or a TCP dialog, it is
probably a new job in `probes/bin/probe.sh` (+ its formatter in `probes/bin/lib.sh` and a case in
`scripts/test_probes_lib.sh`, + a crontab line) on **both** hosts — not a new container.

## Canary tests

bpvps2 is not a staging box: it serves the booking API and `booking-staging` holds real studio
data. bpvps1 is the mail platform. Each test that interrupts anything runs in a **short, announced
window** agreed in advance, and is recorded here.

| Test | How | Result |
|---|---|---|
| Metrics arrive | Dashboard **Hosts** shows bpvps1 and bpvps2 host and container panels | _pending deploy_ |
| Log search | `docker exec backup sh -c 'echo monitoring-canary-<uuid> > /proc/1/fd/1'`, then find it in Explore with `{host="<host>", container="backup"}` — on both hosts | _pending deploy_ |
| bpvps1 root-owned containers visible | `container_last_seen{host="bpvps1"}` lists stalwart, traefik, wordpress; `{host="bpvps1", container="stalwart"}` returns lines | Pre-deploy smoke run on the host, 2026-09-14: cadvisor saw all 8 containers; the log tailer attached to all 8, `last_error` empty. _In Grafana: pending deploy_ |
| Container down | Announced window. `docker stop backup` — serves no public path. Alert fires within ~5 min; `docker start backup`; alert resolves | _pending deploy_ |
| **Disk warning (#25)** | bpvps2, no window needed (48 GB, 13% used on 2026-09-14). `ssh bp-bpvps2 'fallocate -l $(( $(df --output=avail -B1 / \| tail -1) - $(df --output=size -B1 / \| tail -1) / 6 )) /home/deploy/disk-canary'` leaves ~83% used. Pass: `disk-warning` for `/` on bpvps2 fires after ~6 min. Then `ssh bp-bpvps2 'rm /home/deploy/disk-canary'` at once; it resolves. Never let it reach 90% — Postgres lives on that disk | _pending deploy_ |
| Probes, both hosts | `ssh bp-<host> 'docker exec probes sh -c "cat /textfile/*.prom"'` | Image built and every job run on both hosts, 2026-09-14: bpvps2 docker/postgres (7/100 each)/mail (0 failures)/tailscale (no expiry) all rc 0; bpvps1 postgres (none, heartbeat only), tailscale rc 0, mail **refused** as the mail host. _In Grafana: pending deploy_ |
| Rules evaluate | Local pipeline (Alloy v1.19.2 → Prometheus v3.5.0) with fabricated `.prom` files, 2026-09-14: `probes-stale` named exactly the two stale probes; `postgres-connections` 85; `mail-port-down` only the port at 2; all 18 expressions pass `promtool check rules` | done (local) |
| Mail port down | Announced window on bpvps1 — interrupts mail. Not run by default: the prober is proven above, and stopping Stalwart to prove the rule costs real mail. If run: `docker stop stalwart`, alert within ~3 min, `docker start stalwart` | _not scheduled_ |
| Agent overhead | `docker stats --no-stream alloy probes` over a week, both hosts | _pending deploy_ |
| **Traefik stopped → phone alert (#24, the headline test)** | Announced window — interrupts the booking API. Silence nothing. `ssh bp-bpvps2 'docker stop traefik'`, note the time. Pass: `endpoint-down` for `api.reservetoday.app` and `api.dev.reservetoday.app` reaches the **phone** within 5 min, naming **bpvps2**. Then `ssh bp-bpvps2 'docker start traefik'` at once, and confirm it resolves. `container-down-bpvps2` for `traefik` fires too — expected | **PASS, 2026-09-14** (times UTC). `docker stop traefik` 15:07:46. `Public endpoint failing` reached `Alerting` for **both** `api.reservetoday.app` and `api.dev.reservetoday.app` at **15:10:23 — 2 min 37 s**, against a 5 min bar. **The Discord message arrived on the phone**, which is the leg no API check can prove: two lines, `🔴 Public endpoint failing (2)`, naming bpvps2. `docker start traefik` 15:10:23; alert back to `inactive` within ~60 s; both sites answering 200. Traefik was down **2 min 37 s** total. This is the VPS1 failure mode — every container healthy, every domain 404 — and it is now demonstrably caught |
| Textfile seam | [`textfile-metrics.md`](textfile-metrics.md), "Testing the seam" — no window needed. Pass: value queryable within a minute; `textfile-canary-stale` fires when left, resolves when refreshed | **Pass, 2026-09-14 on bpvps2** (times UTC). Written 14:04:44, queryable 14:05:44 — 60 s, one scrape interval. Left to age: `Pending` 14:10:32, **`Alerting` 14:11:34 — 6 min 50 s after the write**, ~50 s later than the documented 5 min + 1 min, which is scrape/evaluation alignment, not a missed alert. Rewritten 14:11:46, back to `Normal` 14:13:30 (1 min 44 s). `canary.prom` deleted 14:13:39; series gone and the rule inert by 14:14:55 |
| Backup heartbeat (#27) | Blocked on the seam; run right after it. [`backup-restore.md`](backup-restore.md) | **Negative case observed live, 2026-09-14** — not simulated: bpvps1's backup stack deployed today and its first run is 04:30 KL, so it has no heartbeat yet. `count by (host) (backup_last_success_timestamp_seconds)` returns **bpvps2 only** (1 target, `booking-staging`); bpvps1 has no series. "Backup heartbeat stale on bpvps1" is **firing**, `Alerting` since 13:44:10 UTC — the absence half of the rule, exactly as intended. "Backup heartbeat stale on bpvps2" is **inactive** (`Normal (NoData)` = the query returns nothing, which is health). One host red, one green, each for the right reason. _The positive case — a real heartbeat on bpvps1 going stale and resolving — still needs the first 04:30 run._ |
| TLS days vs `openssl` | Dashboard **Endpoints** → *TLS days left* for `api.reservetoday.app`, against `echo \| openssl s_client -servername api.reservetoday.app -connect api.reservetoday.app:443 2>/dev/null \| openssl x509 -noout -enddate`. Pass: same day count. `openssl` side on 2026-09-14: `notAfter=Nov 7 15:40:49 2026 GMT` (≈54 days) | **Pass, 2026-09-14.** `probe_ssl_earliest_cert_expiry{job="api.reservetoday.app"}` = `1794066049` from all three probes (Singapore, Tokyo, Mumbai) = **Nov 7 15:40:49 2026 UTC**, ≈54.1 days left — **identical to the second** to `openssl`'s `notAfter`. Checked against the raw metric, not the dashboard panel |
| Every name has a check | `python vps/shared/public-endpoints.py` lists 11 names; **Synthetics → Checks** shows the same 11 after apply | repo side: 11 names, all answering on 2026-09-14. Account side _pending_ |
| Budget after a week | "Budget" above | _pending a week of data_ |
