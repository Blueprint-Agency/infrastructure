#!/usr/bin/env bash
# Self-check for vps/bpvps2/stacks/monitoring/probes/bin/lib.sh -- the pure half of the textfile
# probes (#25). bpvps1 carries an identical copy; check-monitoring.py fails CI if the two differ.#
# Everything that touches Docker, Postgres, Tailscale or the network lives in probe.sh and is
# proven by running it on a host. What is covered here are the decisions that fail SILENTLY:
#
#   - output the agent cannot parse is skipped whole, so a probe's metrics would just stop;
#   - a probe that could not read its source must write NOTHING, so its heartbeat goes stale
#     instead of reporting a confident zero (no connections, no restarts, no key expiry);
#   - a mail prober that is itself the mail host only ever talks to itself -- decided by
#     comparing addresses, never names;
#   - "two consecutive failures" is counted by the prober, so scrape timing cannot halve it.
#
# Needs jq (preinstalled on GitHub's ubuntu runners). Without it this test FAILS.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../vps/bpvps2/stacks/monitoring/probes/bin/lib.sh
source "$HERE/../vps/bpvps2/stacks/monitoring/probes/bin/lib.sh"

PASSED=0
FAILED=0

# ok <name> <expected-rc> <function> [args...]
ok() {
  local name="$1" want="$2"; shift 2
  local out rc
  out="$("$@" 2>&1)"; rc=$?
  if [[ "$rc" == "$want" ]]; then
    PASSED=$((PASSED + 1))
  else
    FAILED=$((FAILED + 1))
    printf 'FAIL: %s\n      expected rc=%s, got rc=%s\n      output: %s\n' "$name" "$want" "$rc" "$out" >&2
  fi
}

# is <name> <expected-output> <function> [args...] -- exact stdout, the metric text itself.
is() {
  local name="$1" want="$2"; shift 2
  local out
  out="$("$@" 2>/dev/null)"
  if [[ "$out" == "$want" ]]; then
    PASSED=$((PASSED + 1))
  else
    FAILED=$((FAILED + 1))
    printf 'FAIL: %s\n      expected:\n%s\n      got:\n%s\n' "$name" "$want" "$out" >&2
  fi
}

# ── heartbeat: every job reports when it last completed, and how old is too old ──────────
# The label is `probe`, never `job`: the agent's scrape owns `job`, renames a file's own to
# exported_job, and the staleness rule's on (host, probe) join would then fail (seen 2026-09-14).
is "heartbeat" '# HELP probes_last_success_timestamp_seconds Unix time this probe job last completed.
# TYPE probes_last_success_timestamp_seconds gauge
probes_last_success_timestamp_seconds{probe="postgres"} 1789300000
# HELP probes_max_age_seconds How old the heartbeat may get before the job counts as stopped.
# TYPE probes_max_age_seconds gauge
probes_max_age_seconds{probe="postgres"} 300' \
  prom_heartbeat postgres 1789300000 300

# ── restarts: docker inspect's RestartCount, per container ───────────────────────────────
is "restart counts" '# HELP docker_container_restarts_total Restarts by the restart policy since the container was created.
# TYPE docker_container_restarts_total counter
docker_container_restarts_total{container="traefik"} 0
docker_container_restarts_total{container="booking-be-prod"} 7' \
  prom_restarts $'/traefik 0\n/booking-be-prod 7'
ok "no containers listed is unreadable, not zero" 1 prom_restarts ""
ok "a garbled inspect line is unreadable" 1 prom_restarts $'/traefik 0\n/booking-be-prod <no value>'
is "a container named like the error marker is still a container" \
  "$(printf '%s\n' '# HELP docker_container_restarts_total Restarts by the restart policy since the container was created.' \
     '# TYPE docker_container_restarts_total counter' 'docker_container_restarts_total{container="BAD-actor"} 1')" \
  prom_restarts "/BAD-actor 1"

# ── postgres: connections against max_connections ────────────────────────────────────────
# One line per database, "container connections max_connections". One HELP/TYPE per family
# however many databases: the agent rejects a file that repeats one.
is "postgres connections" '# HELP postgres_connections Client backends connected, from pg_stat_activity.
# TYPE postgres_connections gauge
postgres_connections{container="booking-db-staging"} 5
postgres_connections{container="booking-db-prod"} 2
# HELP postgres_max_connections The server'"'"'s max_connections setting.
# TYPE postgres_max_connections gauge
postgres_max_connections{container="booking-db-staging"} 100
postgres_max_connections{container="booking-db-prod"} 100' \
  prom_postgres $'booking-db-staging 5 100\nbooking-db-prod 2 100'
# bpvps1 runs no Postgres. That is an answer, not a failure: nothing to report, heartbeat still moves.
ok "no Postgres on the host" 0 prom_postgres ""
is "no Postgres writes no samples" "" prom_postgres ""
ok "psql printed nothing" 1 prom_postgres "booking-db-staging  100"
ok "psql printed an error" 1 prom_postgres "booking-db-staging psql: error: connection refused"
ok "max_connections of zero cannot be a ratio" 1 prom_postgres "booking-db-staging 5 0"

# ── tailscale: Self.KeyExpiry is ABSENT when expiry is disabled ──────────────────────────
is "key expiry disabled" '# HELP tailscale_key_expiry_timestamp_seconds When the key expires (Self.KeyExpiry); 0 when it cannot.
# TYPE tailscale_key_expiry_timestamp_seconds gauge
tailscale_key_expiry_timestamp_seconds 0' \
  prom_tailscale '{"Version":"1.102.2","Self":{"HostName":"bpvps2","Online":true}}'
is "key expiry null reads as disabled" "$(prom_tailscale '{"Self":{"HostName":"x"}}')" \
  prom_tailscale '{"Self":{"HostName":"x","KeyExpiry":null}}'
# 2026-12-14T08:00:00Z, the day vps1/2/3 were set to expire -- fractional seconds as tailscaled writes them.
is "key expiry present" '# HELP tailscale_key_expiry_timestamp_seconds When the key expires (Self.KeyExpiry); 0 when it cannot.
# TYPE tailscale_key_expiry_timestamp_seconds gauge
tailscale_key_expiry_timestamp_seconds 1797235200' \
  prom_tailscale '{"Self":{"HostName":"bpvps2","KeyExpiry":"2026-12-14T08:00:00.123456789Z"}}'
ok "no Self in the status is unreadable" 1 prom_tailscale '{"BackendState":"NoState"}'
ok "not JSON is unreadable" 1 prom_tailscale 'curl: (7) Failed to connect'

# ── mail: is the prober the mail host? Addresses, never names ────────────────────────────
ok "prober shares an address with the target" 0 shares_address \
  $'127.0.0.1\n187.127.122.41\n100.94.77.65' "187.127.122.41"
ok "prober is another machine" 1 shares_address \
  $'127.0.0.1\n187.127.207.82\n100.78.5.2' "187.127.122.41"
ok "a partial match is not a match" 1 shares_address "87.127.122.4" "187.127.122.41"
ok "an unresolved target is not the prober" 1 shares_address "187.127.207.82" ""

# ── mail: consecutive failures, counted by the prober ────────────────────────────────────
is "first failure" 1 failures_after 0 down
is "second failure" 2 failures_after 1 down
is "a success resets" 0 failures_after 5 up
is "no previous count" 1 failures_after "" down

is "mail ports" '# HELP mail_port_consecutive_failures Consecutive failed probes of this mail port, from another host.
# TYPE mail_port_consecutive_failures gauge
mail_port_consecutive_failures{target="mail.blueprintdigital.my",port="25"} 0
mail_port_consecutive_failures{target="mail.blueprintdigital.my",port="993"} 2' \
  prom_mail mail.blueprintdigital.my $'25 0\n993 2'

printf 'probes lib: %d passed, %d failed\n' "$PASSED" "$FAILED"
[[ "$FAILED" -eq 0 ]]
