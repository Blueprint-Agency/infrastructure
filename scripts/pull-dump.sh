#!/usr/bin/env bash
# Pull a database snapshot from a host's backups into a LOCAL database -- the one sanctioned way
# member data reaches a laptop. Explicit, named and logged on the host before a byte leaves.
#
#   scripts/pull-dump.sh <ssh-alias> <target> --reason "<why>" --into <local-postgres-url> [--snapshot <id>]
#   scripts/pull-dump.sh bp-bpvps2 booking-staging --reason "reproduce booking-system#131" \
#     --into postgres://postgres:postgres@localhost:5432/booking_restore
#
# --into must be a local database (localhost / 127.0.0.1 / ::1): it is created if missing and
# REPLACED if not. The dump sits in a mode-600 temp file only while pg_restore reads it, and is
# deleted on every exit. --who defaults to `git config user.name`.
#
# The log line is on the host: `docker exec backup cat /cache/exports.log`.
# Runbook: docs/backup-restore.md, "A dump on a developer's machine".
set -euo pipefail

usage='usage: pull-dump.sh <ssh-alias> <target> --reason "<why>" --into <local-postgres-url> [--snapshot <id>] [--who <name>]'
[ $# -ge 2 ] || { echo "$usage" >&2; exit 2; }
host=$1 target=$2
shift 2
reason='' into='' snapshot=latest who=$(git config user.name 2>/dev/null || true)
while [ $# -gt 0 ]; do
  case $1 in
    --reason) reason=${2:-} ;;
    --into) into=${2:-} ;;
    --snapshot) snapshot=${2:-} ;;
    --who) who=${2:-} ;;
    *) echo "$usage" >&2; exit 2 ;;
  esac
  shift 2 || { echo "$usage" >&2; exit 2; }
done
[ -n "$reason" ] && [ -n "$into" ] && [ -n "$who" ] || { echo "$usage" >&2; exit 2; }

# The whole point is that this lands on a developer's own machine, never another server. The
# host is parsed out, not pattern-matched: `...@localhost/db?host=prod` would pass a glob and
# libpq would connect to prod. So no query string at all, and exactly one @.
refuse_into() { echo "refusing: --into must be postgres://user[:pass]@localhost|127.0.0.1|[::1][:port]/db, no ?options -- $1" >&2; exit 2; }
case $into in *\?*) refuse_into "it has a query string" ;; esac
rest=${into#postgres://}; rest=${rest#postgresql://}
[ "$rest" != "$into" ] || refuse_into "not a postgres:// URL"
authority=${rest%%/*}
case $authority in *@*@*) refuse_into "more than one @" ;; *@*) ;; *) refuse_into "no user@" ;; esac
hostport=${authority#*@}
case $hostport in
  localhost | localhost:[0-9]* | 127.0.0.1 | 127.0.0.1:[0-9]* | '[::1]' | '[::1]:'[0-9]*) ;;
  *) refuse_into "host is '$hostport'" ;;
esac

# pg_restore reads postgres dumps only. Decide from the repo's own targets.yml, BEFORE the host
# exports anything: a refused kind must not leave member data and a log line behind for nothing.
targets="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/vps/${host#bp-}/stacks/backup/targets.yml"
[ -r "$targets" ] || { echo "no backup targets file for $host at $targets" >&2; exit 2; }
py=python3; "$py" -c 'import yaml' 2>/dev/null || py=python
kind=$("$py" - "$targets" "$target" <<'PY'
import sys, yaml
t = [x for x in yaml.safe_load(open(sys.argv[1]))["targets"] if x["name"] == sys.argv[2]]
print(t[0]["kind"] if t else "")
PY
)
[ "$kind" = postgres ] || { echo "refusing: $target on $host is '${kind:-not a target}', not postgres" >&2; exit 2; }
command -v pg_restore >/dev/null || { echo "pg_restore is not installed" >&2; exit 2; }

dump=$(mktemp)
chmod 600 "$dump"
trap 'rm -f "$dump"' EXIT

echo "==> $host: exporting $target ($snapshot) -- logged on the host as $who: $reason" >&2
# printf %q: the reason travels through the remote shell as one argument, quotes and all.
ssh -o ConnectTimeout=20 -o BatchMode=yes "$host" \
  "docker exec backup /app/bin/export-dump.sh $(printf '%q ' "$target" "$snapshot" --who "$who" --reason "$reason")" \
  > "$dump"
[ -s "$dump" ] || { echo "the host sent an empty dump" >&2; exit 1; }

# Recreate the local database, so nothing of an earlier pull survives beside this one.
base=${into%%\?*}
dbname=${base##*/}
admin=${base%/*}/postgres
[ -n "$dbname" ] && [ "$dbname" != postgres ] || { echo "refusing: name a database other than postgres in --into" >&2; exit 2; }
echo "==> recreating local database $dbname" >&2
psql "$admin" -v ON_ERROR_STOP=1 -q -c "drop database if exists \"$dbname\" with (force)" -c "create database \"$dbname\""

# --no-owner --no-acl: production's roles do not exist locally, and are not wanted there.
# Row-level-security policies still name booking_app; create that role locally first
# (`create role booking_app`) or those statements are reported and skipped.
echo "==> restoring into $dbname" >&2
rc=0
pg_restore --no-owner --no-acl -d "$into" "$dump" || rc=$?
echo "==> done (pg_restore exit $rc); the dump file is deleted" >&2
exit "$rc"
