# Backups and restore

Nightly, encrypted, off-site snapshots; the commands that restore them to scratch and to live;
and Hostinger's weekly copy of each whole VM underneath.

**At 2am, start here:**

| Situation | Go to |
|---|---|
| Something is broken and data must come back | [Restore to live](#restore-to-live) |
| "Is the backup good?" / the monthly drill | [Everyday commands](#everyday-commands), [The monthly drill](#the-monthly-drill) |
| `backup-stale-<host>` is firing | [When a staleness alert fires](#when-a-staleness-alert-fires) |
| About to migrate, import or change the schema | [Before a migration or an import](#before-a-migration-or-an-import) |
| The host itself is gone | [Hypervisor backups](#hypervisor-backups) |
| A developer needs real data locally | [A dump on a developer's machine](#a-dump-on-a-developers-machine) |
| A token or passphrase leaked, or someone left | [Rotating credentials](#rotating-credentials) |
| A studio asks to be erased | [Removing a tenant from backups](#removing-a-tenant-from-backups) |

**Scope: bpvps1 and bpvps2 only.** The three Teeko hosts — vps1-staging, vps2-prod and
vps3-prod — are out of scope by decision (#4), declared as `no_backups: <reason>` in
`vps/hosts.json`. **They are not backed up at all, and have no hypervisor snapshots either**
(they are in no Hostinger account we hold a token for, so nothing here can even list them).
Unprotected there: **ehailing's production Postgres** and **the WABA database** (vps3-prod),
**n8n's database and its encryption key** on both vps3-prod and vps1-staging — without the key,
a restored n8n cannot decrypt a single stored credential — and **both teeko-website databases**
(vps1-staging, vps2-prod). `check-backup-targets.py` prints that list on every run, so a clean
check never reads as "everything is backed up". The only tool for those hosts is
`scripts/backup.sh`, a same-disk volume tar, which is not a backup of a running database.

**Coverage today** — what each in-scope host backs up is declared in
`vps/<host>/stacks/backup/targets.yml` (#27):

| Host | Targets |
|---|---|
| bpvps2 | `booking-staging` (every studio's real member and booking data, #26), `booking-prod` (seed data today; declared so deploys can snapshot it before migrating, #30), `traefik-certs` (#28) |
| bpvps1 | `mail-store` (all mail, all three domains — **stops Stalwart for a few seconds nightly**, see [The mail store](#the-mail-store), #29), `wordpress` (the Kaiteki blog database), `bulwark-settings`, `bulwark-admin`, `bulwark-admin-state`, `traefik-certs` (#28) |

> Not backed up: the WordPress `wp-content` directory, which is a bind mount, not a volume, and
> so outside `targets.yml` altogether. It is inside the [hypervisor backups](#hypervisor-backups).

## Where snapshots are

| | |
|---|---|
| Bucket | `blueprint-backups`, **Blueprint** Cloudflare account, location APAC |
| Access | private — no `r2.dev` URL, no custom domain. Not `reservetoday-staging`, which serves uploads |
| Repository | one restic repository per host, at the bucket prefix `<host>/` — `bpvps1/`, `bpvps2/` |
| Encryption | client-side, restic, with **that host's own** `RESTIC_PASSWORD`. R2 only ever holds ciphertext, and neither host's passphrase opens the other's repository |
| Credential | an R2 API token with Object Read & Write on **this bucket only** — one token, shared by both hosts (R2 cannot scope a token to a prefix) |
| Schedule | bpvps2 **03:30**, bpvps1 **04:30** Asia/Kuala_Lumpur, each host's `crontab` in its `backup` stack. Staggered so they do not contend for upload bandwidth; CI refuses two hosts on one start time |
| Retention | **every** snapshot from the last 7 days, then 7 daily / 4 weekly / 6 monthly, per target; `forget --prune` only after that target's snapshot succeeded. The 7 days (#30) keep an on-demand snapshot — pre-migration, pre-restore — from being forgotten by the next one taken the same day |

Every target is its own snapshot, tagged with the target's name and taken with `--host <host>`:

| Kind | Snapshot holds |
|---|---|
| `postgres` | `/scratch/<target>/<database>.dump` (`pg_dump -Fc`) and `/scratch/<target>/globals.sql` (roles — `pg_dump` does not carry them, and without `booking_app` a restore fails on every GRANT and policy) |
| `mysql` | `/scratch/<target>/<database>.sql` (`mariadb-dump --single-transaction --routines --triggers --events --databases`) |
| `volume` | `/volumes/<volume>/…`, the volume's files, read through a read-only mount |
| `stalwart` | `/volumes/<volume>/…`, the same — but read while `container` is **stopped** ([The mail store](#the-mail-store)) |

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
  - name: mail-store
    kind: stalwart             # container is STOPPED for the snapshot; it must mount volume
    container: stalwart
    volume: stalwart_stalwart-data
    floor: 4G

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
> a targets file. Remove it from `exclude` when the compose lands (bpvps1's did in #28).

### One job, two copies

CI rsyncs only a stack's own directory, so each host's `backup` stack carries its **own copy**
of `Dockerfile` and `bin/`. The same check fails CI when those copies differ, naming the file
and the hosts — **change the job on both hosts in one commit.** Per host, and free to differ:
`docker-compose.yml`, `crontab`, `targets.yml`, `ci/`. It also fails when two hosts' crontabs
start at the same time.

> bpvps1's `stalwart`, `traefik` and `wordpress` stacks are root-owned and excluded from CI.
> The backup stack does **not** live inside them: `/root/stacks/backup` is its own
> `deploy`-owned directory (deploy owns `/root/stacks`, so CI's rsync creates it — no root step),
> and it reaches their data only through the Docker socket. Its `post-sync.sh` fails the deploy
> if anything in that directory is not owned by `deploy`, so a root-owned leftover cannot
> quietly pin the host to an old job.

### The floor

Every target has one. A dump or volume **smaller than its floor fails that target and writes no
heartbeat** — so an empty or truncated database raises the same alarm as a backup that never
ran. Set it above what an *empty* instance of the same thing measures:

| Target | Measured | Floor |
|---|---|---|
| booking-staging | 2026-09-13: live 327,605 B · schema only 255,569 B · booking-prod (seed data) 282,750 B | `280K` (286,720 B) |
| booking-prod | 2026-09-14: live (seed data) 282,750 B · schema only 255,416 B | `256K` (262,144 B) — catches a schema with nothing in it, **not** a lost seed row; raise it once a studio is on prod |
| wordpress (bpvps1) | 2026-09-14: live 49,037,512 B · posts/postmeta/users/terms alone 18,209,402 B · schema only 66,830 B | `16M` |
| mail-store | 2026-09-14: 7.3G (7,865,384,960 B allocated) — 6.1G `.blob` (message bodies), 1.1G `.sst`; an empty store is a few MB | `4G` |
| bulwark-settings | 2026-09-14: 92K, 22 files | `32K` |
| bulwark-admin | 2026-09-14: 20K, 4 files | `12K` |
| bulwark-admin-state | 2026-09-14: 12K, 2 files | `8K` |
| traefik-certs | 2026-09-14: bpvps1 80K, bpvps2 92K | `32K` |

> **Volume sizes are du's allocated KiB**, not bytes: 4K for the directory and at least 4K per
> file, however small. A volume floor therefore reads "at least this many files". An empty,
> freshly created volume measures 4K. WordPress's floor deliberately leaves out Rank Math's
> analytics cache (most of the live dump), which a plugin reset may legitimately empty.

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
`mail-store` is no exception: every way its capture can fail (below) ends in no heartbeat.

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
Each in-scope host's Environment (`bpvps1`, `bpvps2`) holds the same five names:

| Name | Where in GitHub | Also in |
|---|---|---|
| `R2_BACKUP_ACCOUNT_ID` | Environment secret | — |
| `R2_BACKUP_BUCKET` | Environment variable | — |
| `R2_BACKUP_ACCESS_KEY_ID`, `R2_BACKUP_SECRET_ACCESS_KEY` | Environment secret — the same token in both | Cloudflare → R2 → API tokens; `.env` |
| `RESTIC_PASSWORD` | Environment secret — **different in each** | **team password manager**; `.env` as `RESTIC_PASSWORD_<HOST>` |

Rendered by CI from `vps/<host>/stacks/backup/ci/env.ci`; a blank one fails the deploy.
All of them sit in the **Environment**, not at repo level, so no other host's deploy job ever
receives them.

> ⚠️ **Lose a host's `RESTIC_PASSWORD` and every snapshot of that host is unreadable.** GitHub
> never returns a secret's value, so the password-manager copy is the only one a human can read
> back. One passphrase per host, on purpose: bpvps1's cannot open bpvps2's repository, nor the
> reverse.

## Everyday commands

All run on the host (`ssh bp-bpvps1` or `ssh bp-bpvps2`), as `deploy`. The container is
`backup` on both.

```bash
# What is in the repository
docker exec backup restic snapshots

# Take a snapshot now -- before a production migration or an import
docker exec backup /app/bin/backup.sh                    # every target, exit 0
docker exec backup /app/bin/backup.sh booking-staging    # just this one, exit 3 when green

# Is every target fresh?
docker exec backup /app/bin/healthcheck.sh
docker exec backup cat /textfile/backup.prom

# Restore to SCRATCH (the drill): latest snapshot -> throwaway copy -> compared with live
docker exec backup /app/bin/restore-drill.sh booking-staging              # bpvps2
docker exec backup /app/bin/restore-drill.sh wordpress                    # bpvps1
docker exec backup /app/bin/restore-drill.sh bulwark-settings <snapshot-id>

# Last night's run
docker logs backup --since 24h

# Restore OVER LIVE -- a different command; the instance name twice. See "Restore to live".
docker exec backup /app/bin/restore-live.sh booking-staging <snapshot-id> --confirm booking-staging
```

`restore-drill.sh` never writes to anything live; `restore-live.sh` is the only script that
does. They are separate files so that no flag, typo or shell-history edit turns one into the
other.

The drill takes any target's name and reads everything else from `targets.yml`:

| Kind | Restored into | Pass means |
|---|---|---|
| `postgres` | a scratch Postgres from the live container's image, **no network** | `COUNT(*)` on the target's `drill_tables` equals live |
| `mysql` | a scratch MariaDB/MySQL from the live container's image, **no network** | the same |
| `volume` | a scratch directory in a throwaway container | every file is byte-identical to the live volume (mounted read-only), and there is at least one |

| `stalwart` | a scratch volume, opened by a scratch Stalwart from the live container's image with the live `config.json`, **no network**, and a throwaway recovery admin | every account's message count and summed bytes equal live — the numbers `scripts/mail-inventory.py` records |

A database target without `drill_tables` cannot be drilled — the drill refuses rather than
counting nothing. The scratch container is `restore-drill-<target>` and is removed on exit.
Anything written since the snapshot reads as a mismatch — for an exact comparison, run
`backup.sh <target>` immediately before.

## The mail store

`mail-store` on bpvps1 is `stalwart_stalwart-data`: all mail for kaiteki.my,
blueprintdigital.my and reservetoday.app, in Stalwart's RocksDB store. Reading RocksDB while
the server writes to it is the same mistake as tarring a running Postgres. So the method was
decided first, with evidence (#29).

### Does Stalwart v0.16.21 have an online export? No.

Checked on bpvps1, 2026-09-14, against a restored copy of the real store:

| Candidate | Result |
|---|---|
| A backup/export object in the management API | None. The server's own schema (`GET /api/schema`, 940,603 B) has no object or task named backup, export, snapshot, checkpoint or dump — the only "export" is `enableLogExporter` / `enableSpanExporter` (telemetry). |
| `stalwart --export <dir>` while the server runs | **Refuses.** `Failed to open database: IO error: While lock file: /opt/stalwart/data/LOCK: Resource temporarily unavailable` — it needs RocksDB's exclusive lock, which the running server holds. It still **exits 0** with an empty directory, so a job built on it would upload nothing every night and call it success. |
| `stalwart --export <dir>` with the server stopped | Works: 19 `subspace_*` files, 6.4G, **56 s**. But it needs the same stop, a full 6.4G rewrite every night, and a matching `--import` to restore. |

The CLI's only other store tools are `--import` and `--console` (a raw key-value debugger,
same lock). **So option (a) — an export run against the running container — does not exist
in this build**, and a stopped export is strictly worse than a stopped copy: longer pause, and
nothing restic can deduplicate.

### The decision: stop Stalwart, snapshot the volume, start it (option b)

Chosen deliberately, not by default: **every night at 04:30 KL, mail on bpvps1 pauses for a
few seconds.** Measured on the first run (2026-09-14 02:29 KL): **stopped for 4 s.**

How `backup.sh` keeps it that short:

1. **Warm pass, Stalwart running.** The volume is read into the repository while mail flows —
   58 s for 7.3G into a local repository; longer to R2 the first night, and nobody waits on it.
   This read is *not* a backup: it is tagged `mail-store-warm` and forgotten at the end.
2. **Stop.** `docker stop -t 120 stalwart`, so RocksDB flushes and closes cleanly. A record is
   written to `/cache/stopped-by-backup/stalwart` *before* the stop.
3. **Real pass, Stalwart stopped.** Same volume, with the warm pass as restic's parent. RocksDB
   never rewrites a `.sst` or `.blob` file once written, so restic skips all but the handful
   written since: first run, 3 changed files of 157, 1.9 MiB. (Compaction does *delete* files
   while Stalwart runs, so the warm pass may exit 3 — "some files could not be read". That is
   accepted there; never on the real pass.) Bounded by
   `BACKUP_PAUSE_LIMIT` (600 s, the compose file), enforced on restic inside its container.
4. **Start**, remove the record, and wait for Stalwart to answer on `:8080/healthz/live`.

### What the pause does to mail

- **Inbound SMTP** (25): connections are refused for the pause. Sending servers treat that as
  temporary and retry — for days, by RFC 5321. Nothing bounces for a pause of seconds.
- **Outbound**: the queue lives in the store; it resumes on start.
- **IMAP / POP / JMAP / webmail**: clients drop and reconnect. Bulwark shows an error for a
  request that lands in the window.

### When the capture fails

Every failure writes **no heartbeat**, so `mail-store` goes stale like any other target: the
healthcheck turns `backup` unhealthy after 25 h, and the staleness alert fires at 26 h on a
monitored host. What each failure does to mail:

| Failure | Mail | What you see |
|---|---|---|
| Warm pass fails (R2 down, repository locked) | **untouched** — Stalwart is never stopped | `mail-store: FAILED` in `docker logs backup` |
| Real pass fails or overruns 600 s | paused until the failure, **at most ~13 min** (120 s stop + 600 s + 60 s to kill a restic that ignores SIGINT); then started | `the snapshot failed or overran 600s` |
| Stalwart does not answer within 180 s of starting | **down** — this is a mail outage | `snapshot taken, but stalwart is not answering`; target fails |
| Stalwart will not start | **down** | `COULD NOT START stalwart … docker start stalwart`; record kept |
| The backup container dies mid-pause (killed, OOM, host reboot) | **down** until the container starts again — `restart: unless-stopped` does not revive a container stopped on purpose | on its next start `entrypoint.sh` starts every recorded container; `healthcheck.sh` is unhealthy while a record is older than the longest possible pause plus 5 min (21 min at the 600 s limit) |

Any "down" row: `docker start stalwart` on bpvps1, then `scripts/verify-mail.sh`. Two runs
never overlap — a second `backup.sh` exits 2 at once (`flock`) — because the second one
finishing would restart Stalwart in the middle of the first one's snapshot.

### Proving it round-trips

```bash
docker exec backup /app/bin/backup.sh mail-store       # exit 3 when green (a subset)
docker exec backup /app/bin/restore-drill.sh mail-store
```

The drill restores into a scratch volume, starts a scratch Stalwart on it **with no network**
(it holds the outbound queue — with a network it would re-send), and counts every account's
messages and bytes on live and on the copy. The counting runs inside each server as its own
recovery admin over loopback, so this job holds no mail password. Its numbers are
`scripts/mail-inventory.py`'s: on 2026-09-14 the two agreed on all 24 accounts. Mail that
arrived after the snapshot shows as a mismatch — run it straight after `backup.sh`, at a quiet
hour. ~2 min, and ~7.5G free disk for the scratch copy (removed on exit).

## Restore to live

Restoring over a live database is **`restore-live.sh`**, never the drill, and it takes the
instance name twice:

```bash
ssh bp-bpvps2
docker exec backup restic snapshots --tag booking-staging        # pick the snapshot
docker exec backup /app/bin/restore-live.sh booking-staging 4f2a9c1b --confirm booking-staging
```

It refuses — before touching anything — when `--confirm` is missing or differs from the target,
when no snapshot is named (`latest` is allowed, but must be typed), when the snapshot does not
exist, and for any target that is not `postgres`. Then (seconds at booking's size — proved end
to end in local Docker, not yet run over a real instance):

1. **Restores beside live**, into `<db>_restore_<stamp>`, with live's owner, encoding, locale and
   database-level grants. (`booking_app`'s `CONNECT` is a database grant, which `pg_dump` does
   not carry — without the copy, the app's RLS role could not connect at all.) A role the dump
   needs and live lacks stops it here.
2. **Prints row counts**, live vs restored, for the target's `drill_tables` — the difference
   you are about to make. Informational; it does not gate.
3. **Snapshots live as it is now** (`backup.sh <target>`), so the restore itself can be undone.
   If that fails, it stops. This runs *after* step 1 on purpose: a snapshot's prune could
   otherwise forget the snapshot being restored.
4. **Swaps**: live stops accepting connections, its sessions are ended, and **one transaction**
   renames live to `<db>_pre_restore_<stamp>` and the restored copy to live's name. If it cannot
   commit in 15 tries, live is reopened unchanged and the copy dropped. Ctrl-C at any point
   before the commit does the same.

After it:

- **The app's connections were cut.** booking-be reconnects on its next query; if it does not,
  `docker restart booking-be-staging` (or `-prod`).
- **The original database is still there**, as `yoga-sadhana_pre_restore_<stamp>` — anything
  written after step 3 is only in it. Drop it once satisfied:
  `docker exec booking-db-staging dropdb -U postgres 'yoga-sadhana_pre_restore_<stamp>'`.
- Undo the restore: the step-3 snapshot is the newest one; restore it the same way.

### Other kinds — by hand

No script, because each is a service outage and needs a human watching it. Take a snapshot
first in every case (`backup.sh <target>`).

| Kind | Procedure |
|---|---|
| `mysql` (wordpress) | `docker exec backup restic dump --host bpvps1 --tag wordpress <id> /scratch/wordpress/<db>.sql \| docker exec -i <container> sh -c 'mariadb -u root -p"$MARIADB_ROOT_PASSWORD"'` — the dump was taken with `--databases`, so it drops and recreates each table in place. Stop the WordPress container first so nothing writes mid-load. |
| `volume` | `docker stop` every container mounting the volume; `docker run --rm -v <volume>:/volumes/<volume> -v backup_restic_cache:/cache -e RESTIC_REPOSITORY -e RESTIC_PASSWORD -e RESTIC_CACHE_DIR -e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY -e AWS_DEFAULT_REGION --entrypoint restic blueprint-backup:local restore --host <host> --tag <target> <id> --target / --delete` (run from inside `backup`, so those variables are set); start the containers. |
| `stalwart` (mail-store) | As `volume`, with `docker stop -t 120 stalwart` first. **All mail since the snapshot is lost** unless it is still queued on the senders' side; run `restore-drill.sh mail-store <id>` first to see the snapshot's counts, then `scripts/verify-mail.sh` for each domain after. |

## Before a migration or an import

```bash
ssh bp-bpvps2 'docker exec backup /app/bin/backup.sh booking-prod'      # exit 3 = green
```

- **booking-system's deploy does this itself** (#30): immediately before `db:migrate`, the
  `deploy-be.yml` job runs `backup.sh booking-<env>` for the instance it is about to migrate —
  `booking-staging` on the `staging` branch (which holds the real data), `booking-prod` on
  `main`. Exit 0 or 3 continues; anything else stops the deploy before the migration runs. A
  bad schema change is then undone with `restore-live.sh` and that snapshot. It fails with exit 2
  if the nightly run holds the lock (bpvps2's, 03:30, takes seconds): re-run the deploy.
- **The Mindbody import runbook opens with this command** (booking-system
  `docs/md/mindbody-import.md`, #130). The import is why this whole runbook was written.
- The snapshot is kept at least 7 days, however many are taken after it that day.

## The monthly drill

Calendar-driven, manual, **first working Monday of the month**, on bpvps2:

```bash
ssh bp-bpvps2
docker exec backup /app/bin/backup.sh booking-prod booking-staging    # a fresh snapshot, exit 3
docker exec backup /app/bin/restore-drill.sh booking-prod
docker exec backup /app/bin/restore-drill.sh booking-staging          # the real member data
```

Pass is `PASS -- restored row counts match live` on both. Add a row to
[Record of restores](#record-of-restores) with the snapshot ids and the counts, pass or fail.
The mail equivalent, on bpvps1, is `restore-drill.sh mail-store` (#29) — the inventory diff —
at a quiet hour, since it pauses nothing but reads all 7 GB.

> Once it has run by hand **twice** without surprises (1 of 2: 2026-09-14), it becomes a
> monthly cron line in bpvps2's `crontab` writing its own heartbeat, with a staleness alert
> beside `backup-stale-bpvps2`. Not before: an automated drill nobody has watched fail is a
> green light nobody understands.

## When a staleness alert fires

`backup-stale-<host>`: some target on that host has not succeeded in 26 h, or there is no
heartbeat at all. The alert's own first checks are in [`monitoring.md`](monitoring.md); then:

1. `ssh bp-<host> 'docker exec backup /app/bin/healthcheck.sh'` — names the stale target(s).
2. `docker logs backup --since 30h | grep -E 'FAILED|below its floor|cannot open|refusing'`:

   | Log says | Meaning | Do |
   |---|---|---|
   | `below its floor` | the dump or volume is suspiciously small — **treat as possible data loss**, not a backup fault | look at the live database before anything else |
   | `cannot open the restic repository` | R2 unreachable, or the token/passphrase is wrong | `docker exec backup restic cat config`; a 403 is the token ([rotate](#rotating-credentials)) |
   | `refusing to dump as` | the target's `role` is not a superuser | fix `role` in `targets.yml` |
   | `another backup run is in progress` | a run hung and still holds the lock | `docker exec backup ps`; kill it, then run again |
   | `mail-store: ... stalwart` | see [When the capture fails](#when-the-capture-fails) | — |
   | nothing at 03:30 / 04:30 at all | cron did not run: container recreated with a bad crontab, or stopped | `docker ps -a --filter name=backup`; `docker exec backup cat /etc/crontabs/root` |

3. Fix, then `docker exec backup /app/bin/backup.sh <target>` — the heartbeat moves and the
   alert resolves on its next evaluation.

## Hypervisor backups

The independent layer: Hostinger's copy of the **whole VM** — every volume, bind mount,
`/root/stacks`, the Docker daemon config — on Hostinger's storage, restored from hPanel or the
API. It survives what restic cannot: a host lost together with its `RESTIC_PASSWORD`, or data
nobody declared in `targets.yml` (such as `wp-content`).

bpvps1 and bpvps2 are exactly the two hosts the Blueprint Hostinger token can see, so all of it
is API, no hPanel:

```bash
python scripts/hypervisor-backups.py status              # exit 1 if a weekly backup is > 8 days old
python scripts/hypervisor-backups.py snapshot bpvps2     # before a risky change to the host itself
```

| | Weekly backups | Snapshot |
|---|---|---|
| Taken | **automatically, weekly** — bpvps1 Tuesdays, bpvps2 Wednesdays, ~05:20–06:30 UTC (2026-09-01/08 and 09-02/09) | on demand |
| Enabled how | **already on; cannot be toggled.** Hostinger's VPS API has no endpoint to enable, schedule or disable them (OpenAPI checked 2026-09-14) — only list and restore. `status` is the proof they are running | `snapshot` → `POST /virtual-machines/<id>/snapshot`, polled on `/actions/<id>` to `success` |
| Kept | 2 listed on 2026-09-14 (the last two weeks) | **one per VM**; a new one overwrites it; **expires after 24 h** |
| Restore | `POST /virtual-machines/<id>/backups/<backupId>/restore` | `POST /virtual-machines/<id>/snapshot/restore` |

> ⚠️ **Restoring either one replaces the entire VM**, including every database written since.
> On bpvps2 that is every studio's bookings since the backup. Last resort — the host is gone or
> will not boot — and take a restic snapshot of anything still reachable first.

> The snapshot `action` passes through `sent` and `started` — a state not in Hostinger's own
> schema — before `success`. Poll the action; do not read the snapshot's `created_at`, which the
> API sets to the request time even when there is no snapshot (id `0`). The same rule as the
> shared firewall group 319466, whose `is_synced` flag flips before its sync action finishes.

> Snapshots are short-lived (24 h) and single, so they are not a schedule: they are for "about
> to upgrade Docker / change the kernel / resize the disk". The weekly backups are the layer.

VM ids: bpvps1 `1778283`, bpvps2 `1831058`. The Teeko hosts are not visible to this token and
have neither.

## A dump on a developer's machine

The one sanctioned path for member data to reach a laptop. It is **logged on the host before a
byte leaves**, with who and why:

```bash
scripts/pull-dump.sh bp-bpvps2 booking-staging \
  --reason "reproduce booking-system#131" \
  --into postgres://postgres:postgres@localhost:5432/booking_restore
```

- On the host, `export-dump.sh` refuses a blank `--who` (default: `git config user.name`) or
  `--reason`, resolves `latest` to a snapshot id, and writes
  `EXPORT target=… snapshot=… who=… reason="…"` to `docker logs backup` (in Grafana Cloud once
  the host is monitored) and to `/cache/exports.log`, which survives the container. It refuses
  to write to a terminal.
- On the laptop, `--into` must be `localhost`/`127.0.0.1`/`[::1]`. The database is **dropped and
  recreated**, restored with `--no-owner --no-acl`, and the dump file (mode 600) is deleted on
  every exit. `create role booking_app` locally first, or its RLS policies are skipped with
  errors. Needs a local `pg_restore`/`psql` of major 16 or newer.
- `--snapshot <id>` for an older one. postgres targets only.

Who has pulled what: `ssh bp-bpvps2 'docker exec backup cat /cache/exports.log'`.

> `/cache` is `backup_restic_cache`, which `targets.yml` skips as rebuildable. Removing that
> volume **loses `exports.log`** with it; the same lines stay in `docker logs backup` until the
> container is recreated, and in Grafana Cloud once the host is monitored. Do not delete the
> volume to "clear a cache".

Anything pulled is still member data: drop the local database when the work is done. Do not
`restic dump` to a file by hand to get round the log.

## Rotating credentials

Both are shared by nothing but this job. New first, verify, then revoke the old — never the
other way round.

### The R2 token (both hosts at once)

1. Cloudflare (**Blueprint** account) → R2 → Manage API tokens → create: **Object Read & Write**,
   bucket **`blueprint-backups` only**.
2. GitHub → `Blueprint-Agency/infrastructure` → Environments **`bpvps1` and `bpvps2`**: set
   `R2_BACKUP_ACCESS_KEY_ID` and `R2_BACKUP_SECRET_ACCESS_KEY`. Update `.env`.
3. Re-run `deploy-infra.yml` for both hosts (Actions → Run workflow).
4. On each: `docker exec backup restic cat config >/dev/null && echo ok`, then
   `docker exec backup /app/bin/backup.sh traefik-certs` (exit 3).
5. Delete the old token in Cloudflare. Re-run step 4's first command to prove the running job
   was not still on it.

### A host's `RESTIC_PASSWORD`

restic encrypts the repository's master key under each *key*; a passphrase is one key. Rotating
adds a key and removes the old one — no data is re-encrypted.

```bash
ssh bp-bpvps2
NEW=$(head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 40)
# 1. Password manager FIRST: "restic bpvps2" = $NEW. Lose it and every snapshot is unreadable.
printf %s "$NEW" | docker exec -i backup sh -c \
  'cat > /tmp/np && restic key add --new-password-file /tmp/np; rc=$?; rm -f /tmp/np; exit $rc'
docker exec backup restic key list          # two keys now; * marks the one in use (the old)
```

2. GitHub Environment `bpvps2` → secret `RESTIC_PASSWORD` = `$NEW`; `.env`
   `RESTIC_PASSWORD_BPVPS2`. Re-run the deploy for bpvps2.
3. `docker exec backup restic key list` — `*` is now on the new key. Then
   `docker exec backup restic key remove <old key id>` and `backup.sh booking-staging`.
4. **bpvps2 only**: the [`manual/` repository](#the-july-2026-dumps-manual) uses the same
   passphrase. Repeat the `key add` / `key remove` with
   `RESTIC_REPOSITORY=${RESTIC_REPOSITORY%/bpvps2}/manual` set, using the old password as
   `RESTIC_PASSWORD` for the add.

> **A leaked passphrase is not fixed by rotation.** Anyone who had it *and* a copy of the
> repository's key file already holds the master key. If the R2 token leaked too, the honest
> fix is a new repository: a new passphrase, `RESTIC_REPOSITORY` pointed at a new prefix,
> `backup.sh`, a drill, and the old prefix deleted in R2 once the new one holds a week.

## Removing a tenant from backups

A studio that leaves, or a member's erasure request that must reach backups. restic snapshots
are immutable and a dump is one file, so rows cannot be cut out of a snapshot: the tenant's
data leaves the backups when **every snapshot taken before its deletion is forgotten and
pruned**. Worst case it takes no action at all — 6 months (the monthly retention) — so this
procedure is what makes it days.

1. **Delete the tenant in the live database** (booking-system's own procedure). Note the time.
2. **Snapshot now**: `docker exec backup /app/bin/backup.sh booking-staging` — the first
   snapshot without the tenant. Confirm the tenant's rows are gone from live, then
   `restore-drill.sh booking-staging`: its PASS proves the snapshot matches that live.
3. **Forget every older snapshot of that instance**, and prune:

   ```bash
   docker exec backup restic snapshots --host bpvps2 --tag booking-staging   # note the new id
   docker exec backup restic forget --host bpvps2 --tag booking-staging --group-by host,tags \
     --keep-last 1 --dry-run                                                  # read the list
   docker exec backup restic forget --host bpvps2 --tag booking-staging --group-by host,tags \
     --keep-last 1 --prune
   ```

   `--group-by host,tags` is the nightly job's grouping; without it restic groups by path too,
   and a snapshot with a different path would survive as its own group. Repeat steps 2–3 for
   **`booking-prod`** if the tenant was ever on it.

   **This deletes all restore history for that instance**, every studio's, not just the
   leaver's. From here the only restorable point is step 2. That is the cost, and why it is a
   decision, not a cron job.
4. **`manual/`** (bpvps2): the July dumps predate most tenants — check with a drill restore of
   `52d4593f` before assuming. If the tenant is in them: `restic forget 52d4593f --prune` there.
5. **Hypervisor backups** hold the whole disk and cannot be edited. They age out on their own:
   the last pre-deletion one is gone **~14 days** after step 1 (two weekly copies kept). A
   snapshot, if one was taken, expires in 24 h.
6. **Laptops**: `/cache/exports.log` names everyone who pulled that instance before step 1.
   Ask each to drop their local copy.
7. Record the date, instance, and the ids forgotten in the issue or ticket that asked for it.

Done inside the retention window: restic immediately (step 3), everything within 14 days.

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
| 2026-09-14 | bpvps1, all five targets | throwaway local `rest-server` repository on bpvps1, before the first deploy (#28) | PASS — wordpress: kbsb_posts 910, kbsb_postmeta 13,884, kbsb_users 30, kbsb_terms 88, kbsb_term_relationships 615, kbsb_comments 123 · bulwark-settings 22 files · bulwark-admin 4 · bulwark-admin-state 2 · traefik-certs 3, all identical |
| 2026-09-14 | booking-staging — **monthly drill, by hand, 1 of 2** (#30) | `fefe6523`, from R2, taken seconds before | PASS — tenants 3, clients 6, bookings 4, client_packages 6, stripe_payments 6 |
| 2026-09-14 | booking-prod — **monthly drill, by hand, 1 of 2** (#30); run with a one-target copy of `targets.yml` before the target was deployed | first `booking-prod` snapshot, from R2 (282,750 B dump) | PASS — tenants 1, clients 0, bookings 0, client_packages 0, stripe_payments 0 (seed data) |
| 2026-09-14 | `restore-live.sh`, end to end (#30) | local Docker: a throwaway Postgres 16 with an RLS policy and a `booking_app` connection held open, local restic repository | PASS — refused a mismatched `--confirm`, a missing one, a volume target and an unknown snapshot id without touching live; a restore failing on a missing role left live open and dropped the copy; a real restore of the **oldest** of five same-day snapshots swapped in ~5 s with the held connection ended, database grants copied, and `booking_app` still subject to RLS on the result |
| 2026-09-14 | bpvps1 + bpvps2 hypervisor snapshots (#30) | `hypervisor-backups.py snapshot`, actions `114673851` (bpvps2), `114673893` (bpvps1) | PASS — each polled `sent` → `started` → `success` in ~16 s. Weekly backups present on both (bpvps1 09-01, 09-08; bpvps2 09-02, 09-09) |
| 2026-09-14 | bpvps1 mail-store (#29) | `f94ff6c3`, throwaway local `rest-server` repository on bpvps1, before the first deploy; Stalwart stopped 4 s | PASS — 24 accounts, 158,946 messages, 8,437,924,652 B. Inventory before capture = inventory after restart (nothing arrived in the window) = restored copy, on every account. The in-server count matched `scripts/mail-inventory.py` on all 24 accounts. |
