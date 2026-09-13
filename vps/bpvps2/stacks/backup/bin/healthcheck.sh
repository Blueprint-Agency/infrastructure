#!/bin/sh
# Docker healthcheck: unhealthy when any declared target has no successful backup newer
# than BACKUP_MAX_AGE seconds. Reads the same heartbeat file the monitoring agent reads,
# so `docker ps` and the staleness alert can never disagree about what "last success" is.
#
# Also unhealthy while a container this job stopped has stayed stopped longer than any run
# keeps one down: the pause limit, plus 120 s to stop, 60 s to kill, 180 s to answer, plus
# five minutes' slack. That is a mail server down, and it is this job's doing.
set -eu
. /app/bin/lib.sh
. /app/bin/stalwart.sh

rc=0
minutes=$(( (${BACKUP_PAUSE_LIMIT:-600} + 120 + 60 + 180) / 60 + 5 ))
for f in $(find "$STOPPED_ROOT" -type f -mmin +"$minutes" 2>/dev/null); do
  echo "${f##*/}: stopped by the backup job over $minutes minutes ago and never started -- docker start ${f##*/}"
  rc=1
done

lines=$(load_targets "$BACKUP_TARGETS")
check_health "$(date +%s)" "${BACKUP_MAX_AGE:?}" \
  "$(cat "$TEXTFILE_DIR/backup.prom" 2>/dev/null || true)" "$(target_names "$lines")" || rc=1
exit "$rc"
