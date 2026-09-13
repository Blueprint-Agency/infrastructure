#!/bin/sh
# One backup run: every target declared in targets.yml, each snapshotted into this host's
# restic repository in R2 under its own tag, each pruned only after its own snapshot
# succeeded, each writing its own heartbeat.
#
# Nightly at 03:30 Asia/Kuala_Lumpur via crontab. On demand (before a migration):
#   docker exec backup /app/bin/backup.sh                    # every target
#   docker exec backup /app/bin/backup.sh booking-staging    # just these; exits 3, not 0
#
# Exit: 0 every target green · 1 a target failed · 2 the run could not start
#       3 green, but targets were left out -- a partial run never reads as a clean pass.
#
# One target failing does not stop the others: a broken volume must not also cost tonight's
# database. The failed target writes no heartbeat, so its metric goes stale and alerts.
# See docs/backup-restore.md.
set -eu
. /app/bin/lib.sh

: "${BACKUP_HOST:?}" "${BACKUP_TARGETS:?}" "${BACKUP_IMAGE:?}" "${TEXTFILE_DIR:?}"
: "${RESTIC_REPOSITORY:?}" "${RESTIC_PASSWORD:?}" "${RESTIC_CACHE_VOLUME:?}"

log() { printf '%s [backup] %s\n' "$(date '+%F %T %Z')" "$*"; }

lines=$(load_targets "$BACKUP_TARGETS") || exit 2
names=$(target_names "$lines")
selected=$(select_targets "$names" "$@") || exit 2

# The dumps are plaintext member data: never leave one behind, including on failure.
trap 'rm -rf "$SCRATCH_ROOT"/*' EXIT

# Exit 10 is restic's "repository does not exist". Anything else -- a bad key, no
# network -- must fail the run, not attempt an init against a repository we cannot see.
# (The repository URL carries the R2 account id, so it is not logged.)
restic cat config >/dev/null 2>&1 || {
  rc=$?
  [ "$rc" -eq 10 ] || { log "cannot open the restic repository (restic exit $rc)"; exit 2; }
  log "initialising new repository"
  restic init
}

# ── Per-target steps ─────────────────────────────────────────────────────────────────
# Every step below ends in `|| return 1`, explicitly. `set -e` cannot be trusted here:
# these functions run inside command substitutions, where busybox ash (like bash) does
# not apply it -- a refused dump role would log its refusal and carry on dumping anyway.

# postgres: pg_dump runs INSIDE the server container, so client and server are the same
# build -- a restore never meets a format from a newer pg_dump.
dump_postgres() { # <name> <container> <database> <role> <dir>
  super=$(docker exec "$2" psql -U "$4" -d "$3" -At \
    -c 'select rolsuper from pg_roles where rolname = current_user') || return 1
  check_dump_role "$4" "$super" || return 1
  docker exec "$2" pg_dump -U "$4" -Fc "$3" > "$5/$3.dump" || return 1
  # Roles are cluster-wide and not in pg_dump: without them a restore fails on every
  # GRANT and policy that names an application role.
  docker exec "$2" pg_dumpall -U "$4" --globals-only > "$5/globals.sql" || return 1
  [ -s "$5/globals.sql" ] || { echo "$1: globals.sql is empty" >&2; return 1; }
  wc -c < "$5/$3.dump" | tr -d ' '
}

# mysql: mariadb-dump where the image has it (MariaDB 11 dropped the mysqldump name),
# mysqldump otherwise. The password is read from the server container's OWN environment
# inside that container, so it never appears in an argv on this side.
dump_mysql() { # <name> <container> <database> <role> <dir>
  # shellcheck disable=SC2016
  docker exec "$2" sh -c '
    if [ "$1" = root ]; then
      MYSQL_PWD=${MARIADB_ROOT_PASSWORD:-${MYSQL_ROOT_PASSWORD:-}}
    else
      MYSQL_PWD=${MARIADB_PASSWORD:-${MYSQL_PASSWORD:-}}
    fi
    export MYSQL_PWD
    dump=mysqldump; command -v mariadb-dump >/dev/null && dump=mariadb-dump
    exec $dump -u "$1" --single-transaction --routines --triggers --events --databases "$2"
  ' sh "$4" "$3" > "$5/$3.sql" || return 1
  wc -c < "$5/$3.sql" | tr -d ' '
}

# volume: measured through a read-only mount in a throwaway container from this image.
# busybox du has no -b, so this is allocated KiB x 1024 -- close enough for a floor.
volume_bytes() { # <volume>
  docker volume inspect "$1" >/dev/null || return 1
  kb=$(docker run --rm -v "$1:/volumes/$1:ro" --entrypoint du "$BACKUP_IMAGE" -sk "/volumes/$1") || return 1
  echo $((${kb%%[!0-9]*} * 1024))
}

# volume snapshot: restic runs in a sibling container that mounts the volume READ-ONLY,
# so the volume is never mounted into this long-lived container and adding one needs no
# compose change. -e NAME passes this container's value through without putting it in argv.
snapshot_volume() { # <name> <volume>
  docker run --rm \
    -v "$2:/volumes/$2:ro" -v "$RESTIC_CACHE_VOLUME:/cache" \
    -e RESTIC_REPOSITORY -e RESTIC_PASSWORD -e RESTIC_CACHE_DIR \
    -e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY -e AWS_DEFAULT_REGION \
    --entrypoint restic "$BACKUP_IMAGE" \
    backup --host "$BACKUP_HOST" --tag "$1" "/volumes/$2"
}

# run_target <line>: everything for one target. Logs go to stderr; the only thing on
# stdout is the size that passed the floor.
run_target() {
  IFS='|' read -r name kind container database role volume floor <<EOF
$1
EOF
  dir=$(scratch_path "$name") || return 1
  rm -rf "$dir" && mkdir -p "$dir" || return 1

  case $kind in
    postgres | mysql)
      log "$name: dumping $database from $container as $role" >&2
      bytes=$("dump_$kind" "$name" "$container" "$database" "$role" "$dir") || return 1
      check_floor "$name" "$bytes" "$floor" || return 1
      log "$name: snapshot ($bytes bytes)" >&2
      restic backup --host "$BACKUP_HOST" --tag "$name" "$dir" >&2 || return 1
      ;;
    volume)
      bytes=$(volume_bytes "$volume") || return 1
      check_floor "$name" "$bytes" "$floor" || return 1
      log "$name: snapshot of volume $volume ($bytes bytes)" >&2
      snapshot_volume "$name" "$volume" >&2 || return 1
      ;;
  esac

  log "$name: pruning 7 daily / 4 weekly / 6 monthly" >&2
  restic forget --host "$BACKUP_HOST" --tag "$name" --group-by host,tags \
    --keep-daily 7 --keep-weekly 4 --keep-monthly 6 --prune >&2 || return 1

  rm -rf "$dir"
  echo "$bytes"
}

# The heartbeat: atomically replace this job's file in the monitoring textfile directory.
# A rename within one directory is atomic, so the agent never reads half a file; the temp
# name does not end in .prom, so it is never read at all.
heartbeat() { # <name> <bytes>
  prom="$TEXTFILE_DIR/backup.prom"
  old=$(cat "$prom" 2>/dev/null || true)
  metrics_update "$old" "$names" "$1" "$(date +%s)" "$2" > "$prom.tmp" || return 1
  # Explicit: cron runs inherit the entrypoint's umask 077, a `docker exec` run does not,
  # and a monitoring agent that is not root must be able to read the file after either.
  chmod 644 "$prom.tmp"
  mv "$prom.tmp" "$prom"
}

failed=0
skipped=0
for name in $names; do
  case " $selected " in *" $name "*) ;; *) skipped=$((skipped + 1)); continue ;; esac

  if bytes=$(run_target "$(target_line "$lines" "$name")"); then
    # A heartbeat that cannot be written is a failure too -- but of this target only.
    if heartbeat "$name" "$bytes"; then
      log "$name: done"
    else
      failed=$((failed + 1))
      log "$name: snapshot taken, but the heartbeat could not be written to $TEXTFILE_DIR"
    fi
  else
    rm -rf "$(scratch_path "$name")"
    failed=$((failed + 1))
    log "$name: FAILED -- no heartbeat written"
  fi
done

status=$(run_exit "$failed" "$skipped")
log "finished: $failed failed, $skipped left out of this run, exit $status"
exit "$status"
