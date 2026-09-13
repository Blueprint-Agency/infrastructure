#!/bin/sh
# One backup run: dump each booking instance as its owner role, snapshot it into this
# host's restic repository in R2, then prune -- only after that snapshot succeeded.
#
# Nightly at 03:30 Asia/Kuala_Lumpur via crontab. On demand (before a migration):
#   docker exec backup /app/bin/backup.sh
#
# BACKUP_ENVS lists booking ENV_NAMEs. booking-staging holds every studio's real data.
# See docs/backup-restore.md.
set -eu
set -o pipefail
. /app/bin/lib.sh

: "${BACKUP_HOST:?}" "${BACKUP_ENVS:?}" "${RESTIC_REPOSITORY:?}" "${RESTIC_PASSWORD:?}"

log() { printf '%s [backup] %s\n' "$(date '+%F %T %Z')" "$*"; }

# The dumps are plaintext member data: never leave one behind, including on failure.
trap 'rm -rf "$SCRATCH_ROOT"/*' EXIT

# Exit 10 is restic's "repository does not exist". Anything else -- a bad key, no
# network -- must fail the run, not attempt an init against a repository we cannot see.
# (The repository URL carries the R2 account id, so it is not logged.)
restic cat config >/dev/null 2>&1 || {
  rc=$?
  [ "$rc" -eq 10 ] || { log "cannot open the restic repository (restic exit $rc)"; exit "$rc"; }
  log "initialising new repository"
  restic init
}

for env in $BACKUP_ENVS; do
  inst=$(instance_name "$env")
  db=$(db_container "$env")
  dir=$(scratch_path "$inst")

  # The server's own env names the role that created -- and so owns -- the database.
  # shellcheck disable=SC2016
  ident=$(docker exec "$db" sh -c 'echo "$POSTGRES_USER $POSTGRES_DB"')
  set -- $ident
  [ $# -eq 2 ] || { log "$inst: cannot read POSTGRES_USER/POSTGRES_DB from $db"; exit 1; }
  role=$1 dbname=$2
  super=$(docker exec "$db" psql -U "$role" -d "$dbname" -At \
    -c 'select rolsuper from pg_roles where rolname = current_user')
  check_dump_role "$role" "$super"

  rm -rf "$dir" && mkdir -p "$dir"
  log "$inst: dumping $dbname as $role"
  # pg_dump runs INSIDE the server container, so client and server are the same build --
  # a restore never meets a format from a newer pg_dump.
  docker exec "$db" pg_dump -U "$role" -Fc "$dbname" > "$dir/$dbname.dump"
  # Roles are cluster-wide and not in pg_dump: without them a restore fails on every
  # GRANT and policy that names booking_app.
  docker exec "$db" pg_dumpall -U "$role" --globals-only > "$dir/globals.sql"
  for f in "$dir/$dbname.dump" "$dir/globals.sql"; do
    [ -s "$f" ] || { log "$inst: $(basename "$f") is empty"; exit 1; }
  done

  log "$inst: snapshot ($(du -h "$dir/$dbname.dump" | cut -f1))"
  restic backup --host "$BACKUP_HOST" --tag "$inst" "$dir"

  log "$inst: pruning 7 daily / 4 weekly / 6 monthly"
  restic forget --host "$BACKUP_HOST" --tag "$inst" --group-by host,tags \
    --keep-daily 7 --keep-weekly 4 --keep-monthly 6 --prune

  rm -rf "$dir"
  log "$inst: done"
done
