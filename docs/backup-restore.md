# Backups and restore

Nightly, encrypted, off-site snapshots, and the one command that proves they restore.

**Scope: bpvps1 and bpvps2 only.** The three Teeko hosts — vps1-staging, vps2-prod and
vps3-prod — are out of scope by decision (#4), declared as `no_backups: <reason>` in
`vps/hosts.json`. **They are not backed up at all**, and each reason names what that leaves
unprotected: ehailing production Postgres, both n8n databases and their encryption keys, the
WABA database, and both teeko-website databases. `check-backup-targets.py` prints that list on
every run, so a clean check never reads as "everything is backed up".

**Coverage today: `booking-staging` on bpvps2 only** (#26) — the instance that holds every
studio's real member and booking data. What each in-scope host backs up is declared in
`vps/<host>/stacks/backup/targets.yml` (#27). Still to land: bpvps1 (#28), the mail store
(#29), and restore-to-live plus the monthly drill and hypervisor snapshots (#30). Until those
land, nothing except `booking-staging` is backed up anywhere.

## Where snapshots are

| | |
|---|---|
| Bucket | `blueprint-backups`, **Blueprint** Cloudflare account, location APAC |
| Access | private — no `r2.dev` URL, no custom domain. Not `reservetoday-staging`, which serves uploads |
| Repository | one restic repository per host, at the bucket prefix `<host>/` (here `bpvps2/`) |
| Encryption | client-side, restic, with that host's `RESTIC_PASSWORD`. R2 only ever holds ciphertext |
| Credential | an R2 API token with Object Read & Write on **this bucket only** |
| Schedule | 03:30 Asia/Kuala_Lumpur, `crontab` in the `backup` stack |
| Retention | 7 daily / 4 weekly / 6 monthly per target, `forget --prune` only after that target's snapshot succeeded |

Every target is its own snapshot, tagged with the target's name and taken with `--host <host>`:

| Kind | Snapshot holds |
|---|---|
| `postgres` | `/scratch/<target>/<database>.dump` (`pg_dump -Fc`) and `/scratch/<target>/globals.sql` (roles — `pg_dump` does not carry them, and without `booking_app` a restore fails on every GRANT and policy) |
| `mysql` | `/scratch/<target>/<database>.sql` (`mariadb-dump --single-transaction --routines --triggers --events --databases`) |
| `volume` | `/volumes/<volume>/…`, the volume's files, read through a read-only mount |

> **Target names are the snapshot tags and scratch paths**, and CI refuses two targets with one
> name. `booking-staging` and `booking-prod` can therefore never share a tag, a scratch path or
> a retention group — on the host where one of them holds the real data.

> **The dump runs as the database's owner role, never as `booking_app`.** `booking_app` is
> subject to Row-Level Security, and `pg_dump` as that role dumps every table with no tenant's
> rows in it and exits 0. `backup.sh` checks the declared role is a superuser and refuses
> otherwise.

> Dumps run **inside** the database container (`docker exec`), so the client is the server's
> own build and a major-version mismatch cannot happen. The restore drill starts its scratch
> server from the live container's image for the same reason.

## What gets backed up: `targets.yml`

One file per host, read by the job at every run. Adding a database or a volume is a line there
plus a deploy — never a new script, never a change to `deploy-infra.yml`.

```yaml
targets:
  - name: booking-staging      # snapshot tag; lowercase, digits, -
    kind: postgres             # postgres | mysql | volume
    container: booking-db-staging
    database: yoga-sadhana
    role: postgres             # the OWNER; superuser, or RLS silently empties the dump
    floor: 280K                # bytes, or K / M / G
  - name: traefik-certs
    kind: volume
    volume: infra_traefik-letsencrypt   # the name `docker volume ls` shows
    floor: 4K

skip:
  - volume: booking_prod_pgdata
    reason: why it is safe not to back this up
```

**CI checks it** (`vps/shared/check-backup-targets.py`, run by
`test_check_backup_targets.py` on every deploy): every **in-scope** host in `vps/hosts.json`
has the file, and every named volume in that host's compose files is backed up — by a `volume`
target, or by a `postgres`/`mysql` target dumping the container that mounts it — or skipped
**with a reason**. A host carrying `no_backups: <reason>` is exempt instead, and must have
**no** targets file: a leftover one means the scope decision and the repo disagree, and the
check fails. A blank reason fails too — an exemption nobody justified is indistinguishable
from one nobody noticed.
It also fails on a declaration that no compose file matches any more. A new stack with a volume
therefore cannot ship until someone decides about that volume.

> Volume names are the real Docker names: `name:` if set, the bare key if `external`, otherwise
> `<stack dir>_<key>`, once per fanout destination with its own `ENV_NAME`. The check prints the
> name it expects.

> On a host with no backup compose yet, `targets: []` plus skips is allowed, and `backup` sits
> in that host's `exclude` in `vps/hosts.json` so CI does not try to start a stack that has only
> a targets file. Remove it from `exclude` when #28 adds the compose.

### The floor

Every target has one. A dump or volume **smaller than its floor fails that target and writes no
heartbeat** — so an empty or truncated database raises the same alarm as a backup that never
ran. Set it above what an *empty* instance of the same thing measures:

| Target | Measured 2026-09-13 | Floor |
|---|---|---|
| booking-staging | live 327,605 B · schema only 255,569 B · booking-prod (seed data) 282,750 B | `280K` (286,720 B) |

## Did it work? Heartbeat, healthcheck, exit code

**Heartbeat.** After each target's snapshot *and* prune succeed, the job rewrites
`backup.prom` in the monitoring textfile volume (`monitoring_textfile`, contract in
[`textfile-metrics.md`](textfile-metrics.md)):

```
backup_last_success_timestamp_seconds{target="booking-staging"} 1789311303
backup_last_size_bytes{target="booking-staging"} 327605
```

A failed target keeps its previous timestamp, so it goes stale; the dead-man's switch is an
ordinary staleness alert on that metric (older than 26 h), not a second alerting vendor.

**Healthcheck.** `docker ps` shows `backup` **unhealthy** when any declared target's last
success is older than `BACKUP_MAX_AGE` (90,000 s — a day, plus an hour for tonight's run to
finish), or has never succeeded. It reads the same `backup.prom`, so `docker ps` and the alert
cannot disagree. A freshly created container is unhealthy until its first run — after a
first deploy, run `docker exec backup /app/bin/backup.sh` rather than wait for 03:30. (The
healthcheck's 25 h and the alert's 26 h differ on purpose: `docker ps` is looked at by a
human, the alert pages one.)

**Exit code** of `backup.sh`, the same contract as `scripts/verify-mail.sh`:

| | |
|---|---|
| `0` | every target green |
| `1` | at least one target failed (the others still ran) |
| `2` | the run could not start — bad `targets.yml`, unknown target name, repository unreachable |
| `3` | green, but targets were left out: `backup.sh <target>` ran a subset |

## Secrets — two homes, neither is the host

| Name | Where in GitHub | Also in |
|---|---|---|
| `R2_BACKUP_ACCOUNT_ID` | `bpvps2` Environment secret | — |
| `R2_BACKUP_BUCKET` | `bpvps2` Environment variable | — |
| `R2_BACKUP_ACCESS_KEY_ID`, `R2_BACKUP_SECRET_ACCESS_KEY` | `bpvps2` Environment secret | Cloudflare → R2 → API tokens |
| `RESTIC_PASSWORD` | `bpvps2` Environment secret | **team password manager** |

Rendered by CI from `vps/bpvps2/stacks/backup/ci/env.ci`; a blank one fails the deploy.
All of them sit in the **Environment**, not at repo level, so no other host's deploy job ever
receives them. When #28 adds a host, that host's Environment gets its own set.

> ⚠️ **Lose `RESTIC_PASSWORD` and every bpvps2 snapshot is unreadable.** GitHub never returns a
> secret's value, so the password-manager copy is the only one a human can read back. It is
> per host: when #28 adds hosts, each gets its own, in its own Environment.

## Everyday commands

All run on the host (`ssh bp-bpvps2`), as `deploy`.

```bash
# What is in the repository
docker exec backup restic snapshots

# Take a snapshot now -- before a production migration or an import
docker exec backup /app/bin/backup.sh                    # every target, exit 0
docker exec backup /app/bin/backup.sh booking-staging    # just this one, exit 3 when green

# Is every target fresh?
docker exec backup /app/bin/healthcheck.sh
docker exec backup cat /textfile/backup.prom

# Restore drill: latest snapshot -> throwaway Postgres -> row counts vs live
docker exec backup /app/bin/restore-drill.sh booking-staging
docker exec backup /app/bin/restore-drill.sh booking-staging <snapshot-id>

# Last night's run
docker logs backup --since 24h
```

The drill takes a `postgres` target's name and reads its container, database and role from
`targets.yml`. It compares `COUNT(*)` on `tenants`, `clients`, `bookings`, `client_packages` and
`stripe_payments` (the payments table; override with `-e DRILL_TABLES=…`), and exits non-zero
on any difference. Its scratch container is `restore-drill-<target>`, has **no network**, and is
removed on exit. Rows written since the snapshot read as a mismatch — for an exact comparison,
run `backup.sh` immediately before.

## Getting a dump out by hand

```bash
docker exec backup restic dump --host bpvps2 --tag booking-staging latest \
  /scratch/booking-staging/yoga-sadhana.dump > /tmp/booking-staging.dump
```

That is member data in plaintext on disk. Delete it when done.

## The July 2026 dumps (`manual`)

The two dumps taken by hand on 2026-07-21, around the move off VPS3, live in a **separate**
restic repository at the bucket prefix `manual/`, encrypted with **bpvps2's** `RESTIC_PASSWORD`:
snapshot `52d4593f`, tagged `manual,july-2026`, uploaded 2026-09-13. Nothing prunes them.

| File (path in the snapshot) | sha256 |
|---|---|
| `/booking-vps3-20260721.dump` | `6a4c70d15fd97754ddf33747fd476e1200f241fe2bfecdc8925d41884b943e0b` |
| `/booking-staging-pre-seed-20260721.dump` | `3d4abdef6e585d56c0f7d381b12262fefec85ef621c9bb3621d352f0490ff3d1` |

Both hashes were re-read out of R2 after upload and matched the laptop copies.

```bash
docker exec backup sh -c 'RESTIC_REPOSITORY=${RESTIC_REPOSITORY%/bpvps2}/manual restic snapshots'
docker exec backup sh -c 'RESTIC_REPOSITORY=${RESTIC_REPOSITORY%/bpvps2}/manual \
  restic dump latest /booking-vps3-20260721.dump' > /tmp/booking-vps3-20260721.dump
```

> Two more July dumps sit **on bpvps2** in `/root/stacks/booking-staging/`
> (`booking-migration.dump`, `pre-seed-backup.dump`, one of them world-readable). They are
> not part of this repository. Decide whether to keep them before deleting.

## Record of restores

| Date | Instance | Snapshot | Result |
|---|---|---|---|
| 2026-09-13 | booking-staging | local test repository on bpvps2, before R2 credentials existed | PASS — tenants 3, clients 6, bookings 4, client_packages 6, stripe_payments 6 |
| 2026-09-13 | booking-staging | `db582923`, **from R2**, the first real snapshot (327,605 B dump) | PASS — tenants 3, clients 6, bookings 4, client_packages 6, stripe_payments 6 |
