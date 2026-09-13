#!/usr/bin/env bash
# Self-check for vps/bpvps2/stacks/backup/bin/lib.sh -- the pure half of the backup job.
#
# Wired as a CI step alongside vps/shared/test_render_ci.py. Everything that touches
# Docker, Postgres or R2 lives in backup.sh / restore-drill.sh and is proven by running
# them on a host. What is covered here are the decisions that fail SILENTLY when wrong:
#
#   - a targets file that parses to nothing, or to two targets sharing a name, would
#     back up nothing or write one instance into another's snapshot -- so it is refused;
#   - a dump taken as a role subject to Row-Level Security omits every tenant's rows
#     without erroring, so the job must refuse such a role rather than trust it;
#   - a dump below its floor is a failure, not a small success: an empty database must
#     raise the same alarm as a missing backup;
#   - the heartbeat metric must only move for a target that succeeded, and a run that
#     skipped a target must not exit 0;
#   - a restore whose row counts differ from live, or that has nothing to compare, is a
#     failed drill -- an empty comparison is not a smaller pass.
#
# load_targets needs yq (preinstalled on GitHub's ubuntu runners). Without it this test
# FAILS rather than skipping those cases.
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

# ── targets file: what the job backs up is declared, never inferred ─────────────────
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
if ! command -v yq >/dev/null; then
  echo 'FAIL: yq is not installed, so load_targets cannot be tested' >&2
  FAILED=$((FAILED + 1))
fi

cat > "$TMP/good.yml" <<'YML'
targets:
  - name: booking-staging
    kind: postgres
    container: booking-db-staging
    database: yoga-sadhana
    role: postgres
    floor: 280K
  - name: wp-db
    kind: mysql
    container: wp-db
    database: wordpress
    role: root
    floor: 1M
  - name: traefik-certs
    kind: volume
    volume: infra_traefik-letsencrypt
    floor: 1024
skip:
  - volume: booking_prod_pgdata
    reason: fresh instance
YML
ok   'a valid targets file loads'         0 load_targets "$TMP/good.yml"
says 'postgres line carries every field'  'booking-staging|postgres|booking-db-staging|yoga-sadhana|postgres||280K' load_targets "$TMP/good.yml"
says 'volume line carries the volume'     'traefik-certs|volume||||infra_traefik-letsencrypt|1024' load_targets "$TMP/good.yml"
ok   'three targets, three lines'         0 test "$(load_targets "$TMP/good.yml" | wc -l)" -eq 3

printf 'targets: []\n' > "$TMP/empty.yml"
ok   'no targets is refused'              1 load_targets "$TMP/empty.yml"
ok   'a missing file is refused'          1 load_targets "$TMP/nope.yml"
printf 'targets:\n  - {name: a, kind: volume, volume: v, floor: 1}\n  - {name: a, kind: volume, volume: w, floor: 1}\n' > "$TMP/dup.yml"
ok   'duplicate names are refused'        1 load_targets "$TMP/dup.yml"
says 'the duplicate is named'             "'a'" load_targets "$TMP/dup.yml"
printf 'targets:\n  - {name: a, kind: redis, floor: 1}\n' > "$TMP/kind.yml"
ok   'an unknown kind is refused'         1 load_targets "$TMP/kind.yml"
printf 'targets:\n  - {name: a, kind: postgres, container: c, database: d, floor: 1}\n' > "$TMP/role.yml"
ok   'postgres without a role is refused' 1 load_targets "$TMP/role.yml"
printf 'targets:\n  - {name: a, kind: volume, floor: 1}\n' > "$TMP/vol.yml"
ok   'volume without a volume is refused' 1 load_targets "$TMP/vol.yml"
printf 'targets:\n  - {name: a, kind: volume, volume: v}\n' > "$TMP/floor.yml"
ok   'a target without a floor is refused' 1 load_targets "$TMP/floor.yml"
printf 'targets:\n  - {name: "a b", kind: volume, volume: v, floor: 1}\n' > "$TMP/name.yml"
ok   'a name that is not a safe tag is refused' 1 load_targets "$TMP/name.yml"

says 'target names in declared order'     'booking-staging wp-db traefik-certs' target_names "$(load_targets "$TMP/good.yml")"
says 'one target line by name'            'wp-db|mysql|wp-db|wordpress|root||1M' target_line "$(load_targets "$TMP/good.yml")" wp-db
ok   'an unknown name has no line'        1 target_line "$(load_targets "$TMP/good.yml")" ghost

# ── floor size: an empty database is a failure, not a small backup ───────────────────
says 'plain bytes'                        '1024' parse_size 1024
says 'K is KiB'                           '286720' parse_size 280K
says 'M is MiB'                           '1048576' parse_size 1M
says 'G is GiB'                           '1073741824' parse_size 1G
ok   'a blank floor is refused'           1 parse_size ''
ok   'garbage is refused'                 1 parse_size 12Q
ok   'zero is refused -- it guards nothing' 1 parse_size 0
ok   'at the floor passes'                0 check_floor db 286720 280K
ok   'above the floor passes'             0 check_floor db 327605 280K
ok   'below the floor fails'              1 check_floor db 1203 280K
says 'the failure names the target and both sizes' 'db: 1203 bytes is below its floor of 280K' check_floor db 1203 280K
ok   'an unmeasured size fails'           1 check_floor db '' 280K

# ── selection: a partial run is allowed, an unknown target is not ─────────────────────
ALL='booking-staging wp-db traefik-certs'
says 'no arguments selects everything'    'booking-staging wp-db traefik-certs' select_targets "$ALL"
says 'a subset keeps declared order'      'booking-staging traefik-certs' select_targets "$ALL" traefik-certs booking-staging
ok   'an unknown target is refused'       1 select_targets "$ALL" booking-prod
says 'the unknown target is named'        'booking-prod' select_targets "$ALL" booking-prod

# ── exit status: green but skipped is not a clean pass (same as verify-mail.sh) ──────
says 'all green is 0'                     '0' run_exit 0 0
says 'any failure is 1'                   '1' run_exit 1 0
says 'failure beats skip'                 '1' run_exit 1 2
says 'green but skipped is 3'             '3' run_exit 0 1

# ── heartbeat metric: moves only for a target that succeeded ─────────────────────────
M1=$(metrics_update '' 'booking-staging wp-db' booking-staging 1789300000 327605)
says 'first success writes the timestamp' 'backup_last_success_timestamp_seconds{target="booking-staging"} 1789300000' printf '%s' "$M1"
says 'and the size'                       'backup_last_size_bytes{target="booking-staging"} 327605' printf '%s' "$M1"
says 'with a TYPE line'                   '# TYPE backup_last_success_timestamp_seconds gauge' printf '%s' "$M1"
M2=$(metrics_update "$M1" 'booking-staging wp-db' wp-db 1789300100 2048)
says 'another target keeps the first'     'backup_last_success_timestamp_seconds{target="booking-staging"} 1789300000' printf '%s' "$M2"
says 'and adds its own'                   'backup_last_success_timestamp_seconds{target="wp-db"} 1789300100' printf '%s' "$M2"
M3=$(metrics_update "$M2" 'booking-staging wp-db' booking-staging 1789386400 330000)
says 'a later success replaces'           'backup_last_success_timestamp_seconds{target="booking-staging"} 1789386400' printf '%s' "$M3"
ok   'and leaves no old value behind'     1 grep -q 1789300000 <<<"$M3"
ok   'one TYPE line per metric'           0 test "$(grep -c '^# TYPE backup_last_success' <<<"$M3")" -eq 1
M4=$(metrics_update "$M3" 'booking-staging' booking-staging 1789386500 330000)
ok   'an undeclared target is dropped, or it would alert forever' 1 grep -q 'wp-db' <<<"$M4"
says 'last_success reads it back'         '1789386400' last_success "$M3" booking-staging
ok   'a target never backed up has no last success' 0 test -z "$(last_success "$M3" ghost)"

# ── healthcheck: unhealthy once any target's last success is older than the limit ────
ok   'fresh everywhere is healthy'        0 check_health 1789386500 90000 "$M3" 'booking-staging wp-db'
ok   'one stale target is unhealthy'      1 check_health $((1789300100 + 90001)) 90000 "$M3" 'booking-staging wp-db'
says 'the stale target is named'          'wp-db' check_health $((1789300100 + 90001)) 90000 "$M3" 'booking-staging wp-db'
ok   'a target never backed up is unhealthy' 1 check_health 1789400000 90000 "$M3" 'booking-staging ghost'
ok   'no metrics at all is unhealthy'     1 check_health 1789400000 90000 '' 'booking-staging'

# ── scratch paths ───────────────────────────────────────────────────────────────────
says 'scratch path keyed on target'       '/scratch/booking-staging' scratch_path booking-staging
ok   'scratch path needs a target'        1 scratch_path ''

# ── dump role: RLS silently drops every tenant's rows for a non-owning role ─────────
ok   'superuser accepted'                 0 check_dump_role postgres t
ok   'RLS-bound role refused'             1 check_dump_role booking_app f
says 'refusal names the role'             'booking_app' check_dump_role booking_app f
ok   'unknown role refused'               1 check_dump_role ghost ''

# ── row-count comparison: the restore drill's pass criterion ────────────────────────
LIVE=$'tenants 3\nclients 120\nbookings 900'
ok   'identical counts pass'              0 compare_counts "$LIVE" "$LIVE"
ok   'order does not matter'              0 compare_counts "$LIVE" $'bookings 900\ntenants 3\nclients 120'
ok   'a differing count fails'            1 compare_counts "$LIVE" $'tenants 3\nclients 119\nbookings 900'
says 'mismatch names the table'           'clients' compare_counts "$LIVE" $'tenants 3\nclients 119\nbookings 900'
ok   'a table missing from restore fails' 1 compare_counts "$LIVE" $'tenants 3\nclients 120'
ok   'nothing to compare fails'           1 compare_counts '' ''
ok   'zero rows everywhere still passes'  0 compare_counts $'tenants 0' $'tenants 0'

printf '%d passed, %d failed\n' "$PASSED" "$FAILED"
[[ "$FAILED" == 0 ]]
