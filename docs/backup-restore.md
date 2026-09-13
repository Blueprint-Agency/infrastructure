# Backups and restore

Nightly, encrypted, off-site snapshots, and the one command that proves they restore.

**Coverage today: `booking-staging` on bpvps2 only** (#26) — the instance that holds every
studio's real member and booking data. The rest of #4 is ticketed: declarative targets,
heartbeat and healthcheck (#27), the other four hosts (#28), mail (#29), and restore-to-live,
the monthly drill and hypervisor snapshots (#30). Until those land, nothing else on any host is
backed up.

## Where snapshots are

| | |
|---|---|
| Bucket | `blueprint-backups`, **Blueprint** Cloudflare account, location APAC |
| Access | private — no `r2.dev` URL, no custom domain. Not `reservetoday-staging`, which serves uploads |
| Repository | one restic repository per host, at the bucket prefix `<host>/` (here `bpvps2/`) |
| Encryption | client-side, restic, with that host's `RESTIC_PASSWORD`. R2 only ever holds ciphertext |
| Credential | an R2 API token with Object Read & Write on **this bucket only** |
| Schedule | 03:30 Asia/Kuala_Lumpur, `crontab` in the `backup` stack |
| Retention | 7 daily / 4 weekly / 6 monthly per instance, `forget --prune` only after that night's snapshot succeeded |

Each snapshot holds `/scratch/booking-<env>/<db>.dump` (`pg_dump -Fc`) and
`/scratch/booking-<env>/globals.sql` (roles — `pg_dump` does not carry them, and without
`booking_app` a restore fails on every GRANT and policy). Snapshots are tagged `booking-<env>`
and taken with `--host bpvps2`.

> **Tags and paths are keyed on `ENV_NAME`, exactly like the booking compose.** `booking-staging`
> and `booking-prod` never share a tag, a scratch path or a retention group. Adding prod is
> `BACKUP_ENVS: staging prod` in the compose file, nothing more.

> **The dump runs as the database's owner role (`POSTGRES_USER`), never as `booking_app`.**
> `booking_app` is subject to Row-Level Security, and `pg_dump` as that role dumps every table
> with no tenant's rows in it and exits 0. `backup.sh` checks the role is superuser or
> `BYPASSRLS` and refuses otherwise.

> `pg_dump` runs **inside** the database container (`docker exec`), so the client is the
> server's own build and a major-version mismatch cannot happen. The restore drill starts its
> scratch server from the live container's image for the same reason.

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
docker exec backup /app/bin/backup.sh

# Restore drill: latest snapshot -> throwaway Postgres -> row counts vs live
docker exec backup /app/bin/restore-drill.sh staging
docker exec backup /app/bin/restore-drill.sh staging <snapshot-id>

# Last night's run
docker logs backup --since 24h
```

The drill compares `COUNT(*)` on `tenants`, `clients`, `bookings`, `client_packages` and
`stripe_payments` (the payments table), and exits non-zero on any difference. Its scratch
container is `restore-drill-booking-<env>`, has **no network**, and is removed on exit. Rows
written since the snapshot read as a mismatch — for an exact comparison, run `backup.sh`
immediately before.

## Getting a dump out by hand

```bash
docker exec backup restic dump --host bpvps2 --tag booking-staging latest \
  /scratch/booking-staging/yoga-sadhana.dump > /tmp/booking-staging.dump
```

That is member data in plaintext on disk. Delete it when done.

## The July 2026 dumps (`manual`)

The two dumps taken by hand during the 2026-07-21 move off VPS3 live in a **separate** restic
repository at the bucket prefix `manual/`, encrypted with **bpvps2's** `RESTIC_PASSWORD`, tagged
`manual`. They are outside every retention policy — nothing prunes them.

```bash
docker exec -e RESTIC_REPOSITORY="$(docker exec backup sh -c 'echo ${RESTIC_REPOSITORY%/bpvps2}/manual')" \
  backup restic snapshots
```

## Record of restores

| Date | Instance | Snapshot | Result |
|---|---|---|---|
| 2026-09-13 | booking-staging | local test repository on bpvps2, before R2 credentials existed | PASS — tenants 3, clients 6, bookings 4, client_packages 6, stripe_payments 6 |
