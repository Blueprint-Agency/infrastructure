#!/bin/sh
# busybox crond starts every job with an EMPTY environment -- no RESTIC_*, no TZ. Save
# the container's environment where the crontab line can source it, then hand over.
set -eu
umask 077
export -p > /run/job.env
exec crond -f -l 8
