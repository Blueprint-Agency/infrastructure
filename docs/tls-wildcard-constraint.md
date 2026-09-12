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

## Mail records on `reservetoday.app` — what is published, and what is deliberately not

As of 2026-09-12 the zone carries **no MX and no SPF**. The only mail record is DMARC:

```
_dmarc  TXT  v=DMARC1; p=quarantine; adkim=r; aspf=r; rua=mailto:admin@blueprintdigital.my;
```

The `rua` used to be `dmarc_rua@onsecureserver.net` — the registrar's third-party collector,
which nobody here could read. Changed 2026-09-12 (#10) by `vercel dns add` of the new record
and then `vercel dns rm` of the old one, in that order, so the name was never empty. Policy,
`adkim` and `aspf` are unchanged. Every other record was diffed before/after: 27 → 27, only
`_dmarc` differs. **`p=quarantine` stays** until real reports show Clerk's three apps passing.

> `rua` points at a **different domain**, so RFC 7489 §7.1 wants `blueprintdigital.my` to
> consent: `reservetoday.app._report._dmarc.blueprintdigital.my TXT "v=DMARC1"` (Cloudflare,
> Blueprint account). Without it, compliant reporters drop the report instead of sending it.
> Published 2026-09-12 (#14), alongside the matching `kaiteki.my._report._dmarc` record —
> both point at the same one inbox, so both need consent.

The MX / SPF / DKIM for this domain are **held back on purpose** (#10). The spec's MX target
is the shared `mail.blueprintdigital.my`, which still resolves to bpvps2 until #9 moves it, and
bpvps1 is not ready to accept the domain until #8 (behind #13) is closed. Publishing an MX
before then would only make mail bounce. When they land, SPF is `v=spf1 mx ~all` — soft,
because Clerk already sends from this domain — and Stalwart's selectors must not collide with
Clerk's `clk`/`clk2` CNAMEs.

## If this ever needs to change

Split Traefik's DNS-01 credentials per resolver. As of Traefik v3.3 the Cloudflare
provider still reads `CF_DNS_API_TOKEN` process-wide, so the realistic options are
a second Traefik instance, or moving `reservetoday.app` into the Teeko Cloudflare
account. Neither is worth it while Vercel fronts the customer-facing hosts.
