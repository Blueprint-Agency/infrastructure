#!/usr/bin/env bash
# Self-check for the log byte budget in vps/bpvps2/stacks/db-observability/config.alloy (#54):
# the `loki.process "trim"` block that stands between Database Observability's collectors and
# Grafana Cloud's 50 GB month of logs.
#
# Why this is a test and not a comment. The trim is a regular expression over the collector's
# line format, `querytext="..." datname=`. If an Alloy upgrade moves a field it stops matching
# and says nothing -- and the last time nothing was said, ten bulk INSERTs of ~150 KB each,
# re-sent every minute, spent the month's allowance in nine days. Twice.
#
# So the REAL block is cut out of the REAL config and run in the Alloy image that stack's
# Dockerfile pins, over lines shaped like the collector's. What is asserted is what would leave
# the host:
#
#   - a short line is shipped untouched;
#   - a 150 KB line is shipped, cut to about 1 KB, ending `..." datname=`;
#   - a cut never lands inside an escape pair (a lone backslash before the closing quote would
#     swallow it and corrupt every field after);
#   - a 150 KB line in a field order the trim does not know is DROPPED, not shipped whole.
#
# Fixtures are generated here, never copied from a host: real query text names real tables.
#
# Usage: scripts/test_log_pipeline.sh [repo-root]     exit 0 passed, 1 otherwise
# Needs docker. Run by deploy-infra.yml next to validate-alloy.sh.
set -euo pipefail
cd "${1:-.}"

STACK=vps/bpvps2/stacks/db-observability
image=$(sed -n 's/^FROM //p' "$STACK/Dockerfile" | tr -d '\r')
[ -n "$image" ] || { echo "no FROM line in $STACK/Dockerfile" >&2; exit 1; }

# Inside the repo, not /tmp: Docker Desktop on a laptop can only mount paths it shares.
work=$(mktemp -d "$PWD/.log-pipeline-test.XXXXXX")
trap 'rm -rf "$work"' EXIT

# The block under test, exactly as deployed, with only its destination swapped for stdout.
awk '/^  loki\.process "trim" \{/ {on = 1} on {print} on && /^  \}$/ {exit}' "$STACK/config.alloy" \
  | sed 's/loki\.relabel\.db\.receiver/loki.echo.out.receiver/' > "$work/trim.alloy"
grep -q 'stage.replace' "$work/trim.alloy" && grep -q 'loki.echo.out.receiver' "$work/trim.alloy" || {
  echo "FAIL: could not cut loki.process \"trim\" out of $STACK/config.alloy -- was it renamed?" >&2
  exit 1
}
cat >> "$work/trim.alloy" <<'EOF'

loki.source.file "fixture" {
  targets       = [{__path__ = "/t/in.log"}]
  forward_to    = [loki.process.trim.receiver]
  tail_from_end = false
}

loki.echo "out" {}
EOF

# ~150 KB of bulk-INSERT text, every value quoted so escape pairs run its whole length. The
# odd-length prefix puts character 1000 on a different half of a pair in `long` and `long2`.
values=$(awk 'BEGIN { for (i = 0; i < 9000; i++) printf "(\\\"v%d\\\"), ", i }')
{
  printf 'level="info" queryid="short" querytext="SELECT $1 FROM \\"t\\" WHERE \\"id\\" = $2" datname="app"\n'
  printf 'level="info" queryid="long" querytext="INSERT INTO \\"t\\" (\\"a\\")\\n VALUES %s($1)" datname="app"\n' "$values"
  printf 'level="info" queryid="long2" querytext="INSERT  INTO \\"t\\" (\\"a\\")\\n VALUES %s($1)" datname="app"\n' "$values"
  printf 'level="info" datname="app" querytext="INSERT INTO \\"t\\" (\\"a\\") VALUES %s($1)" queryid="reordered"\n' "$values"
} > "$work/in.log"

# `timeout` inside the container: Alloy never exits by itself. --log-driver none: the output is
# read from the attached stream, and on a monitored host it must not be shipped to Loki as a
# container log (the audit's own prototype did exactly that).
out=$(docker run --rm --log-driver none -v "$work:/t:ro" --entrypoint timeout "$image" \
        20 /bin/alloy run --storage.path=/tmp/alloy --disable-reporting \
        --server.http.listen-addr=127.0.0.1:12345 /t/trim.alloy 2>&1 || true)
shipped=$(printf '%s\n' "$out" | grep 'component_id=loki.echo.out' || true)

FAILED=0
fail() { FAILED=$((FAILED + 1)); printf 'FAIL: %s\n' "$1" >&2; }
line() { printf '%s\n' "$shipped" | grep -F "queryid=\\\"$1\\\"" || true; }

[ "$(printf '%s\n' "$shipped" | grep -c .)" = 3 ] \
  || fail "expected 3 lines shipped (short, long, long2), got $(printf '%s\n' "$shipped" | grep -c .)"

[ -n "$(line short)" ] || fail "the short line was not shipped"
line short | grep -qF 'WHERE \\\"id\\\" = $2\" datname=' || fail "the short line was changed"

for id in long long2; do
  got=$(line "$id")
  [ -n "$got" ] || { fail "$id: a 150 KB line in the known format was not shipped at all"; continue; }
  # loki.echo re-quotes the entry, doubling every escape: ~1 KB of text prints as ~2 KB.
  [ "${#got}" -lt 4000 ] || fail "$id: shipped ${#got} characters -- the trim did not cut it"
  printf '%s' "$got" | grep -qF '...\" datname=\"app\"' || fail "$id: does not end ...\" datname=\"app\""
  # Cut inside an escape pair: a single backslash left in front of the closing quote, which
  # loki.echo prints as \\ followed by \" -- so three backslashes then a quote after the dots.
  printf '%s' "$got" | grep -qF '\\\\...' && fail "$id: the cut landed inside an escape pair"
done

[ -z "$(line reordered)" ] || fail "the reordered 150 KB line was shipped -- the oversize drop is gone"

if [ "$FAILED" -gt 0 ]; then
  printf '%s\n' "$out" | grep -v 'component_id=loki.echo.out' | tail -20 >&2
  echo "test_log_pipeline: $FAILED check(s) failed" >&2
  exit 1
fi
echo "test_log_pipeline: all checks passed"
