#!/usr/bin/env bash
# Run by deploy-infra.yml before `docker compose up`.
#
# The monitoring textfile volume is shared between this stack (which writes backup.prom)
# and the monitoring agent (which reads it), so it is external to both and created here.
# Idempotent: `docker volume create` on an existing volume is a no-op. See
# docs/textfile-metrics.md.
set -euo pipefail
docker volume create monitoring_textfile >/dev/null
