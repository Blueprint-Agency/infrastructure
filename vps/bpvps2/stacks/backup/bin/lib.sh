# Pure helpers for backup.sh, restore-drill.sh and healthcheck.sh. POSIX sh: the job runs
# on the restic image's busybox ash, and scripts/test_backup_lib.sh sources this from bash.
# Nothing in here touches Docker, Postgres or R2 -- that is what keeps it testable. The one
# outside tool is yq, which reads the targets file.

SCRATCH_ROOT=/scratch

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
      } else {
        bad($1 ": unknown kind \x27" $2 "\x27 (postgres, mysql or volume)")
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

# compare_counts <live> <restored>   each: lines of "<table> <count>"
#
# Every table in <live> must appear in <restored> with the same count. An empty <live>
# fails: a drill that compared nothing proved nothing.
compare_counts() {
  # Passed via the environment, not -v: some awks reject a newline inside -v.
  printf '%s\n' "$1" | RESTORED="$2" awk '
    BEGIN {
      n = split(ENVIRON["RESTORED"], lines, "\n")
      for (i = 1; i <= n; i++) if (split(lines[i], f, " ") == 2) got[f[1]] = f[2]
    }
    NF == 2 {
      seen++
      if (!($1 in got)) { printf "MISMATCH %s: live=%s restored=(missing)\n", $1, $2; bad++ }
      else if (got[$1] != $2) { printf "MISMATCH %s: live=%s restored=%s\n", $1, $2, got[$1]; bad++ }
      else printf "ok       %s: %s\n", $1, $2
    }
    END {
      if (!seen) { print "nothing to compare: no live counts" > "/dev/stderr"; exit 1 }
      exit bad ? 1 : 0
    }'
}
