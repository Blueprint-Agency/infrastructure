#!/bin/sh
# Restore a snapshot of one postgres target into a throwaway Postgres and compare row
# counts against live. Never touches the live database except to read counts from it.
#
#   docker exec backup /app/bin/restore-drill.sh booking-staging              # latest
#   docker exec backup /app/bin/restore-drill.sh booking-staging <snapshot>
#
# The target's container, database and role come from targets.yml. Exit 0 only when every
# table in DRILL_TABLES matches live. Rows written since the snapshot was taken read as a
# mismatch -- run backup.sh first for an exact comparison.
set -eu
set -o pipefail
. /app/bin/lib.sh

name=${1:?usage: restore-drill.sh <target> [snapshot]}
snapshot=${2:-latest}
: "${BACKUP_HOST:?}" "${BACKUP_TARGETS:?}"
# booking-system table names; "payments" is stripe_payments.
DRILL_TABLES=${DRILL_TABLES:-tenants clients bookings client_packages stripe_payments}

lines=$(load_targets "$BACKUP_TARGETS")
line=$(target_line "$lines" "$name") || {
  echo "no target named '$name' in $BACKUP_TARGETS" >&2; exit 1; }
IFS='|' read -r _ kind live dbname role _ _ <<EOF
$line
EOF
[ "$kind" = postgres ] || { echo "$name is a $kind target; the drill restores postgres" >&2; exit 1; }

path=$(scratch_path "$name")
scratch="restore-drill-$name"
log() { printf '%s [drill] %s\n' "$(date '+%F %T %Z')" "$*"; }

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

log "$name: snapshot $snapshot -> $scratch ($image, no network)"
restic snapshots --host "$BACKUP_HOST" --tag "$name" "$snapshot"
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
restic dump --host "$BACKUP_HOST" --tag "$name" "$snapshot" "$path/globals.sql" \
  | docker exec -i "$scratch" psql -q -U "$role" -d postgres >/dev/null 2>&1 || true
restic dump --host "$BACKUP_HOST" --tag "$name" "$snapshot" "$path/$dbname.dump" \
  | docker exec -i "$scratch" pg_restore -U "$role" -d "$dbname" --exit-on-error

sql=$(count_sql)
live_counts=$(docker exec "$live" psql -U "$role" -d "$dbname" -At -F ' ' -c "$sql")
restored_counts=$(docker exec "$scratch" psql -U "$role" -d "$dbname" -At -F ' ' -c "$sql")

if compare_counts "$live_counts" "$restored_counts"; then
  log "$name: PASS -- restored row counts match live"
else
  log "$name: FAIL -- restored row counts differ from live"
  exit 1
fi
