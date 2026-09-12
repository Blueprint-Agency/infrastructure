#!/usr/bin/env bash
# Self-check for scripts/lib/mail-checks.sh -- the pure, parse-only half of verify-mail.sh.
# Wired as a CI step alongside vps/shared/test_render_ci.py, and follows the same central
# principle as that test: an EMPTY value is a FAILURE, not a smaller success. A DNS record
# that resolves to nothing, or a branding field that comes back "", must fail the check
# rather than pass quietly -- so most of the cases below are the empty/absent ones.
#
# Only the pure functions are covered. Everything network-facing (DNS, SMTP, TLS, JMAP)
# lives in verify-mail.sh itself and is proven by running it against a real domain.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/mail-checks.sh
source "$HERE/lib/mail-checks.sh"

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
    printf 'FAIL: %s\n      expected output to contain: %s\n      got: %s\n' \
      "$name" "$want" "$out" >&2
  fi
}

# eq <name> <expected-stdout> <function> [args...]
eq() {
  local name="$1" want="$2"; shift 2
  local out
  out="$("$@" 2>/dev/null)"
  if [[ "$out" == "$want" ]]; then
    PASSED=$((PASSED + 1))
  else
    FAILED=$((FAILED + 1))
    printf 'FAIL: %s\n      expected: %s\n      got:      %s\n' "$name" "$want" "$out" >&2
  fi
}

# --------------------------------------------------------------------------------------
# require_nonempty -- the rule the whole script is built on
# --------------------------------------------------------------------------------------
ok  'require_nonempty accepts a value'          0 require_nonempty 'MX target' 'mail.kaiteki.my'
ok  'require_nonempty rejects empty string'     1 require_nonempty 'MX target' ''
ok  'require_nonempty rejects whitespace only'  1 require_nonempty 'MX target' '   '
says 'require_nonempty names the thing' 'MX target' require_nonempty 'MX target' ''

# --------------------------------------------------------------------------------------
# mx_pick -- lowest preference wins, trailing dot stripped
# --------------------------------------------------------------------------------------
eq  'mx_pick single record'      'mail.kaiteki.my'  mx_pick '10 mail.kaiteki.my.'
eq  'mx_pick lowest preference'  'primary.example'  mx_pick $'20 backup.example.\n10 primary.example.'
eq  'mx_pick tolerates no dot'   'mail.kaiteki.my'  mx_pick '10 mail.kaiteki.my'
ok  'mx_pick fails on no records'          1 mx_pick ''
ok  'mx_pick fails on a null MX (RFC 7505)' 1 mx_pick '0 .'

# --------------------------------------------------------------------------------------
# spf_check <record> <expected-all-qualifier>
# --------------------------------------------------------------------------------------
ok  'spf hardfail as expected'      0 spf_check 'v=spf1 mx -all' '-all'
ok  'spf softfail as expected'      0 spf_check 'v=spf1 mx ~all' '~all'
ok  'spf posture mismatch fails'    1 spf_check 'v=spf1 mx ~all' '-all'
ok  'spf empty record fails'        1 spf_check '' '-all'
ok  'spf without v=spf1 fails'      1 spf_check 'mx -all' '-all'
ok  'spf with no all term fails'    1 spf_check 'v=spf1 mx' '-all'
ok  'spf neutral is never ok'       1 spf_check 'v=spf1 mx ?all' '-all'
says 'spf names the mismatch' '~all' spf_check 'v=spf1 mx ~all' '-all'

# --------------------------------------------------------------------------------------
# dmarc_check <record> <expected-policy> <expected-rua-address>
# The rua address is asserted, not just its presence: "every domain reports to one inbox"
# (#14) is only true while each record says so, and a registrar-style collector left
# alongside ours would split the reports without ever failing a presence check.
# --------------------------------------------------------------------------------------
RUA='admin@blueprintdigital.my'
ok  'dmarc reject as expected'     0 dmarc_check "v=DMARC1; p=reject; rua=mailto:$RUA; fo=1" 'reject' "$RUA"
ok  'dmarc quarantine as expected' 0 dmarc_check "v=DMARC1; p=quarantine; adkim=r; aspf=r; rua=mailto:$RUA;" 'quarantine' "$RUA"
ok  'dmarc policy mismatch fails'  1 dmarc_check "v=DMARC1; p=none; rua=mailto:$RUA" 'reject' "$RUA"
ok  'dmarc empty record fails'     1 dmarc_check '' 'reject' "$RUA"
ok  'dmarc without v=DMARC1 fails' 1 dmarc_check "p=reject; rua=mailto:$RUA" 'reject' "$RUA"
ok  'dmarc without rua fails'      1 dmarc_check 'v=DMARC1; p=reject' 'reject' "$RUA"
ok  'dmarc with empty rua fails'   1 dmarc_check 'v=DMARC1; p=reject; rua=' 'reject' "$RUA"
ok  'dmarc rua must be a mailto'   1 dmarc_check "v=DMARC1; p=reject; rua=$RUA" 'reject' "$RUA"
ok  'dmarc rua wrong inbox fails'  1 dmarc_check 'v=DMARC1; p=reject; rua=mailto:admin@kaiteki.my; fo=1' 'reject' "$RUA"
says 'dmarc rua mismatch names both' "rua is 'mailto:admin@kaiteki.my', expected 'mailto:$RUA'" \
  dmarc_check 'v=DMARC1; p=reject; rua=mailto:admin@kaiteki.my; fo=1' 'reject' "$RUA"
ok  'dmarc second collector fails'  1 dmarc_check "v=DMARC1; p=reject; rua=mailto:$RUA,mailto:dmarc_rua@onsecureserver.net" 'reject' "$RUA"
ok  'dmarc blank expected rua fails' 1 dmarc_check "v=DMARC1; p=reject; rua=mailto:$RUA" 'reject' ''

# --------------------------------------------------------------------------------------
# dkim_check <record>
# --------------------------------------------------------------------------------------
ok  'dkim rsa key is well formed'   0 dkim_check 'v=DKIM1; k=rsa; p=MIIBIjANBgkqh'
ok  'dkim ed25519 key is well formed' 0 dkim_check 'v=DKIM1; k=ed25519; p=11qYAYKxCrfVS'
ok  'dkim without k= defaults to rsa' 0 dkim_check 'v=DKIM1; p=MIIBIjANBgkqh'
ok  'dkim empty record fails'       1 dkim_check ''
ok  'dkim without v=DKIM1 fails'    1 dkim_check 'k=rsa; p=MIIBIjANBgkqh'
ok  'dkim with empty p= is revoked' 1 dkim_check 'v=DKIM1; k=rsa; p='
ok  'dkim with no p= at all fails'  1 dkim_check 'v=DKIM1; k=rsa'
ok  'dkim unknown key type fails'   1 dkim_check 'v=DKIM1; k=banana; p=MIIBIjANBgkqh'

# --------------------------------------------------------------------------------------
# san_covers <san-list> <name>
# --------------------------------------------------------------------------------------
SANS='DNS:mail.kaiteki.my, DNS:webmail.kaiteki.my'
ok  'san exact match'                0 san_covers "$SANS" 'mail.kaiteki.my'
ok  'san exact match, second entry'  0 san_covers "$SANS" 'webmail.kaiteki.my'
ok  'san is case insensitive'        0 san_covers "$SANS" 'MAIL.Kaiteki.My'
ok  'san missing name fails'         1 san_covers "$SANS" 'mail.blueprintdigital.my'
ok  'san empty list fails'           1 san_covers '' 'mail.kaiteki.my'
ok  'wildcard covers one label'      0 san_covers 'DNS:*.kaiteki.my' 'mail.kaiteki.my'
ok  'wildcard does not cover apex'   1 san_covers 'DNS:*.kaiteki.my' 'kaiteki.my'
ok  'wildcard does not cover two labels' 1 san_covers 'DNS:*.kaiteki.my' 'a.mail.kaiteki.my'
# A substring must never be mistaken for a match -- "notkaiteki.my" ends with "kaiteki.my".
ok  'san rejects a suffix lookalike' 1 san_covers 'DNS:mail.notkaiteki.my' 'mail.kaiteki.my'

# --------------------------------------------------------------------------------------
# branding_check <config-json> <field> <expected>
# The endpoint returning "" for a field is the exact failure mode this guards: an
# unbranded Bulwark answers 200 with empty strings, which must not read as success.
# --------------------------------------------------------------------------------------
CFG='{"appName":"Kaiteki Mail","loginCompanyName":"","faviconUrl":"/branding/Bulwark_Favicon.svg"}'
ok  'branding field matches'          0 branding_check "$CFG" 'appName' 'Kaiteki Mail'
ok  'branding field mismatch fails'   1 branding_check "$CFG" 'appName' 'Blueprint Mail'
ok  'branding empty field fails'      1 branding_check "$CFG" 'loginCompanyName' 'Blueprint Digital'
ok  'branding absent field fails'     1 branding_check "$CFG" 'nosuchField' 'anything'
ok  'branding stock appName fails'    1 branding_check '{"appName":"Bulwark"}' 'appName' 'Bulwark'
ok  'branding empty body fails'       1 branding_check '' 'appName' 'Kaiteki Mail'
# "Version hidden" is a boolean in the response, not a string: `"loginShowVersion":false`.
# A string-only reader reports it absent, and the check would fail on a correctly branded
# instance -- so booleans are read too, and compared as the literal words true/false.
CFG_BOOL='{"appName":"Blueprint Mail","loginShowVersion":false,"loginShowTotp":true}'
ok  'branding boolean false matches'  0 branding_check "$CFG_BOOL" 'loginShowVersion' 'false'
ok  'branding boolean true matches'   0 branding_check "$CFG_BOOL" 'loginShowTotp' 'true'
ok  'branding boolean mismatch fails' 1 branding_check "$CFG_BOOL" 'loginShowVersion' 'true'
# The stock logos are the other way an unbranded instance answers 200: every URL is set,
# just to Bulwark's own files. A config that "expects" a stock path must still fail.
ok  'branding stock logo fails'       1 branding_check "$CFG" 'faviconUrl' '/branding/Bulwark_Favicon.svg'
ok  'branding own logo passes'        0 branding_check '{"loginLogoDarkUrl":"/branding/blueprint/login-dark.svg"}' 'loginLogoDarkUrl' '/branding/blueprint/login-dark.svg'

# --------------------------------------------------------------------------------------
# port25_verdict <report-text> <domain> -- outbound auth AND DMARC alignment
# --------------------------------------------------------------------------------------
read -r -d '' GOOD_REPORT <<'REPORT' || true
==========================================================
Summary of Results
==========================================================
SPF check:          pass
"iprev" check:      pass
DKIM check:         pass
DKIM check:         permerror
SpamAssassin check: ham

==========================================================
Details:
==========================================================

HELO hostname:  mail.kaiteki.my
Source IP:      187.127.122.41
mail-from:      admin@kaiteki.my

----------------------------------------------------------
DKIM check details:
----------------------------------------------------------
DKIM-signature record #1:
d=kaiteki.my
result = pass
REPORT

ok 'port25 pass + aligned' 0 port25_verdict "$GOOD_REPORT" 'kaiteki.my'

# Mutations go through sed rather than ${var/old/new}: the report is column-aligned, so a
# literal pattern with a guessed run of spaces silently fails to match and the "mutated"
# copy comes back identical -- a test that then passes for the wrong reason.
mutate() { sed -E "$1" <<<"$GOOD_REPORT"; }

# Ed25519 alone yields permerror on old verifiers; that must not be read as a pass.
ONLY_PERMERROR="$(mutate 's/^(DKIM check:[[:space:]]*)pass/\1permerror/')"
ok 'port25 permerror only fails' 1 port25_verdict "$ONLY_PERMERROR" 'kaiteki.my'

SPF_FAIL="$(mutate 's/^(SPF check:[[:space:]]*)pass/\1fail/')"
ok 'port25 spf fail fails' 1 port25_verdict "$SPF_FAIL" 'kaiteki.my'

# DKIM passes but signs as another domain -> DMARC would not be aligned.
UNALIGNED_DKIM="$(mutate 's/d=kaiteki\.my/d=mailer.example.net/')"
ok 'port25 unaligned dkim fails' 1 port25_verdict "$UNALIGNED_DKIM" 'kaiteki.my'

# SPF passes but for a different envelope domain -> not aligned either.
UNALIGNED_SPF="$(mutate 's/^(mail-from:[[:space:]]*).*/\1bounce@sendgrid.net/')"
ok 'port25 unaligned spf fails' 1 port25_verdict "$UNALIGNED_SPF" 'kaiteki.my'

ok 'port25 empty report fails' 1 port25_verdict '' 'kaiteki.my'
ok 'port25 truncated report fails' 1 port25_verdict 'Summary of Results' 'kaiteki.my'

# Subdomain alignment is relaxed-mode OK for DMARC, and we accept it.
SUBDOMAIN="$(mutate 's/d=kaiteki\.my/d=mail.kaiteki.my/')"
ok 'port25 subdomain dkim is aligned' 0 port25_verdict "$SUBDOMAIN" 'kaiteki.my'

# --------------------------------------------------------------------------------------
# The expectations files themselves. verify-mail.sh dies at startup on a blank key, but
# only for the one domain being run -- a conf for a domain nobody has run yet could sit
# broken in the repo until the cutover it exists for. So every conf is checked here, and
# every domain that is LIVE on the platform must have one.
# --------------------------------------------------------------------------------------
CONF_KEYS='MAIL_HOST WEBMAIL_HOST EXPECT_MX EXPECT_JMAP_HOST EXPECT_SPF_ALL EXPECT_DMARC_POLICY EXPECT_DMARC_RUA DKIM_SELECTORS BRANDING_EXPECT DEFAULT_ACCOUNTS INVENTORY_ACCOUNT'

# conf_complete <file> -- every required key set and non-blank, in a subshell so the confs
# cannot leak into each other.
conf_complete() (
  # shellcheck disable=SC1090
  source "$1" || exit 1
  for key in $CONF_KEYS; do
    value="${!key-}"
    [[ -n "${value//[[:space:]]/}" ]] || { echo "$1 sets $key to an empty value"; exit 1; }
  done
)

for conf in "$HERE"/verify-mail.d/*.conf; do
  ok "conf complete: $(basename "$conf")" 0 conf_complete "$conf"
done
for domain in kaiteki.my blueprintdigital.my reservetoday.app; do
  ok "conf exists for $domain" 0 test -f "$HERE/verify-mail.d/$domain.conf"
done

# --------------------------------------------------------------------------------------
printf '\n%s\n' "----------------------------------------"
if (( FAILED > 0 )); then
  printf 'test_verify_mail: %d passed, %d FAILED\n' "$PASSED" "$FAILED" >&2
  exit 1
fi
printf 'test_verify_mail: %d passed\n' "$PASSED"
