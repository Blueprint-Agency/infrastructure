# Stalwart + Bulwark — the multi-domain mail platform (BPVPS1)

**Stalwart** (Rust mail server) handles SMTP/IMAP/POP3/JMAP/ManageSieve + DKIM + spam;
**Bulwark** is a modern JMAP webmail (HTML compose, themes, calendar, contacts, files,
built-in admin dashboard). One Stalwart and one Bulwark serve **every** domain: `kaiteki.my`,
`blueprintdigital.my`, `reservetoday.app`. Replaced the earlier Roundcube webmail; the
Kaiteki mail host was renamed `email.kaiteki.my` → `mail.kaiteki.my`.

**The canonical mail host is `mail.blueprintdigital.my`** (since the #9 cutover, 2026-09-12):
it is Stalwart's default hostname, what Bulwark points at, and the MX target every new
domain uses. `mail.kaiteki.my` is the same box under its older name, kept alive so
already-configured Kaiteki IMAP clients never need touching.

| | URL | Login |
|---|---|---|
| Stalwart self-service | `https://mail.blueprintdigital.my` (→ `/account`) | any mailbox |
| Webmail | `https://webmail.blueprintdigital.my` / `https://webmail.kaiteki.my` | mailbox creds — any domain's mailbox at either hostname |
| Bulwark admin dashboard | `https://webmail.kaiteki.my/admin` | `ADMIN_PASSWORD` (stack `.env`, `BULWARK_ADMIN_PASSWORD`) |
| Management API | JMAP `x:` methods, see "Configuring this build" | `admin@blueprintdigital.my` (Admin role) |

Stack dir on VPS: `/root/stacks/stalwart/`. Mail data in the `stalwart-data` volume
(RocksDB at `/opt/stalwart/data`). Co-hosted behind the existing Traefik.

## How it fits together
- **Mail ports** (25/465/587/993/143/110/995/4190) bind directly on the host.
- **Web UIs** go through Traefik: `mail.` → `stalwart:8080`, `webmail.` → `bulwark:3000`,
  over the external `stalwart_mailnet` network. See `../traefik/dynamic/stalwart.yml`.
- **Bulwark → Stalwart is JMAP over HTTPS.** Bulwark uses
  `JMAP_SERVER_URL=https://mail.blueprintdigital.my` and follows the **absolute** URLs
  Stalwart returns in its JMAP session. So:
  - Stalwart's **default hostname must be `mail.blueprintdigital.my`** (`x:SystemSettings`,
    see "Configuring this build"), otherwise the session advertises the wrong host and the
    webmail breaks. And that name's **public A record must be this server** — see the
    hostname landmine below.
  - Both `mail.` names are **network aliases on Traefik** (`../traefik/docker-compose.yml`) so
    the Bulwark container resolves them internally to Traefik → valid cert → `stalwart:8080`.
  - The browser also calls JMAP **cross-origin** (`webmail.` → `mail.`, incl. `/.well-known/jmap`),
    so **Traefik adds CORS** for the mail host (an allow-list of every webmail origin +
    `Allow-Credentials: true`, and it answers preflight) — see the `mail-cors` middleware in
    `../traefik/dynamic/stalwart.yml`. Stalwart's own "Permissive CORS" is left **OFF**: it only
    emits `*` (which browsers reject for credentialed / "Remember me" requests) and it doesn't
    cover the `/.well-known/jmap` discovery redirect.
  - Stalwart must trust the proxy: `x:Http.useXForwarded = true`, plus an `x:AllowedIp` entry
    for **`172.16.0.0/12`** (Docker's default pool; see "Configuring this build"). Without
    this, Stalwart's fail2ban sees every request as coming from Traefik's container IP, and a single
    bot scan for `*/wp-*`/`*.php*` (HTTP "banned paths") bans the proxy → all mail web UIs return 502.

## TLS
One LE cert for **four names across two zones** — `mail.kaiteki.my`, `webmail.kaiteki.my`,
`mail.blueprintdigital.my`, `webmail.blueprintdigital.my` — issued **out-of-band via
Cloudflare DNS-01** (acme.sh + `KAITEKI_CF_DNS_API_TOKEN`) because Traefik's CF token only
covers `teeko.ai`. That one token is a **Blueprint-account** token and is scoped to both
zones, which is the whole reason a single certificate can span them. Cert lands in
`./certs/{fullchain,key}.pem`.
- **Traefik** serves it via the file provider (`stalwart.yml`).
- **Stalwart** reads the same files for mail TLS through **one `x:Certificate` object in the
  store** whose `certificate` / `privateKey` are `@type: File` pointers at
  `/opt/stalwart/certs/{fullchain,key}.pem` — a *pointer*, not a copy, so a renewal only has
  to swap the files and restart Stalwart. That object is pinned as
  `x:SystemSettings.defaultCertificateId` (#17; id in the state table at the bottom).
  ⚠️ The files must be readable by Stalwart's user: `chown 2000:2000 ./certs/*.pem`.
- Renewal: `renew-cert.sh` (daily host cron) re-runs acme.sh (it **reads `CF_Token` from the
  stack `.env`** — the saved-creds path is unreliable), reinstalls to `./certs`, re-chowns,
  restarts Stalwart, and **touches `../traefik/dynamic/stalwart.yml`** so Traefik re-reads the
  cert without a restart. Cert is **ECC**, acme dir `./acme/mail.kaiteki.my_ecc/`.
- The name list lives in `renew-cert.sh` as `CERT_NAMES` and is asserted by
  `scripts/test_renew_cert.sh` in CI. Adding a name is an edit to that array and nothing else.

> ⚠️ **`CERT_NAMES[0]` must stay `mail.kaiteki.my`.** acme.sh keys its state directory on the
> first name, and both the install step and the host cron are hardcoded to
> `./acme/mail.kaiteki.my_ecc/`. Reordering the array reads as cosmetic and reviews clean, but
> it points acme.sh at a fresh state dir while the install keeps publishing the old one: the
> cert silently stops being refreshed and expires 90 days later. **Append, never reorder.**

> ⚠️ **A changed name list is a NEW issuance, not a renewal — so the CA must be pinned.** A
> renewal reuses the CA recorded against the existing cert; a fresh issuance falls back to
> acme.sh's own default, which is **ZeroSSL** and needs an EAB account we do not have. Adding
> the two Blueprint names without `--server letsencrypt` died on *"Please update your account
> with an email address first"* (2026-09-12). The script now passes it explicitly.

> ⚠️ **acme.sh writes the requested names into its `.conf` BEFORE the order succeeds.** When
> that ZeroSSL attempt failed, the conf already claimed all four names while the live cert
> still had two — and every later `--issue` answered *"Domains not changed. Skipping."* The
> script therefore reads the names off the **certificate**, not the conf, and forces a
> re-issue when they differ. It cannot force in a loop: once the cert matches, so does the
> comparison. (Get that normalisation wrong and it force-renews nightly straight into a rate
> limit — `tr -d '[:space:]'` eats the newlines too. `test_renew_cert.sh` covers it.)

> ⚠️ **An empty `KAITEKI_CF_DNS_API_TOKEN` would hide for two months.** `--issue` checks the
> renewal date before it touches DNS, so a missing or renamed `.env` line reports "not due"
> every night and only surfaces on the one night the cert actually had to be renewed. The
> script now refuses to start on an empty token.

## DNS (both zones in the Blueprint CF account — `KAITEKI_CF_DNS_API_TOKEN` covers both)

Zone `kaiteki.my` (`6378ec…`):

| Record | Name | Value |
|--------|------|-------|
| A | `mail.kaiteki.my` / `webmail.kaiteki.my` | `187.127.122.41` (DNS-only) |
| MX | `kaiteki.my` | `mail.kaiteki.my` (10) |
| TXT (SPF) | `kaiteki.my` | `v=spf1 mx -all` |
| TXT (DKIM) | `v1-rsa-20260628._domainkey` / `v1-ed25519-20260628._domainkey` | `v=DKIM1; …` |
| TXT (DMARC) | `_dmarc.kaiteki.my` | `v=DMARC1; p=reject; rua=mailto:admin@blueprintdigital.my; fo=1` (one collector for every domain since #14) |

Zone `blueprintdigital.my` (`32c3ac…`), moved here from bpvps2 on 2026-09-12 (#9):

| Record | Name | Value |
|--------|------|-------|
| A | `mail.blueprintdigital.my` / `webmail.blueprintdigital.my` | `187.127.122.41` (DNS-only) |
| MX | `blueprintdigital.my` | `mail.blueprintdigital.my` (10) |
| TXT (SPF) | `blueprintdigital.my` | `v=spf1 mx -all` — was `mx ip4:187.127.207.82 -all`; the literal is gone so it cannot go stale again |
| TXT (DKIM) | `v1-rsa-20260912._domainkey` / `v1-ed25519-20260912._domainkey` | generated here in #8; the `20260805` pair (bpvps2's keys) was deleted |
| TXT (DMARC) | `_dmarc.blueprintdigital.my` | `v=DMARC1; p=reject; rua=mailto:admin@blueprintdigital.my; fo=1` |

> Both zones' mail records are on a **300 s TTL**, so a DNS rollback lands in minutes.

Zone `reservetoday.app` — **not Cloudflare: Vercel is authoritative** (`vercel dns … --scope
blueprintdigitalmy`; the Cloudflare zone of that name is a dead copy). Published 2026-09-12 (#10):

| Record | Name | Value |
|--------|------|-------|
| MX | `reservetoday.app` | `mail.blueprintdigital.my` (10) — the shared host; no `mail.reservetoday.app` exists, on purpose |
| TXT (SPF) | `reservetoday.app` | `v=spf1 mx ~all` — **soft**, three Clerk apps also send from this domain |
| TXT (DKIM) | `v1-rsa-20260912._domainkey` / `v1-ed25519-20260912._domainkey` | generated here in #8; Clerk's `clk` / `clk2` CNAMEs sit alongside and are not ours |
| TXT (DMARC) | `_dmarc.reservetoday.app` | `v=DMARC1; p=quarantine; adkim=r; aspf=r; rua=mailto:admin@blueprintdigital.my;` |

> **Do not "fix" this zone up to `-all` / `p=reject`** to match the other two until DMARC
> reports show Clerk passing — a hardfail here can send the booking product's magic links to
> spam. The full reasoning and the record diffs are in `docs/tls-wildcard-constraint.md`.

PTR (Hostinger hPanel, manual — no API token for this account): `187.127.122.41` should
read **`mail.blueprintdigital.my`**, the name Stalwart announces at SMTP greeting time
(FCrDNS / deliverability). ⚠️ **Still `mail.kaiteki.my` as of the #9 cutover** — the hPanel
change is pending; FCrDNS still resolves, so deliverability is unaffected until it is done.

> **Anti-spoof on `kaiteki.my` and `blueprintdigital.my`: SPF `-all` + DMARC `p=reject`
> (hardfail) — do not loosen.** On those two zones `mx` (this VPS) is the *only* authorized
> sender, so hardfail is safe; `reservetoday.app` is the exception above, because Clerk also
> sends for it. Set 2026-07-30 after a forged
> `support@kaiteki.my` phish (a non-existent address; SMTP lets anyone forge From) reached
> `hr@`'s Inbox: the old `~all`/`p=quarantine` was a softfail so Stalwart accepted it as ham.
> If you ever add a 3rd-party sender (CRM, marketing), add its `include:` to SPF **before** it
> sends, or DMARC will reject it. Watch the `rua` reports at `admin@kaiteki.my` for spoof attempts.

## ⚠️ Gotchas / landmines
- **Stalwart is version-pinned** (`v0.16.21` since 2026-09-12, #13; was `v0.16.16`), not
  `:latest` — an unattended `up -d` must not cross a major (1.0) with a data migration. Bump
  the tag deliberately; `0.16.x → 0.16.y` is a plain binary swap per upstream, and the
  `.16 → .21` bump was exactly that: no store migration, every setting intact, same management
  surface. Back up the `stalwart-data` volume first (see Ops).
  > **Do not expect a bump within 0.16.x to add an admin UI.** #13 was opened on the theory
  > that `.16` lacked a management surface; it was canaried on bpvps2 and the surface on
  > `.21` is byte-for-byte the same story — `/api/*` 404, `/manage/` 404, `/admin/` is the
  > self-service Portal. The management surface IS the JMAP `x:` API below, on every 0.16.x.
- **Only 25/465/993/995/4190 actually serve.** The compose also publishes 587/143/110 but
  Stalwart has **no listener** on them (implicit-TLS-only setup), so those three are dead
  ports — a connection is accepted by docker-proxy and then dropped. Add the listener
  (`x:NetworkListener/set`, "Configuring this build") *first* if a client ever needs STARTTLS
  submission. 4190 listens but is blocked at
  the Hostinger firewall.
- **`config.json` is persistence-critical** — the storage pointer Stalwart reads on boot
  (`/etc/stalwart/config.json`), bind-mounted from `./config.json`. Without it a container
  recreate wipes Stalwart back into the setup wizard (mail data survives, config lost).
- **Most config lives in the store**, written over JMAP `x:` methods — there is no admin UI on
  this build. See "Configuring this build" below for the exact calls.
- Stalwart settings the webmail depends on, all already set in the store: **`defaultHostname =
  mail.blueprintdigital.my`**, the **TLS File** cert refs, **`x:Http.useXForwarded = true`**, and an
  **`x:AllowedIp`** entry `172.16.0.0/12`. CORS is handled by **Traefik** (Stalwart
  `usePermissiveCors` stays `false`).
- ⚠️ **The default hostname is a public-DNS commitment.** Stalwart builds the absolute JMAP
  session URLs from it and ignores the request's `Host` header, and Bulwark serves its JMAP host
  to the *browser*. Changing it to a name whose public A record is another machine sends every
  webmail user to that machine, with a valid certificate and no error.
  See [`docs/mail/hostname-cutover-constraint.md`](../../../../docs/mail/hostname-cutover-constraint.md).
- ⚠️ **fail2ban behind a reverse proxy** — Stalwart bans by source IP; behind Traefik every request
  looks like it comes from Traefik's container IP, so a bot scan for an HTTP "banned path"
  (`*/wp-*`, `*.php*`, …) bans the proxy and **every mail web UI 502s**. The two settings above fix
  it: XFF trust makes bans use the real client IP, and the Allowed-IPs entry exempts the proxy.
  > The entry was `172.16.0.0/16` until 2026-09-12, which was only correct **here** because this
  > host's `stalwart_mailnet` happens to be `172.16.3.0/24` — bpvps2's mailnet is `172.21.0.0/16`,
  > outside it. It is now **`172.16.0.0/12`**, Docker's whole default pool, which is the value
  > to use on any host. Check with `docker network inspect stalwart_mailnet` before trusting it.
  > Bans persist in the store — restarting Stalwart does **not** clear them.
- Old DKIM verifiers (e.g. port25) can't evaluate Ed25519 → harmless `permerror`; RSA passes.
- **DNSBLs only work through the local `unbound` container** (added 2026-08-27). Spamhaus/URIBL
  refuse public+shared resolvers: via the host default, `2.0.0.127.zen.spamhaus.org` (the
  must-always-list test point) returned NXDOMAIN, so every RBL check silently scored 0 — this is
  how obvious phish reached inboxes. The `stalwart` service pins `dns: 172.16.3.53` (unbound's
  static mailnet IP). If unbound is down Stalwart has **no outbound DNS at all** (delivery pauses
  and retries) — check `docker ps` for `unbound` before debugging "DNS is broken" inside Stalwart.
  Re-test with: `docker run --rm --network stalwart_mailnet --dns 172.16.3.53 alpine nslookup
  2.0.0.127.zen.spamhaus.org` → must return `127.0.0.2/4/10`.

## Branding — one Bulwark, a different brand per webmail hostname
`webmail.kaiteki.my` shows the Kaiteki mark and "Kaiteki Mail"; `webmail.blueprintdigital.my`
shows the Blueprint lockup and "Blueprint Mail". Same container. Bulwark picks the brand from
the request `Host` / `X-Forwarded-Host` (Traefik forwards both) and answers it at
`/api/config`, which is what `verify-mail.sh` asserts per domain (`BRANDING_EXPECT` in
`scripts/verify-mail.d/<domain>.conf`).

- **It is all compose environment, never the admin dashboard.** `APP_NAME`, `FAVICON_URL`,
  `PWA_*`, `LOGIN_*` are the agency defaults; `DOMAIN_BRANDING` (one JSON array, folded over
  several lines in `docker-compose.yml`) carries the per-hostname overrides. The dashboard's
  branding page writes to the `bulwark-admin` volume, which is not backed up and is not in git
  — and anything set there **silently overrides** the env, so if a value on the page does not
  match the compose file, look at `/admin` before anything else.
- **Logo files live in `./branding/<brand>/` and are bind-mounted** to
  `/app/public/branding/<brand>` (read-only). Next.js serves `/app/public` from disk at request
  time, so a new file is live on the next request; no image rebuild. Each brand has a light and a
  dark login logo — Kaiteki's dark one is the same PNG with the taupe lifted to cream. The
  Blueprint lockup's "Blueprint" is **outlined Archivo** (wdth 75 / wght 900, the marketing
  site's display axes), not a `font-family` reference: Bulwark loads the logo through `<img>`,
  and an SVG loaded that way cannot pull a web font, so text would render in whatever the
  visitor has installed. Regenerate with fontTools if the wordmark changes; don't hand-edit the
  path data.
- **The login page's colours are Bulwark's, not ours.** The supported branding surface is logos,
  names, links, favicon and the PWA theme/background colours (`#1c1039` / `#120926`, from the
  marketing site's tokens). The blue button and the card are Bulwark's stock theme; changing
  them means a Bulwark *theme*, which #5 puts out of scope. The version line is off
  (`LOGIN_SHOW_VERSION=false`).
- **Onboarding a client's webmail** = a DNS record for `webmail.<client>`, a Traefik router +
  CORS origin (`../traefik/dynamic/stalwart.yml`), the name added to `CERT_NAMES` in
  `renew-cert.sh`, a folder under `./branding/`, a mount line, a `DOMAIN_BRANDING` entry, and a
  `scripts/verify-mail.d/<domain>.conf`. Never a second container.
- To push a change: `docker compose up -d bulwark` on the host (see Ops for how to get files
  into the root-owned stack dir). Bulwark reads `DOMAIN_BRANDING` at startup.

## Verifying it works
`../../../../scripts/verify-mail.sh kaiteki.my admin@kaiteki.my` (from the repo root:
`./scripts/verify-mail.sh kaiteki.my`) checks this stack end to end from outside — MX/SPF/DKIM/DMARC,
the cert on **both** 443 and 465, the webmail and its branding, the CORS preflight, a real JMAP
login, and both delivery legs. Run it before and after any change here; it changes nothing.

> The inbound leg runs over SSH from `bp-vps3-prod` (`--via`), because home ISPs block outbound 25
> and a laptop probe would read BLOCKED on a healthy server. The outbound leg sends through 465 and
> waits for `check-auth@verifier.port25.com` to report the SPF/DKIM it observed, reading the reply
> back over JMAP — the estate has an instance that has never written a log line, so nothing here is
> proven by grepping our own logs. Mailbox passwords come from `.env` as `MAIL_PASSWORD_*`.

> ⚠️ **Traefik and Stalwart can drift onto different copies of the same cert.** Hit on 2026-09-12:
> port 443 served the **28 Jun** cert while port 465 served the **29 Aug** renewal — same names, same
> files, different serials, and 443 was 14 days from expiry. **Traefik watches its config file, not
> the cert files the config points at**, so a renewal that swaps the certs without touching
> `../traefik/dynamic/stalwart.yml` is never noticed. The README line claiming it "auto-reloads on
> change" was wrong. Fixed by `touch`ing that yml — no restart, no downtime. **The permanent fix
> landed with #7**: `renew-cert.sh` now touches that file after every install, and exits non-zero
> if the file is missing rather than reporting a renewal that only reached the mail ports. All
> ports serve the same serial. That is why `verify-mail.sh` checks 443 and 465 separately rather
> than assuming one cert.

> **`Multiple TLS certificates available … total = 4` (event `tls.multiple-certificates-available`)
> was SAN NAMES, not certificates, and it is silenced since #17 (2026-09-12).**
> `x:Certificate/get` returned exactly **one** object throughout; `total` went from 2 to 4 at
> the moment the cert went from two names to four. What was observed:
> `x:SystemSettings.defaultCertificateId` was `null`, and the warning fired every 30 s.
> Setting it to the file cert's id and restarting Stalwart stopped it (0 in the next 10 min,
> versus one per 30 s before). On that day 443/465/993 — `openssl s_client` with and without
> `-servername` — all served the file serial; the standing guard is `verify-mail.sh`, which
> checks the serial on 443 and 465 separately. **In-store ACME stays off**:
> `x:AcmeProvider/get` is empty and all three domains are `certificateManagement: Manual`.
> Keep it that way — the one certificate is shared with Traefik and renewed by
> `renew-cert.sh` (above); an `Automatic` domain would put a second, separately-renewed
> certificate in the store that Traefik never sees. If the warning comes back, check two
> things: `x:Certificate/get` has grown a second object, or `defaultCertificateId` no longer
> points at the one that exists (a store restore or a re-created object gets a new id).

## Ops
```bash
cd /root/stacks/stalwart
docker compose ps
docker compose up -d            # safe to recreate (config.json is mounted)
./renew-cert.sh                 # manual cert renew (also daily via cron)

# Version bump — back up the 8GB RocksDB store first (stop for a consistent copy):
docker compose stop stalwart
docker run --rm -v stalwart_stalwart-data:/d:ro -v /home/deploy/backups:/b \
  alpine tar cf /b/stalwart-data-$(date +%Y%m%d-%H%M).tar -C /d .
# ...edit the image tag, then:
docker compose pull stalwart && docker compose up -d stalwart
```
> On this host `docker compose` has to run from a `docker:cli` container (root-owned stack
> dir, see below). Stopping only the `stalwart` service keeps `unbound` and `bulwark` up.
> The `.16 → .21` bump on 2026-09-12 (#13) took **22 s** of mail downtime (14:22:39 →
> 14:23:01 UTC), almost all of it the 7.8 GB backup tar; pre-pull the image so the swap
> itself is a container recreate. Canary any future bump on a non-production
> instance first — bpvps2 played that role for #13 and is gone after #12.
>
> **Rollback** is the reverse: put the old tag back in the compose, `up -d stalwart`. The
> store is forward-compatible within 0.16.x, so the backup tar is only for a *damaged* store,
> restored with the "Proving a backup is restorable" recipe below pointed at the live volume
> (stop Stalwart first).
> `deploy` has no passwordless sudo and `/root/stacks/stalwart` is root-owned — to update a
> file there, pipe it through a container:
> `cat file | ssh bp-bpvps1 "docker run --rm -i -v /root/stacks/stalwart:/s alpine sh -c 'cat > /s/file'"`

### Proving a backup is restorable

`tar -tf` proves the archive is readable, not that Stalwart can open what is inside it. Restore
into a **scratch volume** and let Stalwart itself read the store — the live volume is never
touched, so this is safe to run against production at any time:

```bash
docker volume create stalwart-restoretest
docker run --rm -v stalwart-restoretest:/d -v /home/deploy/backups:/b:ro \
  alpine tar xf /b/stalwart-data-<stamp>.tar -C /d
mkdir -p /tmp/stexport && chown 2000:2000 /tmp/stexport   # Stalwart runs as uid 2000
docker run --rm --entrypoint /usr/local/bin/stalwart \
  -v stalwart-restoretest:/opt/stalwart \
  -v /root/stacks/stalwart/config.json:/etc/stalwart/config.json:ro \
  -v /tmp/stexport:/out \
  stalwartlabs/stalwart:v0.16.21 --export /out --config /etc/stalwart/config.json
rm -rf /tmp/stexport; docker volume rm stalwart-restoretest
```

> Two traps. The image's **ENTRYPOINT is the binary itself**, so `docker run … stalwart --export`
> passes `stalwart` as an argument and just prints usage — override the entrypoint. And the
> output directory must be writable by **uid 2000**, or the export dies mid-run with
> `Failed to create backup file: Permission denied` while still exiting **0**.

> `--console` needs an argument this build does not document and could not be invoked. Budget
> ~15 GB free: the restore is a second full copy of the store.

### Listing accounts

There is **no admin UI that lists accounts** on 0.16.x (checked on `.16` and `.21`) — `/account/` is a self-service page,
and the REST `/api/principal` of older versions is gone. Any instruction to "read it out of
the admin UI" is describing something this build does not have.

**JMAP does it instead**, two ways. `x:Account/get` (next section) is the management view:
every account with its role and domain, and needs the **Admin** role. The RFC `Principal/get`
returns every account to any mailbox; reading those accounts' *mail* is what needs Admin,
and that is what `scripts/mail-inventory.py <domain>` does (see `docs/mail/`). Since
2026-09-12 the Admin is `admin@blueprintdigital.my`, not `admin@kaiteki.my`. It is also why
`verify-mail.sh` takes the accounts to test as arguments: "can this real person sign in" is
the better test.

### Configuring this build — the management API is JMAP with an `x:` prefix

**v0.16 deleted the REST management API.** Every setting now lives in the datastore as a JMAP
object, reached through the ordinary `/jmap` endpoint. `config.json` on disk describes only the
datastore; there is no TOML to edit (`/opt/stalwart/etc/config.toml` exists and is **empty**).
The "admin UI → Settings → …" phrasing in older notes describes the webadmin this build no
longer ships: `/admin/` and `/account/` serve the same self-service "Portal" bundle.

**The methods are `x:<Object>/{get,set,query}`**, and `using` must include
`urn:stalwart:jmap`. That prefix is the whole trick — `Domain/get` is `unknownMethod`,
`x:Domain/get` works. (Source: `crates/jmap-proto/src/request/method.rs` at tag v0.16.16.
Confirmed live here 2026-09-12 on `.16`, and again on `.21` after #13 — same methods, same
shapes, same answers.) Basic auth as any account with the **Admin** role, or as the
env recovery admin (`STALWART_RECOVERY_ADMIN`) over loopback `:8090`.

```bash
# On the host. Read the three domains, the hostname, and the proxy setting in one call.
cd /root/stacks/stalwart
P=$(grep -E '^STALWART_RECOVERY_PASS=' .env | cut -d= -f2- | tr -d '"'"'"'\r')
curl -s -u "admin:$P" -H 'Content-Type: application/json' http://127.0.0.1:8090/jmap -d '{
  "using":["urn:ietf:params:jmap:core","urn:stalwart:jmap"],
  "methodCalls":[
    ["x:Domain/get",{"properties":["id","name","isEnabled"]},"d"],
    ["x:SystemSettings/get",{"ids":["singleton"]},"s"],
    ["x:Http/get",{"ids":["singleton"]},"h"],
    ["x:AllowedIp/get",{},"a"]]}'
```

The objects this stack has needed so far, with the exact shapes that worked:

| Need | Call |
|---|---|
| Add a domain (DKIM keys are generated automatically on create) | `x:Domain/set` `{"create":{"n0":{"name":"example.my","isEnabled":true,"dkimManagement":{"@type":"Automatic","algorithms":{"Dkim1Ed25519Sha256":true,"Dkim1RsaSha256":true},"selectorTemplate":"v{version}-{algorithm}-{date-%Y%m%d}","rotateAfter":7776000000,"retireAfter":604800000,"deleteAfter":2592000000}}}}` |
| Read DKIM selectors + public keys | `x:DkimSignature/get` `{"properties":["selector","domainId","publicKey","stage"]}` — or read the domain's `dnsZoneFile`, which is the ready-to-paste TXT |
| Force a DKIM rotation | `x:Task/set` `{"create":{"t":{"@type":"DkimManagement","domainId":"<id>"}}}` |
| Create an account | `x:Account/set` `{"create":{"n0":{"@type":"User","name":"alice","domainId":"<id>","roles":{"@type":"User"},"credentials":{"0":{"@type":"Password","secret":"…"}}}}}` — `emailAddress` is derived as `name@domain` |
| Grant / remove the administrator role | `x:Account/set` `{"update":{"<id>":{"roles":{"@type":"Admin"}}}}` — variants are `User`, `Admin`, `Custom` |
| Default hostname | `x:SystemSettings/set` `{"update":{"singleton":{"defaultHostname":"…"}}}` — ⚠️ read the hostname warning above first |
| Trust `X-Forwarded-For` | `x:Http/set` `{"update":{"singleton":{"useXForwarded":true}}}` |
| Allowed (never-banned) networks | `x:AllowedIp/set` `{"create":{"n0":{"address":"172.16.0.0/12","reason":"…"}}}` — `address` is immutable: to change one, create the new entry and `destroy` the old id |
| List TLS certificates (SANs, issuer, expiry are server-derived from the file) | `x:Certificate/get` `{"properties":["id","certificate","issuer","notValidAfter","subjectAlternativeNames"]}` — here `certificate`/`privateKey` are `{"@type":"File","filePath":"…"}` |
| Pin which cert the mail ports present without SNI (silences `multiple-certificates-available`; needs a restart) | `x:SystemSettings/set` `{"update":{"singleton":{"defaultCertificateId":"<x:Certificate id>"}}}` |
| See whether anything mints certs in-store | `x:AcmeProvider/get` `{}` (must stay empty) and `x:Domain/get` `{"properties":["name","certificateManagement"]}` (must all be `{"@type":"Manual"}`) |

Singletons are addressed by the literal id `"singleton"`. Tagged unions use `"@type"`. Lists
are objects keyed `"0"`, `"1"`, …. `query` filters are flat (`{"filter":{"name":"example.my"}}`)
and only indexed properties filter. There is no `changes`/`queryChanges` for `x:` objects.

> The full property reference is the server's own schema:
> `GET /api/schema` with Basic auth **302s to `/api/schema/<hash>`** for the running build
> (seen on `.21`), so `curl -sL --compressed -u admin:… http://127.0.0.1:8090/api/schema` is
> the whole lookup (~940 KB of JSON; it comes back gzip-encoded whether or not you asked, hence
> `--compressed`) — no need for `resources/schema/schema.json.sha256` in the source tree. Upstream also publishes `stalwart-cli`
> (`github.com/stalwartlabs/cli`, a separate repo — it is **not** a release asset of the server),
> which speaks exactly this protocol and derives its commands from that schema. Not yet used here.

> `--console` is a **raw key-value store debugger** (`scan`/`get`/`put`/`delete` on serialized
> blobs), needs the server stopped to take the RocksDB lock, and knows nothing about domains
> or settings. It is not an admin CLI. Its "Missing value for argument" response to every
> input is why it was written off; the answer was never there anyway.

**State of this instance as of 2026-09-12 (#8, #9, #17):**

| Object | Value |
|---|---|
| Domains | `kaiteki.my` (id `b`), `blueprintdigital.my` (`c`), `reservetoday.app` (`d`) — all with automatic DKIM |
| Administrator | **`admin@blueprintdigital.my`** (id `t`). `admin@kaiteki.my` (id `b`) is a plain `User` mailbox again. The recovery admin in `.env` is unchanged. |
| `blueprintdigital.my` mailboxes | `admin@` (`t`), `chriskke@` (`u`), `danielchua@` (`v`), `yuchen@` (`w`) — the last three re-created from bpvps2 in #9 with fresh passwords (`MAIL_PASSWORD_*` in the repo `.env`) |
| `reservetoday.app` mailboxes | `hello@` (`x`, #15), `admin@` (`y`, #10) — both plain `User`; the domain's DNS went live 2026-09-12 (#10) |
| `defaultHostname` | **`mail.blueprintdigital.my`** since #9 (2026-09-12), moved together with the A records — see the hostname warning |
| `useXForwarded` | `true` (was already) |
| Allowed IPs | `172.16.0.0/12` (Docker default pool; replaced the `/16`), `60.54.118.137` (Kaiteki office) |
| TLS | one `x:Certificate` (`iydcxwghksqa`, `File` → `/opt/stalwart/certs/{fullchain,key}.pem`), pinned as `defaultCertificateId` since #17; `x:AcmeProvider` empty; every domain `certificateManagement: Manual` |

`scripts/mail-inventory.py` and anything else that reads other people's mailboxes must now
authenticate as `admin@blueprintdigital.my` (`INVENTORY_ACCOUNT` in the domain conf,
`MAIL_PASSWORD_ADMIN_BLUEPRINTDIGITAL_MY` in `.env`). The Kaiteki admin can still list
accounts, but every read of another mailbox is `forbidden`.
