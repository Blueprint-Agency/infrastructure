#!/usr/bin/env bash
# verify-mail.sh <domain> [account ...]
#
# Proves that mail works for one domain, entirely from the outside. This is the single
# verification seam for the mail platform: DNS, inbound delivery, outbound authentication,
# TLS, the webmail, and a real login all converge on one question -- "does mail work for
# this domain?" -- and one exit code.
#
# Run it before a change to capture a known-good baseline, and again after, unchanged.
#
#   ./scripts/verify-mail.sh kaiteki.my
#   ./scripts/verify-mail.sh kaiteki.my admin@kaiteki.my staff@kaiteki.my
#
# Expectations per domain live in scripts/verify-mail.d/<domain>.conf, so onboarding a new
# domain is a new config file, not a new script.
#
# ---------------------------------------------------------------------------------------
# DESIGN NOTES -- the non-obvious parts
#
# * AN EMPTY VALUE IS A FAILURE. Most of what breaks mail fails "successfully": a TXT
#   lookup returns NOERROR with no records, Bulwark answers 200 with every branding field
#   blank, a DKIM record publishes `p=` with no key (which is the REVOKED form). Each of
#   those is a check that passes if you only ask "did it respond". The parsing half of this
#   script lives in lib/mail-checks.sh precisely so those cases can be tested, and
#   scripts/test_verify_mail.sh is mostly made of them.
#
# * THE INBOUND TEST CANNOT RUN FROM A LAPTOP. Home ISPs block outbound port 25, so a
#   direct connection reads BLOCKED whether or not the mail server is healthy -- a false
#   alarm, and the repo has been bitten by exactly this before. The inbound leg therefore
#   runs over ssh from another VPS (--via, default bp-vps3-prod), which is also the more
#   honest test: it is a real internet path from a different host to the resolved MX.
#
# * OUTBOUND IS JUDGED BY A THIRD PARTY, NOT BY OUR LOGS. One Stalwart in this estate has
#   never written a log line, so "grep the logs" proves nothing. Instead a message is sent
#   through the real submission port and check-auth@verifier.port25.com replies with the
#   SPF and DKIM results it observed; the reply is then read back through JMAP. DMARC is
#   derived from those, which is stricter than DMARC itself: DMARC passes if EITHER SPF or
#   DKIM passes and aligns, and this requires BOTH.
#
# * DNS IS RESOLVED BY dig IF PRESENT, ELSE BY DNS-over-HTTPS THROUGH curl. Git Bash on
#   Windows ships no dig, and "install bind-tools first" is a poor answer for a script
#   whose whole point is to be run on the spot during a cutover.
#
# * NOTHING HERE CHANGES A SERVER. The only side effects are two test emails, both clearly
#   subject-tagged, delivered to a mailbox you named.
# ---------------------------------------------------------------------------------------
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
# shellcheck source=lib/mail-checks.sh
source "$HERE/lib/mail-checks.sh"

CONF_DIR="$HERE/verify-mail.d"
RUN_ID="$(date +%Y%m%d-%H%M%S)-$$"
OUTBOUND_PROBE="${VERIFY_MAIL_OUTBOUND_PROBE:-check-auth@verifier.port25.com}"
OUTBOUND_WAIT="${VERIFY_MAIL_OUTBOUND_WAIT:-240}"   # seconds to wait for the report reply
# An imminent outage, not a renewal reminder: the ticket asks only that the cert covers the
# name, so the floor is set where "this expires before anyone could reasonably react".
TLS_MIN_DAYS="${VERIFY_MAIL_TLS_MIN_DAYS:-7}"
SMTP_VIA="${VERIFY_MAIL_SMTP_VIA:-bp-vps3-prod}"
PROBE_FROM="${VERIFY_MAIL_PROBE_FROM:-}"   # envelope sender for the inbound probe
SKIP="${VERIFY_MAIL_SKIP:-}"

# ---------------------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------------------
usage() {
  cat >&2 <<'USAGE'
usage: verify-mail.sh <domain> [account ...]

  <domain>          a domain with a config in scripts/verify-mail.d/<domain>.conf
  [account ...]     mailboxes to prove a login for. Defaults to DEFAULT_ACCOUNTS from the
                    config. Accounts are NOT enumerated: this build's management API does
                    not expose a listing to scripts, and "can this real person sign in" is
                    the better test anyway.

options:
  --via <ssh-alias>   host to run the inbound SMTP probe from (default: bp-vps3-prod).
                      Must not be the mail host itself, or the probe never leaves the box.
  --skip <list>       comma-separated checks to skip: inbound, outbound. Skipped checks are
                      reported as SKIP, never counted as a pass, and change the exit status
                      (see below) so a partial run can never be mistaken for a green one.
  --wait <seconds>    how long to wait for the outbound report reply (default: 240).
  -h, --help          this text.

environment overrides (all optional):
  VERIFY_MAIL_SMTP_VIA        same as --via
  VERIFY_MAIL_SKIP            same as --skip
  VERIFY_MAIL_OUTBOUND_WAIT   same as --wait
  VERIFY_MAIL_TLS_MIN_DAYS    fail a certificate with fewer days left (default: 7)
  VERIFY_MAIL_OUTBOUND_PROBE  the authentication auto-responder to send the outbound probe
                              to (default: check-auth@verifier.port25.com)
  VERIFY_MAIL_PROBE_FROM      envelope sender for the inbound probe. Defaults to
                              verify-mail@<relay's own FQDN>. Never the domain under test:
                              it publishes SPF, so a probe claiming to come from it would
                              be sent from an unauthorised IP and correctly rejected.

passwords:
  Each account needs its mailbox password, for the JMAP login and the outbound send.
  Looked up as MAIL_PASSWORD_<ACCOUNT>, uppercased with every non-alphanumeric character
  replaced by _ -- admin@kaiteki.my becomes MAIL_PASSWORD_ADMIN_KAITEKI_MY. The repo .env
  is sourced automatically if present, per the credentials rule. If the variable is unset
  and the terminal is interactive, you are prompted instead.

exit status:
  0  every check ran and passed -- and nothing was skipped
  1  at least one check failed
  2  the run could not start (bad arguments, missing config, blank expectation)
  3  everything that ran passed, but something was skipped

  3 exists so that "green" keeps meaning "mail works". A run with the two delivery legs
  skipped has not proven mail works, and exiting 0 for it would be exactly the silent pass
  this script is built to prevent.
USAGE
}

DOMAIN=''
ACCOUNTS=()
while (( $# > 0 )); do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --via)  SMTP_VIA="${2-}"; shift 2 || { usage; exit 2; } ;;
    --skip) SKIP="${2-}";     shift 2 || { usage; exit 2; } ;;
    --wait) OUTBOUND_WAIT="${2-}"; shift 2 || { usage; exit 2; } ;;
    --*) echo "unknown option: $1" >&2; usage; exit 2 ;;
    *)
      if [[ -z "$DOMAIN" ]]; then DOMAIN="$1"; else ACCOUNTS+=("$1"); fi
      shift
      ;;
  esac
done
[[ -n "$DOMAIN" ]] || { usage; exit 2; }

skipping() { [[ ",$SKIP," == *",$1,"* ]]; }

# ---------------------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------------------
if [[ -t 1 ]]; then
  C_PASS=$'\033[32m'; C_FAIL=$'\033[31m'; C_SKIP=$'\033[33m'; C_DIM=$'\033[2m'; C_OFF=$'\033[0m'
else
  C_PASS=''; C_FAIL=''; C_SKIP=''; C_DIM=''; C_OFF=''
fi

PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
FAILED_NAMES=()

section() { printf '\n%s== %s%s\n' "$C_DIM" "$1" "$C_OFF"; }

pass() { PASS_COUNT=$((PASS_COUNT + 1)); printf '  %sPASS%s  %-34s %s\n' "$C_PASS" "$C_OFF" "$1" "${2-}"; }
fail() {
  FAIL_COUNT=$((FAIL_COUNT + 1)); FAILED_NAMES+=("$1")
  printf '  %sFAIL%s  %-34s %s\n' "$C_FAIL" "$C_OFF" "$1" "${2-}"
}
skip() { SKIP_COUNT=$((SKIP_COUNT + 1)); printf '  %sSKIP%s  %-34s %s\n' "$C_SKIP" "$C_OFF" "$1" "${2-}"; }

# check <name> <command...> -- runs the command, prints its output as the reason on failure.
check() {
  local name="$1"; shift
  local out
  if out="$("$@" 2>&1)"; then
    pass "$name" "$out"
  else
    fail "$name" "$out"
  fi
}

die() { printf '%sverify-mail: %s%s\n' "$C_FAIL" "$1" "$C_OFF" >&2; exit 2; }

# ---------------------------------------------------------------------------------------
# A JSON reader. lib/mail-checks.sh parses the flat branding response with no dependency at
# all, but the JMAP session and response objects are nested and need a real parser. python3
# is on every host in this estate; on Git Bash the `python3` on PATH is a Windows Store stub
# that exits 9009, so the interpreter is probed rather than assumed.
# ---------------------------------------------------------------------------------------
PY=''
for candidate in python3 python py; do
  if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'import sys' >/dev/null 2>&1; then
    PY="$candidate"; break
  fi
done

# json_path <json> <dotted.path>  -- prints the value, or returns 1 if any step is missing.
# Path segments are passed as separate argv entries rather than one delimited string:
# command substitution silently drops NUL bytes, so the obvious `tr '.' '\0'` trick hands
# python an empty separator and blows up instead of reading the path.
json_path() {
  [[ -n "$PY" ]] || return 1
  local segments=()
  IFS='.' read -r -a segments <<<"$2"
  "$PY" -c '
import json, sys
try:
    doc = json.loads(sys.stdin.read() or "null")
except ValueError:
    sys.exit(1)
for key in sys.argv[1:]:
    if key == "":
        continue
    if isinstance(doc, list):
        try:
            doc = doc[int(key)]
        except (ValueError, IndexError):
            sys.exit(1)
    elif isinstance(doc, dict):
        if key not in doc:
            sys.exit(1)
        doc = doc[key]
    else:
        sys.exit(1)
if doc is None:
    sys.exit(1)
sys.stdout.write(doc if isinstance(doc, str) else json.dumps(doc))
' "${segments[@]}" <<<"$1"
}

# ---------------------------------------------------------------------------------------
# Preconditions
# ---------------------------------------------------------------------------------------
command -v curl    >/dev/null 2>&1 || die "curl is required but not installed"
command -v openssl >/dev/null 2>&1 || die "openssl is required but not installed"
[[ -n "$PY" ]]                     || die "a working python3 is required to read JMAP responses"

# A blank numeric knob is not a looser check, it is no check: bash evaluates an empty
# OUTBOUND_WAIT as 0, so the poll loop never runs and the outbound check reports "mail may
# not have left the server" for a purely local reason. Same rule as the .conf keys below.
for knob in OUTBOUND_WAIT TLS_MIN_DAYS; do
  value="${!knob-}"
  [[ "$value" =~ ^[0-9]+$ ]] && (( value > 0 )) \
    || die "$knob is '${value:-<empty>}'; it must be a positive whole number"
done

CONF="$CONF_DIR/$DOMAIN.conf"
[[ -f "$CONF" ]] || die "no expectations file for '$DOMAIN' -- create $CONF (copy an existing one)"
# shellcheck disable=SC1090
source "$CONF"

for key in MAIL_HOST WEBMAIL_HOST EXPECT_MX EXPECT_SPF_ALL EXPECT_DMARC_POLICY \
           EXPECT_DMARC_RUA DKIM_SELECTORS BRANDING_EXPECT DEFAULT_ACCOUNTS; do
  value="${!key-}"
  [[ -n "${value//[[:space:]]/}" ]] || die "$CONF sets $key to an empty value -- a blank expectation is not a check"
done

if (( ${#ACCOUNTS[@]} == 0 )); then
  read -r -a ACCOUNTS <<<"$DEFAULT_ACCOUNTS"
fi

# The repo credentials rule: secrets come from .env, nowhere else.
if [[ -f "$REPO_ROOT/.env" ]]; then
  set -a; # shellcheck disable=SC1091
  source "$REPO_ROOT/.env"; set +a
fi

# Passwords are resolved ONCE, here in the main shell, before any check runs. They cannot
# be resolved lazily inside a check: the check harness captures both stdout and stderr of
# each check, so an interactive prompt written from in there is swallowed and the script
# just appears to hang on a silent `read`. Resolving up front also means one prompt per
# account rather than one per check that needs it.
declare -A PASSWORDS=()

password_var_for() { # password_var_for <account> -> MAIL_PASSWORD_ADMIN_KAITEKI_MY
  local var
  var="MAIL_PASSWORD_$(tr '[:lower:]' '[:upper:]' <<<"$1" | tr -c '[:alnum:]' '_')"
  printf '%s' "${var%_}"
}

resolve_passwords() { # resolve_passwords <account>...
  local account var value
  for account in "$@"; do
    [[ -n "${PASSWORDS[$account]-}" ]] && continue
    var="$(password_var_for "$account")"
    value="${!var-}"
    if [[ -z "$value" && -t 0 && -t 2 ]]; then
      printf 'password for %s (or set %s): ' "$account" "$var" >&2
      read -r -s value; printf '\n' >&2
    fi
    [[ -n "$value" ]] && PASSWORDS[$account]="$value"
  done
}

# password_for <account> -- read-only lookup; the resolution above already happened.
password_for() {
  local value="${PASSWORDS[$1]-}"
  [[ -n "$value" ]] || return 1
  printf '%s' "$value"
}

# ---------------------------------------------------------------------------------------
# DNS. dig when it exists, DNS-over-HTTPS through curl when it does not.
# Both backends are normalised to the same shape: one record per line, TXT chunks joined.
# ---------------------------------------------------------------------------------------
DNS_BACKEND='doh'
command -v dig >/dev/null 2>&1 && DNS_BACKEND='dig'

# join_txt_chunks -- a long TXT record arrives as `"part1" "part2"`; the quotes and the
# separator between chunks are not part of the value and must not end up inside a DKIM key.
join_txt_chunks() { sed -e 's/" *"//g' -e 's/"//g'; }

dns_query() { # dns_query <type> <name>
  local type="$1" name="$2"
  if [[ "$DNS_BACKEND" == 'dig' ]]; then
    dig +short +timeout=5 +tries=2 "$type" "$name" 2>/dev/null
    return 0
  fi
  local body
  body="$(curl -s --max-time 15 -H 'accept: application/dns-json' \
    --get --data-urlencode "name=$name" --data-urlencode "type=$type" \
    'https://cloudflare-dns.com/dns-query' 2>/dev/null)" || return 0
  local want_type
  case "$type" in MX) want_type=15 ;; TXT) want_type=16 ;; A) want_type=1 ;; CNAME) want_type=5 ;; *) want_type='' ;; esac
  "$PY" -c '
import json, sys
try:
    doc = json.loads(sys.stdin.read() or "{}")
except ValueError:
    sys.exit(0)
want = sys.argv[1]
for answer in doc.get("Answer") or []:
    if want and str(answer.get("type")) != want:
        continue
    sys.stdout.write(str(answer.get("data", "")) + "\n")
' "$want_type" <<<"$body"
}

dns_txt() { dns_query TXT "$1" | join_txt_chunks; }

# ---------------------------------------------------------------------------------------
# Check bodies. Each is a plain function returning 0/1 and printing one line of detail,
# so the `check` harness can render it uniformly.
# ---------------------------------------------------------------------------------------

check_mx() {
  local records target
  records="$(dns_query MX "$DOMAIN")"
  target="$(mx_pick "$records")" || { echo "$target"; return 1; }
  if [[ "$target" != "$EXPECT_MX" ]]; then
    echo "MX points at '$target', expected '$EXPECT_MX'"
    return 1
  fi
  # An MX target that does not resolve is a domain that accepts no mail, however tidy the
  # record looks.
  local addrs
  addrs="$(dns_query A "$target")"
  require_nonempty "A record for MX target $target" "$addrs" || return 1
  echo "$target -> $(tr '\n' ' ' <<<"$addrs")"
}

check_spf() {
  local all_txt spf count
  all_txt="$(dns_txt "$DOMAIN")"
  spf="$(grep -i '^v=spf1' <<<"$all_txt")"
  count="$(grep -c . <<<"${spf:-}")"
  if [[ -n "$spf" ]] && (( count > 1 )); then
    # Two SPF records is a permerror for every receiver, which fails DMARC entirely.
    echo "domain publishes $count SPF records; RFC 7208 permits exactly one"
    return 1
  fi
  spf_check "$spf" "$EXPECT_SPF_ALL" || return 1
  echo "$spf"
}

check_dmarc() {
  local record
  record="$(dns_txt "_dmarc.$DOMAIN" | grep -i '^v=DMARC1' | head -n1)"
  dmarc_check "$record" "$EXPECT_DMARC_POLICY" "$EXPECT_DMARC_RUA" || return 1
  echo "$record"
}

check_dkim() {
  local selector record out failures=0 seen=0 selectors=()
  # read -ra, not an unquoted expansion: a selector containing a glob character would
  # otherwise be expanded against the working directory.
  read -r -a selectors <<<"$DKIM_SELECTORS"
  for selector in "${selectors[@]}"; do
    seen=$((seen + 1))
    record="$(dns_txt "$selector._domainkey.$DOMAIN" | grep -i '^v=DKIM1' | head -n1)"
    if ! out="$(dkim_check "$record")"; then
      echo "selector '$selector': $out"
      failures=$((failures + 1))
    fi
  done
  (( seen > 0 )) || { echo "no DKIM selectors configured for this domain"; return 1; }
  (( failures == 0 )) || return 1
  echo "$seen selector(s) published and well-formed"
}

# tls_on <host> <port> -- SAN coverage plus remaining validity. A cert that covers the name
# but expires next week is a scheduled outage, so days-remaining is part of the check.
tls_on() {
  local host="$1" port="$2" cert sans enddate end_epoch now_epoch days
  cert="$(echo | openssl s_client -connect "$host:$port" -servername "$host" 2>/dev/null \
          | openssl x509 -noout -ext subjectAltName -enddate 2>/dev/null)"
  require_nonempty "certificate on $host:$port" "$cert" || return 1

  sans="$(grep -o 'DNS:[^,]*\(, *DNS:[^,]*\)*' <<<"$cert" | head -n1)"
  san_covers "$sans" "$host" || return 1

  enddate="${cert#*notAfter=}"
  enddate="${enddate%%$'\n'*}"
  require_nonempty "notAfter on $host:$port" "$enddate" || return 1

  end_epoch="$("$PY" -c '
import calendar, sys, time
try:
    sys.stdout.write(str(calendar.timegm(time.strptime(sys.argv[1].strip(), "%b %d %H:%M:%S %Y %Z"))))
except ValueError:
    sys.exit(1)
' "$enddate")" || { echo "could not parse expiry '$enddate'"; return 1; }
  now_epoch="$(date -u +%s)"
  days=$(( (end_epoch - now_epoch) / 86400 ))
  if (( days < TLS_MIN_DAYS )); then
    echo "expires in ${days}d (notAfter=$enddate), under the ${TLS_MIN_DAYS}d floor"
    return 1
  fi
  echo "covers $host, ${days}d remaining"
}

check_webmail_answers() {
  local code
  code="$(curl -s -o /dev/null --max-time 20 -w '%{http_code}' "https://$WEBMAIL_HOST/")"
  require_nonempty "HTTP status from $WEBMAIL_HOST" "$code" || return 1
  if [[ ! "$code" =~ ^(2|3)[0-9][0-9]$ ]]; then
    echo "https://$WEBMAIL_HOST/ returned HTTP $code"
    return 1
  fi
  echo "HTTP $code"
}

check_branding() {
  local body pair field expected out failures=0 seen=0 reported=''
  body="$(curl -s --max-time 20 "https://$WEBMAIL_HOST/api/config")"
  require_nonempty "branding response from $WEBMAIL_HOST" "$body" || return 1

  # BRANDING_EXPECT is one `field=value` per LINE, not space-separated: branding values are
  # human-facing strings like "Kaiteki Mail" and word-splitting would cut them in half.
  while IFS= read -r pair; do
    pair="${pair#"${pair%%[![:space:]]*}"}"
    pair="${pair%"${pair##*[![:space:]]}"}"
    [[ -z "$pair" ]] && continue
    seen=$((seen + 1))
    field="${pair%%=*}"
    expected="${pair#*=}"
    if out="$(branding_check "$body" "$field" "$expected")"; then
      reported+="$field='$expected' "
    else
      echo "$out"
      failures=$((failures + 1))
    fi
  done <<<"$BRANDING_EXPECT"

  (( seen > 0 )) || { echo "BRANDING_EXPECT lists no fields to assert"; return 1; }
  (( failures == 0 )) || return 1
  echo "$reported"
}

check_cors_preflight() {
  local headers origin="https://$WEBMAIL_HOST"
  headers="$(curl -s -o /dev/null -D - --max-time 20 -X OPTIONS \
    "https://$MAIL_HOST/.well-known/jmap" \
    -H "Origin: $origin" \
    -H 'Access-Control-Request-Method: GET' \
    -H 'Access-Control-Request-Headers: authorization')"
  require_nonempty "preflight response from $MAIL_HOST" "$headers" || return 1

  local allow_origin allow_creds
  allow_origin="$(grep -i '^access-control-allow-origin:' <<<"$headers" | head -n1 | cut -d: -f2- | tr -d ' \r')"
  allow_creds="$(grep -i '^access-control-allow-credentials:' <<<"$headers" | head -n1 | cut -d: -f2- | tr -d ' \r')"

  require_nonempty 'Access-Control-Allow-Origin' "$allow_origin" || return 1
  # A wildcard is not a pass here. Browsers reject `*` on credentialed requests, and the
  # webmail's JMAP calls are credentialed, so `*` means the webmail is broken in a way that
  # a naive "is the header present" check would call healthy.
  if [[ "$allow_origin" == '*' ]]; then
    echo "preflight answers Access-Control-Allow-Origin: * -- browsers reject that for credentialed JMAP calls"
    return 1
  fi
  if [[ "$allow_origin" != "$origin" ]]; then
    echo "preflight allows origin '$allow_origin', expected '$origin'"
    return 1
  fi
  if [[ "$allow_creds" != 'true' ]]; then
    echo "preflight does not set Access-Control-Allow-Credentials: true (got '${allow_creds:-<absent>}')"
    return 1
  fi
  echo "allows $origin with credentials"
}

# ---------------------------------------------------------------------------------------
# JMAP
# ---------------------------------------------------------------------------------------

# jmap_session <account> <password> -- prints the raw session object.
jmap_session() {
  curl -s --max-time 25 -u "$1:$2" -L "https://$MAIL_HOST/.well-known/jmap"
}

# jmap_context <account> <password> -- authenticates once and prints EITHER
#   OK <api-url> <account-id>
# or
#   ERR <reason>
# Both callers need that pair, and fetching the session in each of them meant the outbound
# poll re-authenticated on every 15s tick.
#
# The reason travels on STDOUT, not in a global. Callers invoke this inside `$(…)`, which
# is a subshell, so a global set in here never reaches them -- an earlier version did
# exactly that and reported a failed login with a completely blank reason, which is how a
# real Stalwart restart showed up as an unexplained red line.
jmap_context() {
  local account="$1" password="$2" session api_url account_id
  session="$(jmap_session "$account" "$password")"
  if [[ -z "${session//[[:space:]]/}" ]]; then
    echo "ERR no response from https://$MAIL_HOST/.well-known/jmap -- is Stalwart up?"
    return 1
  fi
  if ! api_url="$(json_path "$session" 'apiUrl')"; then
    echo "ERR JMAP session has no apiUrl -- authentication most likely failed"
    return 1
  fi
  if ! account_id="$(json_path "$session" 'primaryAccounts.urn:ietf:params:jmap:mail')"; then
    echo "ERR session returned no primary mail account for $account"
    return 1
  fi
  # An absolute apiUrl on the wrong host is the specific breakage that takes the webmail
  # down when Stalwart's Default Hostname is wrong, so it is asserted rather than assumed.
  if [[ "$api_url" == http* && "$api_url" != "https://$MAIL_HOST"* ]]; then
    echo "ERR session advertises apiUrl '$api_url', which is not on $MAIL_HOST -- the webmail will break"
    return 1
  fi
  [[ "$api_url" == http* ]] || api_url="https://$MAIL_HOST$api_url"
  printf 'OK %s %s\n' "$api_url" "$account_id"
}

check_login() { # check_login <account>
  local account="$1" password context
  password="$(password_for "$account")" || {
    echo "no password available -- set $(password_var_for "$account") in .env, or run interactively"
    return 1
  }
  context="$(jmap_context "$account" "$password")"
  [[ "$context" == OK\ * ]] || { echo "${context#ERR }"; return 1; }
  echo "account ${context##* }"
}

# jmap_call <account> <password> <api-url> <method-calls-json> -- prints the raw response.
jmap_call() {
  curl -s --max-time 30 -u "$1:$2" -X POST "$3" \
    -H 'Content-Type: application/json' \
    --data-binary "$4"
}

# ---------------------------------------------------------------------------------------
# Inbound delivery, through the resolved MX host, from another VPS.
# ---------------------------------------------------------------------------------------
check_inbound() { # check_inbound <recipient>
  local recipient="$1" mx probe_from subject remote mx_addrs relay_addrs addr
  mx="$(mx_pick "$(dns_query MX "$DOMAIN")")" || { echo "$mx"; return 1; }

  [[ -n "$SMTP_VIA" ]] || { echo "no relay host set; pass --via <ssh-alias>"; return 1; }

  # The relay must not BE the mail host, or the probe never crosses the internet and the
  # check proves nothing. Comparing the ssh alias against the mail hostname does not do
  # that -- `--via bp-bpvps1` is the mail host and looks nothing like `mail.kaiteki.my` --
  # so the addresses are compared instead.
  mx_addrs="$(dns_query A "$mx")"
  relay_addrs="$(ssh -o ConnectTimeout=15 -o BatchMode=yes "$SMTP_VIA" \
    'hostname -I 2>/dev/null || ip -4 -o addr show scope global | awk "{print \$4}" | cut -d/ -f1' \
    2>/dev/null | tr -d '\r' | tr ' ' '\n')"
  require_nonempty "addresses of relay $SMTP_VIA" "$relay_addrs" || return 1
  while IFS= read -r addr; do
    [[ -z "${addr//[[:space:]]/}" ]] && continue
    if grep -qxF "$addr" <<<"$mx_addrs"; then
      echo "relay '$SMTP_VIA' ($addr) IS the mail host $mx -- the probe would never leave the box"
      return 1
    fi
  done <<<"$relay_addrs"

  subject="verify-mail inbound probe $RUN_ID"
  # The envelope sender is the relay's own hostname, never the domain under test: that
  # domain publishes SPF -all, so a probe claiming to be from it would be sent from an
  # unauthorised IP and correctly rejected -- a failure of the test, not of the server.
  # Resolved HERE rather than left as an unexpanded `$(hostname -f)` for the remote shell,
  # so that a rejection message can name the address the server actually saw. During an
  # incident, "sender was verify-mail@$(hostname -f)" tells you nothing.
  local relay_fqdn note=''
  if [[ -n "$PROBE_FROM" ]]; then
    probe_from="$PROBE_FROM"
    relay_fqdn="${probe_from##*@}"
  else
    relay_fqdn="$(ssh -o ConnectTimeout=15 -o BatchMode=yes "$SMTP_VIA" 'hostname -f' 2>/dev/null | tr -d '\r' | head -n1)"
    require_nonempty "fully-qualified hostname of relay $SMTP_VIA" "$relay_fqdn" || return 1
    probe_from="verify-mail@$relay_fqdn"
  fi

  # A relay that never had its hostname set reports a placeholder like `prod2.domain.tld`,
  # or a bare name. Stalwart logs the resulting EHLO as invalid and a stricter receiver
  # would reject the probe outright -- a test artefact that looks exactly like a mail
  # server fault. It is surfaced rather than hidden, and VERIFY_MAIL_PROBE_FROM overrides.
  if [[ "$relay_fqdn" != *.* || "$relay_fqdn" == *.domain.tld || "$relay_fqdn" == *.localdomain \
        || "$relay_fqdn" == localhost* ]]; then
    note=" [relay hostname '$relay_fqdn' is a placeholder, so the probe's EHLO is not a real FQDN --"
    note+=" set VERIFY_MAIL_PROBE_FROM if a receiver ever rejects it]"
  fi

  # curl runs with -S so that a refusal comes back with the server's own SMTP reply text.
  # A rejected probe has two very different causes -- the mail server is broken, or the
  # probe's own envelope sender was not acceptable -- and without the reply text they are
  # indistinguishable, which is how a test artefact gets read as an outage.
  remote="$(ssh -o ConnectTimeout=15 -o BatchMode=yes "$SMTP_VIA" "
    set -u
    FROM=\"$probe_from\"
    TMP=\$(mktemp)
    {
      printf 'From: verify-mail <%s>\r\n' \"\$FROM\"
      printf 'To: <%s>\r\n' '$recipient'
      printf 'Subject: %s\r\n' '$subject'
      printf 'Date: %s\r\n' \"\$(date -R)\"
      printf 'Message-ID: <%s@%s>\r\n' '$RUN_ID' '$relay_fqdn'
      printf '\r\n'
      printf 'Automated inbound delivery probe from verify-mail.sh. Safe to delete.\r\n'
    } > \"\$TMP\"
    curl -sS --max-time 60 --url 'smtp://$mx:25' --ssl \
         --mail-from \"\$FROM\" --mail-rcpt '$recipient' \
         --upload-file \"\$TMP\" -o /dev/null
    echo \"rc=\$?\"
    rm -f \"\$TMP\"
  " 2>&1 | tr -d '\r')"

  if [[ "$remote" != *'rc=0'* ]]; then
    echo "delivery to $mx:25 via $SMTP_VIA was not accepted (sender was $probe_from): $(tr '\n' ' ' <<<"$remote")"
    return 1
  fi
  echo "accepted by $mx:25 (probe sent from $SMTP_VIA as $probe_from)$note"
}

# ---------------------------------------------------------------------------------------
# Outbound authentication, judged by a third party and read back over JMAP.
# ---------------------------------------------------------------------------------------
check_outbound() { # check_outbound <account>
  local account="$1" password subject body_file sent_at deadline report=''
  password="$(password_for "$account")" || {
    echo "no password available -- set $(password_var_for "$account") in .env, or run interactively"
    return 1
  }

  subject="verify-mail outbound probe $RUN_ID"
  body_file="$(mktemp)"
  {
    printf 'From: <%s>\r\n' "$account"
    printf 'To: <%s>\r\n' "$OUTBOUND_PROBE"
    printf 'Subject: %s\r\n' "$subject"
    printf 'Date: %s\r\n' "$(date -R)"
    printf '\r\n'
    printf 'Automated outbound authentication probe from verify-mail.sh.\r\n'
  } > "$body_file"

  sent_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  if ! curl -s --max-time 60 --url "smtps://$MAIL_HOST:465" --ssl-reqd \
        --user "$account:$password" \
        --mail-from "$account" --mail-rcpt "$OUTBOUND_PROBE" \
        --upload-file "$body_file" -o /dev/null; then
    rm -f "$body_file"
    echo "submission to $MAIL_HOST:465 as $account failed"
    return 1
  fi
  rm -f "$body_file"

  # Authenticate once, then poll the sending mailbox for the auto-responder's reply. The
  # wait is real: the report is generated only after the message is delivered and scanned.
  local context api_url account_id
  context="$(jmap_context "$account" "$password")"
  [[ "$context" == OK\ * ]] || { echo "${context#ERR }"; return 1; }
  context="${context#OK }"
  api_url="${context%% *}"
  account_id="${context##* }"

  # The request body is built by json.dumps with the account id passed in as an argument.
  # It used to be built once and the account id patched in with a string substitution on
  # `"accountId": null`, which silently depended on json.dumps' exact spacing -- a
  # formatting change would have left the filter unfilled and the check would have
  # reported "mail never left the server" for a purely local reason.
  local calls responses text
  calls="$("$PY" -c '
import json, sys
sent_at, account_id, probe_domain = sys.argv[1], sys.argv[2], sys.argv[3]
print(json.dumps({
  "using": ["urn:ietf:params:jmap:core", "urn:ietf:params:jmap:mail"],
  "methodCalls": [
    ["Email/query", {
      "accountId": account_id,
      "filter": {"from": probe_domain, "after": sent_at},
      "sort": [{"property": "receivedAt", "isAscending": False}],
      "limit": 5
    }, "q"],
    ["Email/get", {
      "accountId": account_id,
      "#ids": {"resultOf": "q", "name": "Email/query", "path": "/ids"},
      "properties": ["subject", "receivedAt", "textBody", "bodyValues"],
      "fetchTextBodyValues": True
    }, "g"]
  ]
}))
' "$sent_at" "$account_id" "${OUTBOUND_PROBE##*@}")"

  deadline=$(( $(date +%s) + OUTBOUND_WAIT ))
  while (( $(date +%s) < deadline )); do
    sleep 15
    responses="$(jmap_call "$account" "$password" "$api_url" "$calls")"
    [[ -n "$responses" ]] || continue

    text="$("$PY" -c '
import json, sys
try:
    doc = json.loads(sys.stdin.read() or "{}")
except ValueError:
    sys.exit(1)
for name, args, _ in doc.get("methodResponses", []):
    if name != "Email/get":
        continue
    for email in args.get("list", []):
        for value in (email.get("bodyValues") or {}).values():
            body = value.get("value") or ""
            if "Summary of Results" in body:
                sys.stdout.write(body)
                sys.exit(0)
sys.exit(1)
' <<<"$responses")" && { report="$text"; break; }
  done

  if [[ -z "$report" ]]; then
    echo "no authentication report from $OUTBOUND_PROBE within ${OUTBOUND_WAIT}s -- mail may not have left the server"
    return 1
  fi
  port25_verdict "$report" "$DOMAIN" || return 1
  echo "SPF and DKIM pass and are aligned with $DOMAIN, so DMARC passes"
}

# ---------------------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------------------
resolve_passwords "${ACCOUNTS[@]}"

printf '%sverify-mail %s%s  (run %s, DNS via %s)\n' "$C_DIM" "$DOMAIN" "$C_OFF" "$RUN_ID" "$DNS_BACKEND"
printf '%s  mail host %s, webmail %s, accounts: %s%s\n' \
  "$C_DIM" "$MAIL_HOST" "$WEBMAIL_HOST" "${ACCOUNTS[*]}" "$C_OFF"

section 'DNS'
check 'MX'    check_mx
check 'SPF'   check_spf
check 'DKIM'  check_dkim
check 'DMARC' check_dmarc

section 'TLS'
check "cert on $MAIL_HOST:443"    tls_on "$MAIL_HOST" 443
check "cert on $MAIL_HOST:465"    tls_on "$MAIL_HOST" 465
check "cert on $WEBMAIL_HOST:443" tls_on "$WEBMAIL_HOST" 443

section 'Web'
check 'webmail answers'  check_webmail_answers
check 'branding applied' check_branding
check 'CORS preflight'   check_cors_preflight

section 'Login'
for account in "${ACCOUNTS[@]}"; do
  check "JMAP login $account" check_login "$account"
done

section 'Delivery'
if skipping inbound; then
  skip 'inbound via MX' 'skipped by --skip'
else
  check "inbound via MX -> ${ACCOUNTS[0]}" check_inbound "${ACCOUNTS[0]}"
fi
if skipping outbound; then
  skip 'outbound authentication' 'skipped by --skip'
else
  check "outbound auth from ${ACCOUNTS[0]}" check_outbound "${ACCOUNTS[0]}"
fi

# ---------------------------------------------------------------------------------------
printf '\n%s----------------------------------------%s\n' "$C_DIM" "$C_OFF"
if (( FAIL_COUNT > 0 )); then
  printf '%s%s: %d passed, %d FAILED, %d skipped%s\n' \
    "$C_FAIL" "$DOMAIN" "$PASS_COUNT" "$FAIL_COUNT" "$SKIP_COUNT" "$C_OFF"
  printf '  failed: %s\n' "${FAILED_NAMES[*]}"
  exit 1
fi
printf '%s%s: %d passed, %d skipped%s\n' "$C_PASS" "$DOMAIN" "$PASS_COUNT" "$SKIP_COUNT" "$C_OFF"
if (( SKIP_COUNT > 0 )); then
  printf '  %snote: %d check(s) were skipped and proved nothing, so this is not a green run%s\n' \
    "$C_SKIP" "$SKIP_COUNT" "$C_OFF"
  exit 3
fi
exit 0
