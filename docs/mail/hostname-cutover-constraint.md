# Stalwart's default hostname is a public-DNS commitment, not an internal one

**Short version.** Changing Stalwart's default hostname on bpvps1 to `mail.blueprintdigital.my`
while that name still resolves to bpvps2 would break Kaiteki webmail for every user, silently
and without a certificate warning. The hostname move and the A-record move are one step, not
two. Verified against the live servers on 2026-09-12.

> **Done, 2026-09-12 (#9).** The cutover below was executed in this order the same day:
> the three bpvps2 mailboxes re-created on bpvps1 first → A records + SPF + DKIM at
> 13:58:55Z → hostname (14:04:18Z) and Bulwark repoint (14:04:50Z) after the 300 s TTL had
> run out. The rule is kept
> here as written because it applies to any future hostname change, not just that one.

## The two facts that combine badly

**1. Stalwart builds its JMAP session URLs from the configured default hostname and ignores
the request's `Host` header.** Asked for `/jmap/session` on bpvps1 through three different
`Host` values, the answer never changed:

| `Host:` sent | `apiUrl` returned |
|---|---|
| `mail.kaiteki.my` | `https://mail.kaiteki.my/jmap/` |
| `mail.blueprintdigital.my` | `https://mail.kaiteki.my/jmap/` |
| `example.invalid` | `https://mail.kaiteki.my/jmap/` |

So every client that authenticates anywhere on this server is told, in absolute terms, to go
to whatever the default hostname says — `downloadUrl`, `uploadUrl` and `eventSourceUrl` too.

**2. Bulwark hands its JMAP host to the BROWSER.** `https://webmail.kaiteki.my/api/config`
returns `"jmapServerUrl":"https://mail.kaiteki.my"` to anyone who asks. The browser resolves
that name itself, on the visitor's resolver, over public DNS.

The `mail.*` network alias on Traefik (`vps/bpvps1/stacks/traefik/docker-compose.yml`) fixes
only the container's own lookups. It has no reach into a laptop's resolver. Reading the alias
as "the new hostname works now" is the mistake this document exists to prevent.

## Why it fails silently rather than loudly

*(Written before the cutover; the tense is that day's. bpvps2's mail stack was deleted in #12
on 2026-09-12, so this exact trap no longer exists — but the mechanism does, for any future
name that resolves to any other machine serving TLS.)*

`mail.blueprintdigital.my` is not a dead name. It resolves to `187.127.207.82` (bpvps2), which
runs its own Stalwart and its own Bulwark, and answers `/jmap/session` with **HTTP 200** under a
**valid certificate** whose SANs are `mail.blueprintdigital.my` and `webmail.blueprintdigital.my`.

So a Kaiteki user redirected there gets no TLS warning and no connection error. They get a
different, near-empty mail server that has never heard of their mailbox. The failure surfaces as
"webmail says my password is wrong", which points the investigation at Bulwark and at passwords,
which is the wrong place.

## The rule

The A record and the default hostname move **together**, and neither moves before bpvps2's
`blueprintdigital.my` mailboxes exist on bpvps1. In order:

0. Every mailbox that bpvps2's Stalwart holds for `blueprintdigital.my` is created on bpvps1
   (same addresses, passwords re-issued — the store holds hashes, so they cannot be carried
   over). bpvps2 held `chriskke@`, `danielchua@` and `yuchen@`; bpvps1 held only `admin@`
   until #9 created the other three (ids `u`, `v`, `w`).
1. `mail.blueprintdigital.my` and `webmail.blueprintdigital.my` A → `187.127.122.41` (bpvps1),
   DNS-only. bpvps1's certificate already carries both names and the Traefik routers already
   exist, so the names answer the moment the record lands.
2. Immediately after: Stalwart's default hostname and Bulwark's `JMAP_SERVER_URL`.

Step 1 is **not** safe on its own, and this document must not be read as saying it is. It is
the same trap in reverse: bpvps2 runs its own Stalwart + Bulwark on those names, so its users'
browsers are sent to bpvps1 — valid cert, no warning — where their mailbox does not exist unless
step 0 happened. It also moves inbound mail for `blueprintdigital.my`, because that zone's MX
names `mail.blueprintdigital.my`; any address bpvps1 does not hold **bounces** from that point.

There is no version of this that leaves public DNS untouched. Any plan that says "internal
only, nothing public moves" and also says "change the default hostname" is asking for two
things that cannot both be true.

## How to re-check it

```bash
# What does the server tell clients to use?
curl -s -u '<admin>:<pass>' -H 'Host: anything.example' \
  http://127.0.0.1:8090/jmap/session | python3 -c 'import json,sys;print(json.load(sys.stdin)["apiUrl"])'

# What does Bulwark tell the browser to use?
curl -s https://webmail.kaiteki.my/api/config | python3 -c 'import json,sys;print(json.load(sys.stdin)["jmapServerUrl"])'
```

Both must name a host whose **public** A record is this server.
