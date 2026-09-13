# The textfile metric seam

The one door through which a cross-cutting signal — the backup heartbeat, the Tailscale
key-expiry check, anything later — enters monitoring. A new signal is a file written into a
directory, never a new exporter, integration or alerting vendor (#22).

> **Status: producer side only.** The backup job (#27) writes here. The reader — Alloy's
> textfile collector, and the staleness alert on top of it — is #24, which owns proving this
> end to end. Until #24 lands, the files are written and nothing reads them.

## The contract

| | |
|---|---|
| Where | the Docker volume **`monitoring_textfile`**, one per host. External to every stack; each stack that uses it creates it in its `ci/post-sync.sh` (`docker volume create` is idempotent) |
| Writers mount it at | `/textfile`, read-write |
| The agent mounts it | read-only, and points its textfile collector at it |
| One file per producer | `<producer>.prom` — `backup.prom`. Never write another producer's file |
| Format | Prometheus text exposition: `# HELP`, `# TYPE`, then `name{labels} value` |
| Writes | **atomic**: write `<producer>.prom.tmp` in the same directory, then `mv` it over. The agent reads only `*.prom`, so it never sees half a file |
| Time | Unix seconds, as a gauge named `*_timestamp_seconds` |

A volume rather than a host path because `deploy` has no sudo and cannot create anything under
`/var/lib`; `docker` group membership is enough to create a volume.

## Alerting on staleness

A producer reports *when it last succeeded*, not *that it failed* — a producer that crashed,
was stopped, or never started cannot report anything. So the alert is on age:

```promql
# A backup target has not succeeded for 26 h (nightly run + slack)
time() - backup_last_success_timestamp_seconds > 26 * 3600
```

Also alert on the series being **absent** for a host that runs the job, or a deleted file reads
as silence rather than failure.

## Producers

| File | Written by | Metrics |
|---|---|---|
| `backup.prom` | `backup` stack, after each target's snapshot and prune succeed | `backup_last_success_timestamp_seconds{target}`, `backup_last_size_bytes{target}` — see [`backup-restore.md`](backup-restore.md) |
