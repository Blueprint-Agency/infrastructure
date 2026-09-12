---
name: onboard-mail-domain
description: Add a client's mail domain to the one Stalwart + Bulwark platform on bpvps1. Use when a domain needs mailboxes, an MX, DKIM/SPF/DMARC, a branded webmail hostname, or when someone proposes a new mail server or stack for a client — that is never the answer.
---

# Onboarding a mail domain

One Stalwart and one Bulwark on bpvps1 serve every domain. A new client is **rows added to
that instance**, never a second stack, container or host. The reference for every request
shape below is `vps/bpvps1/stacks/stalwart/README.md` — "Configuring this build" for the
JMAP `x:` API, "Branding" for Bulwark, "TLS" for the certificate. This file is the order;
that file is the detail.

Two facts shape every step:

- **The mail host is shared.** The MX for a new domain is `mail.blueprintdigital.my`. A client
  never gets a `mail.<client>` — that is what keeps the certificate short and the DNS work
  small. A `webmail.<client>` vanity host is optional (step 3).
- **`/root/stacks/stalwart` on bpvps1 is root-owned.** `docker compose` runs from a
  `docker:cli` container (recipe in CLAUDE.md, "bpvps1's `stalwart` and `traefik` stacks are
  root-owned"); file writes go through the `alpine` pipe (recipe in the README, "Ops").
  In #9, `compose up -d bulwark` was observed to recreate `stalwart` and `unbound` as well
  (~7 s of mail-port downtime), so batch the compose edits from steps 3 and 4 into one `up`
  and expect a blip.

`<domain>` below is the client's zone (`example.my`). `<brand>` is a short lowercase name
used only for the logo folder and its mount path (`branding/<brand>/`); everything Bulwark
matches on is the hostname `webmail.<domain>`.

## 1. Stalwart: the domain exists

`x:Domain/set` create, as the Admin (`admin@blueprintdigital.my`) or the recovery admin over
loopback `:8090`. Automatic DKIM generates both key pairs on create.

Done when `x:Domain/get` lists `<domain>` with `isEnabled: true` and
`certificateManagement: {"@type":"Manual"}` (the default — `reservetoday.app` was created
with exactly the README shape and came out Manual; if yours says `Automatic`, set it back,
or Stalwart mints a second certificate Traefik never sees), and its `dnsZoneFile` shows two
`v1-*-<date>._domainkey` TXT records. Copy that zone file — step 2 pastes from it.

## 2. DNS, at the provider that actually answers

`dig +short NS <domain>` first. The registrar's or Cloudflare's zone may be a dead copy
(`reservetoday.app` is on Vercel while a Cloudflare zone of the same name exists and serves
nothing — `docs/tls-wildcard-constraint.md`). Records go where the NS points.

| Record | Value |
|---|---|
| MX `@` | `10 mail.blueprintdigital.my` |
| TXT `@` | `v=spf1 mx -all` — **`~all` if any third party already sends as this domain** (a CRM, an auth provider). Hardfail with an unlisted sender rejects their mail. |
| TXT `v1-rsa-<date>._domainkey`, `v1-ed25519-<date>._domainkey` | from `dnsZoneFile`, verbatim |
| TXT `_dmarc` | `v=DMARC1; p=reject; rua=mailto:admin@blueprintdigital.my; fo=1` — `p=quarantine` with the `~all` case above |
| TTL | 300 on all of them, so a rollback lands in minutes |

Then the **consent record in the Blueprint Cloudflare zone**, because `rua` points at a
different domain (RFC 7489 §7.1): `<domain>._report._dmarc.blueprintdigital.my TXT "v=DMARC1"`.
Without it compliant reporters silently drop the reports.

Done when `dig +short MX <domain>` returns the shared host from 1.1.1.1 and 8.8.8.8, and
`dig +short TXT <selector>._domainkey.<domain>` returns each key.

## 3. Vanity webmail hostname — optional

Skip this if the client is happy signing in at `webmail.blueprintdigital.my`
(reservetoday.app does). Otherwise `webmail.<domain>` needs four things, and the first
one gates the rest:

1. **Certificate SAN.** The cert is one acme.sh certificate issued on
   `KAITEKI_CF_DNS_API_TOKEN`, so the zone must be in the **Blueprint Cloudflare account** and
   the token scoped to it — otherwise DNS-01 fails and there is no vanity host. *Append*
   `webmail.<domain>` to `CERT_NAMES` in `vps/bpvps1/stacks/stalwart/renew-cert.sh` — never
   reorder, `mail.kaiteki.my` stays first — push the file to the host and run it. Done when
   the script prints `cert RENEWED` and `scripts/test_renew_cert.sh` passes.
2. **A record** `webmail.<domain>` → `187.127.122.41`, DNS-only (grey cloud).
3. **Traefik router + CORS**, `vps/bpvps1/stacks/traefik/dynamic/stalwart.yml`: add
   `|| Host(`webmail.<domain>`)` to the `bulwark` router rule, and the origin
   `https://webmail.<domain>` to `mail-cors.accessControlAllowOriginList`. Both, or login
   fails preflight with no server-side error. The file provider reloads on save; a broken
   rule only shows in `docker logs traefik`.
4. **Nothing on the Traefik `mailnet` aliases** — those are for `mail.*` names only.

Done when `curl -sI https://webmail.<domain>/` is `200` under the shared certificate.

## 4. Branding entry

Only with step 3; a domain without its own hostname shows the Blueprint brand. Three edits
in `vps/bpvps1/stacks/stalwart/`, all compose, never the Bulwark admin dashboard:

- `branding/<brand>/` — light + dark login logo and a favicon (the "Branding" section says
  what format works and why text in an SVG must be outlined).
- A mount line under the `bulwark` service: `./branding/<brand>:/app/public/branding/<brand>:ro`.
- One `DOMAIN_BRANDING` entry for `webmail.<domain>` — copy the Kaiteki entry, every field.

Push the folder and the compose to the host, then `compose up -d bulwark` (from the
`docker:cli` container). Done when `curl -s https://webmail.<domain>/api/config` returns the
client's `appName` and `loginLogoLightUrl`, not the Blueprint defaults.

## 5. Mailboxes

`x:Account/set` create per address, role `User`. The **temporary-password convention** —
generated, stored as `MAIL_PASSWORD_<ACCOUNT>` in the repo `.env`, proved by step 6,
handed over out-of-band, changed by the owner at first login — is
`docs/mail/staff-mail-setup.md`, which is also the card the owner gets.

Done when every address is in `x:Account/get` and has a `MAIL_PASSWORD_*` line.

## 6. Verify — the only definition of finished

- `scripts/verify-mail.d/<domain>.conf` — copy `reservetoday.app.conf` (no vanity host) or
  `blueprintdigital.my.conf` (vanity host) and fill every key; a blank key fails the run.
- Add `<domain>` to the `for domain in …` line near the end of `scripts/test_verify_mail.sh`
  (the "conf exists for" assertion — every conf is already checked by glob), then
  `bash scripts/test_verify_mail.sh` green.
- `./scripts/verify-mail.sh <domain> <one real mailbox>` → **exit 0**. Exit 3 means something
  was skipped and is not green.
- Record it: `apps/registry.yml` `mail[0].domains`, and the README's DNS tables + "State of
  this instance" (domain id, mailbox ids).

Done when the verify run is pasted on the ticket with `rc=0` and the three files above are
in the same commit.
