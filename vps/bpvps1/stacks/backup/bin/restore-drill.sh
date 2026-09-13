#!/bin/sh
# Restore a snapshot of one target somewhere throwaway and prove it matches live. Never
# writes to anything live.
#
#   docker exec backup /app/bin/restore-drill.sh <target>              # latest
#   docker exec backup /app/bin/restore-drill.sh <target> <snapshot>
#
# What "matches" means depends on the target's kind in targets.yml:
#
#   postgres, mysql  restored into a scratch server started from the live container's own
#                    image, with no network; COUNT(*) on the target's drill_tables compared
#                    against live.
#   volume           restored into a scratch directory; every file compared byte for byte
#                    against the live volume, mounted read-only.
#   stalwart         restored into a scratch volume and opened by a scratch Stalwart from
#                    the live container's image, with no network; every account's message
#                    count and bytes compared against live. A byte diff cannot work here:
#                    the live store has been running, and rewriting its files, since the
#                    snapshot. What must survive is the mail, so the mail is what is counted.
#
# Exit 0 only on a full match. Anything written since the snapshot reads as a mismatch --
# run backup.sh <target> first for an exact comparison.
set -eu
set -o pipefail
. /app/bin/lib.sh
. /app/bin/stalwart.sh

name=${1:?usage: restore-drill.sh <target> [snapshot]}
snapshot=${2:-latest}
: "${BACKUP_HOST:?}" "${BACKUP_TARGETS:?}" "${BACKUP_IMAGE:?}" "${RESTIC_CACHE_VOLUME:?}"

lines=$(load_targets "$BACKUP_TARGETS")
line=$(target_line "$lines" "$name") || {
  echo "no target named '$name' in $BACKUP_TARGETS" >&2; exit 1; }
IFS='|' read -r _ kind live dbname role volume _ <<EOF
$line
EOF

path=$(scratch_path "$name")
scratch="restore-drill-$name"
log() { printf '%s [drill] %s\n' "$(date '+%F %T %Z')" "$*"; }

docker rm -f "$scratch" >/dev/null 2>&1 || true
trap 'docker rm -f "$scratch" >/dev/null 2>&1 || true' EXIT

restic snapshots --host "$BACKUP_HOST" --tag "$name" "$snapshot"
dump() { # <file inside the snapshot>
  restic dump --host "$BACKUP_HOST" --tag "$name" "$snapshot" "$1"
}

# ── volume: restore to a scratch directory, diff against the live volume ─────────────
if [ "$kind" = volume ]; then
  log "$name: snapshot $snapshot -> scratch directory, compared with $volume (read-only)"
  # The restore runs in a sibling container: the live volume is never mounted into this
  # long-lived one, the same rule backup.sh follows. --name makes the trap clean it up.
  # shellcheck disable=SC2016
  docker run --rm --name "$scratch" \
    -v "$volume:/live:ro" -v "$RESTIC_CACHE_VOLUME:/cache" \
    -e RESTIC_REPOSITORY -e RESTIC_PASSWORD -e RESTIC_CACHE_DIR \
    -e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY -e AWS_DEFAULT_REGION \
    --entrypoint sh "$BACKUP_IMAGE" -c '
      set -eu
      restic restore --host "$1" --tag "$2" "$3" --target /restored >/dev/null
      got=/restored/volumes/$4
      files=$(find "$got" -type f | wc -l)
      # An empty restore of an empty volume would diff clean. That proves nothing.
      [ "$files" -gt 0 ] || { echo "restored no files"; exit 1; }
      diff -r "$got" /live
      echo "$files files identical"
    ' sh "$BACKUP_HOST" "$name" "$snapshot" "$volume" && {
    log "$name: PASS -- restored files match the live volume"
    exit 0
  }
  log "$name: FAIL -- restored files differ from the live volume"
  exit 1
fi

# ── stalwart: restore to a scratch volume, open it with a scratch server, count mail ────
if [ "$kind" = stalwart ]; then
  image=$(docker inspect -f '{{.Config.Image}}' "$live")
  # The live server's own config.json -- the storage pointer -- so the scratch server opens
  # the restored store exactly the way live opens its own.
  config=$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/etc/stalwart/config.json"}}{{.Source}}{{end}}{{end}}' "$live")
  [ -n "$config" ] || { log "$live mounts no /etc/stalwart/config.json"; exit 1; }
  # -v: the image declares /etc/stalwart and /var/lib/stalwart as VOLUMEs, so every scratch
  # server would otherwise leave two anonymous volumes behind.
  trap 'docker rm -f -v "$scratch" >/dev/null 2>&1 || true; docker volume rm "$scratch" >/dev/null 2>&1 || true' EXIT
  docker volume rm "$scratch" >/dev/null 2>&1 || true
  docker volume create "$scratch" >/dev/null

  log "$name: snapshot $snapshot -> scratch volume $scratch (all mail, in plaintext; removed on exit)"
  # Mounted where restic restores the snapshot's path, so the files land at the volume root.
  docker run --rm --name "$scratch" \
    -v "$scratch:/restored/volumes/$volume" -v "$RESTIC_CACHE_VOLUME:/cache" \
    -e RESTIC_REPOSITORY -e RESTIC_PASSWORD -e RESTIC_CACHE_DIR \
    -e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY -e AWS_DEFAULT_REGION \
    --entrypoint restic "$BACKUP_IMAGE" \
    restore --host "$BACKUP_HOST" --tag "$name" "$snapshot" --target /restored >/dev/null

  # --network none: this is every mailbox and the outbound queue. With a network it would
  # deliver queued mail a second time. A throwaway recovery admin, never live's password.
  pass=$(head -c 24 /dev/urandom | base64 | tr -dc 'A-Za-z0-9')
  log "$name: starting $scratch ($image, no network)"
  docker run -d --name "$scratch" --network none \
    -e STALWART_RECOVERY_ADMIN="admin:$pass" \
    -v "$scratch:/opt/stalwart" -v "$config:/etc/stalwart/config.json:ro" \
    "$image" >/dev/null
  stalwart_ready "$scratch" 300 || { docker logs --tail 30 "$scratch" >&2; exit 1; }

  # Live first: it is the side still moving, so read it nearest the snapshot.
  log "$name: counting every account's mail on $live, then on $scratch"
  live_counts=$(mail_inventory "$live")
  restored_counts=$(mail_inventory "$scratch")

  if compare_counts "$live_counts" "$restored_counts"; then
    log "$name: PASS -- every account's messages and bytes match live"
    exit 0
  fi
  log "$name: FAIL -- restored mail differs from live (mail that arrived after the snapshot counts as a difference)"
  exit 1
fi

# ── postgres / mysql: restore into a scratch server, compare row counts ──────────────
tables=$(drill_tables "$BACKUP_TARGETS" "$name")
sql=$(count_sql "$kind" "$tables")
# The live container's own image, so the restoring server is the build that wrote the dump.
image=$(docker inspect -f '{{.Config.Image}}' "$live")
log "$name: snapshot $snapshot -> $scratch ($image, no network), counting: $tables"

wait_ready() { # <command...>
  i=0
  until "$@" >/dev/null 2>&1; do
    i=$((i + 1)); [ "$i" -lt 90 ] || { log "scratch server never became ready"; exit 1; }
    sleep 1
  done
}

case $kind in
  postgres)
    docker run -d --name "$scratch" --network none \
      -e POSTGRES_USER="$role" -e POSTGRES_DB="$dbname" -e POSTGRES_HOST_AUTH_METHOD=trust \
      "$image" >/dev/null
    # Over TCP, not the socket: the image's init-time server listens on the socket only, so
    # a TCP answer means the real server is up.
    wait_ready docker exec "$scratch" pg_isready -h 127.0.0.1 -U "$role" -d "$dbname" -q

    # Roles first. psql keeps going past "role postgres already exists", which is expected
    # here; a role that genuinely failed to create surfaces below, when pg_restore
    # --exit-on-error meets a GRANT that names it.
    dump "$path/globals.sql" | docker exec -i "$scratch" psql -q -U "$role" -d postgres >/dev/null 2>&1 || true
    dump "$path/$dbname.dump" | docker exec -i "$scratch" pg_restore -U "$role" -d "$dbname" --exit-on-error

    live_counts=$(docker exec "$live" psql -U "$role" -d "$dbname" -At -F ' ' -c "$sql")
    restored_counts=$(docker exec "$scratch" psql -U "$role" -d "$dbname" -At -F ' ' -c "$sql")
    ;;
  mysql)
    docker run -d --name "$scratch" --network none \
      -e MARIADB_ALLOW_EMPTY_ROOT_PASSWORD=1 -e MYSQL_ALLOW_EMPTY_PASSWORD=1 \
      "$image" >/dev/null
    # Over TCP for the same reason as postgres: the entrypoint's init server has networking
    # off, so an answer on 127.0.0.1 is the real server.
    client=mysql; docker exec "$scratch" sh -c 'command -v mariadb' >/dev/null 2>&1 && client=mariadb
    wait_ready docker exec "$scratch" "$client" -h 127.0.0.1 -u root -e 'select 1'

    # The dump was taken with --databases, so it creates and selects its own database.
    dump "$path/$dbname.sql" | docker exec -i "$scratch" "$client" -u root

    # Live counts as the dump role, logged in exactly as backup.sh dumps (MYSQL_LOGIN).
    # shellcheck disable=SC2016
    live_counts=$(docker exec "$live" sh -c "$MYSQL_LOGIN"'
      exec $client -u "$1" -N -B -D "$2" -e "$3"
    ' sh "$role" "$dbname" "$sql" | tr '\t' ' ')
    restored_counts=$(docker exec "$scratch" "$client" -u root -N -B -D "$dbname" -e "$sql" | tr '\t' ' ')
    ;;
esac

if compare_counts "$live_counts" "$restored_counts"; then
  log "$name: PASS -- restored row counts match live"
else
  log "$name: FAIL -- restored row counts differ from live"
  exit 1
fi
