# Pure helpers for backup.sh and restore-drill.sh. POSIX sh: the job runs on the
# restic image's busybox ash, and scripts/test_backup_lib.sh sources this from bash.
# Nothing in here touches Docker, Postgres or R2 -- that is what keeps it testable.

SCRATCH_ROOT=/scratch

# instance_name <env>  ->  booking-staging
#
# The booking compose is deployed twice on this host keyed on ENV_NAME, so every tag
# and path is keyed the same way. Refuse a blank env: "booking-" would be one name
# shared by both instances, and staging would write into prod's snapshot.
instance_name() {
  if [ -z "$1" ]; then
    echo "instance_name: an env is required" >&2
    return 1
  fi
  printf 'booking-%s\n' "$1"
}

# db_container <env>  ->  booking-db-staging   (the booking compose's container_name)
db_container() {
  printf 'booking-db-%s\n' "$1"
}

# scratch_path <instance>  ->  /scratch/<instance>
scratch_path() {
  if [ -z "$1" ]; then
    echo "scratch_path: an instance is required" >&2
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
