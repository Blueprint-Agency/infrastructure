# The textfile metric seam

The one door through which a cross-cutting signal — the backup heartbeat, the Tailscale
key-expiry check, anything later — enters monitoring. A new signal is a file written into a
directory, never a new exporter, integration or alerting vendor (#22).

> **Status: both halves in the repo (#24), bpvps2 only.** The backup job (#27) writes; Alloy's
> textfile collector reads; `grafana/rules/textfile.yml` alerts. The end-to-end test below is
> _pending the first deploy of the monitoring stack_. bpvps1 gets the same reader in #25.

## The contract

| | |
|---|---|
| Where | the Docker volume **`monitoring_textfile`**, one per host. External to every stack; each stack that uses it — producers **and** the monitoring stack — creates it in its `ci/post-sync.sh` (`docker volume create` is idempotent), because either may deploy first |
| Writers mount it at | `/textfile`, read-write |
| The agent mounts it | `/textfile`, **read-only**, with `prometheus.exporter.unix`'s `textfile { directory = "/textfile" }`. `vps/shared/check-monitoring.py` fails CI if either is missing or the mount is writable |
| One file per producer | `<producer>.prom` — `backup.prom`. Never write another producer's file |
| Format | Prometheus text exposition: `# HELP`, `# TYPE`, then `name{labels} value` |
| Writes | **atomic**: write `<producer>.prom.tmp` in the same directory, then `mv` it over. The agent reads only `*.prom`, so it never sees half a file |
| Time | Unix seconds, as a gauge named `*_timestamp_seconds` |
| Labels | the agent adds `host`; do not write one yourself |
| Freshness | read on every scrape, every 60 s — a new value is queryable within one scrape interval |

A volume rather than a host path because `deploy` has no sudo and cannot create anything under
`/var/lib`; `docker` group membership is enough to create a volume.

> **A malformed file is skipped, not fatal** — verified against `grafana/alloy:v1.19.2` on
> 2026-09-14: a broken `broken.prom` beside a good `canary.prom` still exported the canary, and
> set `node_textfile_scrape_error` to 1. Rule `textfile-unreadable-<host>` fires on that, so a
> parse error is named as a parse error instead of looking like the producer went stale.

## Alerting on staleness

A producer reports *when it last succeeded*, not *that it failed* — a producer that crashed,
was stopped, or never started cannot report anything. So the alert is on age, **or** absence —
without the second half a deleted file reads as silence rather than failure:

```promql
# A backup target has not succeeded for 26 h (nightly run + slack), or there is no heartbeat
(time() - backup_last_success_timestamp_seconds{host="bpvps2"} > 26 * 3600)
or absent_over_time(backup_last_success_timestamp_seconds{host="bpvps2"}[15m])
```

`noDataState: OK` on that rule: when every target is fresh the query returns nothing, and that
is health.

## Adding a producer

All in one commit:

1. The producer's stack mounts `monitoring_textfile` at `/textfile` and creates the volume in its
   `ci/post-sync.sh` (copy `vps/bpvps2/stacks/backup/ci/post-sync.sh`).
2. Its metric names go in the host's `metrics.allowlist` — otherwise the agent drops them.
3. A staleness rule in `grafana/rules/textfile.yml`, age **or** absent, with its host matcher.
4. Its metric prefix goes in `FAMILY` in `vps/shared/check-monitoring.py`, so CI also catches a
   rule reading one of its metrics that the allowlist forgot.
5. A row in the table below.

## Producers

| File | Written by | Metrics | Rule |
|---|---|---|---|
| `backup.prom` | `backup` stack, after each target's snapshot and prune succeed | `backup_last_success_timestamp_seconds{target}`, `backup_last_size_bytes{target}` — see [`backup-restore.md`](backup-restore.md) | `backup-stale-bpvps2` |
| `canary.prom` | nobody, normally — the seam test below, by hand | `textfile_canary_timestamp_seconds` | `textfile-canary-stale-bpvps2` (inert while the file is absent) |

## Testing the seam (bpvps2)

This proves the seam itself, apart from any consumer. Nothing user-facing is touched, so it
needs no announced window. Write through a throwaway container, since `deploy` cannot reach the
volume's host path:

```bash
# 1. Write a value. Within a minute it is queryable:
#    Explore -> grafanacloud-prom: textfile_canary_timestamp_seconds{host="bpvps2"}
ssh bp-bpvps2 'docker run --rm -v monitoring_textfile:/t alpine sh -c \
  "printf \"textfile_canary_timestamp_seconds %s\n\" \$(date +%s) > /t/canary.prom.tmp && mv /t/canary.prom.tmp /t/canary.prom"'

# 2. Leave it. After 5 min (+1 min pending) textfile-canary-stale-bpvps2 fires.
# 3. Re-run step 1. The alert resolves on the next evaluation.
# 4. Clean up. The series ends, and the rule goes back to inert.
ssh bp-bpvps2 'docker run --rm -v monitoring_textfile:/t alpine rm -f /t/canary.prom'
```

Record the result in [`monitoring.md`](monitoring.md), "Canary tests". Then run #27's heartbeat
negative test, which was blocked on this seam: [`backup-restore.md`](backup-restore.md).
