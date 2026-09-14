# Pure helpers for probe.sh: turn what a probe read into Prometheus text for the textfile seam
# (docs/textfile-metrics.md). No Docker, network or clock in here -- tested by
# scripts/test_probes_lib.sh. Every monitored host carries an identical copy; CI fails if they drift.
#
# Every prom_* function returns 1 and prints nothing useful when its input is not what a
# healthy source prints. The caller then writes nothing, the job's heartbeat ages, and
# probes-stale-<host> fires. A probe that cannot read must never report a confident zero.

is_uint() {
  case "$1" in
    '' | *[!0-9]*) return 1 ;;
  esac
}

# prom_heartbeat <job> <epoch> <max-age-seconds>
#
# Labelled `probe`, not `job`: the agent's scrape owns `job` and would rename this one to
# exported_job, breaking the on (host, probe) join in probes-stale-<host>.
prom_heartbeat() {
  printf '# HELP probes_last_success_timestamp_seconds Unix time this probe job last completed.\n'
  printf '# TYPE probes_last_success_timestamp_seconds gauge\n'
  printf 'probes_last_success_timestamp_seconds{probe="%s"} %s\n' "$1" "$2"
  printf '# HELP probes_max_age_seconds How old the heartbeat may get before the job counts as stopped.\n'
  printf '# TYPE probes_max_age_seconds gauge\n'
  printf 'probes_max_age_seconds{probe="%s"} %s\n' "$1" "$3"
}

# prom_restarts <lines of "/name count">, as `docker inspect --format '{{.Name}} {{.RestartCount}}'`
#
# RestartCount counts restarts by the restart policy -- a crash loop -- and resets when the
# container is recreated. The rule takes increase() over it, which survives that reset.
prom_restarts() {
  [ -n "$1" ] || return 1
  _bad=$(printf '%s\n' "$1" | while read -r _name _count _rest; do
    { is_uint "$_count" && [ -z "$_rest" ]; } || echo BAD
  done)
  [ -z "$_bad" ] || return 1
  printf '# HELP docker_container_restarts_total Restarts by the restart policy since the container was created.\n'
  printf '# TYPE docker_container_restarts_total counter\n'
  printf '%s\n' "$1" | while read -r _name _count; do
    printf 'docker_container_restarts_total{container="%s"} %s\n' "${_name#/}" "$_count"
  done
}

# prom_postgres <lines of "container client-connections max_connections">
#
# Empty input is a host with no Postgres: valid, prints nothing. Any malformed line fails the
# whole job -- one database's metrics silently missing is the failure this must not hide.
prom_postgres() {
  [ -n "$1" ] || return 0
  _bad=$(printf '%s\n' "$1" | while read -r _c _n _max _rest; do
    { is_uint "$_n" && is_uint "$_max" && [ "$_max" -gt 0 ] && [ -z "$_rest" ]; } || echo BAD
  done)
  [ -z "$_bad" ] || return 1
  printf '# HELP postgres_connections Client backends connected, from pg_stat_activity.\n'
  printf '# TYPE postgres_connections gauge\n'
  printf '%s\n' "$1" | while read -r _c _n _max; do
    printf 'postgres_connections{container="%s"} %s\n' "$_c" "$_n"
  done
  printf "# HELP postgres_max_connections The server's max_connections setting.\n"
  printf '# TYPE postgres_max_connections gauge\n'
  printf '%s\n' "$1" | while read -r _c _n _max; do
    printf 'postgres_max_connections{container="%s"} %s\n' "$_c" "$_max"
  done
}

# prom_tailscale <tailscaled LocalAPI /localapi/v0/status JSON>
#
# Self.KeyExpiry is ABSENT (or null) when key expiry is disabled -- the state all five nodes
# were put in on 2026-08-09. Present means the node will drop off the tailnet on that date, and
# with port 22 closed to the internet that is console-only recovery.
prom_tailscale() {
  _exp=$(printf '%s' "$1" | jq -er '
    if (.Self | type) != "object" then error("no Self")
    elif .Self.KeyExpiry == null then 0
    else .Self.KeyExpiry | sub("\\.[0-9]+"; "") | fromdateiso8601
    end' 2>/dev/null) || return 1
  is_uint "$_exp" || return 1
  printf '# HELP tailscale_key_expiry_timestamp_seconds When the key expires (Self.KeyExpiry); 0 when it cannot.\n'
  printf '# TYPE tailscale_key_expiry_timestamp_seconds gauge\n'
  printf 'tailscale_key_expiry_timestamp_seconds %s\n' "$_exp"
}

# shares_address <prober addresses> <target addresses>  ->  rc 0 if any address is in both
#
# A mail port probed from the mail host itself never leaves the box, so it proves nothing. The
# NAMES never match (bp-bpvps1 vs mail.blueprintdigital.my); the addresses do. Whitespace- or
# newline-separated lists; whole addresses only.
shares_address() {
  for _a in $1; do
    for _b in $2; do
      [ "$_a" = "$_b" ] && return 0
    done
  done
  return 1
}

# failures_after <previous count> <up|down>  ->  the new consecutive-failure count
failures_after() {
  if [ "$2" = up ]; then echo 0; else echo $(( ${1:-0} + 1 )); fi
}

# prom_mail <target> <lines of "port failures">
prom_mail() {
  printf '# HELP mail_port_consecutive_failures Consecutive failed probes of this mail port, from another host.\n'
  printf '# TYPE mail_port_consecutive_failures gauge\n'
  printf '%s\n' "$2" | while read -r _port _n; do
    printf 'mail_port_consecutive_failures{target="%s",port="%s"} %s\n' "$1" "$_port" "$_n"
  done
}
