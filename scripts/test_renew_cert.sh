#!/usr/bin/env bash
# Self-check for vps/bpvps1/stacks/stalwart/renew-cert.sh -- the declaration half.
#
# Wired as a CI step alongside vps/shared/test_render_ci.py and scripts/test_verify_mail.sh.
#
# WHY THIS TEST EXISTS. The certificate on bpvps1 carries four names across two zones, but
# acme.sh keys its whole state directory on the FIRST name it was issued with
# (./acme/mail.kaiteki.my_ecc/). renew-cert.sh publishes from that path and the daily host
# cron calls the script by its own fixed path. So reordering the name list -- which looks
# like a cosmetic edit, and which a reviewer would wave through -- silently sends acme.sh to
# a NEW state directory while the publish step keeps reading the old one. Nothing errors. The
# certificate simply stops being refreshed and expires 90 days later, taking mail TLS and
# every web UI on the host with it.
#
# The script is written so its declarations can be sourced without running anything, which is
# the only reason these assertions are possible at all.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../vps/bpvps1/stacks/stalwart/renew-cert.sh"

PASSED=0
FAILED=0

eq() { # eq <name> <expected> <actual>
  if [[ "$3" == "$2" ]]; then
    PASSED=$((PASSED + 1))
  else
    FAILED=$((FAILED + 1))
    printf 'FAIL: %s\n      expected: %s\n      got:      %s\n' "$1" "$2" "$3" >&2
  fi
}

has() { # has <name> <needle> <haystack>
  if [[ "$3" == *"$2"* ]]; then
    PASSED=$((PASSED + 1))
  else
    FAILED=$((FAILED + 1))
    printf 'FAIL: %s\n      expected to contain: %s\n      got: %s\n' "$1" "$2" "$3" >&2
  fi
}

[[ -f "$SCRIPT" ]] || { printf 'test_renew_cert: no script at %s\n' "$SCRIPT" >&2; exit 1; }

# A canary for the source guard. The script must return before its first side effect; if that
# guard ever breaks, sourcing here would run a real `docker run neilpang/acme.sh --issue`
# against Cloudflare -- docker exists on GitHub runners -- with no token. This variable is
# only ever assigned below the guard, so it must still be unset afterwards.
unset RENEW_CERT_RAN 2>/dev/null || true

# shellcheck source=../vps/bpvps1/stacks/stalwart/renew-cert.sh
source "$SCRIPT"

# `set -e` is shell-global and `source` sets it in THIS shell, overriding the header above.
# Left alone, the first assertion built on a command that legitimately returns non-zero would
# abort the run mid-file: no summary line, no indication of which assertion died, which is
# the worst possible diagnostic for a test guarding a silent 90-day failure.
set +e

eq 'sourcing runs nothing below the guard' '' "${RENEW_CERT_RAN-}"

# --------------------------------------------------------------------------------------
# The name list
# --------------------------------------------------------------------------------------
eq 'four names are requested' 4 "${#CERT_NAMES[@]}"

# The primary. This is the load-bearing one: it names the acme state directory.
eq 'primary name is unchanged' 'mail.kaiteki.my' "${CERT_NAMES[0]}"

joined=" ${CERT_NAMES[*]} "
has 'kaiteki mail name present'     ' mail.kaiteki.my '             "$joined"
has 'kaiteki webmail name present'  ' webmail.kaiteki.my '          "$joined"
has 'blueprint mail name added'     ' mail.blueprintdigital.my '    "$joined"
has 'blueprint webmail name added'  ' webmail.blueprintdigital.my ' "$joined"

# A wildcard as the primary would make ACME_STATE_DIR a path acme.sh never creates.
case "${CERT_NAMES[0]}" in
  \*) FAILED=$((FAILED + 1)); printf 'FAIL: primary name must not be a wildcard\n' >&2 ;;
  *)  PASSED=$((PASSED + 1)) ;;
esac

# --------------------------------------------------------------------------------------
# The CA. acme.sh only reuses the recorded CA when it is RENEWING; a changed name list is a
# fresh issuance and falls back to acme.sh's own default, which is ZeroSSL. Observed for real
# on 2026-09-12 while adding the two Blueprint names: the run died on "Please update your
# account with an email address first". Losing this is not a loud failure forever -- it is a
# loud failure until someone registers a ZeroSSL account, and then it is a silent CA swap on
# production mail TLS.
# --------------------------------------------------------------------------------------
eq 'CA is pinned to Let'"'"'s Encrypt' 'letsencrypt' "$CERT_CA"

# The acme.sh image is pinned by digest, because this script depends on acme.sh's exit-code
# contract (rc 2 = RENEW_SKIP), which is an implementation detail and not a public API.
has 'acme.sh image is pinned by digest' '@sha256:' "$ACME_IMAGE"

# --------------------------------------------------------------------------------------
# The state directory and the primary must agree. If they ever disagree, acme.sh renews one
# certificate and the publish step ships a different, stale one.
# --------------------------------------------------------------------------------------
eq 'state dir is derived from the primary' "$D/acme/${CERT_NAMES[0]}_ecc" "$ACME_STATE_DIR"
eq 'publish reads the fullchain from that state dir' "$ACME_STATE_DIR/fullchain.cer" "$SRC"
eq 'published cert path' "$D/certs/fullchain.pem" "$PUBLISHED"

# --------------------------------------------------------------------------------------
# The cron contract: the stack dir the script works from is the one the host crontab, the
# compose file and CI all assume.
# --------------------------------------------------------------------------------------
eq 'stack dir unchanged' '/root/stacks/stalwart' "$D"

# The Traefik reload seam. Traefik watches this file, not the certificates it names, so
# touching it is what makes a renewal reach port 443. Point it at the wrong path and the
# renewal still "succeeds" while the web UIs quietly keep serving the expired certificate.
eq 'traefik dynamic config path' '/root/stacks/traefik/dynamic/stalwart.yml' "$TRAEFIK_DYNAMIC"

# --------------------------------------------------------------------------------------
# No duplicates. acme.sh accepts a repeated -d and still issues, so a duplicate never
# announces itself -- but it means someone appended instead of editing, and the next append
# is the one that lands on the primary.
# --------------------------------------------------------------------------------------
uniq_count="$(printf '%s\n' "${CERT_NAMES[@]}" | sort -u | wc -l | tr -d ' ')"
eq 'no duplicate names' "${#CERT_NAMES[@]}" "$uniq_count"

# --------------------------------------------------------------------------------------
# Flags the sourced variables cannot see. A variable can hold the right value while the flag
# that uses it has been deleted from the command line, so assert against the source text.
# --keylength ec-256 matters as much as the CA: it is what puts acme.sh's state in the `_ecc`
# directory that ACME_STATE_DIR and `--install-cert --ecc` both point at. Drop it and acme.sh
# renews into `mail.kaiteki.my/` while this script publishes from `mail.kaiteki.my_ecc/` --
# the same silent 90-day expiry, by a different route, with every assertion above still green.
# --------------------------------------------------------------------------------------
SRC_TEXT="$(cat "$SCRIPT")"
has 'the CA flag is actually passed'      '--server "$CERT_CA"' "$SRC_TEXT"
has 'the ECC keylength is actually passed' '--keylength ec-256' "$SRC_TEXT"
has 'install reads the ECC bundle'         '--ecc'              "$SRC_TEXT"
has 'the pinned image is what runs'        '"$ACME_IMAGE"'      "$SRC_TEXT"

# --------------------------------------------------------------------------------------
# san_names_from and want_names_from: the comparison that decides whether to force a re-issue.
#
# This is the check that keeps the certificate honest, because acme.sh's own record of what it
# issued is written before the order succeeds and can therefore be a lie. If the normalisation
# is wrong in the harmless-looking direction -- names that never compare equal -- the script
# force-renews every night: five duplicate certificates into a Let's Encrypt rate limit, and a
# nightly Stalwart restart on production mail. That is exactly what `tr -d '[:space:]'` did on
# 2026-09-12, by eating the newlines along with the spaces.
# --------------------------------------------------------------------------------------
OPENSSL_OUT='X509v3 Subject Alternative Name:
    DNS:mail.blueprintdigital.my, DNS:mail.kaiteki.my, DNS:webmail.blueprintdigital.my, DNS:webmail.kaiteki.my'

eq 'SAN names are split, not run together' \
  'mail.blueprintdigital.my mail.kaiteki.my webmail.blueprintdigital.my webmail.kaiteki.my ' \
  "$(san_names_from "$OPENSSL_OUT")"

# THE assertion. Both sides use the script's own functions, so a change to either
# normalisation is caught rather than mirrored.
eq 'the wanted list equals the parsed list, so no nightly force' \
  "$(want_names_from "${CERT_NAMES[@]}")" \
  "$(san_names_from "$OPENSSL_OUT")"

# Order on the certificate is the CA's choice, not ours, so both sides are sorted.
eq 'input order does not matter' \
  "$(san_names_from "$OPENSSL_OUT")" \
  "$(san_names_from 'DNS:webmail.kaiteki.my, DNS:mail.kaiteki.my, DNS:webmail.blueprintdigital.my, DNS:mail.blueprintdigital.my')"

# Case. DNS is case-insensitive and a CA may echo a name back in any case; an equality test
# that can never be true is a nightly forced re-issue, not a warning.
eq 'certificate-side case is normalised' \
  "$(san_names_from "$OPENSSL_OUT")" \
  "$(san_names_from 'DNS:Mail.Blueprintdigital.MY, DNS:MAIL.KAITEKI.MY, DNS:webmail.BlueprintDigital.my, DNS:Webmail.Kaiteki.My')"
eq 'wanted-side case is normalised' 'mail.kaiteki.my ' "$(want_names_from Mail.Kaiteki.MY)"

# A single name, and no trailing empty field from the final newline.
eq 'single name' 'mail.kaiteki.my ' "$(san_names_from 'DNS:mail.kaiteki.my')"

# Empty means "could not parse", and the script treats that as a hard stop rather than as a
# reason to force -- see the openssl error handling. The function itself just returns empty.
eq 'empty input yields empty' '' "$(san_names_from '')"

# An IP SAN or an emailAddress SAN must not be picked up as a DNS name.
eq 'non-DNS SAN entries are ignored' 'mail.kaiteki.my ' \
  "$(san_names_from 'DNS:mail.kaiteki.my, IP Address:187.127.122.41')"

# A wildcard survives intact rather than being mangled or dropped.
eq 'wildcards survive' '*.kaiteki.my mail.kaiteki.my ' \
  "$(san_names_from 'DNS:*.kaiteki.my, DNS:mail.kaiteki.my')"

# --------------------------------------------------------------------------------------
# The publish trigger. It must be the stamp, never an mtime against the published file:
# --install-cert rewrites that file, so an mtime test is consumed by the first publish step
# and the steps after it (chown, Stalwart restart, Traefik reload) get no retry if they fail.
# The alarm would fire once and then silence itself while port 443 served the old cert.
# --------------------------------------------------------------------------------------
eq 'publish stamp lives beside the cert' "$D/certs/.published-serial" "$PUBLISH_STAMP"
has 'the publish decision reads the stamp' 'published_serial' "$SRC_TEXT"
# Comments are stripped first: the publish block explains at length why the mtime test is
# wrong, and a naive match on the whole file would fail on the explanation. Same trap the
# repo hit reading `vars.` references out of a commented-out line in a workflow.
SRC_CODE="$(grep -v '^[[:space:]]*#' <<<"$SRC_TEXT")"
if [[ "$SRC_CODE" == *'"$SRC" -nt'* ]]; then
  FAILED=$((FAILED + 1))
  printf 'FAIL: publish is triggered by an mtime comparison again\n' >&2
else
  PASSED=$((PASSED + 1))
fi

# --------------------------------------------------------------------------------------
printf '\n%s\n' "----------------------------------------"
if (( FAILED > 0 )); then
  printf 'test_renew_cert: %d passed, %d FAILED\n' "$PASSED" "$FAILED" >&2
  exit 1
fi
printf 'test_renew_cert: %d passed\n' "$PASSED"
