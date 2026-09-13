# The Docker half of the `stalwart` kind, sourced by backup.sh, restore-drill.sh and
# entrypoint.sh. The pure half -- reading a JMAP response -- is in lib.sh, and is tested.
#
# Why this kind exists, what it costs and how it fails: docs/backup-restore.md, "The mail
# store". In one line: Stalwart keeps mail in RocksDB, v0.16.21 has no online export, so
# the job stops the server, snapshots the volume, and starts it again.

# Where the job records a container it has stopped, one empty file per container, removed
# once that container is running again. /cache is a volume, so the record outlives this
# container: if the job dies mid-pause -- killed, OOM, a host reboot -- the next start of
# the container brings the mail server back (entrypoint.sh), and healthcheck.sh reports a
# record that has sat there too long.
STOPPED_ROOT=/cache/stopped-by-backup

# stderr, so a caller capturing an inventory on stdout never captures a log line with it.
stalwart_log() { printf '%s [stalwart] %s\n' "$(date '+%F %T %Z')" "$*" >&2; }

# stop_for_backup <container>: record first, then stop -- so no stopped container is ever
# unrecorded. 120 s lets Stalwart flush RocksDB and close cleanly rather than be SIGKILLed.
stop_for_backup() {
  mkdir -p "$STOPPED_ROOT" && : > "$STOPPED_ROOT/$1" || return 1
  docker stop -t 120 "$1" >/dev/null
}

# restart_stopped: start every container this job recorded as stopped, and forget each one
# that starts. Safe to call at any time and more than once.
restart_stopped() {
  _rc=0
  for _f in "$STOPPED_ROOT"/*; do
    [ -f "$_f" ] || continue
    _c=${_f##*/}
    if docker start "$_c" >/dev/null; then
      rm -f "$_f"
      stalwart_log "started $_c (stopped by the backup job)"
    else
      stalwart_log "COULD NOT START $_c -- it was stopped by the backup job; start it by hand: docker start $_c"
      _rc=1
    fi
  done
  return "$_rc"
}

# stalwart_ready <container> [seconds]: wait until the server answers on its own loopback.
# The same URL the image's healthcheck falls back to, so "ready" here and "healthy" in
# `docker ps` mean the same thing -- without waiting out a 30 s healthcheck interval.
stalwart_ready() {
  _i=0
  until docker exec "$1" curl -fsS -o /dev/null -H 'X-Forwarded-For: 127.0.0.1' \
    http://127.0.0.1:8080/healthz/live 2>/dev/null; do
    _i=$((_i + 1))
    [ "$_i" -lt "${2:-180}" ] || { stalwart_log "$1 did not answer on :8080 within ${2:-180}s"; return 1; }
    sleep 1
  done
}

# stalwart_jmap <container> <request json>  ->  the response
#
# As the recovery admin from that container's OWN environment (STALWART_RECOVERY_ADMIN),
# over its own loopback: the password is never in an argv, never leaves the container, and
# this job holds no mail credential at all. The Authorization header goes in on stdin.
stalwart_jmap() {
  # shellcheck disable=SC2016
  docker exec "$1" sh -c '
    printf "Authorization: Basic %s\n" "$(printf %s "$STALWART_RECOVERY_ADMIN" | base64 -w0)" |
      exec curl -sS --max-time 240 -H @- -H "Content-Type: application/json" \
        --data-binary "$1" http://127.0.0.1:8080/jmap
  ' sh "$2"
}

# mail_inventory <container>  ->  "<account> <messages> <bytes>" per account, sorted
#
# The numbers scripts/mail-inventory.py records -- every principal, its Email/query total,
# and the summed size of its messages -- read over JMAP from inside the container, 500 at a
# time (maxObjectsInGet). ~2 min on bpvps1, most of it admin@kaiteki.my's 145k messages.
mail_inventory() {
  _resp=$(stalwart_jmap "$1" '{"using":["urn:ietf:params:jmap:core","urn:ietf:params:jmap:principals"],"methodCalls":[["Principal/get",{"ids":null,"properties":["id","name","email"]},"0"]]}') || return 1
  _principals=$(jmap_principals "$_resp") || return 1
  _out=$(printf '%s\n' "$_principals" | while read -r _id _name; do
    _pos=0 _bytes=0 _total=0
    while :; do
      _resp=$(stalwart_jmap "$1" "{\"using\":[\"urn:ietf:params:jmap:core\",\"urn:ietf:params:jmap:mail\"],\"methodCalls\":[[\"Email/query\",{\"accountId\":\"$_id\",\"calculateTotal\":true,\"position\":$_pos,\"limit\":500},\"0\"],[\"Email/get\",{\"accountId\":\"$_id\",\"#ids\":{\"resultOf\":\"0\",\"name\":\"Email/query\",\"path\":\"/ids\"},\"properties\":[\"size\"]},\"1\"]]}") || exit 1
      _page=$(jmap_page "$_resp") || { stalwart_log "$1: $_name: bad page at position $_pos"; exit 1; }
      # shellcheck disable=SC2086 # "<total> <messages> <bytes>" -> $2 $3 $4
      set -- "$1" $_page
      [ "$_pos" -eq 0 ] && _total=$2
      _bytes=$((_bytes + $4))
      _pos=$((_pos + $3))
      [ "$3" -gt 0 ] && [ "$_pos" -lt "$_total" ] || break
    done
    echo "$_name $_total $_bytes"
  done) || return 1
  printf '%s\n' "$_out" | sort
}
