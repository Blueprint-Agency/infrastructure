# Stalwart + Bulwark — self-hosted email for `kaiteki.my` (BPVPS1)

**Stalwart** (Rust mail server, v1.0) handles SMTP/IMAP/POP3/JMAP/ManageSieve + DKIM +
spam; **Bulwark** is a modern JMAP webmail (HTML compose, themes, calendar, contacts,
files, built-in admin dashboard). Replaced the earlier Roundcube webmail; the mail host
was renamed `email.kaiteki.my` → `mail.kaiteki.my`.

| | URL | Login |
|---|---|---|
| Stalwart admin | `https://mail.kaiteki.my` (→ `/account`) | `admin@kaiteki.my` |
| Webmail | `https://webmail.kaiteki.my` | mailbox creds (e.g. `admin@kaiteki.my`) |
| Bulwark admin dashboard | `https://webmail.kaiteki.my/admin` | `ADMIN_PASSWORD` (stack `.env`, `BULWARK_ADMIN_PASSWORD`) |

Stack dir on VPS: `/root/stacks/stalwart/`. Mail data in the `stalwart-data` volume
(RocksDB at `/opt/stalwart/data`). Co-hosted behind the existing Traefik.

## How it fits together
- **Mail ports** (25/465/587/993/143/110/995/4190) bind directly on the host.
- **Web UIs** go through Traefik: `mail.` → `stalwart:8080`, `webmail.` → `bulwark:3000`,
  over the external `stalwart_mailnet` network. See `../traefik/dynamic/stalwart.yml`.
- **Bulwark → Stalwart is JMAP over HTTPS.** Bulwark uses `JMAP_SERVER_URL=https://mail.kaiteki.my`
  and follows the **absolute** URLs Stalwart returns in its JMAP session. So:
  - Stalwart's **Default Hostname must be `mail.kaiteki.my`** (admin UI → Settings → Network),
    otherwise the session advertises the wrong host and the webmail breaks.
  - `mail.kaiteki.my` is a **network alias on Traefik** (`../traefik/docker-compose.yml`) so the
    Bulwark container resolves it internally to Traefik → valid cert → `stalwart:8080`.
  - The browser also calls JMAP **cross-origin** (`webmail.` → `mail.`, incl. `/.well-known/jmap`),
    so **Traefik adds CORS** for the mail host (specific origin `https://webmail.kaiteki.my` +
    `Allow-Credentials: true`, and it answers preflight) — see the `mail-cors` middleware in
    `../traefik/dynamic/stalwart.yml`. Stalwart's own "Permissive CORS" is left **OFF**: it only
    emits `*` (which browsers reject for credentialed / "Remember me" requests) and it doesn't
    cover the `/.well-known/jmap` discovery redirect.
  - Stalwart must trust the proxy: **Settings → Network → HTTP Server → "Obtain remote IP from
    Forwarded header" = ON**, plus **Settings → Security → Allowed IPs → `172.16.0.0/16`**. Without
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
- **Stalwart** reads the same files for mail TLS — set in the admin UI → Settings → TLS as
  **File** references. ⚠️ The files must be readable by Stalwart's user: `chown 2000:2000 ./certs/*.pem`.
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

## DNS (zone `kaiteki.my`, separate CF account — `KAITEKI_CF_DNS_API_TOKEN`, zone `6378ec…`)
| Record | Name | Value |
|--------|------|-------|
| A | `mail.kaiteki.my` / `webmail.kaiteki.my` | `187.127.122.41` (DNS-only) |
| MX | `kaiteki.my` | `mail.kaiteki.my` (10) |
| TXT (SPF) | `kaiteki.my` | `v=spf1 mx -all` |
| TXT (DKIM) | `v1-rsa-20260628._domainkey` / `v1-ed25519-20260628._domainkey` | `v=DKIM1; …` |
| TXT (DMARC) | `_dmarc.kaiteki.my` | `v=DMARC1; p=reject; rua=mailto:admin@kaiteki.my; fo=1` |

PTR (Hostinger hPanel): `187.127.122.41` → **`mail.kaiteki.my`** (FCrDNS / deliverability).

> **Anti-spoof: SPF `-all` + DMARC `p=reject` (hardfail) — do not loosen.** `mx` (this VPS)
> is the *only* authorized sender, so hardfail is safe. Set 2026-07-30 after a forged
> `support@kaiteki.my` phish (a non-existent address; SMTP lets anyone forge From) reached
> `hr@`'s Inbox: the old `~all`/`p=quarantine` was a softfail so Stalwart accepted it as ham.
> If you ever add a 3rd-party sender (CRM, marketing), add its `include:` to SPF **before** it
> sends, or DMARC will reject it. Watch the `rua` reports at `admin@kaiteki.my` for spoof attempts.

## ⚠️ Gotchas / landmines
- **Stalwart is version-pinned** (`v0.16.16`), not `:latest` — an unattended `up -d` must not
  cross a major (1.0) with a data migration. Bump the tag deliberately; `0.16.x → 0.16.y` is a
  plain binary swap per upstream. Back up the `stalwart-data` volume first (see Ops).
- **Only 25/465/993/995/4190 actually serve.** The compose also publishes 587/143/110 but
  Stalwart has **no listener** on them (implicit-TLS-only setup), so those three are dead
  ports — a connection is accepted by docker-proxy and then dropped. Add the listener in the
  admin UI *first* if a client ever needs STARTTLS submission. 4190 listens but is blocked at
  the Hostinger firewall.
- **`config.json` is persistence-critical** — the storage pointer Stalwart reads on boot
  (`/etc/stalwart/config.json`), bind-mounted from `./config.json`. Without it a container
  recreate wipes Stalwart back into the setup wizard (mail data survives, config lost).
- **Most config lives in the store**, set via the admin UI. The v1.0 management REST API is
  OAuth-only and not the documented `/api/settings*` path — there's no easy scripting; use the UI.
- Stalwart settings the webmail depends on (all via the admin UI): **Default Hostname =
  mail.kaiteki.my**, the **TLS File** cert refs, **"Obtain remote IP from Forwarded header" = ON**,
  and an **Allowed IPs** entry `172.16.0.0/16`. CORS is handled by **Traefik** (Stalwart Permissive
  CORS stays OFF).
- ⚠️ **fail2ban behind a reverse proxy** — Stalwart bans by source IP; behind Traefik every request
  looks like it comes from Traefik's container IP, so a bot scan for an HTTP "banned path"
  (`*/wp-*`, `*.php*`, …) bans the proxy and **every mail web UI 502s**. The two settings above fix
  it: XFF trust makes bans use the real client IP, and the Allowed-IPs entry exempts the proxy.
  > ⚠️ `172.16.0.0/16` is only correct **here**, because this host's `stalwart_mailnet` happens
  > to be `172.16.3.0/24`. Don't copy that value to another host — bpvps2's mailnet is
  > `172.21.0.0/16`, outside the /16. Prefer **`172.16.0.0/12`**, which covers Docker's whole
  > default pool. Check with `docker network inspect stalwart_mailnet` before trusting it.
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

> **Stalwart logs `Multiple TLS certificates available` continuously — the number is SAN
> NAMES, not certificates, and it is harmless.** The earlier reading of this, that a leftover
> entry in the store meant "which cert the mail ports present is not fully determined", was
> wrong and is corrected here. `total` went from **2 to 4 at the exact moment** the cert went
> from two names to four (2026-09-12), with one `fullchain.pem` on disk throughout and no
> change to the store. It is counting resolvable SNI names. There is one certificate and
> `verify-mail.sh` checks its serial on 443 and 465 separately, which is the real guard.

## Ops
```bash
cd /root/stacks/stalwart
docker compose ps
docker compose up -d            # safe to recreate (config.json is mounted)
./renew-cert.sh                 # manual cert renew (also daily via cron)

# Version bump — back up the 7GB RocksDB store first (stop for a consistent copy):
docker compose stop
docker run --rm -v stalwart_stalwart-data:/d:ro -v /home/deploy/backups:/b \
  alpine tar cf /b/stalwart-data-$(date +%Y%m%d).tar -C /d .
# ...edit the image tag, then:
docker compose pull && docker compose up -d
```
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
  stalwartlabs/stalwart:v0.16.16 --export /out --config /etc/stalwart/config.json
rm -rf /tmp/stexport; docker volume rm stalwart-restoretest
```

> Two traps. The image's **ENTRYPOINT is the binary itself**, so `docker run … stalwart --export`
> passes `stalwart` as an argument and just prints usage — override the entrypoint. And the
> output directory must be writable by **uid 2000**, or the export dies mid-run with
> `Failed to create backup file: Permission denied` while still exiting **0**.

> `--console` needs an argument this build does not document and could not be invoked. Budget
> ~15 GB free: the restore is a second full copy of the store.

### Listing accounts

There is **no admin API and no admin UI that lists accounts** on v0.16.16 — `/api/principal`
and every sibling 404 (through Traefik and directly on the container), the OAuth metadata
offers only `mail`/`contacts`/`calendars` scopes so there is no admin scope to ask for, and
`/account/` is a self-service page whose JS bundle holds exactly two routes. Any instruction
to "read it out of the admin UI" is describing something this build does not have.

**JMAP does it instead.** The admin mailbox can run `Principal/get`, which returns every
account on the server, and can query other accounts' mail. That is what
`scripts/mail-inventory.py <domain>` is built on — see `docs/mail/`. It is also why
`verify-mail.sh` takes the accounts to test as arguments: that predates knowing this worked,
and "can this real person sign in" is still the better test.
