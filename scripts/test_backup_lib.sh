#!/usr/bin/env bash
# Self-check for vps/bpvps2/stacks/backup/bin/lib.sh -- the pure half of the backup job.
#
# Wired as a CI step alongside vps/shared/test_render_ci.py. Everything that touches
# Docker, Postgres or R2 lives in backup.sh / restore-drill.sh and is proven by running
# the restore drill on the host. What is covered here are the three decisions that fail
# SILENTLY when wrong:
#
#   - staging and prod must get different snapshot tags and scratch paths, or
#     booking-staging writes into booking-prod's snapshot -- on the instance that holds
#     the real data;
#   - a dump taken as a role subject to Row-Level Security omits every tenant's rows
#     without erroring, so the job must refuse such a role rather than trust it;
#   - a restore whose row counts differ from live, or that has nothing to compare, is a
#     failed drill -- an empty comparison is not a smaller pass.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../vps/bpvps2/stacks/backup/bin/lib.sh
source "$HERE/../vps/bpvps2/stacks/backup/bin/lib.sh"

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
    printf 'FAIL: %s\n      expected rc=%s, got rc=%s\n      output: %s\n' \
      "$name" "$want" "$rc" "$out" >&2
  fi
}

# says <name> <substring> <function> [args...] -- rc is ignored; the message is the subject.
says() {
  local name="$1" want="$2"; shift 2
  local out
  out="$("$@" 2>&1)"
  if [[ "$out" == *"$want"* ]]; then
    PASSED=$((PASSED + 1))
  else
    FAILED=$((FAILED + 1))
    printf 'FAIL: %s\n      expected output containing: %s\n      got: %s\n' \
      "$name" "$want" "$out" >&2
  fi
}

# ── instance naming: the collision the booking fanout exists to prevent ─────────────
ok   'instance name'                  0 instance_name staging
says 'instance name is booking-env'   'booking-staging' instance_name staging
ok   'empty env refused'              1 instance_name ''
ok   'staging and prod differ'        0 test "$(instance_name staging)" != "$(instance_name prod)"
says 'db container matches the booking compose' 'booking-db-staging' db_container staging
says 'scratch path keyed on instance' '/scratch/booking-staging' scratch_path booking-staging
ok   'scratch path needs an instance' 1 scratch_path ''
ok   'staging and prod scratch differ' 0 test "$(scratch_path booking-staging)" != "$(scratch_path booking-prod)"

# ── dump role: RLS silently drops every tenant's rows for a non-owning role ─────────
ok   'superuser accepted'             0 check_dump_role postgres t
ok   'RLS-bound role refused'         1 check_dump_role booking_app f
says 'refusal names the role'         'booking_app' check_dump_role booking_app f
ok   'unknown role refused'           1 check_dump_role ghost ''

# ── row-count comparison: the restore drill's pass criterion ────────────────────────
LIVE=$'tenants 3\nclients 120\nbookings 900'
ok   'identical counts pass'          0 compare_counts "$LIVE" "$LIVE"
ok   'order does not matter'          0 compare_counts "$LIVE" $'bookings 900\ntenants 3\nclients 120'
ok   'a differing count fails'        1 compare_counts "$LIVE" $'tenants 3\nclients 119\nbookings 900'
says 'mismatch names the table'       'clients' compare_counts "$LIVE" $'tenants 3\nclients 119\nbookings 900'
ok   'a table missing from restore fails' 1 compare_counts "$LIVE" $'tenants 3\nclients 120'
ok   'nothing to compare fails'       1 compare_counts '' ''
ok   'zero rows everywhere still passes' 0 compare_counts $'tenants 0' $'tenants 0'

printf '%d passed, %d failed\n' "$PASSED" "$FAILED"
[[ "$FAILED" == 0 ]]
