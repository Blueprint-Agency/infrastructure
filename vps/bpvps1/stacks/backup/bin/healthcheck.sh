#!/bin/sh
# Docker healthcheck: unhealthy when any declared target has no successful backup newer
# than BACKUP_MAX_AGE seconds. Reads the same heartbeat file the monitoring agent reads,
# so `docker ps` and the staleness alert can never disagree about what "last success" is.
set -eu
. /app/bin/lib.sh

lines=$(load_targets "$BACKUP_TARGETS")
check_health "$(date +%s)" "${BACKUP_MAX_AGE:?}" \
  "$(cat "$TEXTFILE_DIR/backup.prom" 2>/dev/null || true)" "$(target_names "$lines")"
