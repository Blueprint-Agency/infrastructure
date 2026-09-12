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
One LE cert for `mail.kaiteki.my` + `webmail.kaiteki.my`, issued **out-of-band via
Cloudflare DNS-01** (acme.sh + `KAITEKI_CF_DNS_API_TOKEN`) because Traefik's CF token only
covers `teeko.ai`. Cert lands in `./certs/{fullchain,key}.pem`.
- **Traefik** serves it via the file provider (`stalwart.yml`).
- **Stalwart** reads the same files for mail TLS — set in the admin UI → Settings → TLS as
  **File** references. ⚠️ The files must be readable by Stalwart's user: `chown 2000:2000 ./certs/*.pem`.
- Renewal: `renew-cert.sh` (daily host cron) re-runs acme.sh (it **reads `CF_Token` from the
  stack `.env`** — the saved-creds path is unreliable), reinstalls to `./certs`, re-chowns,
  restarts Stalwart. Cert is **ECC**, acme dir `./acme/mail.kaiteki.my_ecc/`.

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

> ⚠️ **Traefik and Stalwart can drift onto different copies of the same cert.** Verified 2026-09-12:
> port 443 served the **28 Jun** cert while port 465 served the **29 Aug** renewal — same names, same
> files, different serials. `renew-cert.sh` restarts Stalwart but nothing makes Traefik re-read the
> file, so the web UIs keep the old cert until Traefik is restarted, and expire on the old date.
> That is why `verify-mail.sh` checks 443 and 465 separately rather than assuming one cert.

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
