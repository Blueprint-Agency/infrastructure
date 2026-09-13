# Pure helpers for backup.sh, restore-drill.sh and healthcheck.sh. POSIX sh: the job runs
# on the restic image's busybox ash, and scripts/test_backup_lib.sh sources this from bash.
# Nothing in here touches Docker, Postgres or R2 -- that is what keeps it testable. The one
# outside tool is yq, which reads the targets file.

SCRATCH_ROOT=/scratch

# MYSQL_LOGIN: shell text run INSIDE a MySQL/MariaDB container, `sh -c "$MYSQL_LOGIN ..." sh
# <role>`. It exports MYSQL_PWD for <role> from that container's OWN environment -- so the
# password never appears in an argv on this side -- and sets $client and $dump to the
# binaries the image has (MariaDB 11 dropped the mysql / mysqldump names). backup.sh dumps
# through it and restore-drill.sh counts live rows through it: one login, two callers.
# shellcheck disable=SC2016
MYSQL_LOGIN='
  if [ "$1" = root ]; then
    MYSQL_PWD=${MARIADB_ROOT_PASSWORD:-${MYSQL_ROOT_PASSWORD:-}}
  else
    MYSQL_PWD=${MARIADB_PASSWORD:-${MYSQL_PASSWORD:-}}
  fi
  export MYSQL_PWD
  client=mysql; command -v mariadb >/dev/null && client=mariadb
  dump=mysqldump; command -v mariadb-dump >/dev/null && dump=mariadb-dump
'

# load_targets <targets.yml>  ->  one line per target, in declared order:
#
#   name|kind|container|database|role|volume|floor
#
# Fields a kind does not use are empty. Refuses, naming the problem, a file that declares
# no targets (a job that backs up nothing must not look like a job that succeeded), a
# duplicate name (two targets would share one snapshot tag and one retention group), an
# unknown kind, a missing field, and a name that is not a safe restic tag.
load_targets() {
  if [ ! -r "$1" ]; then
    echo "load_targets: cannot read $1" >&2
    return 1
  fi
  _lines=$(yq -r '(.targets // [])[] | [.name, .kind, .container, .database, .role, .volume, .floor] | map(. // "" | tostring) | join("|")' "$1") || {
    echo "load_targets: yq could not read $1 (invalid YAML, or yq missing)" >&2
    return 1
  }
  printf '%s\n' "$_lines" | awk -F'|' -v file="$1" '
    function bad(msg) { printf "load_targets: %s: %s\n", file, msg > "/dev/stderr"; errors++ }
    $0 == "" { next }
    {
      n++
      if (NF != 7) { bad("a field contains \"|\": " $0); next }
      if ($1 !~ /^[a-z0-9][a-z0-9-]*$/) bad("target name \x27" $1 "\x27 must be lowercase letters, digits and -")
      if ($1 in seen) bad("target name \x27" $1 "\x27 is declared twice")
      seen[$1] = 1
      if ($7 == "") bad($1 ": no floor")
      if ($2 == "postgres" || $2 == "mysql") {
        if ($3 == "" || $4 == "" || $5 == "") bad($1 ": " $2 " needs container, database and role")
      } else if ($2 == "volume") {
        if ($6 == "") bad($1 ": volume needs a volume")
      } else if ($2 == "stalwart") {
        if ($3 == "" || $6 == "") bad($1 ": stalwart needs container (the server it stops) and volume")
      } else {
        bad($1 ": unknown kind \x27" $2 "\x27 (postgres, mysql, volume or stalwart)")
      }
    }
    END {
      if (!n) bad("declares no targets")
      exit errors ? 1 : 0
    }' || return 1
  printf '%s\n' "$_lines"
}

# target_names <lines>  ->  names, space separated, in declared order
target_names() {
  printf '%s\n' "$1" | awk -F'|' 'NF { printf "%s%s", sep, $1; sep = " " } END { print "" }'
}

# target_line <lines> <name>  ->  that target's line; rc 1 when there is none
target_line() {
  printf '%s\n' "$1" | awk -F'|' -v n="$2" '$1 == n { print; found = 1 } END { exit found ? 0 : 1 }'
}

# drill_tables <targets.yml> <name>  ->  that target's drill_tables, space separated
#
# The tables restore-drill.sh counts, declared beside the target so a drill needs no flags.
# Refused when the target declares none -- a drill that counts nothing proves nothing -- and
# when a name is not a plain identifier, because count_sql splices them into SQL.
drill_tables() {
  _tables=$(NAME="$2" yq -r '.targets[] | select(.name == strenv(NAME)) | (.drill_tables // [])[]' "$1") || return 1
  if [ -z "$_tables" ]; then
    echo "drill_tables: target '$2' declares no drill_tables in $1" >&2
    return 1
  fi
  # One yq line per declared name, checked whole -- so "a b" is refused, not read as two.
  printf '%s\n' "$_tables" | awk '
    !/^[A-Za-z_][A-Za-z0-9_]*$/ { printf "drill_tables: \x27%s\x27 is not a table name\n", $0 > "/dev/stderr"; bad = 1 }
    { out = out sep $0; sep = " " }
    END { if (bad) exit 1; print out }'
}

# count_sql <postgres|mysql> <tables>  ->  one query returning "<table> <count>" rows
count_sql() {
  case $1 in
    postgres) _q='"' ;;
    mysql) _q='`' ;;
    *) echo "count_sql: no count query for '$1'" >&2; return 1 ;;
  esac
  _sep=""
  for _t in $2; do
    printf "%sselect '%s', count(*) from %s%s%s" "$_sep" "$_t" "$_q" "$_t" "$_q"
    _sep=" union all "
  done
  echo
}

# parse_size <floor>  ->  bytes.   1024, 280K, 1M, 1G  (binary units)
#
# Zero is refused along with blank and garbage: a floor of nothing guards nothing.
parse_size() {
  _num=${1%[KMG]}
  _unit=${1#"$_num"}
  case $_num in
    '' | *[!0-9]*) echo "parse_size: '$1' is not a size (e.g. 1024, 280K, 1M)" >&2; return 1 ;;
  esac
  case $_unit in
    '') _mult=1 ;;
    K) _mult=1024 ;;
    M) _mult=1048576 ;;
    G) _mult=1073741824 ;;
  esac
  if [ $((_num * _mult)) -le 0 ]; then
    echo "parse_size: a floor of '$1' guards nothing" >&2
    return 1
  fi
  echo $((_num * _mult))
}

# check_floor <target> <bytes> <floor>
#
# An empty or truncated dump is a failure, not a small backup: the target writes no
# heartbeat, so it raises the same alarm as a backup that never ran.
check_floor() {
  _floor=$(parse_size "$3") || return 1
  case $2 in
    '' | *[!0-9]*) echo "$1: the size could not be measured" >&2; return 1 ;;
  esac
  if [ "$2" -lt "$_floor" ]; then
    echo "$1: $2 bytes is below its floor of $3" >&2
    return 1
  fi
}

# select_targets <all-names> [requested...]  ->  names to run, in declared order
#
# No request runs everything. An unknown name is refused rather than ignored, so a typo
# before a migration cannot quietly back up nothing.
select_targets() {
  _all=$1
  shift
  if [ $# -eq 0 ]; then
    echo "$_all"
    return 0
  fi
  for _want in "$@"; do
    case " $_all " in
      *" $_want "*) ;;
      *) echo "select_targets: no target named '$_want' (declared: $_all)" >&2; return 1 ;;
    esac
  done
  _out=""
  for _name in $_all; do
    for _want in "$@"; do
      [ "$_name" = "$_want" ] && _out="$_out${_out:+ }$_name"
    done
  done
  echo "$_out"
}

# run_exit <failed-count> <skipped-count>  ->  0 green, 1 a failure, 3 green but skipped
#
# The same contract as scripts/verify-mail.sh: a run that left a target out must never
# read as a clean pass.
run_exit() {
  if [ "$1" -gt 0 ]; then echo 1
  elif [ "$2" -gt 0 ]; then echo 3
  else echo 0
  fi
}

# metrics_update <prom-text> <declared-names> <target> <epoch> <bytes>  ->  new prom text
#
# The textfile the monitoring agent reads. Only <target>'s values change; every other
# declared target keeps what it had, so a target that failed tonight keeps last night's
# timestamp and goes stale. A target no longer declared is dropped -- left in, it would
# go stale and alert forever.
metrics_update() {
  printf '%s\n' "$1" | awk -v declared="$2" -v t="$3" -v ts="$4" -v sz="$5" '
    /^backup_last_(success_timestamp_seconds|size_bytes)\{target="/ {
      split($1, q, "\"")
      metric = substr($1, 1, index($1, "{") - 1)
      val[metric, q[2]] = $2
    }
    END {
      val["backup_last_success_timestamp_seconds", t] = ts
      val["backup_last_size_bytes", t] = sz
      n = split(declared, names, " ")
      help["backup_last_success_timestamp_seconds"] = "Unix time of the last snapshot of this target that passed its floor."
      help["backup_last_size_bytes"] = "Bytes dumped or read for that snapshot."
      order[1] = "backup_last_success_timestamp_seconds"
      order[2] = "backup_last_size_bytes"
      for (m = 1; m <= 2; m++) {
        printf "# HELP %s %s\n# TYPE %s gauge\n", order[m], help[order[m]], order[m]
        for (i = 1; i <= n; i++)
          if ((order[m], names[i]) in val)
            printf "%s{target=\"%s\"} %s\n", order[m], names[i], val[order[m], names[i]]
      }
    }'
}

# last_success <prom-text> <target>  ->  epoch, or nothing if it has never succeeded
last_success() {
  printf '%s\n' "$1" | awk -v t="$2" '
    index($0, "backup_last_success_timestamp_seconds{target=\"" t "\"} ") == 1 { print $2 }'
}

# check_health <now> <max-age-seconds> <prom-text> <names>
#
# Unhealthy when ANY declared target has never succeeded or last succeeded longer ago
# than the limit -- one stale database is not hidden by four fresh volumes.
check_health() {
  _bad=0
  for _name in $4; do
    _ts=$(last_success "$3" "$_name")
    if [ -z "$_ts" ]; then
      echo "$_name: no successful backup recorded"
      _bad=1
    elif [ $(($1 - _ts)) -gt "$2" ]; then
      echo "$_name: last success $(( ($1 - _ts) / 3600 ))h ago"
      _bad=1
    else
      echo "$_name: ok"
    fi
  done
  return $_bad
}

# scratch_path <target>  ->  /scratch/<target>
scratch_path() {
  if [ -z "$1" ]; then
    echo "scratch_path: a target is required" >&2
    return 1
  fi
  printf '%s/%s\n' "$SCRATCH_ROOT" "$1"
}

# check_dump_role <role> <rolsuper>   (psql boolean: t / f)
#
# booking-be connects as booking_app so Row-Level Security applies. pg_dump run as a
# role like that does not error -- it dumps every table with no tenant's rows in it.
# Superuser is required, not merely BYPASSRLS: pg_dumpall --globals-only must read
# pg_authid too.
check_dump_role() {
  if [ "$2" = t ]; then
    return 0
  fi
  echo "refusing to dump as '$1': not a superuser, so the dump could silently omit every tenant's rows" >&2
  return 1
}

# compare_counts <live> <restored>   each: lines of "<key> <value>..."
#
# "<table> <count>" for the database drills, "<account> <messages> <bytes>" for the mail
# drill: everything after the key must match. Every key in <live> must appear in <restored>
# with the same values, and <restored> may hold no key <live> lacks. An empty <live> fails:
# a drill that compared nothing proved nothing.
compare_counts() {
  # Passed via the environment, not -v: some awks reject a newline inside -v.
  printf '%s\n' "$1" | RESTORED="$2" awk '
    function rest(line) { sub(/^[^ ]+ +/, "", line); return line }
    BEGIN {
      n = split(ENVIRON["RESTORED"], lines, "\n")
      for (i = 1; i <= n; i++) if (split(lines[i], f, " ") >= 2) got[f[1]] = rest(lines[i])
    }
    NF >= 2 {
      seen++
      want = rest($0)
      live[$1] = 1
      if (!($1 in got)) { printf "MISMATCH %s: live=%s restored=(missing)\n", $1, want; bad++ }
      else if (got[$1] != want) { printf "MISMATCH %s: live=%s restored=%s\n", $1, want, got[$1]; bad++ }
      else printf "ok       %s: %s\n", $1, want
    }
    END {
      if (!seen) { print "nothing to compare: no live counts" > "/dev/stderr"; exit 1 }
      for (k in got) if (!(k in live)) { printf "MISMATCH %s: live=(missing) restored=%s\n", k, got[k]; bad++ }
      exit bad ? 1 : 0
    }'
}

# ── JMAP, for the stalwart kind ──────────────────────────────────────────────────────
# The mail drill counts every account's messages and bytes on the live server and on the
# restored copy -- the numbers scripts/mail-inventory.py records. These read one response
# each; bin/stalwart.sh makes the requests.

# jmap_error <json>  ->  rc 1, naming the problem, unless <json> is a JMAP response with no
# method error in it
jmap_error() {
  _err=$(printf '%s' "$1" | yq -p json -r '
    (.methodResponses // error("no methodResponses")) | map(select(.[0] == "error") | .[1].type) | join(",")
  ' 2>/dev/null) || { echo "jmap: not a JMAP response: $(printf '%s' "$1" | head -c 200)" >&2; return 1; }
  [ -z "$_err" ] || { echo "jmap: method error: $_err" >&2; return 1; }
}

# jmap_principals <Principal/get response>  ->  "<id> <name>" per account
#
# Refused when the list is empty: an inventory of nobody compares equal to another one.
jmap_principals() {
  jmap_error "$1" || return 1
  _p=$(printf '%s' "$1" | yq -p json -r '.methodResponses[0][1].list[] | .id + " " + (.name // .email // .id)') || return 1
  [ -n "$_p" ] || { echo "jmap: Principal/get listed no accounts" >&2; return 1; }
  printf '%s\n' "$_p"
}

# jmap_page <Email/query + Email/get(size) response>  ->  "<total> <messages> <bytes>"
#
# total is the account's whole message count; messages and bytes are this page's.
jmap_page() {
  jmap_error "$1" || return 1
  _page=$(printf '%s' "$1" | yq -p json -r '
    select(.methodResponses[0][0] == "Email/query" and .methodResponses[1][0] == "Email/get")
    | [.methodResponses[0][1].total, (.methodResponses[1][1].list | length),
     (.methodResponses[1][1].list | map(.size // 0) | .[] as $x ireduce (0; . + $x))]
    | map(tostring) | join(" ")' 2>/dev/null)
  case $_page in
    *[!0-9\ ]* | '' | *' '*' '*' '*) ;;
    *' '*' '*) echo "$_page"; return 0 ;;
  esac
  echo "jmap: not an Email/query + Email/get page: $(printf '%s' "$1" | head -c 200)" >&2
  return 1
}

# restic_snapshot_id <restic backup --json output>  ->  the id of the snapshot it wrote
restic_snapshot_id() {
  printf '%s\n' "$1" | awk '
    /"message_type":"summary"/ && match($0, /"snapshot_id":"[0-9a-f]+"/) {
      print substr($0, RSTART + 15, RLENGTH - 16); found = 1 }
    END { if (!found) { print "restic: no snapshot id in the backup output" > "/dev/stderr"; exit 1 } }'
}
