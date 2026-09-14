#!/bin/sh
# One backup run: every target declared in targets.yml, each snapshotted into this host's
# restic repository in R2 under its own tag, each pruned only after its own snapshot
# succeeded, each writing its own heartbeat.
#
# Nightly via this host's crontab (the hosts stagger). On demand (before a migration):
#   docker exec backup /app/bin/backup.sh                    # every target
#   docker exec backup /app/bin/backup.sh <target>...        # just these; exits 3, not 0
#
# This file is identical on every host that runs the job -- nothing host-specific in here.
#
# Exit: 0 every target green · 1 a target failed · 2 the run could not start
#       3 green, but targets were left out -- a partial run never reads as a clean pass.
#
# One target failing does not stop the others: a broken volume must not also cost tonight's
# database. The failed target writes no heartbeat, so its metric goes stale and alerts.
# See docs/backup-restore.md.
set -eu
. /app/bin/lib.sh
. /app/bin/stalwart.sh

: "${BACKUP_HOST:?}" "${BACKUP_TARGETS:?}" "${BACKUP_IMAGE:?}" "${TEXTFILE_DIR:?}"
: "${RESTIC_REPOSITORY:?}" "${RESTIC_PASSWORD:?}" "${RESTIC_CACHE_VOLUME:?}"
# The longest a `stalwart` target may keep its server stopped for the snapshot, in seconds.
# Past it the snapshot is abandoned, the server started, and the target fails.
PAUSE_LIMIT=${BACKUP_PAUSE_LIMIT:-600}

log() { printf '%s [backup] %s\n' "$(date '+%F %T %Z')" "$*"; }

lines=$(load_targets "$BACKUP_TARGETS") || exit 2
names=$(target_names "$lines")
selected=$(select_targets "$names" "$@") || exit 2

# One run at a time. Two would share scratch paths -- and a second run ending would start a
# mail server the first had stopped, mid-snapshot, making that snapshot a live read.
exec 9> /run/backup.lock
flock -n 9 || { log "another backup run is in progress; not starting a second"; exit 2; }

# The dumps are plaintext member data: never leave one behind, including on failure. And
# never leave a mail server stopped: whatever ends this run -- an error, `docker stop
# backup`, Ctrl-C -- starts any container a stalwart target stopped.
trap 'restart_stopped || true; rm -rf "$SCRATCH_ROOT"/*' EXIT
# Covers Ctrl-C on a `docker exec` run. `docker stop backup` signals crond (PID 1), not this
# script, and takes it down with the container: for that, entrypoint.sh is the safety net.
trap 'exit 1' INT TERM HUP

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

# mysql: logged in by MYSQL_LOGIN (lib.sh), inside the server container, so the password
# never appears in an argv on this side and the dump tool is the server's own build.
dump_mysql() { # <name> <container> <database> <role> <dir>
  # shellcheck disable=SC2016
  docker exec "$2" sh -c "$MYSQL_LOGIN"'
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
#
# <limit> is seconds, or 0 for none. It is enforced INSIDE the sibling, on restic itself:
# killing this side's `docker run` client would leave the container, and restic, running.
# SIGINT, so restic removes its repository lock on the way out.
snapshot_volume() { # <name> <volume> <limit> [restic backup args...]
  _sv_name=$1 _sv_volume=$2 _sv_limit=$3
  shift 3
  # busybox `timeout 0` does not mean "no limit": it kills at once. No limit is no timeout.
  if [ "$_sv_limit" -gt 0 ]; then
    # -k 60: a restic that ignores the SIGINT is KILLed a minute later, so the limit holds.
    set -- timeout -s INT -k 60 "$_sv_limit" restic backup "$@"
  else
    set -- restic backup "$@"
  fi
  _sv_entry=$1
  shift
  docker run --rm \
    -v "$_sv_volume:/volumes/$_sv_volume:ro" -v "$RESTIC_CACHE_VOLUME:/cache" \
    -e RESTIC_REPOSITORY -e RESTIC_PASSWORD -e RESTIC_CACHE_DIR \
    -e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY -e AWS_DEFAULT_REGION \
    --entrypoint "$_sv_entry" "$BACKUP_IMAGE" \
    "$@" --host "$BACKUP_HOST" --tag "$_sv_name" "/volumes/$_sv_volume"
}

# forget_warm <name>: drop the warm-pass snapshots of a stalwart target -- tonight's, and
# any a failed run left behind. Their data stays wherever tonight's real snapshot uses it;
# the rest goes at this target's --prune.
forget_warm() {
  # Two steps, not a pipe: ash has no pipefail here, and a failed listing piped into yq
  # reads as "no warm snapshots" -- which would leave them to pile up, never pruned.
  json=$(restic snapshots --host "$BACKUP_HOST" --tag "$1-warm" --json) || return 1
  ids=$(printf '%s' "$json" | yq -p json -r '.[].id') || return 1
  # shellcheck disable=SC2086 # one argument per id
  [ -z "$ids" ] || restic forget $ids >/dev/null
}

# stalwart: Stalwart keeps mail in RocksDB, and a live read of that is not a backup. v0.16.21
# has no online export (docs/backup-restore.md, "The mail store"), so the server is stopped
# for the snapshot. Two passes keep that stop short:
#
#   1. warm: the volume, read while Stalwart runs. NOT a backup -- an inconsistent read,
#      tagged <name>-warm and forgotten below -- but it puts nearly every byte in the
#      repository, so the pause does not depend on how much is new or how fast R2 is.
#   2. real: Stalwart stopped, the volume read again with the warm pass as parent. restic
#      skips every file whose size and mtime are unchanged, and RocksDB's .sst and .blob
#      files never change once written -- so this reads the few files written since.
#
# Then Stalwart starts, and the target fails unless it answers again.
snapshot_stalwart() { # <name> <container> <volume>
  forget_warm "$1" || return 1
  log "$1: warm pass of $3 while $2 runs (inconsistent; tagged $1-warm, forgotten after)"
  # restic exit 3 is "snapshot written, some files could not be read": RocksDB compaction
  # deletes .sst files while the server runs, so on this pass that is expected, not a fault.
  warm=$(snapshot_volume "$1-warm" "$3" 0 --json) || [ $? -eq 3 ] || return 1
  warm_id=$(restic_snapshot_id "$warm") || return 1

  log "$1: stopping $2 -- mail is paused until it starts (limit ${PAUSE_LIMIT}s)"
  stopped_at=$(date +%s) || return 1
  stop_for_backup "$2" || { restart_stopped; return 1; }
  rc=0
  snapshot_volume "$1" "$3" "$PAUSE_LIMIT" --parent "$warm_id" || rc=1
  restart_stopped || rc=1
  log "$1: $2 was stopped for $(($(date +%s) - stopped_at))s"
  [ "$rc" -eq 0 ] || { log "$1: the snapshot failed or overran ${PAUSE_LIMIT}s"; return 1; }

  stalwart_ready "$2" || { log "$1: snapshot taken, but $2 is not answering"; return 1; }
  # Not a failure of tonight's backup: the snapshot is good. A leftover warm snapshot is
  # forgotten at the start of the next run.
  forget_warm "$1" || log "$1: could not forget the warm pass; the next run will"
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
      snapshot_volume "$name" "$volume" 0 >&2 || return 1
      ;;
    stalwart)
      bytes=$(volume_bytes "$volume") || return 1
      check_floor "$name" "$bytes" "$floor" || return 1
      log "$name: snapshot of mail store $volume ($bytes bytes)" >&2
      snapshot_stalwart "$name" "$container" "$volume" >&2 || return 1
      ;;
  esac

  # --keep-within 7d: every snapshot of the last week survives, not just the newest of each day.
  # Without it, a second deploy's pre-migration snapshot forgets the first one's the same day --
  # the one that made the first migration reversible.
  log "$name: pruning -- everything from 7 days, then 7 daily / 4 weekly / 6 monthly" >&2
  restic forget --host "$BACKUP_HOST" --tag "$name" --group-by host,tags \
    --keep-within 7d --keep-daily 7 --keep-weekly 4 --keep-monthly 6 --prune >&2 || return 1

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
