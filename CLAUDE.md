# Infrastructure Repository

Central infrastructure-as-code repo. Manages all VPS, Docker deployments, CI/CD, monitoring, and GitHub org.

## Credentials Rule

**All credentials live in `.env` only.** Never hardcode tokens or passwords anywhere else. `.env` is gitignored. Use `.env.example` as the template.

## Two Accounts — Read This First

**Only Cloudflare and Hostinger are split.** Everything else is single-tenant. Verified 2026-08-09.

| | Teeko | Blueprint |
|---|---|---|
| Cloudflare account | `Teekoaitech@gmail.com` | `Askblueprintagency@gmail.com` |
| Zones | teeko.ai | kaiteki.my, blueprintdigital.my, reservetoday.app ⚠️ |
| Hostinger account | ⚠️ unknown — see below | holds bpvps1 + bpvps2 |
| Hosts | vps1-staging, vps2-prod, vps3-prod | bpvps1, bpvps2 |
| CI (`deploy-infra.yml`) | automated | **not** automated — deploy by hand |

> ⚠️ **`reservetoday.app` is in the Blueprint Cloudflare account but Cloudflare does NOT serve
> it.** Its nameservers are `ns1`/`ns2.vercel-dns.com` — Vercel is authoritative, and the
> Cloudflare zone is a staged copy for a nameserver move that has not happened. Editing it
> changes nothing that resolves. Use `vercel dns ls|add|rm reservetoday.app` (scope
> `blueprintdigitalmy`). Verified 2026-08-31. See `docs/tls-wildcard-constraint.md`.

Shared across both, with **no** per-account split:

| | Single tenant |
|---|---|
| GitHub | one org, `Blueprint-Agency` |
| Vercel | one team, `askblueprintagency-7138s-projects` — holds `teeko-ehailing-*` **and** `booking-system-*`, `blueprint-marketing-website`, `vatti-web`, `persistence-chiro` |
| Tailscale | one tailnet, `taild19da3.ts.net` — all 5 VPS are members |

> ⚠️ The GitHub PAT can also see **`Inquantum-AI`** — a different client's org. Same hazard as the
> bare `vps1-staging` / `vps2-prod` SSH aliases. Check the org name before any write via the REST API.

## MCP Servers

The configured servers, the account-suffix rule, and the scoped-binary rule all live in
`.mcp.json.example` (`_comment_*` keys). Read that, not a copy of it.

**Deliberately not MCP servers.** **GitHub** — `curl` + REST with the `.env` PAT covers repos,
secrets and environments in ~4 calls; an MCP adds ~90 tools. **Tailscale** — no official server
exists and the community ones are unsupported. **`hostinger-{dns,domains,hosting,mail,reach}`** —
both accounts own zero registered domains and zero hosting/mail subscriptions, so these would
manage nothing. DNS is Cloudflare, mail is self-hosted Stalwart.

> ⚠️ **VPS1/2/3 are in no Hostinger account we hold a token for — parked, not solved.** Verified
> 2026-08-09: the Teeko token authenticated (`/vps/v1/data-centers` returned 9; a bogus token 401s)
> but `/vps/v1/virtual-machines`, `/domains/v1/portfolio` and `/billing/v1/subscriptions` all
> returned **empty**. The Blueprint token sees only bpvps1 + bpvps2. So `72.61.114.7`,
> `72.60.235.226`, `72.62.74.77` live under a **third login**. **No `hostinger-*-teeko` server is
> configured**, because one would answer "VPS not found" instead of failing loudly. VPS1/2/3
> firewalls and snapshots stay hPanel-only until the right account is found.

> The Teeko token itself was **removed from `.env` on 2026-08-27** and should be revoked in
> hPanel. Nothing read it — no MCP server, no script, no workflow — so it was a live credential
> guarding nothing. If the third login is ever found, generate a **fresh** token there; do not go
> looking for this one. (Hostinger's API sits behind Cloudflare and 403s `error code: 1010` on a
> bare urllib request — send a normal `User-Agent`, or a live token looks dead.)

**GitHub**: use `git` (bash) for repo operations and `curl` + GitHub REST API for org/repo
management, secrets, and environments. PAT in `.env` as `GITHUB_PERSONAL_ACCESS_TOKEN`.
No GitHub MCP and no `gh` CLI installed — don't reach for either.

**VPS/Docker**: use `ssh bp-vps1-staging` / `ssh bp-vps2-prod` / `ssh bp-vps3-prod` directly.
The Hostinger MCP does **not** replace SSH — it is the hypervisor control plane (power, firewall,
snapshots), and cannot see inside the VM. Anything about containers, files, logs, or `docker
compose` is still SSH.

## VPS Access

| Alias | Role | Specs |
|-------|------|-------|
| `bp-vps1-staging` | Staging | 2 vCPU / 8GB / 100GB |
| `bp-vps2-prod` | Production | 4 vCPU / 16GB / 200GB |
| `bp-vps3-prod` | Production | 4 vCPU / 16GB / 200GB |
| `bp-bpvps1` | Kaiteki (legacy + revamp) + **the mail platform** (all three domains) | 187.127.122.41 |
| `bp-bpvps2` | Booking-system + its `backup` and `monitoring` stacks (the mail-port prober for bpvps1) — no mail since 2026-09-12 (#12) | 187.127.207.82 |

SSH key: `~/.ssh/infra_ed25519`. All hosts log in as **`deploy`**, not root — `deploy` is in the `docker` group and owns `/root/stacks`. Hosts defined in `~/.ssh/config`.

> `deploy` has **no sudo** — only `docker` group membership. Root login is still permitted on purpose:
> it is the break-glass path for anything daemon-level, including the Docker 29.x systemd drop-in
> below. Don't set `PermitRootLogin no` without granting `deploy` sudo first, or that fix becomes
> unappliable. (VPS1/2/3 `deploy` accounts got the `chriskke-infra` key on 2026-08-09; before that
> only the CI key was authorized and interactive logins went in as root.)

> ⚠️ **Always use the `bp-` prefix.** The bare aliases `vps1-staging` / `vps2-prod` in `~/.ssh/config` belong to a **different client (Inquantum AI)** on a different key — operating on them by mistake hits the wrong company's servers. There is no bare `vps3-prod`.

> ⚠️ **`bp-bpvps2` is NOT `bp-vps2-prod`.** One is the booking-system host; the other is live teeko.ai production. They differ by two characters. Re-read the alias before any `docker compose down`, volume removal, or `psql` write.

## What's Running

Per-host stack list is `ls vps/<host>/stacks/`; container names and domains are in each stack's
compose labels; the app → VPS → image → domain mapping is `apps/registry.yml`. bpvps2 is the one
host whose on-host dirs differ from the repo: a single `booking` stack fans out to
`booking-staging` + `booking-prod` per `vps/hosts.json`.

> `docs/running-services.md` is a **2026-07-21 snapshot**, refreshed for bpvps2 on 2026-08-31
> (booking moved off VPS3 and now has its own section) and for both Blueprint hosts on
> 2026-09-12 (mail consolidated onto bpvps1). Everything else in it is still that July
> snapshot — treat the Teeko hosts as history, not as inventory.

> **Backups: bpvps2 (#26) and bpvps1 (#28).** Each host's `backup` stack snapshots nightly into
> its own restic repository in the private R2 bucket `blueprint-backups` (Blueprint account),
> each with its **own** `RESTIC_PASSWORD` — bpvps2 at 03:30 KL (`booking-staging`,
> `traefik-certs`), bpvps1 at 04:30 (`mail-store`, `wordpress`, the three Bulwark volumes,
> `traefik-certs`). ⚠️ **`mail-store` stops Stalwart nightly** (#29) — 4 s measured, ~13 min worst case — v0.16.21
> has no online export; the decision, the failure modes and the round-trip drill are "The mail
> store" in the runbook. Never back it up as a plain `volume` target. The job's `Dockerfile` and
> `bin/` are copied into both stacks and CI fails if they drift: change both in one commit.
> Before any production migration or import, run `docker exec backup /app/bin/backup.sh`.
> Runbook: `docs/backup-restore.md`. `scripts/backup.sh` is a same-host volume tar, **not** a
> backup of a running Postgres.

> **Monitoring: bpvps1 and bpvps2** (#23, #25). Each host's `monitoring` stack runs one Grafana
> Alloy (`alloy`, host network, no published port) shipping host + container metrics and container
> logs to Grafana Cloud, plus `probes` (restart counts, Postgres connections, Tailscale key
> expiry, and — on bpvps2 only — bpvps1's mail ports). Everything in that stack except
> `docker-compose.yml` and `ci/` is **one implementation copied to both hosts**; CI fails if they
> drift. What ships is `metrics.allowlist`; dashboards and alert rules are `grafana/`, applied by
> `scripts/grafana-apply.py` — never edited in the UI. **A new container on a monitored host means
> a line in `grafana/rules/containers.yml`**, and a host with neither a monitoring stack nor
> `no_monitoring: <reason>` fails CI (`vps/shared/check-monitoring.py`). Mail ports are never
> probed from bpvps1 or a laptop. Runbook — every alert's meaning and first three checks, and the
> tune-or-delete rule: `docs/monitoring.md`. Deployed: _not yet_ (Grafana Cloud setup pending).

> **What a host backs up is `vps/<host>/stacks/backup/targets.yml`** (#27) — every **in-scope**
> host has one, and CI fails if a named volume in that host's compose files is neither in it nor
> skipped with a reason. **A new stack with a volume means an edit to that file**, or the
> deploy fails. A host without the backup compose yet carries only skips and lists `backup` in
> `exclude`.

> ⚠️ **Backups and monitoring cover bpvps1 and bpvps2 only.** vps1-staging, vps2-prod and
> vps3-prod are out of scope by decision (#4, #22) and carry `no_backups: <reason>` and
> `no_monitoring: <reason>` in `vps/hosts.json` instead of a targets file or monitoring stack. **Nothing on those three is backed up or
> monitored** — not ehailing's production Postgres, not either n8n (database *and* encryption
> key), not the WABA database, not either teeko-website database. The reason string on each host
> names its own casualties, `check-backup-targets.py` prints them on every run, and a leftover
> targets file on an exempt host fails the check. Do not read "backup targets: all clear" as
> "everything is backed up".

Five things the compose files will not tell you — all of them "do not prune":

> **Mail is ONE platform on bpvps1** — one Stalwart, one Bulwark, one `unbound`, serving
> `kaiteki.my`, `blueprintdigital.my` and `reservetoday.app`. A new mail domain is a domain
> *added* to that instance, never a second stack or host: the `onboard-mail-domain` skill
> (`.claude/skills/onboard-mail-domain/SKILL.md`) is the checklist. bpvps2's copy of the stack
> was deleted on 2026-09-12 (#12) with its 52 MB of test mail; nothing there listens on a mail
> port any more. On bpvps1 those three containers are the whole stack — `unbound` is not an orphan.

> The `n8n` stack on VPS3 carries **three** containers, not two: `n8n-prod`, `n8n-db`, and
> `waba-db` (service `db-waba`, `postgres:alpine`). `waba-db` is a separate database that happens to
> live in the n8n compose, with no app container running against it — don't read it as an orphan.

> **ga4-mcp / gsc-mcp stacks**: each is 3 containers (`*-mcp` backend, `*-gateway` OAuth 2.1 front,
> `*-dex` IdP) and **all three are required** to serve `https://ga4.teeko.ai/mcp` and
> `https://gsc.teeko.ai/mcp`. The `*-mcp` backends have no public route. None are redundant.

> **booking-system is multi-tenant.** One deployment serves every studio; a studio is a
> Tenant row in `tenants`, never its own stack, container or database. Never add a stack
> per customer. `booking-staging` (api.dev.reservetoday.app) carries the real data;
> `booking-prod` (api.reservetoday.app) is fresh. Both live on **bpvps2** since the
> 2026-07-21 move off VPS3. The domains are on `reservetoday.app` — the registry claimed
> `bookingapi.teeko.ai` until 2026-08-31, which was drift, not the truth. bpvps2 cannot
> issue a wildcard for that zone: see [`docs/tls-wildcard-constraint.md`](docs/tls-wildcard-constraint.md).

> **Portainer and pgAdmin are gone** (removed 2026-07-21) — no container UI at all. Postgres is
> managed via drizzle-gateway on all 3 Teeko VPS (`stagingpg` / `pg` / `pg3`.teeko.ai), all sharing
> the `GATEWAY_MASTERPASS` secret.

## Architecture

Topology, registry and database choices are in `README.md`; per-app detail is `apps/registry.yml`.
Timezone: **Asia/Kuala_Lumpur**.

> ⚠️ **A Cloudflare token cannot span accounts, and Traefik reads `CF_DNS_API_TOKEN`
> process-wide.** bpvps2's token is a **Teeko** token (teeko.ai only), so DNS-01 there cannot
> issue for `reservetoday.app` / `kaiteki.my` / `blueprintdigital.my` — it fails with
> `cloudflare: failed to find zone …: zone could not be found`. Adding a second DNS-01 resolver
> does **not** help: both resolvers would read the same env var. bpvps2 therefore carries a
> second resolver, **`le-tls`** (TLS-ALPN-01 on :443, no credentials), used by the booking
> stacks. It requires the record to be **DNS-only** — a Cloudflare-proxied (orange) host
> terminates TLS at the edge and the challenge never lands — and it cannot issue wildcards.
> Keep `letsencrypt` (DNS-01) for teeko.ai and for any wildcard.

> **bpvps1 is the opposite case, and it works.** Its mail cert is issued out-of-band by
> `stalwart/renew-cert.sh` (acme.sh, not Traefik) on a **Blueprint** token that is scoped to
> `kaiteki.my` **and** `blueprintdigital.my`, so since 2026-09-12 one certificate carries all
> four `mail.`/`webmail.` names across both zones. The name list is `CERT_NAMES` in that script
> and is asserted in CI by `scripts/test_renew_cert.sh`; the primary must stay
> `mail.kaiteki.my`, because acme.sh keys its state directory on it. Read the stack README
> before touching it — the CA has to be pinned, and acme.sh's own record of what it issued
> cannot be trusted. **`webmail.reservetoday.app` is deliberately NOT in that list** (#19):
> its zone is on Vercel, so bpvps1's Traefik carries a `le-tls` (TLS-ALPN-01) resolver for
> that one name — the same trick as bpvps2 — and Traefik renews it itself.

## CI/CD

`.github/workflows/deploy-infra.yml` deploys **all five hosts** from one matrix job.
`vps/hosts.json` is the source of truth and documents its own fields inline. The ordered procedure
for onboarding a host or adding a stack is the **`provision` skill**
(`.claude/skills/provision/SKILL.md`) — read that rather than a summary here.

`staging` branch → VPS1; `main` → VPS2 or VPS3. App images are built by each app's own repo, which
then triggers the deploy.

### Per-stack secrets live in `ci/`, never in the workflow

**`deploy-infra.yml` knows nothing about any individual stack.** A stack that needs generated files
carries them itself in `vps/<host>/stacks/<stack>/ci/`, as templates with `@@MARKER@@` placeholders;
`render-ci.py` fills each marker from the same-named env var in the deploy step and rsyncs the
result. The `provision` skill has the path-by-path contract. **Never add a branch to the workflow.**

> An unset or empty marker **fails the deploy**. This is deliberate: a blank secret is not a smaller
> failure than a missing file — it is a Dex with no admin password that starts happily and serves
> 401s, or a Postgres that initialises a brand new empty database. `render-ci.py` names the variable
> and the file and exits 1. `vps/shared/test_render_ci.py` covers this and runs as a CI step.

> **`.env` is MERGED, not replaced.** CI-owned keys (`BASE_DOMAIN`, `ACME_EMAIL`,
> `CF_DNS_API_TOKEN`, `TRAEFIK_DASHBOARD_AUTH`, `ENV_NAME`, plus whatever the stack's own `ci/env.ci`
> contributes) win; every other line, comments included, is preserved. This is what lets stacks keep
> host-managed values such as booking's `BOOKING_HOST`/`IMAGE_TAG`. App repo deploys are compatible
> with this: `booking-system` rewrites its own keys idempotently, and `ehailing` / `kaiteki-web`
> write only their own `.env.*` files, which CI's rsync excludes.

> `GA4_MCP_PATH_TOKEN` left the host-wide key list on 2026-08-09 and moved to
> `ga4-mcp/ci/env.ci`, where it belongs — only ga4-mcp's compose reads it, but it was previously
> written into **every** stack's `.env` on **every** host. Stale copies still sit in other stacks'
> `.env` files; they are inert, and the merge no longer refreshes them.

> **`env_name` is per fanout destination, not per host.** bpvps2 deploys one `booking` compose into
> `booking-staging` and `booking-prod`. A host-level `ENV_NAME` would give both `prod`, making
> booking-**staging** resolve to booking-prod's container, volume and network — on the instance that
> holds the real data.

> A stack dir must be owned by **`deploy`** for CI to deploy it — `root:root` fails silently at
> rsync. That is why bpvps1's `stalwart` / `traefik` / `wordpress` are still in `exclude` in
> `vps/hosts.json`, which records the reason per host. Check ownership before onboarding.

### ⚠️ Org-level vars are consumed by OTHER repos — check before deleting one

`deploy-infra.yml` reads only `vars.TAILSCALE_HOST` (per-Environment). Every other `*_TAILSCALE_HOST`
org variable exists for a **different repo's** deploy workflow. The org holds exactly **8**:

| Org variable | Consumed by |
|---|---|
| `VPS1_TAILSCALE_HOST`, `VPS2_TAILSCALE_HOST` | `teeko-website` → `be-deploy.yml`, `fe-deploy.yml` |
| `VPS3_TAILSCALE_HOST` | `teeko-ehailing` → `deploy-backend.yml` |
| `BPVPS1_TAILSCALE_HOST` | `kaiteki-web` → `deploy-prod.yml`, `deploy-staging.yml` |
| `BPVPS2_TAILSCALE_HOST` | `booking-system` → `deploy-be.yml` |
| `ACME_EMAIL`, `BASE_DOMAIN`, `DOCKERHUB_USERNAME` | infra + every app build |

> **The GitHub code-search API does not index these workflow files.** A `/search/code?q=VPS1_HOST`
> returns `total_count: 0` for names that are demonstrably in use. On 2026-08-09 that false
> negative got `VPS1_HOST` deleted while `teeko-website` still needed it. **Verify by reading
> `.github/workflows/` from each repo's contents API**, never by code search.

> **Strip comments before deciding a variable is unused.** `teeko-ehailing` carries the line
> `# SSH in over Tailscale (was the public vars.VPS3_HOST before Tailscale)`. A naive
> `vars\.([A-Z_]+)` match reads that as a live reference and keeps a dead variable alive forever.
> The comment is accurate history — leave it; just don't count it.

> `booking-system`'s deploy runs `db:migrate && db:seed`, and **`booking-staging` carries the real
> data** — so exercise that deploy on `main`, not `staging`.

> **Seven secrets referenced by app workflows do not exist anywhere** (checked repo-level, and every
> environment, as both secret and variable). Each is silently written as an empty value into the
> app's `.env`: `booking-system` → `R2_ACCESS_KEY_ID`, `R2_ACCOUNT_ID`, `R2_BUCKET_NAME`,
> `R2_PUBLIC_URL`, `R2_SECRET_ACCESS_KEY` (object storage — uploads);
> `teeko-ehailing` → `CLERK_DRIVER_WEBHOOK_SIGNING_SECRET`, `CLERK_RIDER_WEBHOOK_SIGNING_SECRET`
> (webhook signature verification).

## Agent skills

`docs/agents/issue-tracker.md` — GitHub Issues on `Blueprint-Agency/infrastructure`, via
`curl` + REST. `docs/agents/triage-labels.md` — the five canonical roles.
`docs/agents/domain.md` — single-context `CONTEXT.md` + `docs/adr/` at the root, created lazily.

## Git Commits

Do NOT add `Co-Authored-By` lines. Claude Code must not be listed as co-author.

## Operational Notes

### Firewall (Hostinger VPS panel)

**Port 22 is CLOSED to the internet on all five hosts as of 2026-08-09.** SSH is tailnet-only.
Otherwise open: **80**, **443**. Close everything else — especially 3000, 5432, 5678, 8080, 9090
(reached via Traefik only) and 9001 (portainer-agent, no longer needed).

| Host | How |
|---|---|
| bpvps1, bpvps2 | group 319466 rule 22 restricted to `100.64.0.0/10`, then synced (API) |
| vps1-staging, vps2-prod, vps3-prod | hPanel — different Hostinger account, no API token |

Current 319466 rules: **25, 80, 443, 465, 587, 993, 995** `accept TCP` from any, plus **22**
`accept TCP` from **`100.64.0.0/10` only** (the Tailscale CGNAT range). Rule 22 was **restricted
rather than deleted** — reversible, self-documenting, and the tailnet source keeps a way in
without recreating a rule.

> bpvps1 and bpvps2 **share** group `319466` — editing it hits both, and syncing one VM applies it
> to both. The sync action sits in state `started` for ~100s; the rules do **not** take effect until
> it reaches `success`. Poll `/virtual-machines/<id>/actions/<actionId>` rather than trusting the
> group's `is_synced` flag, which flips to `true` while the action is still running.

> Testing ports from a laptop is unreliable: home ISPs block outbound **25**, so it reads BLOCKED
> even when open, and an unsynced firewall reads OPEN long after the rule looks right. Re-test
> server-to-server (`ssh bp-vps3-prod` → `/dev/tcp/<ip>/<port>`). Port **587** reads BLOCKED
> because nothing listens on it, not because of the firewall.

**Key expiry is DISABLED on all five nodes** (2026-08-09, verified: `Self.KeyExpiry` absent on
every host). This is what makes a tailnet-only SSH policy survivable — before it, vps1/vps2/vps3
were all set to expire **2026-12-14**, which would have taken staging and both Teeko production
hosts on the same day. An expired key drops the node off the tailnet, which with port 22 closed
means console-only recovery.

> A tag does **not** disable expiry on its own; it has to be turned off explicitly per machine.
> Check any new node with `tailscale status --json` → `Self.KeyExpiry`; absent means disabled.
> There is no Tailscale API token in `.env`, so this is admin-console work: **Machines → select →
> ⋯ → Disable key expiry**. (The `TS_OAUTH_*` GitHub org secrets belong to the deploy action, and
> GitHub never returns secret values, so they cannot be reused for this.)

> **Getting back in if the tailnet is ever unavailable**: Hostinger's browser console (hPanel →
> VPS → Console). That is now the only path — plan any change that could drop tailscaled with
> that in mind.

> ⚠️ **We hold a console credential for bpvps1 only.** The console wants an OS login, and
> `PasswordAuthentication no` is set on all five hosts (verified 2026-08-27), so SSH passwords are
> useless anyway — the console is the only thing a password is still for. `.env` keeps
> `BPVPS1_USER`/`BPVPS1_PASSWORD` (root) for exactly that. The four `deploy` passwords that used to
> sit beside them were deleted on 2026-08-27: `deploy` has no sudo, so even a working console login
> as `deploy` could not fix a daemon. If you want real break-glass on vps1/vps2/vps3/bpvps2, set a
> root password on each (hPanel → VPS → Root password) and store it as `<HOST>_ROOT_PASSWORD`.

> `deploy` cannot enumerate `/root` (mode `drwx--x--x`) — a `find /` as `deploy` silently returns
> nothing. Search host paths as root, and search recursively: the 2026-08-09 `_preflight_*` cleanup
> first reported "absent" on VPS3 while 284 MB sat nested one level down inside a stack dir.

### Docker 29.x breaks Traefik's Docker provider — fix differs per VPS

Docker 29.x raises `MinAPIVersion` above 1.24. Traefik v3.3 **hardcodes** Docker API 1.24 and
ignores `DOCKER_API_VERSION`, so the daemon rejects it and Traefik loads **zero routes** — every
domain on that host 404s while the containers stay healthy. The fix is always daemon-side, but
the unit path depends on how Docker was installed:

| VPS | Docker install | systemd unit | Drop-in path |
|-----|----------------|--------------|--------------|
| VPS2, VPS3 | apt `docker-ce` | `docker.service` | `/etc/systemd/system/docker.service.d/min-api.conf` |
| **VPS1** | **snap** (`canonical/docker`) | **`snap.docker.dockerd.service`** | **`/etc/systemd/system/snap.docker.dockerd.service.d/min-api.conf`** |

Contents either way: `[Service]` + `Environment="DOCKER_MIN_API_VERSION=1.24"`, then
`systemctl daemon-reload && systemctl restart <unit>` (restarts all containers on that host).

> ⚠️ VPS1 runs the **snap** Docker — there is no `docker.service` there. A drop-in under
> `docker.service.d/` is silently inert. This is exactly how VPS1 sat fully 404 from
> 2026-05-10 to 2026-07-21. Verify with `systemctl list-units '*docker*'` before assuming
> the unit name. Must reapply if Docker is reinstalled.

### Shared Scripts

`vps/shared/` holds the CI helpers (see the `provision` skill); `scripts/backup.sh <bp-alias>` tars
every named volume on that host into `/home/deploy/backups/`.

`scripts/verify-mail.sh <domain> [account…]` is the **one verification seam for mail** — DNS, TLS,
webmail, CORS, JMAP login and both delivery legs for a domain, in one exit code. Per-domain
expectations are `scripts/verify-mail.d/<domain>.conf`, so a new mail domain is a new config file,
never a new script. The parsing half is `scripts/lib/mail-checks.sh` and is covered by
`scripts/test_verify_mail.sh`, which runs as a CI step next to `test_render_ci.py`.

> ⚠️ **The inbound check must run from another host, and does so over SSH** (`--via`, default
> `bp-vps3-prod`). Home ISPs block outbound 25, so a laptop-direct probe reads BLOCKED on a
> perfectly healthy server — the same trap the firewall notes warn about. It refuses to relay
> through the mail host itself by comparing **addresses**, not names: `--via bp-bpvps1` is the
> mail host, and no string comparison against `mail.kaiteki.my` would ever catch it.

> Exit status is `0` fully green, `1` a failure, `2` the run could not start, and **`3` green but
> something was skipped** — so `--skip` can never be mistaken for a passing run.

> Mailbox passwords come from `.env` as `MAIL_PASSWORD_<ACCOUNT>` (uppercased, non-alphanumerics
> to `_`), or an interactive prompt. `verify-mail.sh` takes the accounts to test as arguments,
> because "can this real person sign in" is the better test.

`scripts/mail-inventory.py <domain>` is the other half: one JSON snapshot per capture of every
account, its message count and its bytes, so a migration can be proved invisible by diffing a
before against an after. Snapshots live in `docs/mail/`.

> ⚠️ **Stalwart 0.16.x has no admin UI, and its management API is JMAP with an `x:` prefix.**
> (Pinned at `v0.16.21` since 2026-09-12, #13. The bump from `.16` was canaried on bpvps2 and
> changed nothing about this — do not bump again hoping for a UI.)
> The REST `/api/*` management paths of older versions all 404, and `/account/` is a
> self-service page — a ticket that says "set it in the admin UI" is describing a screen this
> build does not have. The real surface is `x:Domain/set`, `x:Account/set`,
> `x:SystemSettings/set`, `x:Http/set`, `x:AllowedIp/set` and friends on `/jmap`, with
> `urn:stalwart:jmap` in `using`, as an **Admin**-role account or the env recovery admin over
> loopback. Exact request shapes: `vps/bpvps1/stacks/stalwart/README.md`, "Configuring this
> build". Without the `x:` prefix every one of those is `unknownMethod`, which is what made it
> look like no API existed. **The Admin role on bpvps1 is `admin@blueprintdigital.my`** since
> 2026-09-12; `admin@kaiteki.my` is an ordinary mailbox. `mail-inventory.py` enumerates via
> `Principal/get`, which also needs Admin. Sizes are summed per message, not read from
> `Quota/get`, which returns empty here because no quotas are set.

> ⚠️ **Stalwart's default hostname is a public-DNS commitment.** The JMAP session's absolute
> URLs come from it and ignore the request `Host`, and Bulwark hands its JMAP host to the
> *browser*. Set it to a name whose A record is another machine and every webmail user is sent
> there, under a valid cert, with no error. `docs/mail/hostname-cutover-constraint.md`.
> **Since 2026-09-12 (#9) it is `mail.blueprintdigital.my`** — the canonical mail host and the
> MX target for every domain except kaiteki.my, whose MX stays `mail.kaiteki.my` — the same box under its old name, kept for
> configured IMAP clients. `mail.`/`webmail.blueprintdigital.my` A records point at bpvps1;
> bpvps2's mail stack was deleted on 2026-09-12 (#12), so there is no longer a second
> Stalwart anywhere for that name to land on by mistake.

> **bpvps1's `stalwart` and `traefik` stacks are root-owned, so `deploy` cannot run
> `docker compose` in them directly** — the `.env` read fails with `permission denied`. Run
> compose from a container instead: `docker run --rm -v /var/run/docker.sock:/var/run/docker.sock
> -v /root/stacks/<stack>:/root/stacks/<stack> -w /root/stacks/<stack> docker:cli compose up -d
> <service>` (same absolute path on both sides, so the compose file's relative bind mounts
> resolve). File writes go through the `alpine` pipe in the stalwart README.

> ⚠️ **Traefik v3.3 `Host()` takes ONE name.** `Host(`a`, `b`)` passes YAML and the file
> provider, then fails at router build with "unexpected number of parameters", and the router
> silently ceases to exist — every name on it 404s. Write `Host(`a`) || Host(`b`)`. This took
> the Kaiteki web UIs down for ~13 minutes on 2026-09-12; the only symptom was in
> `docker logs traefik`.
