#!/bin/sh
# busybox crond starts every job with an EMPTY environment -- no RESTIC_*, no TZ. Save
# the container's environment where the crontab line can source it, then hand over.
set -eu
umask 077
export -p > /run/job.env

# A backup that died while a mail server was stopped for it -- this container killed, OOM,
# the host rebooted -- left that server stopped, and `restart: unless-stopped` will not
# bring back a container that was stopped on purpose. This start is the first chance to.
. /app/bin/stalwart.sh
restart_stopped || true

exec crond -f -l 8
