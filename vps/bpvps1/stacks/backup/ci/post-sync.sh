#!/usr/bin/env bash
# Run by deploy-infra.yml before `docker compose up`.
#
# 1. Refuse a stack dir that is not wholly deploy-owned. On this host stalwart, traefik and
#    wordpress are root:root, and a root-owned file here means an rsync that could not
#    replace it -- a deploy that "succeeded" while the host kept running the old job.
#    Fail loudly instead.
# 2. Create the monitoring textfile volume the heartbeat is written into. It belongs to no
#    stack (see docs/textfile-metrics.md). Idempotent.
set -euo pipefail

# `|| true`: with many offending files, head exits early and find dies of SIGPIPE --
# which pipefail would turn into a silent exit before the message below.
not_ours=$(find . ! -user deploy -print | head -5 || true)
if [ -n "$not_ours" ]; then
  echo "backup: $(pwd) holds files not owned by deploy -- CI cannot keep them current:" >&2
  echo "$not_ours" >&2
  echo "fix as root: chown -R deploy:deploy $(pwd)" >&2
  exit 1
fi

docker volume create monitoring_textfile >/dev/null
