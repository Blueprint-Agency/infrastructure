#!/usr/bin/env bash
# probe.sh <job> -- run one textfile probe and write /textfile/<job>.prom (#25).
#
#   docker     restart count of every container                       every minute
#   postgres   client connections vs max_connections, per Postgres    every minute
#   mail       mail ports on ANOTHER host (MAIL_PROBE_TARGET)          every minute, if set
#   tailscale  Self.KeyExpiry from tailscaled's LocalAPI               weekly, and at start
#
# Contract: docs/textfile-metrics.md. Written atomically (tmp + mv). Each file carries its job's
# heartbeat, probes_last_success_timestamp_seconds{probe}, and how old that may get. A job that
# cannot read its source writes NOTHING and exits 1: the heartbeat ages and probes-stale-<host>
# fires, naming the probe. The formatting half is bin/lib.sh, tested by scripts/test_probes_lib.sh.
#
# Every monitored host carries an identical copy of this directory; CI fails if they drift.
# What differs per host is the environment in its docker-compose.yml.
set -euo pipefail
. /app/bin/lib.sh

TEXTFILE_DIR=${TEXTFILE_DIR:-/textfile}
STATE_DIR=${STATE_DIR:-/tmp/probes}
job=${1:?usage: probe.sh docker|postgres|mail|tailscale}
now=$(date +%s)

fail() {
  echo "probe $job: $*" >&2
  exit 1
}

# write <body> <max-age-seconds>
write() {
  { [ -z "$1" ] || printf '%s\n' "$1"; prom_heartbeat "$job" "$now" "$2"; } > "$TEXTFILE_DIR/$job.prom.tmp"
  # The entrypoint's umask is 077; the agent must be able to read this even if it stops being root.
  chmod 644 "$TEXTFILE_DIR/$job.prom.tmp"
  mv "$TEXTFILE_DIR/$job.prom.tmp" "$TEXTFILE_DIR/$job.prom"
}

# dialog <plain|tls> <host> <port> <expected-greeting-prefix> <goodbye>
#
# Waits for the server's greeting, THEN says goodbye. Never talk first: an SMTP client that
# sends before the 220 is an "early talker", a spam signal, and a mail server may ban the
# address -- which would be bpvps2's own address. Never just hang up either: an idle connection
# that never issues a command reads as loitering. Greeting, one clean QUIT/LOGOUT, done.
#
# Both modes run under `timeout 20`: a firewall that silently drops packets must cost one failed
# probe, not a two-minute kernel connect timeout that overlaps the next minute's run.
dialog() {
  local mode=$1 host=$2 port=$3 want=$4 bye=$5 line=''
  # 9>&-: the child must not inherit the job lock, or a killed run's orphan keeps holding it.
  if [ "$mode" = plain ]; then
    coproc CONN { timeout 20 nc -w 10 "$host" "$port" 2>/dev/null 9>&-; }
  else
    coproc CONN { timeout 20 openssl s_client -quiet -verify_quiet -connect "$host:$port" -servername "$host" 2>/dev/null 9>&-; }
  fi
  local out=${CONN[1]} in=${CONN[0]}
  IFS= read -r -t 15 line <&"$in" || true
  [ "${line#"$want"}" != "$line" ] && printf '%s\r\n' "$bye" >&"$out"
  # Close our end so the client sees EOF and exits once the server says goodbye -- otherwise
  # it sits until `timeout`, and three ports take a minute.
  exec {out}>&-
  wait "$CONN_PID" 2>/dev/null || true
  [ "${line#"$want"}" != "$line" ]
}

# One run per job at a time. A run still going when cron starts the next would race on the
# failure counters; the late one gives up instead, and the heartbeat says so if it keeps happening.
mkdir -p "$STATE_DIR"
exec 9>"$STATE_DIR/$job.lock"
flock -n 9 || fail "previous run still in progress"

case "$job" in
  docker)
    ids=$(docker ps -aq) || fail "docker ps failed"
    # shellcheck disable=SC2086 # one argument per container id
    inspected=$(docker inspect --format '{{.Name}} {{.RestartCount}}' $ids) || fail "docker inspect failed"
    body=$(prom_restarts "$inspected") || fail "unexpected docker inspect output: $inspected"
    write "$body" 300
    ;;

  postgres)
    # Discovered, not declared: every RUNNING container whose image is a Postgres. None on this
    # host is a valid answer (a MariaDB is not a Postgres). Queried inside the container over the
    # local socket, where the official image trusts the local user -- no password in this stack.
    running=$(docker ps --format '{{.Names}} {{.Image}}') || fail "docker ps failed"
    lines=''
    while read -r name image; do
      case "$image" in
        postgres:* | */postgres:* | pgvector/* | postgis/* | timescale/*) ;;
        *) continue ;;
      esac
      out=$(docker exec "$name" sh -c 'psql -X -U "${POSTGRES_USER:-postgres}" -d postgres -tA \
        -c "select count(*) from pg_stat_activity where backend_type = '\''client backend'\''" \
        -c "show max_connections"' 2>&1) || fail "psql in $name failed: $out"
      lines+="$name $(printf '%s' "$out" | tr '\n' ' ')"$'\n'
    done <<< "$running"
    body=$(prom_postgres "${lines%$'\n'}") || fail "unexpected psql output: $lines"
    write "$body" 300
    ;;

  mail)
    target=${MAIL_PROBE_TARGET:-}
    if [ -z "$target" ]; then
      # Not the prober on this host. Remove a leftover so it cannot go stale and alert.
      rm -f "$TEXTFILE_DIR/mail.prom"
      exit 0
    fi
    target_addrs=$(dig +short A "$target" | grep -E '^[0-9.]+$' || true)
    [ -n "$target_addrs" ] || fail "$target resolves to no A record"
    own_addrs=$(ip -4 -o addr show | awk '{print $4}' | cut -d/ -f1)
    [ -n "$own_addrs" ] || fail "cannot list this host's addresses"
    if shares_address "$own_addrs" "$target_addrs"; then
      fail "this host IS $target ($target_addrs) -- a probe from here never leaves the box. Probe from another host."
    fi
    # Counters live in the container's /tmp: a restart resets them to 0, which can delay an
    # alert by at most two probes -- never raise a false one.
    counts=''
    for port in ${MAIL_PROBE_PORTS:-25 465 993}; do
      case "$port" in
        25) dialog plain "$target" 25 "220" "QUIT" && r=up || r=down ;;
        465) dialog tls "$target" 465 "220" "QUIT" && r=up || r=down ;;
        993) dialog tls "$target" 993 "* OK" "a LOGOUT" && r=up || r=down ;;
        *) fail "no dialog for port $port" ;;
      esac
      n=$(failures_after "$(cat "$STATE_DIR/mail-$port" 2>/dev/null || true)" "$r")
      echo "$n" > "$STATE_DIR/mail-$port"
      [ "$r" = down ] && echo "probe mail: $target:$port failed ($n in a row)" >&2
      counts+="$port $n"$'\n'
    done
    write "$(prom_mail "$target" "${counts%$'\n'}")" 300
    ;;

  tailscale)
    status=$(curl -sf --max-time 10 --unix-socket /var/run/tailscale/tailscaled.sock \
      http://local-tailscaled.sock/localapi/v0/status) || fail "tailscaled LocalAPI did not answer"
    body=$(prom_tailscale "$status") || fail "LocalAPI status has no Self"
    # Weekly, so a week and a day: one missed run is not yet an alert, two are.
    write "$body" $((8 * 86400))
    ;;

  *) fail "unknown job" ;;
esac
