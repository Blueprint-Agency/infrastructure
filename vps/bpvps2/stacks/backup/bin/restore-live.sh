#!/bin/sh
# Restore a snapshot OVER a live database. The one script in this job that writes to live
# data, so it is a different command from restore-drill.sh and takes the instance name twice:
#
#   docker exec backup /app/bin/restore-live.sh <target> <snapshot> --confirm <target>
#
# <snapshot> is an id from `restic snapshots`, or `latest` typed out. postgres targets only;
# every other kind is a hand procedure in docs/backup-restore.md, "Restore to live".
#
# What it does, in an order where every step before the swap leaves live untouched:
#
#   1. restores <snapshot> into a NEW database beside live, <db>_restore_<stamp>, with live's
#      owner, encoding, locale and database-level grants (pg_dump does not carry those);
#   2. prints the drill tables' row counts, live and restored, side by side;
#   3. snapshots live as it is now (backup.sh <target>), so the restore itself can be undone --
#      and refuses to go on if that fails. After step 1, not before: this snapshot's prune may
#      forget older same-day snapshots, possibly the very one being restored;
#   4. swaps: live stops accepting connections, its sessions are ended, and in ONE
#      transaction live is renamed <db>_pre_restore_<stamp> and the restored copy takes its
#      name. If the swap cannot commit, live is reopened unchanged.
#
# The original is kept, renamed, until someone drops it. Writes that landed between step 3
# and step 4 are in it, not in the restored database.
#
# Exit: 0 swapped · 1 refused or failed, live unchanged and open
set -eu
set -o pipefail
. /app/bin/lib.sh

usage='usage: restore-live.sh <target> <snapshot> --confirm <target>'
name=${1:-}
snapshot=${2:-}
confirm=
[ "${3:-}" = --confirm ] && confirm=${4:-}
[ -n "$name" ] || { echo "$usage" >&2; exit 1; }
: "${BACKUP_HOST:?}" "${BACKUP_TARGETS:?}"

log() { printf '%s [restore-live] %s\n' "$(date '+%F %T %Z')" "$*"; }

lines=$(load_targets "$BACKUP_TARGETS")
line=$(target_line "$lines" "$name") || line=
IFS='|' read -r _ kind live dbname role _ _ <<EOF
$line
EOF
check_live_restore "$name" "$kind" "$snapshot" "$confirm" || { echo "$usage" >&2; exit 1; }

# Resolve the snapshot to its id before anything is done in its name. `restic snapshots <id>`
# exits 0 for an id that matches nothing, so the JSON is read instead. The id, not `latest`,
# is what gets restored: step 3 writes a newer snapshot.
json=$(restic snapshots --host "$BACKUP_HOST" --tag "$name" --json "$snapshot") || {
  log "cannot read the restic repository (restic exit $?)"; exit 1; }
id=$(snapshot_short_id "$json") || {
  log "no snapshot '$snapshot' of $name on $BACKUP_HOST -- docker exec backup restic snapshots --tag $name"; exit 1; }

stamp=$(date +%Y%m%dt%H%M%S)
names=$(restore_db_names "$dbname" "$stamp") || exit 1
new=${names% *} old=${names#* }

psql_live() { # <database> [psql args...] -- as the target's owner role, stopping on error
  _db=$1; shift
  docker exec -i "$live" psql -U "$role" -d "$_db" -v ON_ERROR_STOP=1 -q "$@"
}

# Whatever ends this run before the swap commits -- an error, Ctrl-C -- reopens live if it
# was closed and drops the half-restored copy. After the swap there is nothing to undo here.
state=restoring
on_exit() {
  [ "$state" = swapped ] && return 0
  if [ "$state" = closed ]; then
    psql_live postgres -v live="$dbname" <<'SQL' || log "COULD NOT REOPEN $dbname -- run: ALTER DATABASE \"$dbname\" WITH ALLOW_CONNECTIONS true"
select format('ALTER DATABASE %I WITH ALLOW_CONNECTIONS true', :'live') \gexec
SQL
  fi
  docker exec "$live" dropdb -U "$role" --if-exists "$new" >/dev/null 2>&1 || true
  log "$name: NOT restored -- live $dbname is unchanged and open"
}
trap on_exit EXIT
trap 'exit 1' INT TERM HUP

log "$name: RESTORING OVER LIVE -- $live/$dbname <- snapshot $id"

# ── 1. restore beside live ───────────────────────────────────────────────────────────
log "$name: 1/4 restoring snapshot $id into $new"
# Settings made with ALTER DATABASE ... SET are not in the dump either. There are none today;
# rather than half-copy them if that changes, refuse and let a human carry them over.
settings=$(psql_live postgres -At -v live="$dbname" <<'SQL'
select count(*) from pg_db_role_setting s join pg_database d on d.oid = s.setdatabase
 where d.datname = :'live';
SQL
)
[ "$settings" = 0 ] || { log "$dbname has ALTER DATABASE ... SET settings; copy them by hand -- not restoring"; exit 1; }
# Only libc collation is copied below. An ICU database would come back with a different
# collation provider -- different sort order, different unique-index behaviour -- so refuse.
provider=$(psql_live postgres -At -v live="$dbname" <<'SQL'
select datlocprovider from pg_database where datname = :'live';
SQL
)
[ "$provider" = c ] || { log "$dbname uses locale provider '$provider', not libc; restore it by hand -- not restoring"; exit 1; }

psql_live postgres -v live="$dbname" -v new="$new" <<'SQL'
select format('CREATE DATABASE %I WITH TEMPLATE template0 OWNER %I ENCODING %L LC_COLLATE %L LC_CTYPE %L',
              :'new', pg_get_userbyid(datdba), pg_encoding_to_char(encoding), datcollate, datctype)
  from pg_database where datname = :'live' \gexec
-- Database-level grants: booking_app's CONNECT lives here, not in the dump. Without it the
-- app's RLS role could not connect to the restored database at all.
select format('REVOKE ALL ON DATABASE %I FROM PUBLIC', :'new')
  from pg_database where datname = :'live' and datacl is not null \gexec
select format('GRANT %s ON DATABASE %I TO %s', a.privilege_type, :'new',
              case when a.grantee = 0 then 'PUBLIC' else quote_ident(pg_get_userbyid(a.grantee)) end)
  from pg_database d, aclexplode(d.datacl) a where d.datname = :'live' \gexec
SQL

# Roles are cluster-wide and already on live, so globals.sql is not replayed. A role the dump
# needs and live lacks stops the restore here, before the swap.
restic dump --host "$BACKUP_HOST" --tag "$name" "$id" "$(scratch_path "$name")/$dbname.dump" |
  docker exec -i "$live" pg_restore -U "$role" -d "$new" --exit-on-error

# ── 2. what is about to change ───────────────────────────────────────────────────────
log "$name: 2/4 row counts -- live now vs the restored copy"
sql=$(count_sql postgres "$(drill_tables "$BACKUP_TARGETS" "$name")")
live_counts=$(docker exec "$live" psql -U "$role" -d "$dbname" -At -F ' ' -c "$sql")
new_counts=$(docker exec "$live" psql -U "$role" -d "$new" -At -F ' ' -c "$sql")
compare_counts "$live_counts" "$new_counts" || true

# ── 3. the undo: a snapshot of live as it is right now ───────────────────────────────
log "$name: 3/4 snapshot of live before replacing it"
rc=0
/app/bin/backup.sh "$name" || rc=$?
# 3 is "green, but other targets were left out" -- exactly what a one-target run is.
[ "$rc" -eq 0 ] || [ "$rc" -eq 3 ] || { log "$name: the pre-restore snapshot failed (exit $rc); refusing to swap"; exit 1; }

# From here no nightly run may start: it would dump a database halfway through the swap.
exec 9> /run/backup.lock
flock -n 9 || { log "a backup run is in progress; try again when it ends"; exit 1; }

# ── 4. the swap ──────────────────────────────────────────────────────────────────────
log "$name: 4/4 swapping: $dbname -> $old, $new -> $dbname"
state=closed
psql_live postgres -v live="$dbname" <<'SQL'
select format('ALTER DATABASE %I WITH ALLOW_CONNECTIONS false', :'live') \gexec
SQL

swapped=0
i=0
while [ "$i" -lt 15 ]; do
  i=$((i + 1))
  # Sessions end asynchronously, so the rename may meet one still closing: retry briefly.
  if psql_live postgres -v live="$dbname" -v new="$new" -v old="$old" >/dev/null 2>&1 <<'SQL'
select pg_terminate_backend(pid) from pg_stat_activity
 where datname in (:'live', :'new') and pid <> pg_backend_pid();
select pg_sleep(1);
begin;
select format('ALTER DATABASE %I RENAME TO %I', :'live', :'old') \gexec
select format('ALTER DATABASE %I RENAME TO %I', :'new', :'live') \gexec
commit;
SQL
  then
    swapped=1
    break
  fi
done

if [ "$swapped" != 1 ]; then
  log "$name: FAILED -- sessions on $dbname kept the swap from committing after $i attempts"
  exit 1  # on_exit reopens live and drops $new
fi
state=swapped

# The set-aside original stays readable for comparison; nothing connects to it by name.
psql_live postgres -v old="$old" <<'SQL'
select format('ALTER DATABASE %I WITH ALLOW_CONNECTIONS true', :'old') \gexec
SQL

log "$name: DONE -- $dbname is now snapshot $id; the previous database is $old"
log "$name: the app's connections were ended; restart its container if it does not reconnect"
log "$name: drop the original once satisfied: docker exec $live dropdb -U $role '$old'"
