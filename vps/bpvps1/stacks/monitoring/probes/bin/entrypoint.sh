#!/bin/sh
# busybox crond starts every job with an EMPTY environment. Save the container's environment
# where the crontab lines can source it, run every job once so a fresh container reports within
# a minute instead of a week (tailscale), then hand over to crond.
set -eu
umask 077
export -p > /run/job.env
mkdir -p /tmp/probes
for job in docker postgres mail tailscale; do
  /app/bin/probe.sh "$job" || true
done
exec crond -f -l 8
