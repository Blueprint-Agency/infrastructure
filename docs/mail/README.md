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

Stalwart v0.16.16 has **no scriptable admin surface and no admin UI that lists accounts**.
`/api/principal` and every sibling management path 404, both through Traefik and directly on
the container; the OAuth metadata advertises only `mail`, `contacts` and `calendars` scopes,
so there is no admin scope to request; `/account/` is a self-service page whose JS bundle
contains exactly two routes; and `--console` demands an argument this build does not
document. Tickets that say "read it out of the admin UI" are describing something that does
not exist here.

What does work: the admin mailbox can run JMAP `Principal/get`, which enumerates every
account on the server, and can then query other accounts' mail. Sizes are summed from each
message rather than read from `Quota/get`, because no quotas are configured on this instance
and `Quota/get` accordingly returns an empty list for every account.

## Captures

| File | Domain | Taken | Why |
|---|---|---|---|
| `kaiteki.my-inventory-2026-09-12.json` | kaiteki.my | 2026-09-12 | The **before** half for the Stalwart consolidation (#5), captured alongside the verified backup in #7. 17 accounts, 158,907 messages. |
