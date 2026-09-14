#!/bin/sh
# Stream one database snapshot's dump to stdout, for a developer's local database. Member data
# in plaintext leaving the host -- so it happens only as a named, reasoned act, logged first:
#
#   docker exec backup /app/bin/export-dump.sh <target> <snapshot> --who <name> --reason "<why>" > file
#
# Normally run through scripts/pull-dump.sh on a laptop, which restores it and deletes the file.
# The log line goes to `docker logs backup` (shipped to Grafana Cloud where the host is
# monitored) and to /cache/exports.log, which outlives the container.
#
# postgres (the pg_dump -Fc file) and mysql (the .sql file) targets only.
set -eu
set -o pipefail
. /app/bin/lib.sh

usage='usage: export-dump.sh <target> <snapshot> --who <name> --reason "<why>"'
name=${1:-} snapshot=${2:-}
if [ $# -lt 2 ]; then echo "$usage" >&2; exit 1; fi
shift 2
who='' reason=''
while [ $# -gt 0 ]; do
  case $1 in
    --who) who=${2:-}; shift 2 || { echo "$usage" >&2; exit 1; } ;;
    --reason) reason=${2:-}; shift 2 || { echo "$usage" >&2; exit 1; } ;;
    *) echo "$usage" >&2; exit 1 ;;
  esac
done
: "${BACKUP_HOST:?}" "${BACKUP_TARGETS:?}"

# A dump in a terminal is binary noise and, worse, member data in scrollback.
[ ! -t 1 ] || { echo "refusing to write a dump to a terminal: redirect it to a file" >&2; exit 1; }

lines=$(load_targets "$BACKUP_TARGETS")
target=$(target_line "$lines" "$name") || { echo "no target named '$name'" >&2; exit 1; }
IFS='|' read -r _ kind _ dbname _ _ _ <<EOF
$target
EOF
case $kind in
  postgres) file=$dbname.dump ;;
  mysql) file=$dbname.sql ;;
  *) echo "refusing: $name is a $kind target -- only database dumps are exported" >&2; exit 1 ;;
esac

[ -n "$snapshot" ] || { echo "$usage" >&2; exit 1; }
# Refuse a blank --who or --reason before asking R2 for anything.
export_log_line "$name" "$snapshot" "$who" "$reason" >/dev/null || exit 1

# Resolve `latest` to its id, so the log names exactly what left.
json=$(restic snapshots --host "$BACKUP_HOST" --tag "$name" --json "$snapshot") || {
  echo "cannot read the restic repository (restic exit $?)" >&2; exit 1; }
id=$(snapshot_short_id "$json") || { echo "no snapshot '$snapshot' of $name on $BACKUP_HOST" >&2; exit 1; }
entry=$(export_log_line "$name" "$id" "$who" "$reason") || exit 1

# Logged BEFORE any byte leaves: an export that dies halfway still happened.
logged="$(date '+%F %T %Z') [export] $entry"
printf '%s\n' "$logged" >> /cache/exports.log
printf '%s\n' "$logged" > /proc/1/fd/1
printf '%s\n' "$logged" >&2

restic dump --host "$BACKUP_HOST" --tag "$name" "$id" "$(scratch_path "$name")/$file"
