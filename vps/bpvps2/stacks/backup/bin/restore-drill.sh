#!/bin/sh
# Restore a snapshot of one booking instance into a throwaway Postgres and compare row
# counts against live. Never touches the live database except to read counts from it.
#
#   docker exec backup /app/bin/restore-drill.sh staging            # latest snapshot
#   docker exec backup /app/bin/restore-drill.sh staging <snapshot>
#
# Exit 0 only when every table in DRILL_TABLES matches live. Rows written since the
# snapshot was taken read as a mismatch -- run backup.sh first for an exact comparison.
set -eu
set -o pipefail
. /app/bin/lib.sh

env=${1:?usage: restore-drill.sh <env> [snapshot]}
snapshot=${2:-latest}
: "${BACKUP_HOST:?}"
# booking-system table names; "payments" is stripe_payments.
DRILL_TABLES=${DRILL_TABLES:-tenants clients bookings client_packages stripe_payments}

inst=$(instance_name "$env")
live=$(db_container "$env")
path=$(scratch_path "$inst")
scratch="restore-drill-$inst"
log() { printf '%s [drill] %s\n' "$(date '+%F %T %Z')" "$*"; }

# shellcheck disable=SC2016
ident=$(docker exec "$live" sh -c 'echo "$POSTGRES_USER $POSTGRES_DB"')
set -- $ident
[ $# -eq 2 ] || { log "cannot read POSTGRES_USER/POSTGRES_DB from $live"; exit 1; }
role=$1 dbname=$2
# The live container's own image, so the restoring server is the build that wrote the dump.
image=$(docker inspect -f '{{.Config.Image}}' "$live")

count_sql() {
  sep=""
  for t in $DRILL_TABLES; do
    printf "%sselect '%s', count(*) from %s" "$sep" "$t" "$t"
    sep=" union all "
  done
}

docker rm -f "$scratch" >/dev/null 2>&1 || true
trap 'docker rm -f "$scratch" >/dev/null 2>&1 || true' EXIT

log "$inst: snapshot $snapshot -> $scratch ($image, no network)"
restic snapshots --host "$BACKUP_HOST" --tag "$inst" "$snapshot"
docker run -d --name "$scratch" --network none \
  -e POSTGRES_USER="$role" -e POSTGRES_DB="$dbname" -e POSTGRES_HOST_AUTH_METHOD=trust \
  "$image" >/dev/null

# Over TCP, not the socket: the image's init-time server listens on the socket only, so
# a TCP answer means the real server is up.
i=0
until docker exec "$scratch" pg_isready -h 127.0.0.1 -U "$role" -d "$dbname" -q 2>/dev/null; do
  i=$((i + 1)); [ "$i" -lt 60 ] || { log "scratch Postgres never became ready"; exit 1; }
  sleep 1
done

# Roles first. psql keeps going past "role postgres already exists", which is expected
# here; a role that genuinely failed to create surfaces below, when pg_restore
# --exit-on-error meets a GRANT that names it.
restic dump --host "$BACKUP_HOST" --tag "$inst" "$snapshot" "$path/globals.sql" \
  | docker exec -i "$scratch" psql -q -U "$role" -d postgres >/dev/null 2>&1 || true
restic dump --host "$BACKUP_HOST" --tag "$inst" "$snapshot" "$path/$dbname.dump" \
  | docker exec -i "$scratch" pg_restore -U "$role" -d "$dbname" --exit-on-error

sql=$(count_sql)
live_counts=$(docker exec "$live" psql -U "$role" -d "$dbname" -At -F ' ' -c "$sql")
restored_counts=$(docker exec "$scratch" psql -U "$role" -d "$dbname" -At -F ' ' -c "$sql")

if compare_counts "$live_counts" "$restored_counts"; then
  log "$inst: PASS -- restored row counts match live"
else
  log "$inst: FAIL -- restored row counts differ from live"
  exit 1
fi
