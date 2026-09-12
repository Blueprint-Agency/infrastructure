# bpvps2 cannot issue a wildcard certificate for `reservetoday.app`

Recorded 2026-08-31. **No action needed** — this is written down so it is not
rediscovered the next time someone asks "why aren't the frontends on the VPS?"

## The constraint

Traefik on bpvps2 has two ACME resolvers:

| Resolver | Challenge | Can do wildcards? |
|---|---|---|
| `le-tls` | TLS-ALPN-01 | **No** |
| `letsencrypt` | DNS-01 (Cloudflare) | Yes, but only for the Teeko zone |

`booking-be` uses `le-tls`. Two independent reasons block a wildcard:

1. **TLS-ALPN-01 cannot issue wildcards.** The challenge proves control of port 443
   for one exact hostname. Let's Encrypt only issues `*.example.com` off DNS-01.

2. **The DNS-01 resolver cannot reach the right Cloudflare account.**
   `CF_DNS_API_TOKEN` on this host is an org-level secret holding the **Teeko**
   token, scoped to `teeko.ai`. `reservetoday.app` was in the **Blueprint**
   Cloudflare account when this was recorded, and has since moved to **Vercel
   nameservers** — which removes the Cloudflare token as an option entirely
   rather than restoring one. Traefik reads that token from the **process
   environment**, not per-resolver — so adding a second DNS-01 resolver for
   reservetoday.app would silently reuse the Teeko token and fail, and there is
   no longer a Cloudflare zone for it to reach. bpvps1 has the opposite problem
   and overrides the token at the host level; bpvps2 cannot, because its Teeko
   certs would then break.

## What follows from it

- **The frontends stay on Vercel.** Vercel issues the wildcard certificates itself.
  This is the concrete reason, not a preference.
- **Every backend hostname on bpvps2 must be named explicitly**, one Traefik router
  rule per exact FQDN, with a DNS record to match.
- **A new backend hostname needs an explicit A record → 187.127.207.82 created
  first**, and that record is made **at Vercel**, not Cloudflare — see below.
  TLS-ALPN-01 proves control of port 443 on that IP, so without the record
  Traefik gets no certificate and the hostname serves a TLS handshake failure.
- **Keep the old hostname as a router alias through any rename**, until the new
  name is confirmed serving a valid certificate.

## Where `reservetoday.app` DNS actually lives — read this before editing anything

**Vercel is authoritative.** The zone's nameservers are `ns1.vercel-dns.com` and
`ns2.vercel-dns.com`. Manage records with `vercel dns ls|add|rm reservetoday.app`
under the `blueprintdigitalmy` scope.

**There is also a Cloudflare zone for `reservetoday.app` in the Blueprint account,
and it is NOT live.** It is a staged copy prepared for a nameserver move that has
not happened. Editing it changes nothing that resolves. Verified 2026-08-31: the
Cloudflare zone had no `api.dev` record while `api.dev.reservetoday.app` resolved
fine, because the answer was never coming from Cloudflare. Do not trust that zone
as a picture of reality until the nameservers actually move.

**The wildcard is a trap.** Vercel serves `* ALIAS cname.vercel-dns-016.com`, so a
hostname with no explicit record does **not** NXDOMAIN — it silently resolves to
Vercel and serves a Vercel certificate for someone else's name. A backend
hostname that "resolves" therefore proves nothing. Check the record exists:

```bash
vercel dns ls reservetoday.app | grep api
```

**CAA is already correct.** The zone publishes `0 issue "letsencrypt.org"` (plus
pki.goog and sectigo.com), so Let's Encrypt is permitted to issue. A new backend
hostname needs no CAA change.

## Mail records on `reservetoday.app` — published 2026-09-12 (#10)

The domain receives mail on the shared platform host since 2026-09-12. Five records — four
added, and `_dmarc` repointed — all via `vercel dns add reservetoday.app … --scope blueprintdigitalmy`:

```
@                                MX   10 mail.blueprintdigital.my
@                                TXT  v=spf1 mx ~all
v1-rsa-20260912._domainkey       TXT  v=DKIM1; k=rsa; h=sha256; p=MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA3QR50FoTQzSCaoMsuT+XxEkdlAD3Y+txF+BAo+uC7J0vlddstVh+kire/98nhWLvZZYxLw0YDwjyHQc6JVGH0ouN6HCbTSbklx9vmw6X6wjxOfh4rzkB7A3XbHhrMKVh0W/QmAD3PT34xYBYCf0IQz/iIeQ+TUTfFasFzXeWKPGD/f24p95U8eCY7zJ9TjdSqysb5WPhWGfYBgDhRP1ut9cJFVeGXA5/FzxnTPdSe3kY8UFa/gNjr1MxYyWmRmLvOJl2jT4V/FH3uoxP7R6pZArypbqS0365ZTwvcFhkUgZD9lvUozJoa5lEzWjj7knkNsdbQRfSLHB0cxxXMqr8VQIDAQAB
v1-ed25519-20260912._domainkey   TXT  v=DKIM1; k=ed25519; h=sha256; p=RK0SHFwCg+KaVOR8U50jUvdtoV2fN8vOg7imzMh0LcM=
_dmarc                           TXT  v=DMARC1; p=quarantine; adkim=r; aspf=r; rua=mailto:admin@blueprintdigital.my;
```

The DKIM keys are the pair Stalwart generated on bpvps1 in #8 (`x:Domain/get` →
`dnsZoneFile` is the ready-to-paste source; Vercel accepted the 2048-bit RSA value as one
string and splits it on the wire itself). Every other record was diffed before/after each
change: 27 → 27 for the `_dmarc` edit, 27 → 31 for the four additions — the apex ALIAS, `*`,
`api`, `api.dev` and every Clerk `clk*` / `clerk` / `accounts` record are byte-identical.

**This posture is deliberately soft, and there is no `mail.reservetoday.app`.**

- **SPF is `~all`, DMARC stays `p=quarantine`.** Three Clerk apps (the apex, `portal`,
  `admin.portal`) already send the booking product's auth mail from this domain under their
  own `clk` / `clk2` selectors. A hardfail here could send magic links to spam. Tighten to
  `-all` / `p=reject` only after the DMARC reports at `admin@blueprintdigital.my` show Clerk
  passing. (Stalwart's own `dnsZoneFile` suggests `-all` / `p=reject` — ignore that half.)
- The `rua` was `dmarc_rua@onsecureserver.net` — the registrar's collector, which nobody here
  could read — until 2026-09-12; the new record was added before the old one was removed, so
  the name was never empty. `rua` is a **different domain**, so `blueprintdigital.my` publishes
  the RFC 7489 §7.1 consent record `reservetoday.app._report._dmarc` (#14).
- The MX is the shared platform host. The domain has no `mail.` name of its own on purpose.
- **`webmail.reservetoday.app` exists since #19** (`A 187.127.122.41`, the one record added
  in that ticket; 26 → 27, everything else byte-identical). It is the same Bulwark as
  `webmail.blueprintdigital.my` under the product's own name. Its certificate is the
  exception to "the mail cert is acme.sh DNS-01": that path cannot reach a Vercel zone, and
  acme.sh's `dns_vercel` plugin cannot either (no `teamId` — `blueprintdigitalmy` is a team),
  so bpvps1's Traefik issues this one name over **TLS-ALPN-01** — the same `le-tls` resolver
  bpvps2 uses for the booking API. Detail: `vps/bpvps1/stacks/stalwart/README.md`, "TLS".

`scripts/verify-mail.sh reservetoday.app` is the check: 13/13 on 2026-09-12, including
inbound through the MX and an outbound probe that passed SPF, DKIM and DMARC alignment;
13/13 again after #19 with the webmail checks pointed at the new name.
Its expectations are `scripts/verify-mail.d/reservetoday.app.conf`.

## If this ever needs to change

Split Traefik's DNS-01 credentials per resolver. As of Traefik v3.3 the Cloudflare
provider still reads `CF_DNS_API_TOKEN` process-wide, so the realistic options are
a second Traefik instance, or moving `reservetoday.app` into the Teeko Cloudflare
account. Neither is worth it while Vercel fronts the customer-facing hosts.
