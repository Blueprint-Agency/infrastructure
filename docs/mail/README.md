# Mail inventories

Account-by-account snapshots of a mail domain, one JSON file per capture, named
`<domain>-inventory-<date>.json`. They exist so a migration can be proved invisible: capture
before, capture after, diff the two.

Produce one with the script, never by hand:

```bash
python scripts/mail-inventory.py kaiteki.my --out docs/mail/kaiteki.my-inventory-$(date +%F).json
```

## What is in a file

Per account: the address, its description, its message count, and the summed size of its
messages. Plus a `totals` block.

> **`bytes` is the sum of message sizes, not the size of the store on disk.** It excludes
> RocksDB overhead and index space and cannot see compression or single-instance storage, so
> it will not match `du` on the volume. On 2026-09-12 the sum was 7.86 GiB against a 7.4 GiB
> volume — the right ballpark, in the direction you would expect. Compare a snapshot against
> another snapshot, never against a disk figure.

## Why this is JMAP and not the admin UI

Stalwart 0.16.x (checked on `.16` and `.21`) has **no admin UI that lists accounts**. The REST `/api/principal` of older
versions is gone, `/account/` is a self-service page, and `--console` is a raw key-value
debugger. Tickets that say "read it out of the admin UI" are describing something that does
not exist here.

What does work is JMAP. The management API is `x:Account/get` and friends (JMAP methods with
an `x:` prefix and `urn:stalwart:jmap` in `using` — see the stalwart stack README,
"Configuring this build"). This script predates that discovery and uses the RFC
`Principal/get` instead, which enumerates every account for any mailbox; reading those
accounts' mail is what needs the **Admin** role. Since 2026-09-12 that is
`admin@blueprintdigital.my` (`INVENTORY_ACCOUNT` in the domain conf), not
`admin@kaiteki.my`, which now dies on `forbidden` at the first foreign mailbox. Sizes are summed from
each message rather than read from `Quota/get`, because no quotas are configured on this
instance and `Quota/get` accordingly returns an empty list for every account.

## Captures

| File | Domain | Taken | Why |
|---|---|---|---|
| `kaiteki.my-inventory-2026-09-12.json` | kaiteki.my | 2026-09-12 | The **before** half for the Stalwart consolidation (#5), captured alongside the verified backup in #7. 17 accounts, 158,907 messages. |
| `platform-inventory-2026-09-12-after-issue15.json` | all three (run as `blueprintdigital.my`) | 2026-09-12 | After the staff mailboxes (#15). 23 accounts: Kaiteki's 17 unchanged in name and size except `admin@kaiteki.my`, which had received 16 new messages — a live inbox, not drift — plus `admin@`/`chriskke@`/`danielchua@`/`yuchen@blueprintdigital.my` and `admin@`/`hello@reservetoday.app`. |

> **The script lists the whole platform, whatever domain you name.** `Principal/get`
> enumerates every account on the instance; the domain argument only picks the conf (and
> so the admin login). One capture covers all three domains — name the file accordingly.

## Staff-facing

[`staff-mail-setup.md`](staff-mail-setup.md) is the one-page card handed to a new mailbox
owner (webmail first; IMAP 993/465 SSL; full address as username), with the operator's
temporary-password convention at the bottom. The per-domain onboarding checklist — the
`onboard-mail-domain` skill, `.claude/skills/onboard-mail-domain/SKILL.md` (#12) — links to
it at its "mailboxes" step.

## Branding screenshots

`branding-screenshots/<brand>-<light|dark>-<desktop|phone>.png` — the two webmail login pages
as delivered in #11 (2026-09-12), at 1280px and 400px, in both colour schemes. Taken with
Playwright against the live hostnames, `color_scheme` emulated, PWA install nag dismissed.
They are evidence for the ticket, not a spec: the branding itself is
`vps/bpvps1/stacks/stalwart/docker-compose.yml`.
