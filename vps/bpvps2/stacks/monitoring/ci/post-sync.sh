#!/usr/bin/env bash
# Run by deploy-infra.yml before `docker compose up`.
#
# The textfile volume is external to every stack that uses it -- producers write into it, this
# agent reads it -- so each of them creates it. `compose up` refuses a missing external volume,
# and this stack may deploy before any producer does. Idempotent. See docs/textfile-metrics.md.
set -euo pipefail
docker volume create monitoring_textfile >/dev/null
