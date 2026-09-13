#!/usr/bin/env bash
# Validate every config.alloy in the repo against the Alloy tag its own Dockerfile pins.
# A mistyped argument otherwise surfaces only on the host, as a crash-looping agent.
#
# Usage: vps/shared/validate-alloy.sh [repo-root]     exit 0 all valid, 1 otherwise
# Needs docker. Run by deploy-infra.yml.
set -euo pipefail
cd "${1:-.}"

found=0
for cfg in vps/*/stacks/*/config.alloy; do
  [ -f "$cfg" ] || continue
  dir=$(dirname "$cfg")
  image=$(sed -n 's/^FROM //p' "$dir/Dockerfile" | tr -d '\r')
  if [ -z "$image" ]; then
    echo "$cfg: no FROM line in $dir/Dockerfile -- the Alloy tag must be pinned there" >&2
    exit 1
  fi
  echo "--- $cfg against $image"
  docker run --rm -v "$PWD/$dir:/etc/alloy:ro" "$image" validate /etc/alloy/config.alloy
  found=$((found + 1))
done
echo "validate-alloy: $found config(s) valid"
