#!/usr/bin/env bash
# Pure check functions for verify-mail.sh. No network, no globals, no side effects --
# every function takes the already-fetched text as an argument and returns 0 (pass) or
# 1 (fail), printing the reason on failure. That is what makes them testable, and
# scripts/test_verify_mail.sh covers them.
#
# The one rule the whole file enforces: AN EMPTY VALUE IS A FAILURE. A TXT lookup that
# returns nothing, a branding field that comes back "", a DKIM record with `p=` and no
# key -- each is a real outage dressed as a successful HTTP 200 or NOERROR, and each
# must be reported as a failure rather than skipped over. This mirrors the principle in
# vps/shared/test_render_ci.py: a blank secret is not a smaller failure than a missing one.
#
# Sourced by scripts/verify-mail.sh and scripts/test_verify_mail.sh. Not executable.

# ---------------------------------------------------------------------------------------
# require_nonempty <label> <value>
# Whitespace-only counts as empty: `dig +short` prints a blank line for a name that exists
# with no data of the requested type, and that must not read as "found it".
# ---------------------------------------------------------------------------------------
require_nonempty() {
  local label="$1" value="${2-}"
  if [[ -z "${value//[[:space:]]/}" ]]; then
    echo "$label is empty or absent"
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------------------
# mx_pick <mx-answer-lines>
# Input is one "<preference> <target>" per line, as both `dig +short MX` and the DoH
# fallback produce. Prints the lowest-preference target with its trailing dot stripped.
# A null MX (RFC 7505, `0 .`) is an explicit "this domain accepts no mail" and is a
# failure here, not a target.
# ---------------------------------------------------------------------------------------
mx_pick() {
  local records="${1-}"
  require_nonempty 'MX record set' "$records" || return 1

  local best_pref='' best_target='' pref target line
  while IFS= read -r line; do
    line="${line//$'\r'/}"
    [[ -z "${line//[[:space:]]/}" ]] && continue
    pref="$(awk '{print $1}' <<<"$line")"
    target="$(awk '{print $2}' <<<"$line")"
    [[ "$pref" =~ ^[0-9]+$ ]] || continue
    [[ -z "$target" ]] && continue
    target="${target%.}"
    if [[ -z "$target" ]]; then
      echo "MX is a null MX (RFC 7505) -- this domain declares that it accepts no mail"
      return 1
    fi
    if [[ -z "$best_pref" || "$pref" -lt "$best_pref" ]]; then
      best_pref="$pref"
      best_target="$target"
    fi
  done <<<"$records"

  if [[ -z "$best_target" ]]; then
    echo "no usable MX record found in: $records"
    return 1
  fi
  printf '%s\n' "$best_target"
}

# ---------------------------------------------------------------------------------------
# spf_check <txt-record> <expected-all-qualifier>
# The expected qualifier comes from the domain's config file, because the posture is a
# per-domain decision: kaiteki.my is hardfail `-all`, but reservetoday.app must stay on
# `~all` while Clerk sends its auth mail, and silently "upgrading" it would put password
# resets in spam.
# ---------------------------------------------------------------------------------------
spf_check() {
  local record="${1-}" expected="${2-}"
  require_nonempty 'SPF record' "$record" || return 1

  record="${record//\"/}"
  if [[ "$record" != v=spf1* ]]; then
    echo "SPF record does not start with v=spf1: $record"
    return 1
  fi

  local actual
  actual="$(grep -oE '[-~?+]?all([[:space:]]|$)' <<<"$record" | tail -n1)"
  actual="${actual//[[:space:]]/}"
  if [[ -z "$actual" ]]; then
    echo "SPF record has no 'all' term, so it authorises nothing conclusively: $record"
    return 1
  fi
  [[ "$actual" == 'all' ]] && actual='+all'

  # `?all` and `+all` are never a posture we accept, whatever the config asks for: one
  # makes SPF advisory and the other authorises the entire internet to send as us.
  case "$actual" in
    '?all'|'+all')
      echo "SPF ends in '$actual', which authorises forged senders -- never acceptable"
      return 1
      ;;
  esac

  if [[ "$actual" != "$expected" ]]; then
    echo "SPF posture is '$actual', expected '$expected'"
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------------------
# tag_value <record> <tag>
# Pulls `tag=value` out of a semicolon-separated DNS record (DMARC, DKIM). Anchored on a
# start-or-separator boundary so that reading `p=` never matches the `p` inside `sp=` or
# `adkim=`. Prints the value; returns 1 only when the tag is absent (an empty value is
# printed as empty and judged by the caller, which is the distinction that matters).
# ---------------------------------------------------------------------------------------
tag_value() {
  local record="${1-}" tag="${2-}" field
  record="${record//\"/}"
  while IFS= read -r field; do
    field="${field#"${field%%[![:space:]]*}"}"   # ltrim
    field="${field%"${field##*[![:space:]]}"}"   # rtrim
    if [[ "$field" == "$tag="* ]]; then
      printf '%s\n' "${field#"$tag="}"
      return 0
    fi
  done < <(tr ';' '\n' <<<"$record")
  return 1
}

# ---------------------------------------------------------------------------------------
# dmarc_check <txt-record> <expected-policy> <expected-rua-address>
# A DMARC record with no `rua=` is the common half-configured case: the policy is
# published but nobody ever sees a report, so a spoofing run against the domain is
# invisible. Treated as a failure. The address is asserted too, as the whole `rua` value:
# every domain reports to ONE inbox (#14), and a second collector left in the list -- a
# registrar's, typically -- splits the reports without ever failing a presence check.
# ---------------------------------------------------------------------------------------
dmarc_check() {
  local record="${1-}" expected="${2-}" expected_rua="${3-}"
  require_nonempty 'DMARC record' "$record" || return 1
  require_nonempty 'expected DMARC rua address' "$expected_rua" || return 1

  record="${record//\"/}"
  if [[ "$record" != v=DMARC1* ]]; then
    echo "DMARC record does not start with v=DMARC1: $record"
    return 1
  fi

  local policy rua
  if ! policy="$(tag_value "$record" 'p')"; then
    echo "DMARC record has no p= policy tag: $record"
    return 1
  fi
  if [[ "$policy" != "$expected" ]]; then
    echo "DMARC policy is 'p=${policy:-<empty>}', expected 'p=$expected'"
    return 1
  fi

  if ! rua="$(tag_value "$record" 'rua')"; then
    echo "DMARC record has no rua= address, so aggregate reports go nowhere"
    return 1
  fi
  require_nonempty 'DMARC rua address' "$rua" || return 1
  if [[ "$rua" != mailto:* ]]; then
    echo "DMARC rua is not a mailto: URI: $rua"
    return 1
  fi
  if [[ "$rua" != "mailto:$expected_rua" ]]; then
    echo "DMARC rua is '$rua', expected 'mailto:$expected_rua'"
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------------------
# dkim_check <txt-record>
# `p=` with an empty value is the DKIM revocation syntax -- a perfectly valid record that
# tells every receiver to reject signatures from this selector. It resolves, so a
# "does it resolve" check passes it; it must fail here.
# ---------------------------------------------------------------------------------------
dkim_check() {
  local record="${1-}"
  require_nonempty 'DKIM record' "$record" || return 1

  record="${record//\"/}"
  if [[ "$record" != v=DKIM1* ]]; then
    echo "DKIM record does not start with v=DKIM1: $record"
    return 1
  fi

  local keytype pubkey
  keytype="$(tag_value "$record" 'k')" || keytype='rsa'   # k= is optional, default rsa
  case "$keytype" in
    rsa|ed25519) ;;
    *) echo "DKIM key type 'k=$keytype' is not one this estate publishes (rsa, ed25519)"; return 1 ;;
  esac

  if ! pubkey="$(tag_value "$record" 'p')"; then
    echo "DKIM record has no p= public key tag: $record"
    return 1
  fi
  if [[ -z "${pubkey//[[:space:]]/}" ]]; then
    echo "DKIM record has an empty p= tag -- that is the REVOKED form, not a working key"
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------------------
# san_covers <san-list> <name>
# <san-list> is openssl's rendering: "DNS:mail.kaiteki.my, DNS:webmail.kaiteki.my".
# Matching is exact or single-label wildcard, per RFC 6125 -- never a suffix test, or
# "mail.notkaiteki.my" would be read as covering "mail.kaiteki.my".
# ---------------------------------------------------------------------------------------
san_covers() {
  local sans="${1-}" name="${2-}"
  require_nonempty 'certificate SAN list' "$sans" || return 1
  require_nonempty 'hostname to match' "$name" || return 1

  sans="$(tr '[:upper:]' '[:lower:]' <<<"$sans")"
  name="$(tr '[:upper:]' '[:lower:]' <<<"$name")"
  name="${name%.}"

  local entry
  while IFS= read -r entry; do
    entry="${entry//[[:space:]]/}"
    # The list was lowercased above, so the openssl "DNS:" prefix is "dns:" here.
    [[ "$entry" == dns:* ]] || continue
    entry="${entry#dns:}"
    entry="${entry%.}"
    [[ -z "$entry" ]] && continue

    if [[ "$entry" == "$name" ]]; then
      return 0
    fi
    if [[ "$entry" == '*.'* ]]; then
      # One label only: *.kaiteki.my covers mail.kaiteki.my, but not kaiteki.my itself
      # and not a.mail.kaiteki.my.
      local suffix="${entry#'*.'}" head
      if [[ "$name" == *".$suffix" ]]; then
        head="${name%".$suffix"}"
        [[ -n "$head" && "$head" != *.* ]] && return 0
      fi
    fi
  done < <(tr ',' '\n' <<<"$sans")

  echo "certificate does not cover '$name'; it presents: $sans"
  return 1
}

# ---------------------------------------------------------------------------------------
# json_str <json> <key>
# Reads one scalar field from the flat JSON that Bulwark's /api/config returns: a string,
# or one of the bare booleans (`"loginShowVersion":false` is how "version hidden" comes
# back, and it is asserted like any other field). Deliberately not a JSON parser and not
# jq: this keeps verify-mail.sh runnable on a bare laptop with only curl and openssl.
# Returns 1 when the key is ABSENT and prints the value (possibly empty) when it is
# present -- the caller needs to tell those two apart, because "field missing" and "field
# blank" are different bugs. Booleans print as the literal words true / false.
# ---------------------------------------------------------------------------------------
json_str() {
  local json="${1-}" key="${2-}" match
  match="$(grep -oE "\"$key\"[[:space:]]*:[[:space:]]*(\"[^\"]*\"|true|false)" <<<"$json" | head -n1)" || true
  if [[ -z "$match" ]]; then
    return 1
  fi
  match="${match#*:}"
  match="${match#"${match%%[![:space:]]*}"}"
  match="${match#\"}"
  match="${match%\"}"
  printf '%s\n' "$match"
}

# ---------------------------------------------------------------------------------------
# branding_check <config-json> <field> <expected>
# An unbranded Bulwark answers 200 with stock logos and empty strings for the company
# name, which is exactly why "the endpoint responded" is not the check. The field must be
# present, non-empty, equal to what the domain's config expects, and never a stock value:
# neither the product name nor one of Bulwark's own logo files, which is what every URL
# field points at on an instance that has had nothing mounted over them.
# ---------------------------------------------------------------------------------------
branding_check() {
  local json="${1-}" field="${2-}" expected="${3-}"
  require_nonempty 'branding config response' "$json" || return 1

  local actual
  if ! actual="$(json_str "$json" "$field")"; then
    echo "branding field '$field' is absent from the config response"
    return 1
  fi
  if [[ -z "${actual//[[:space:]]/}" ]]; then
    echo "branding field '$field' is present but empty -- Bulwark is still unbranded here"
    return 1
  fi
  # Stock Bulwark values are never a pass, even if a config file asks for them.
  case "$field:$actual" in
    appName:Bulwark)
      echo "branding field 'appName' is the stock 'Bulwark' -- no branding applied"
      return 1
      ;;
    *:/branding/Bulwark_*)
      echo "branding field '$field' is the stock Bulwark asset '$actual' -- no logo applied"
      return 1
      ;;
  esac
  if [[ "$actual" != "$expected" ]]; then
    echo "branding field '$field' is '$actual', expected '$expected'"
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------------------
# aligned_with <candidate-domain> <organisational-domain>
# DMARC relaxed alignment: the authenticated domain must be the domain itself or a
# subdomain of it. Used for both the SPF envelope domain and the DKIM d= tag.
# ---------------------------------------------------------------------------------------
aligned_with() {
  local candidate="${1-}" domain="${2-}"
  candidate="$(tr '[:upper:]' '[:lower:]' <<<"${candidate%.}")"
  domain="$(tr '[:upper:]' '[:lower:]' <<<"${domain%.}")"
  [[ -n "$candidate" && -n "$domain" ]] || return 1
  [[ "$candidate" == "$domain" || "$candidate" == *".$domain" ]]
}

# ---------------------------------------------------------------------------------------
# port25_verdict <report-text> <domain>
# Judges the reply from the check-auth@verifier.port25.com auto-responder, which is how
# the outbound leg is proven: the message really left our server, crossed the internet,
# and was authenticated by a third party rather than by us grepping our own logs.
#
# DMARC is not reported by name, so it is DERIVED, which is also the stricter test: DMARC
# passes when SPF or DKIM passes AND is aligned with the From domain, so requiring both to
# pass and both to align is a superset of "DMARC passed".
#
# A `permerror` DKIM line is expected and tolerated -- old verifiers cannot evaluate the
# Ed25519 signature Stalwart also emits -- but only alongside a real pass. Permerror on
# its own is a failure, never a pass.
# ---------------------------------------------------------------------------------------
port25_verdict() {
  local report="${1-}" domain="${2-}"
  require_nonempty 'authentication report' "$report" || return 1

  if ! grep -q 'Summary of Results' <<<"$report"; then
    echo "report has no 'Summary of Results' section -- it is not a port25 reply"
    return 1
  fi

  # --- SPF result ---
  local spf
  spf="$(grep -oE '^SPF check:[[:space:]]*[a-z]+' <<<"$report" | head -n1 | awk '{print $NF}')"
  if [[ -z "$spf" ]]; then
    echo "report contains no SPF check result"
    return 1
  fi
  if [[ "$spf" != 'pass' ]]; then
    echo "SPF check is '$spf', expected 'pass'"
    return 1
  fi

  # --- DKIM results: at least one pass, and no outright fail ---
  local dkim_results dkim_pass=0 result
  dkim_results="$(grep -oE '^DKIM check:[[:space:]]*[a-z]+' <<<"$report" | awk '{print $NF}')"
  if [[ -z "$dkim_results" ]]; then
    echo "report contains no DKIM check result"
    return 1
  fi
  while IFS= read -r result; do
    [[ -z "$result" ]] && continue
    case "$result" in
      pass) dkim_pass=1 ;;
      permerror|neutral) ;;   # tolerated only because a pass is also required below
      *) echo "DKIM check reported '$result'"; return 1 ;;
    esac
  done <<<"$dkim_results"
  if (( dkim_pass == 0 )); then
    echo "no DKIM signature passed (results: $(tr '\n' ' ' <<<"$dkim_results"))"
    return 1
  fi

  # --- SPF alignment: the envelope sender must belong to this domain ---
  local mailfrom envelope_domain
  mailfrom="$(grep -oE '^mail-from:[[:space:]]*[^[:space:]]+' <<<"$report" | head -n1 | awk '{print $NF}')"
  if [[ -z "$mailfrom" ]]; then
    echo "report does not state the mail-from address, so SPF alignment cannot be judged"
    return 1
  fi
  envelope_domain="${mailfrom##*@}"
  if ! aligned_with "$envelope_domain" "$domain"; then
    echo "SPF passed but for '$envelope_domain', which is not aligned with '$domain'"
    return 1
  fi

  # --- DKIM alignment: some signing domain must belong to this domain ---
  local d_tags aligned=0 d
  d_tags="$(grep -oE '(^|[[:space:]])d=[A-Za-z0-9._-]+' <<<"$report" | sed 's/.*d=//')"
  if [[ -z "$d_tags" ]]; then
    echo "report states no DKIM d= signing domain, so DKIM alignment cannot be judged"
    return 1
  fi
  while IFS= read -r d; do
    [[ -z "$d" ]] && continue
    if aligned_with "$d" "$domain"; then aligned=1; fi
  done <<<"$d_tags"
  if (( aligned == 0 )); then
    echo "DKIM passed but signed as '$(tr '\n' ' ' <<<"$d_tags")', not aligned with '$domain'"
    return 1
  fi

  return 0
}
