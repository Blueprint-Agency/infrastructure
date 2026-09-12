#!/bin/bash
# Renew the bpvps1 mail certificate (acme.sh / Cloudflare DNS-01) and publish it only if it
# actually renewed. Run daily via host cron:
#   0 3 * * * /root/stacks/stalwart/renew-cert.sh >> /var/log/kaiteki-cert-renew.log 2>&1
#
# The CF API token (KAITEKI_CF_DNS_API_TOKEN) is read from the gitignored stack .env and
# exported as CF_Token so acme.sh's dns_cf plugin can update the challenge records. That one
# token is scoped to the Blueprint Cloudflare account and covers BOTH kaiteki.my and
# blueprintdigital.my, which is what lets a single certificate span the two zones.
#
# ---------------------------------------------------------------------------------------
# THE ORDER OF CERT_NAMES IS LOAD-BEARING. acme.sh keys its state directory on the FIRST
# name a certificate was issued with. Reordering the list looks cosmetic and reviews clean,
# but it sends acme.sh to a brand new state directory while the publish step below keeps
# reading the old one: renewals succeed, the published files never change, and the cert
# expires 90 days later, taking mail TLS and every web UI on this host down at once.
# Append to the list; never reorder it. scripts/test_renew_cert.sh guards this in CI.
#
# Write names as LOWERCASE A-LABELS. DNS is case-insensitive and a CA may hand back a
# different case, or the punycode form of a Unicode name, than the one asked for -- either
# would make the comparison below never match and force a re-issue every night. And a
# wildcard must never be CERT_NAMES[0]: acme.sh's directory name for a wildcard is not the
# literal `*.example.com_ecc` that ACME_STATE_DIR would compute.
#
# The renewal engine is `--issue`, not `--cron`, because --cron renews whatever name list is
# already recorded on disk -- so a name added here would never reach the certificate. --issue
# compares the requested list against the stored one, re-issues when it differs, and returns
# its "skip" code when it matches and nothing is due. That makes this file, not the server's
# state directory, the source of truth for which names the certificate carries.
#
# --server letsencrypt is NOT optional. A renewal reuses the CA recorded against the existing
# certificate, but a CHANGED name list is a fresh issuance, and acme.sh's built-in default CA
# is ZeroSSL -- which needs an EAB-registered account we do not have. Adding a name without
# this flag fails with "Please update your account with an email address first", and the day
# it does not fail is worse: the host would quietly start serving a certificate from a
# different CA than the one this stack was built and tested against.
#
# --keylength ec-256 is equally load-bearing: it is what puts acme.sh's state in the `_ecc`
# directory that ACME_STATE_DIR and `--install-cert --ecc` both point at. Drop it and acme.sh
# renews happily into `mail.kaiteki.my/` while this script keeps publishing from
# `mail.kaiteki.my_ecc/` -- the silent 90-day expiry again, by a different route.
# ---------------------------------------------------------------------------------------
set -e

D=/root/stacks/stalwart

CERT_NAMES=(
  mail.kaiteki.my              # primary -- names the acme state dir, do not move
  webmail.kaiteki.my
  mail.blueprintdigital.my
  webmail.blueprintdigital.my
)

CERT_CA=letsencrypt

# Pinned by digest. This script encodes acme.sh's exit-code contract (rc 2 = RENEW_SKIP) and
# its "Domains not changed" behaviour, which are implementation details, not a public API. An
# unpinned :latest can move that contract under the script on any host that pulls fresh.
ACME_IMAGE=neilpang/acme.sh@sha256:5e5713c64816ca2f2dde780df87bc7464e6f6a5995d457710131b688317b8352

# The Traefik dynamic config that names ./certs. Touched, not restarted, after a renewal --
# see the reload comment further down.
TRAEFIK_DYNAMIC=/root/stacks/traefik/dynamic/stalwart.yml

ACME_STATE_DIR="$D/acme/${CERT_NAMES[0]}_ecc"
SRC="$ACME_STATE_DIR/fullchain.cer"
PUBLISHED="$D/certs/fullchain.pem"

# Written only after the WHOLE publish path has succeeded, and holds the serial that was
# published. See the publish block for why an mtime comparison cannot be used here.
PUBLISH_STAMP="$D/certs/.published-serial"

# san_names_from <output of `openssl x509 -noout -ext subjectAltName`> -> sorted, lowercased
# names, one space between each. Normalises both sides of the comparison into one shape.
#
# The whitespace stripping deletes SPACES AND TABS ONLY, never newlines. `tr -d '[:space:]'`
# looks like the obvious way to write this and is silently wrong: it eats the line breaks
# too, so four names collapse into one unsplittable blob that can never equal the wanted
# list, and the script force-renews every single night -- five duplicate certificates into a
# Let's Encrypt rate limit, plus a nightly Stalwart restart. Caught on 2026-09-12 by running
# the script rather than reading it. Lowercasing is here for the same reason: a CA is free to
# echo a name back in a different case, and an equality test that can never be true is a
# nightly forced re-issue, not a warning.
san_names_from() {
  printf '%s' "$1" \
    | tr ',' '\n' \
    | sed -n 's/.*DNS://p' \
    | tr -d ' \t\r' \
    | tr 'A-Z' 'a-z' \
    | sed '/^$/d' \
    | sort \
    | tr '\n' ' '
}

# want_names_from <name>... -> the same shape, for the list we are asking for. This lives
# above the source guard so the test exercises THIS function rather than a copy of it: a test
# that re-implements the normalisation cannot notice the normalisation changing.
want_names_from() {
  printf '%s\n' "$@" | tr 'A-Z' 'a-z' | sort | tr '\n' ' '
}

# serial_of <pem> -> the certificate serial, or empty if the file is absent or unreadable.
serial_of() {
  [ -f "$1" ] || return 0
  openssl x509 -in "$1" -noout -serial 2>/dev/null | cut -d= -f2- || true
}

# Sourced rather than executed (scripts/test_renew_cert.sh) -- declarations only, run nothing.
(return 0 2>/dev/null) && return 0

# Canary for that guard. scripts/test_renew_cert.sh asserts this is still unset after it
# sources the file: if the guard ever breaks, CI would otherwise run a real acme.sh issuance
# against Cloudflare from a GitHub runner before anything noticed.
RENEW_CERT_RAN=yes

# ---------------------------------------------------------------------------------------
# The Cloudflare token
# ---------------------------------------------------------------------------------------
# Quotes and a trailing CR are stripped: `KEY="abc"` in .env yields a token WITH the quote
# characters, and a CRLF-saved .env adds a \r. Both are non-empty, so they pass the guard
# below and then fail at Cloudflare -- which reads like a Cloudflare outage, not a parse bug.
cf_lines="$(grep -cE '^KAITEKI_CF_DNS_API_TOKEN=' "$D/.env" || true)"
if [ "$cf_lines" != "1" ]; then
  echo "$(date -Is) expected exactly one KAITEKI_CF_DNS_API_TOKEN line in $D/.env, found $cf_lines"
  exit 1
fi
CF_Token="$(grep -E '^KAITEKI_CF_DNS_API_TOKEN=' "$D/.env" | cut -d= -f2- | tr -d '"'"'"'\r')"
export CF_Token

# An empty token is a failure, not a smaller one -- the same rule render-ci.py and
# verify-mail.sh follow. `export VAR=$(...)` takes the exit status of `export`, so a missing
# or renamed .env line sails past `set -e` with CF_Token=''. acme.sh would then still exit 2
# ("not due") every night for two months, because --issue checks the renewal date before it
# ever touches DNS -- and only announce itself on the one night the certificate had to be
# renewed and could not be. Fail on the first run instead.
if [ -z "$CF_Token" ]; then
  echo "$(date -Is) KAITEKI_CF_DNS_API_TOKEN is empty in $D/.env -- DNS-01 cannot run"
  exit 1
fi

# ---------------------------------------------------------------------------------------
# Do the names on the certificate match the names we want?
# ---------------------------------------------------------------------------------------
# Read them off the CERTIFICATE rather than asking acme.sh what it thinks it issued. acme.sh
# writes the requested name list into its .conf BEFORE the order succeeds, so a failed
# issuance leaves a file claiming names that were never signed -- and every later --issue
# answers "Domains not changed. Skipping." Seen for real on 2026-09-12: a ZeroSSL fallback
# died mid-run, and the next attempt refused to do anything while the live certificate still
# carried the old two names. The certificate is the only honest record.
want_names="$(want_names_from "${CERT_NAMES[@]}")"
have_names=''
if [ -f "$SRC" ]; then
  # Deliberately NOT `2>/dev/null` into the comparison. If openssl is missing, too old for
  # `x509 -ext`, or the file is truncated, the parse yields nothing -- and "nothing" can never
  # equal want_names, so the script would force a full re-issue every night, straight into
  # the Let's Encrypt duplicate-certificate limit. Refusing to act is the safe direction: an
  # unforced --issue still renews on schedule, so the certificate survives while a human
  # looks. A nightly forced re-issue does not.
  if ! san_raw="$(openssl x509 -in "$SRC" -noout -ext subjectAltName 2>&1)"; then
    echo "$(date -Is) cannot read SANs from $SRC -- refusing to guess: $san_raw"
    exit 1
  fi
  have_names="$(san_names_from "$san_raw")"
  if [ -z "$have_names" ]; then
    echo "$(date -Is) parsed zero SANs from $SRC -- refusing to force a re-issue"
    exit 1
  fi
fi

FORCE_ARGS=()
if [ "$want_names" != "$have_names" ]; then
  echo "$(date -Is) certificate names differ -- have [$have_names] want [$want_names], forcing"
  FORCE_ARGS=(--force)
fi

# ---------------------------------------------------------------------------------------
# Issue / renew
# ---------------------------------------------------------------------------------------
ISSUE_ARGS=()
for name in "${CERT_NAMES[@]}"; do ISSUE_ARGS+=(-d "$name"); done

# rc 0 = issued or renewed. rc 2 = acme.sh's RENEW_SKIP: same names, not due yet -- the
# normal outcome on 89 days out of 90. Any other code is a real failure and must not be
# swallowed, or a broken DNS-01 would look like a quiet no-op every night until expiry.
rc=0
docker run --rm -v "$D/acme:/acme.sh" -e CF_Token="$CF_Token" \
  "$ACME_IMAGE" --issue --server "$CERT_CA" --keylength ec-256 --dns dns_cf \
  --home /acme.sh "${ISSUE_ARGS[@]}" "${FORCE_ARGS[@]}" || rc=$?
if [ "$rc" -ne 0 ] && [ "$rc" -ne 2 ]; then
  echo "$(date -Is) acme.sh --issue FAILED rc=$rc"
  exit "$rc"
fi

# A skip is only a valid answer when we did not force. We force precisely when the live
# certificate is known to be wrong, so "nothing to do" is then a contradiction -- and exactly
# the 2026-09-12 failure, where acme.sh answered "Domains not changed" over a stale conf.
# Without this the script would fall through and report "not due", exiting 0 with the names
# still missing, every night, forever.
if [ "$rc" -eq 2 ] && [ "${#FORCE_ARGS[@]}" -gt 0 ]; then
  echo "$(date -Is) acme.sh SKIPPED a run we forced -- certificate still has [$have_names]"
  exit 1
fi

# ---------------------------------------------------------------------------------------
# Publish
# ---------------------------------------------------------------------------------------
# Driven by a stamp written only after every publish step has succeeded, NOT by comparing
# mtimes of $SRC against the published file. The obvious `[ "$SRC" -nt "$PUBLISHED" ]` is
# self-defeating: --install-cert rewrites $PUBLISHED, so the very first step consumes the
# trigger for all the steps after it. If the Traefik reload or the chown then failed, the
# next night's run would see $SRC no longer newer, print "not due", and exit 0 -- the alarm
# fires once and then silences itself while port 443 serves the old certificate. A serial
# also catches what an mtime cannot: a $PUBLISHED that is newer than $SRC but is the wrong
# certificate, hand-copied or left behind by a restore.
src_serial="$(serial_of "$SRC")"
published_serial="$(cat "$PUBLISH_STAMP" 2>/dev/null || true)"

if [ -z "$src_serial" ]; then
  echo "$(date -Is) no issued certificate at $SRC"
  exit 1
fi

if [ "$src_serial" = "$published_serial" ]; then
  echo "$(date -Is) cert not due for renewal (serial $src_serial already published)"
  exit 0
fi

docker run --rm -v "$D/acme:/acme.sh" -v "$D/certs:/certs" \
  "$ACME_IMAGE" --install-cert -d "${CERT_NAMES[0]}" --ecc \
  --key-file /certs/key.pem --fullchain-file /certs/fullchain.pem

# Stalwart runs as uid 2000 and cannot read the files otherwise.
chown 2000:2000 "$PUBLISHED" "$D/certs/key.pem"

# Post-condition. The script has asked for four names and installed a file; nothing so far
# has checked that the file it published is the one it asked for. Verify before anyone is
# told this succeeded.
published_names="$(san_names_from "$(openssl x509 -in "$PUBLISHED" -noout -ext subjectAltName 2>&1)")"
if [ "$published_names" != "$want_names" ]; then
  echo "$(date -Is) published certificate has [$published_names], expected [$want_names]"
  exit 1
fi

docker restart stalwart >/dev/null

# Traefik reads the same two files through its file provider, but `providers.file.watch`
# watches the dynamic CONFIG DIRECTORY, not the certificate files that config points at. A
# renewal that swaps ./certs without touching the yml is therefore never noticed, and Traefik
# keeps serving the old certificate until something restarts it. That is how port 443 came to
# serve the 28 Jun cert -- 14 days from expiry -- while port 465 served the 29 Aug renewal
# (2026-09-12). Touching the yml makes the watcher reload and re-read the certs: no restart,
# no dropped connections, unlike `docker restart traefik`.
if [ ! -f "$TRAEFIK_DYNAMIC" ]; then
  # Loud and repeated: the stamp is not written, so this fails again tomorrow rather than
  # going quiet while a web UI serves an expiring certificate and the mail ports look fine.
  echo "$(date -Is) cert installed but $TRAEFIK_DYNAMIC is MISSING -- Traefik still serving the OLD certificate"
  exit 1
fi
touch "$TRAEFIK_DYNAMIC"

printf '%s' "$src_serial" > "$PUBLISH_STAMP"
echo "$(date -Is) cert RENEWED (serial $src_serial), Stalwart restarted, Traefik reloaded"
