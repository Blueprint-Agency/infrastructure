# Running apps on Hostinger VPS: best practice, how people do it, and how we compare

Researched 2026-10-09. Sources: Hostinger's published OpenAPI spec, support articles and official GitHub org;
the official docs of Docker, Traefik, Coolify, Dokploy, CapRover, Kamal, k3s, GitHub Actions, Tailscale and
Ubuntu; GitHub's security-advisory API for the self-hosted PaaS projects. Community opinion (Hacker News) appears
only in §2.5 and is labelled as such. Our side comes from this repo plus **read-only** checks: SSH probes of all
five hosts as `deploy`, `GET` calls on the Hostinger API (Blueprint token) and the GitHub API, and TCP connect
tests. Nothing was bought, changed, restarted or deployed.

Source pins:
- `hostinger/api` commit `c8c9b3862bbcecff653ffc84991b6af5dc2ad874`, `openapi.json` version **1.60.1**, abbreviated
  `hapi:` = `https://github.com/hostinger/api/blob/c8c9b3862bbcecff653ffc84991b6af5dc2ad874/openapi.json`.
- `hostinger/deploy-on-vps` commit `78d5707ddc6bd4e4763a4cd7b722a86c6509ec8b` (2025-10-16), abbreviated `dov:<path>`.
- Host probes ran **2026-10-08 16:38 UTC (2026-10-09 00:38 MYT)**. The probe script is a series of `cat`, `grep`,
  `systemctl is-active`, `docker inspect` and `docker info` calls. `deploy` has no sudo, so anything root-only
  (`sshd -T`, `ufw status`, `/etc/docker/daemon.json` on bpvps1) could not be read. Those items are marked.

---

## TL;DR (plain English)

- **Most people on a Hostinger VPS do one of two things.** They run Docker Compose behind a reverse proxy and deploy
  from GitHub Actions over SSH (what we do), or they install a web panel like Coolify or Dokploy that deploys on
  every `git push`. Hostinger sells both as one-click templates.
- **We're already ahead of typical practice on the hard parts.** SSH is reachable only over Tailscale, the firewall
  sits outside the VM where Docker can't punch holes in it, backups go off-host to R2 with restore drills, secrets
  never touch the workflow file, and bpvps1/bpvps2 are monitored with alerts.
- **One real security gap: password login over SSH is switched on, on all five hosts.** Each server offers
  `publickey,password` to anyone on the tailnet. CLAUDE.md says this was turned off, but it wasn't, or it came back.
  The internet can't reach port 22 (checked), so this is a tailnet-only risk. It is still a 30-minute fix.
- **All five hosts need a reboot and none will reboot by itself.** Security updates install nightly, but new kernels
  only take effect after a reboot. Uptime is 73 to 93 days.
- **Smaller gaps:** container logs have no size cap on some containers (bpvps2's Traefik, vps1-staging's whole
  host). Several images use moving tags like `:latest`, including production n8n. Deploys don't wait for health
  checks, and CI deletes old images, which makes rollback slower.
- **The biggest gap is a decision, not a bug.** The three Teeko hosts have no backups and no monitoring (#4, #22).
  That includes ehailing's production database and n8n's encryption key.
- **Should we switch to Coolify or Dokploy? No.** They would replace our version-controlled setup with state kept
  inside a web app. They want a fresh server, and they don't do zero-downtime updates for Compose apps anyway. Both
  have also had many critical security bugs in 2026: 16 critical advisories for Coolify and 33 for Dokploy.
- **Do these next, in order:** (1) turn off SSH passwords properly, (2) add a reboot routine, (3) cap logs
  everywhere, (4) pin image tags and have CI wait for health checks, (5) pin GitHub Actions to commit SHAs.

---

## 1. Hostinger's own tooling

### 1.1 VPS templates (OS images with an app pre-installed)

`GET /api/vps/v1/templates` returned **95 templates** on 2026-10-09. The ones relevant to "how do I run apps":

| Template (id) | What it is |
|---|---|
| Ubuntu 24.04 with **Docker** (1121) | Docker Engine pre-installed. It is the template Hostinger's Docker Manager and GitHub Action say they need |
| Ubuntu 24.04 with **Docker and Traefik** (1210) | "Docker is paired with Traefik … automatic routing, SSL management" (template description). **This is our pattern, sold as a template** |
| Ubuntu 24.04 with **Coolify** (1087), **Dokploy** (1092), **Easypanel** (1122), **Dokku** (1144), **Cloudron** (1135) | Self-hosted PaaS panels |
| Ubuntu 24.04 with **Portainer** (1143) | Container UI (we removed ours on 2026-07-21) |
| **CloudPanel** (1096), cPanel, Plesk, CyberPanel, HestiaCP, aaPanel … | Classic PHP/web-hosting panels |
| n8n (1153), n8n queue mode (1162), Supabase (1199), Posthog, Chatwoot, Odoo … | Single-app images |

There is **no CapRover, Kamal or k3s template**. Our two Blueprint VMs run the plain `Ubuntu 24.04 LTS` template
(`GET /virtual-machines`). The Teeko hosts' templates aren't visible to us. Over SSH, vps2/vps3 report Ubuntu
24.04.3 and vps1-staging reports **22.04.5** with a **snap** Docker.

### 1.2 Docker Manager (Compose from hPanel or the API)

- hPanel → VPS → Docker Manager offers "Compose manually", "Compose from URL" and "One Click Deploy". You can set
  ports, volumes, env vars and restart policies there, and view logs (support articles 12040815 and 12040789).
  It requires "A Hostinger VPS with a Docker template installed".
- The API has the same feature: `POST /api/vps/v1/virtual-machines/{id}/docker` deploys "from docker-compose.yaml
  contents or download contents from URL … If project with the same name already exists, existing project will be
  replaced". There are also `start/stop/restart/update/logs`, and `DELETE …/{project}/down`, which "Completely
  removes a Docker Compose project … including networks, **volumes**, and images. This operation is irreversible"
  (`hapi:`). The request body is `project_name`, `content` (max 8,192 chars) and `environment` (max 8,192 chars).
- **What our hosts return (read-only GET, 2026-10-09):**
  - **bpvps1: Docker Manager lists our CI-deployed stacks** (`backup`, `kaiteki`, … at `/root/stacks/*/docker-compose.yml`).
    It reads any Compose project on the host, not only ones it created.
  - bpvps2: `400 "[VPS:2044] Currently installed operating system does not support Docker Manager."` Both hosts run
    the same template, so why they differ is UNVERIFIED.
  - ⚠️ **Hazard:** on bpvps1, one click on "Delete" in hPanel's Docker Manager, or one `down` call through the
    `hostinger-vps-blueprint` MCP server, removes the project **with its volumes**. That includes `mail-store` and
    `wordpress`. Nothing in this repo warns about it today.

### 1.3 The official GitHub Action: `hostinger/deploy-on-vps`

- The repo is `hostinger/deploy-on-vps` (tags `v1`, `v2`, 34 stars, last commit 2025-10-16). Hostinger's support
  article names it `hostinger/deploy-action`, which **404s**.
- What it does (`dov:action.yaml`): it builds the URL
  `https://github.com/<repo>/blob/<sha>/<compose path>` and `POST`s it to the Docker Manager endpoint above with
  `Authorization: Bearer <api-key>`. That's the whole action: no SSH, no build, no health check, no rollback.
- Prerequisites (`dov:README.md`): "A Hostinger VPS with Docker installed", a `HOSTINGER_API_KEY` secret and a
  `HOSTINGER_VM_ID` variable. Private repos need an SSH deploy key generated *on the VPS*.
- **Why we shouldn't use it:** "Tokens inherit the permissions of the user who created them"
  (docs.hostinger.com/api-reference/overview). There is no per-VM or per-product scope documented. So the
  GitHub secret could also call `recreate` (wipe a VM), `root-password`, `snapshot/restore` or "Purchase new virtual
  machine" (`hapi:`). Our SSH key can only reach `deploy` on hosts in the tailnet, so it has a much smaller blast
  radius. The action also can't see the Teeko hosts, which are in an account we hold no token for.

### 1.4 Firewall

- Groups and rules are fully scriptable: create/update/delete rules, `PUT …/rules` to replace all rules,
  `POST /firewall/{id}/sync` to "Sync firewall to all assigned VMs", and activate/deactivate per VM (`hapi:`).
  The per-VM sync endpoint is now marked "Deprecated". We already use this on group `319466` (CLAUDE.md).
- This firewall sits **outside the VM** (it is managed through the hypervisor's API, not inside the guest). That
  matters because of the Docker/ufw problem (§4).

### 1.5 Backups and snapshots

| | What Hostinger provides | Source |
|---|---|---|
| Automatic backups | "Automated weekly backups (and daily if enabled)", "stored separately from your server" | support 1583232 (modified 2026-09-15) |
| Daily backups | Paid upgrade, **US$6.00/mo** (image caption on the support page) | support 1665153 |
| Retention | "Up to four are retained, two daily and two weekly". Manual deletion isn't supported | 1583232, 1665153 |
| Restore | Whole VM only: "will completely overwrite all current content", can't be cancelled, VM locked. "Downloading backups or snapshots directly to a local device is not supported" | 1583232 |
| Snapshots | One per VM: "Creating new snapshot will overwrite the existing snapshot!" (`hapi:`). Expiry conflicts: the support page says "automatically deleted after 1 day", while the API schema example shows `expires_at` 20 days after `created_at`. UNVERIFIED which is current | 1583232, `hapi:` `VPS.V1.Snapshot.SnapshotResource` |
| API | `GET …/backups`, `POST …/backups/{id}/restore`, `GET/POST/DELETE …/snapshot`, `POST …/snapshot/restore`. **No endpoint creates a backup or changes the schedule** | `hapi:` |

**Live state (GET, 2026-10-09):**
- bpvps1 has weekly backups from 2026-09-29 and 2026-10-06; bpvps2 from 2026-09-30 and 2026-10-07. Two are kept,
  stored at `in-mum-2-pbs` (Mumbai, Proxmox Backup Server).
- **No snapshot exists on either** (`id: 0`).
- Daily backups have not been bought.

### 1.6 Malware scanner (Monarx)

- "Installing the Malware Scanner enables malware detection and scanning only". Automatic clean-up needs a paid
  Monarx licence, which Hostinger's VPS-security tutorial prices at **$7/month** (support 8450363;
  hostinger.com/tutorials/vps-security, dated 2026-09-29).
- It scans files, not databases. It quarantines or blocks execution "via the Protect Zend extension", so it is aimed
  at PHP sites. On our fleet that means WordPress on bpvps1. Whether it sees inside container overlay filesystems
  is UNVERIFIED.
- API: `POST/GET/DELETE …/monarx` (`hapi:`). **Live: not installed on bpvps1 or bpvps2** (`scanned_files: 0`).

### 1.7 Break-glass features worth knowing

- `POST …/recovery`: "Virtual machine will boot recovery disk image and original disk image will be mounted in `/mnt`".
- `PUT …/root-password`: sets the root password through the API.
- Together these can recover a Blueprint host that has dropped off the tailnet without anyone opening hPanel.
  Neither is available for the Teeko hosts (no token).

### 1.8 What can be automated vs hPanel-only

Official clients all wrap the same spec: `api-python-sdk`, `api-php-sdk`, `api-typescript-sdk`, `api-cli`,
`api-mcp-server`, `terraform-provider-hostinger`, `ansible-collection-hostinger`, plus `hostinger-agent-skills`
("Claude Code skills for Hostinger API"), `api-n8n-node` and `deploy-on-vps` (GitHub org listing, 2026-10-09).
The API is limited to **90 requests/minute per user**, and tokens "can be set to expire" (docs.hostinger.com).

| Automatable (API) | hPanel-only, or not available at all |
|---|---|
| Buy a VM, set it up from a template, run post-install scripts, attach SSH keys | Cancel, resize or downgrade a VM (see `serverless-vs-vps-scaling.md` §4) |
| Start/stop/restart, recreate (wipe), recovery mode, root password, hostname, PTR | Turn daily backups on or off; change the backup schedule; take a backup on demand |
| Firewall groups and rules, plus sync | Browser console (the only way in if Tailscale breaks) |
| Snapshot create/restore/delete; list and restore backups | Downloading a backup |
| Docker Manager projects; Monarx install and metrics; metrics | Monarx auto-removal licence |
| *Everything above, but only for an account we hold a token for. That rules out vps1/2/3* | *All of it for vps1/2/3 (third login, CLAUDE.md)* |

---

## 2. App-management patterns on a single VPS

| | (a) Compose + reverse proxy (**us**) | (b) Self-hosted PaaS (Coolify / Dokploy / CapRover) | (c) Kamal | (d) k3s |
|---|---|---|---|---|
| **What runs on the box** | Docker + your compose files + Traefik/Caddy/nginx | Docker + the panel (its own DB, queue, proxy) | Docker + `kamal-proxy` | Kubernetes control plane + agents |
| **Deploy trigger** | CI over SSH, or a human | Git webhook, UI button, API | `kamal deploy` from a laptop or CI | `kubectl`/Helm/GitOps (Argo, Flux) |
| **Where config lives** | Git (yours) | The panel's database (exportable in places) | `config/deploy.yml` in each app repo | Git manifests + cluster state |
| **Zero-downtime** | DIY (two containers + proxy health checks) | Coolify: not for Compose apps; Dokploy: via Swarm | Built in (`/up` health gate) | Built in (rolling updates) |
| **Suits** | One operator who wants everything in Git | Teams that want a Heroku-style UI and per-PR previews | Single-app repos, especially Rails | Multi-node, many services, people who already know k8s |
| **Ops cost** | Low software overhead; you write the glue | Low at first, then upgrades and CVEs of the panel itself | Low; one tool per app | High for one person |

### 2.1 (a) Plain Docker Compose + reverse proxy

- Docker's own production advice is short: use a production override file, set "a restart policy like
  `restart: always`", remove code bind mounts, and redeploy one service with `--no-deps`
  (docs.docker.com/compose/how-tos/production/).
- **Failure modes:**
  - Compose doesn't restart a container just because its health check fails.
  - `up -d` returns before the app is ready unless you use `--wait` ("Wait for services to be running|healthy").
  - Rollback, image pinning and cleanup are your job.
  - The proxy needs the Docker socket. Traefik warns: "Accessing the Docker API without any restriction is a
    security concern" and suggests a socket proxy (Traefik Docker provider reference).
- **Who it suits:** small, predictable workloads with an operator who values a Git-only source of truth. That is
  exactly our case.

### 2.2 (b) Coolify, Dokploy, CapRover

- **Coolify:** needs "2 CPU cores, 2 GB RAM, and 10 GB disk"; root install; dashboard on `:8000`. Its install docs
  say "It's best to use a fresh server for Coolify to avoid any conflicts with existing applications"
  (coolify.io/docs/get-started/installation).
  - Compose files are rewritten: it adds `coolify.*` and proxy labels and generates `SERVICE_*` "magic" variables
    (coolify.io/docs/knowledge-base/docker/compose).
  - **"Rolling updates are not supported for Docker Compose applications"**, and even where they are supported,
    "Rolling updates do not guarantee zero downtime" (coolify.io/docs/knowledge-base/rolling-updates).
  - Built-in backups are "engine-aware database backups" to S3. Docker volumes aren't covered on that page
    (coolify.io/docs/databases/backups).
- **Dokploy:** needs "at least 2GB of RAM and 30GB of disk space". It takes ports 80/443 (Traefik) and 3000 (UI),
  and "The installation will fail if any of these ports are already in use". Built on Docker Swarm
  (docs.dokploy.com/docs/core/installation). Its backup page covers Dokploy's own Postgres and `/etc/dokploy`
  to S3 (docs.dokploy.com/docs/core/backups).
- **CapRover:** single-node firewall example opens 80, 443 (tcp+udp) and 3000. "AVOID snap installation" of Docker.
  Requires Docker ≥ 25 (caprover.com/docs/get-started.html).
- **Security record** (GitHub security-advisory API, published advisories, 2026-10-09):

  | Project | Stars | Latest release | Advisories | Critical (2025 / 2026) |
  |---|---|---|---|---|
  | `coollabsio/coolify` | 62.7k | v4.4.3 (2026-10-08) | **70** | 5 / **16** |
  | `Dokploy/dokploy` | 37.7k | v0.30.8 (2026-09-29) | **60** | 1 / **33** |
  | `caprover/caprover` | 15.2k | v1.15.4 (2026-08-30) | 0 published | n/a |
  | `basecamp/kamal` | 14.6k | v2.12.0 (2026-06-18) | 0 published | n/a |

  Most recent entries: "Host RCE via Log Drain secret/env command injection" (Coolify, 2026-07-02) and "Remote
  Code Execution via volume-backup" (Dokploy, 2026-07-21). A panel like this holds SSH/root on every server it
  manages, so each of these is a fleet-wide compromise. Zero *published* advisories for CapRover/Kamal is not
  proof of zero bugs.
- **Failure modes:**
  - The panel is a single point of failure, and a large attack surface if exposed.
  - Upgrades of the panel itself can break things.
  - Compose quirks from the rewriting described above.
  - Port 80/443 clashes with an existing proxy.
  - Config drifts away from Git.

### 2.3 (c) Kamal

- Builds the image from the app's Dockerfile, pushes it to a registry, then connects over SSH (by default as root).
  It makes sure kamal-proxy runs on 80/443, and tells it to "route traffic to the new container once it is
  responding with `200 OK` to `GET /up`" (kamal-deploy.org/docs/installation).
- Rollback reuses old containers on the host: "Nothing needs to be downloaded from the registry". Old containers
  "are pruned after 3 days when you run `kamal deploy`" (kamal-deploy.org/docs/commands/rollback).
- Secrets go in `.kamal/secrets`.
- **Fit for us:** it's an app-level tool and would sit in each app repo. It would give booking-system real
  zero-downtime deploys, but it brings its own proxy, which competes with our Traefik for 80/443 and with our
  `le-tls` resolver trick (CLAUDE.md, TLS notes). Not worth it at our traffic (see `serverless-vs-vps-scaling.md` §3).

### 2.4 (d) k3s

- Minimum "2 cores" and "2 GB" for a server node. It needs 6443 open between nodes, plus 8472/udp (Flannel) and
  2379-2380 for HA (docs.k3s.io/installation/requirements).
- On one 1-vCPU/4 GB box (bpvps2) that is a large fraction of the machine just for the control plane.
- Its strengths (self-healing, rolling updates, multi-node scheduling) mostly pay off with several nodes and shared
  storage, which we don't have. **Overkill for us.**

### 2.5 How people actually do it (community opinion, Hacker News)

*Opinion, not documentation.*
- "Should I run plain Docker Compose in production in 2026?" (HN 47962032, 413 points). The article answers yes,
  if you close the gaps in "cleanup, healing, image pinning, socket security, and updates". Comment threads:
  - **nickjj:** "Docker Compose was production ready in 2015 and it still is today."
  - **tcgv:** "keep rollback simple: redeploy the previous known-good image/config".
  - **seniorThrowaway**, on health checks: "compose doesn't fully act on them, that's the part that is missing."
  - **tracker1:** "Are you really going to try to get 4+ 9's of uptime for a small, one-off app?"
- Coolify launch thread (HN 43555996, 382 points):
  - **zachlatta:** "clearly the best as long as you don't absolutely require zero downtime deploys".
  - **shash7:** "Those "magic variables" have caused more pain than being helpful".
  - **tharos47:** "The only backup that seems to run in settings is the coolify instance backup".
- Common advice in the comparison posts: put Coolify on a **fresh** server rather than alongside existing Compose
  stacks, and don't expose its panel to the internet.

---

## 3. CI/CD patterns

| Pattern | How it works | Trade-offs |
|---|---|---|
| **GHA → SSH → `docker compose pull && up -d`** (most common; **us**) | A deploy key in GitHub secrets; the runner SSHes in and runs Compose | Simple, transparent. You write health gating, rollback and secret templating yourself |
| **Registry build** (GHCR / Docker Hub) vs **build on the server** | CI builds and pushes a tagged image; the host only pulls. The alternative is `git pull && docker compose build` on the host | Registry: reproducible, rollback = old tag, no build RAM spike on a 4 GB box. On-server: no registry needed, but builds compete with production and need source code on the host. *We use the registry for apps and build on the host only for our own small infra images (`blueprint-backup:local` etc.)* |
| **Webhook / API deploys** (Coolify, Dokploy, Hostinger's action) | The Git host or CI calls the panel or Hostinger API, which pulls and deploys | No SSH key in CI, but the token is panel-wide or account-wide (§1.3) and you inherit the panel's deploy semantics |
| **SSH over Tailscale** vs public 22 | The runner joins the tailnet as an ephemeral node, so port 22 stays closed to the internet | Tailscale: "it creates an ephemeral node" and logs it out "immediately after the CI workflow completes". What it can reach is "subject to the access rules applied to the specified tag" (tailscale.com/kb/1276). Public 22 needs fail2ban, key-only login and a GitHub IP allowlist that changes constantly |

**Zero-downtime and rollback approaches, cheapest first:**
1. **Immutable image tags** (`:sha-abc123` or a version) plus "redeploy the previous known-good image". booking-system
   already does this with `${IMAGE_TAG}`.
2. **Health check + `docker compose up -d --wait --wait-timeout N`** so a bad deploy fails the CI job instead of
   passing silently.
3. **Proxy-gated swap:** run two containers and let the proxy route only to healthy ones. Traefik's Docker provider
   creates a service for unhealthy containers only if `allowEmptyServices` is set ("regardless of the healthiness of
   the corresponding containers"; default `false`). Kamal's `/up` gate and Coolify's rolling updates automate this.
4. **Blue-green** with weighted Traefik services or a DNS cutover. Rarely worth it on one host.

**Secrets** (GitHub's secure-use reference):
- Keep them in GitHub secrets or environments, and mask anything derived.
- "Never use structured data as a secret".
- Pass untrusted input through env vars rather than inline `${{ }}`.
- "Pinning an action to a full-length commit SHA is currently the only way to use an action as an immutable release".
- Environments can require reviewers: "A workflow job cannot access environment secrets until approval is granted".
- Prefer OIDC to long-lived credentials where the target supports it. Hostinger and SSH don't, so this doesn't
  apply to us.

---

## 4. Security and ops checklist for a VPS

| Practice | Why / source |
|---|---|
| Non-root deploy user, SSH keys only, no root password login | Hostinger's own tutorial: disable root login, use SSH keys, change the port, fail2ban, UFW (hostinger.com/tutorials/vps-security). Note: Docker's `docker` group "grants root-level privileges to the user" (docs.docker.com/engine/install/linux-postinstall), so a docker-group deploy user is *not* a privilege boundary, only an audit and footgun boundary |
| Firewall: only 80/443 (+ what the app truly needs) | **Docker/ufw gotcha:** published-port traffic "gets diverted before it goes through the ufw firewall settings … effectively ignoring your firewall configuration", and "Docker and ufw use firewall rules in ways that make them incompatible" (docs.docker.com/engine/network/packet-filtering-firewalls). Fixes: bind internal ports to `127.0.0.1`, use the `DOCKER-USER` chain, or filter **outside** the VM (a provider firewall) |
| fail2ban | Useful when a login port is public. Pointless for SSH that only listens on a private network. For mail, Stalwart has built-in auto-ban that tracks failed logins across JMAP/IMAP/SMTP/ManageSieve (stalw.art/docs/server/auto-ban) |
| Automatic security updates **and reboots** | Ubuntu enables security-only unattended upgrades by default. `Unattended-Upgrade::Automatic-Reboot` "default value is `false`" (ubuntu.com/server/docs/how-to/software/automatic-updates), so kernels stay pending until someone reboots |
| Log rotation | "By default, no log-rotation is performed" for `json-file`. "the `local` logging driver is recommended". "Existing containers don't use the new logging configuration automatically" (docs.docker.com/engine/logging/configure) |
| `live-restore` | Keeps containers running while `dockerd` restarts; "only supported when installing patch releases" (docs.docker.com/engine/daemon/live-restore) |
| Off-host backups + restore tests | Provider backups are whole-VM, can't be downloaded, are weekly by default, and only 2+2 are kept (§1.5), so they are a second layer, not the backup |
| Monitoring + alerting | Disk, container restarts, cert expiry, external uptime |
| Snapshot before risky changes | One snapshot per VM, which overwrites the previous one (§1.5) |
| Least-privilege CI | SHA-pinned actions, scoped tokens, network ACLs for the runner |

---

## 5. Our setup against that checklist

Host facts are from the 2026-10-08 16:38 UTC probes unless stated. **AHEAD** = better than typical practice,
**OK** = meets it, **GAP** = real shortfall, **UNVERIFIED** = couldn't confirm read-only.

| Practice | What we do (evidence) | Verdict |
|---|---|---|
| SSH exposure | Port 22 closed to the internet on all five (TCP connect to each public IP from a laptop: closed/filtered); SSH only via tailnet; key expiry disabled (CLAUDE.md) | **AHEAD** |
| Firewall layer | Hostinger edge firewall, outside the VM. **Proof the Docker/ufw gotcha can't bite:** bpvps1's Stalwart publishes `110`, `143` and `4190` on `0.0.0.0` (`docker inspect`), but group 319466 doesn't allow them, and they read closed from both a laptop and vps3-prod while `993`/`443` read open | **AHEAD** |
| ufw | Installed on all five; `ENABLED=no` on four, **`ENABLED=yes` on bpvps2** (rules root-only, unreadable). Harmless given the edge firewall, but inconsistent | OK / UNVERIFIED rules |
| SSH password auth | **All five advertise `publickey,password`** to a client offering no key (`ssh -o PreferredAuthentications=none`). The likely cause is `/etc/ssh/sshd_config.d/50-cloud-init.conf`: root-only, exactly **27 bytes** = `PasswordAuthentication yes\n`. It sorts before `60-cloudimg-settings.conf` (26 bytes, readable, `PasswordAuthentication no`), and sshd keeps the first value it reads. **vps1-staging's `sshd_config` has no `Include` line at all** and sets `PasswordAuthentication yes` at line 121. This contradicts CLAUDE.md's "`PasswordAuthentication no` is set on all five hosts (verified 2026-08-27)" | **GAP** (tailnet-only exposure) |
| Root login | `PermitRootLogin yes` on all five, on purpose as break-glass (CLAUDE.md). Combined with the row above, root *password* login over the tailnet is probably open wherever root has a password (bpvps1 does, in `.env`). Hostinger's browser console isn't sshd, so `prohibit-password` would keep both key-based root SSH and the console | **GAP** (small) |
| fail2ban | Absent on all five. Not needed for SSH on a private network. Mail ports on bpvps1 are public; Stalwart has auto-ban, but whether it is configured on our instance is UNVERIFIED | OK |
| Non-root deploy user | `deploy`, docker group, no sudo (CLAUDE.md). The docker group is root-equivalent, but we're honest about that | OK |
| Security updates | `unattended-upgrades` installed, enabled and active on all five; `apt-daily-upgrade.timer` active; last apt run 2026-10-07/08 | OK |
| **Reboots** | `/var/run/reboot-required` present on **all five**. Uptime: bpvps1/bpvps2 79 d, vps1-staging 73 d, vps2/vps3 93 d. `Automatic-Reboot` left at its default (off) | **GAP** |
| Log rotation | bpvps1: all 11 containers capped 10m×3 (root-only `daemon.json` present). vps3-prod: all 14 capped. vps2-prod: capped except **`site-db`**. **bpvps2:** booking + db-observability capped; **`traefik`, `alloy`, `probes`, `backup` uncapped** (no `daemon.json`, no `logging:` in those compose files). **vps1-staging:** `daemon.json` caps, but **all 7 containers predate it and are uncapped** | **GAP** (partial) |
| `live-restore` | `false` on all five | Minor gap |
| Off-host backups | restic → private R2, nightly, a separate `RESTIC_PASSWORD` per host. Retention: every snapshot from 7 days, then 7d/4w/6m. Restore drills, a CI check that every volume is covered, and a pre-migration hook (#26-#30) | **AHEAD** (bpvps1/2) |
| Provider backups | Weekly, 2 kept, Mumbai; `hypervisor-backups.py status` alerts on staleness. Daily ($6/mo) not bought | OK |
| Snapshot before risky change | `hypervisor-backups.py snapshot <host>` exists for bpvps1/2; no snapshot currently held. Not possible for Teeko hosts | OK |
| **Teeko hosts' data** | **No backups, no monitoring, by decision** (#4, #22, `vps/hosts.json` `no_backups`). Unprotected: ehailing prod Postgres, n8n DB + encryption key, WABA DB, teeko-website DBs. Whether Hostinger's weekly backups even run on them is UNVERIFIED (third account) | **GAP** (decision) |
| Monitoring | Alloy → Grafana Cloud, probes, 15 Synthetic checks, Discord alerts, rules in Git, CI drift checks. **Live since 2026-09-14** (`docs/monitoring.md`), although CLAUDE.md still says "Deployed: _not yet_". The trial ended 2026-09-27; current tier UNVERIFIED | **AHEAD** (bpvps1/2) |
| Malware scanner | Monarx not installed (API). Only WordPress on bpvps1 would benefit | Optional |
| Config as code | Every stack in Git; `vps/hosts.json` drives a matrix deploy; CI fails on backup or monitoring coverage drift | **AHEAD** |
| Secrets | GitHub secrets → `ci/` templates rendered by `render-ci.py`, which **fails on an empty marker**; `.env` merged, not replaced; nothing stack-specific in the workflow | **AHEAD** |
| Image builds | App images built and pushed to Docker Hub by each app repo. Small infra images (`blueprint-backup:local`, `-probes`, `-alloy`, `-db-observability`) built on-host | OK |
| Image pinning | Pinned: `traefik:v3.3`, `stalwart:v0.16.21`, `mariadb:11.4`, Dex/gateway versions, booking `${IMAGE_TAG}`. **Moving tags:** `n8nio/n8n:latest` (vps1 **and vps3-prod**), `drizzle-team/gateway:latest` ×3, `bulwarkmail/webmail:latest`, `klutchell/unbound:latest`, `postgres:alpine` ×2 (major version floats), app images `:latest`/`:prod`/`:staging`. vps3-prod runs `ehailing-be:staging` (intent UNVERIFIED) | **GAP** |
| Health gating | Healthchecks in only a few compose files (vps2-prod has none). CI runs `docker compose up -d` without `--wait`, so a crash-looping container still passes the deploy | **GAP** |
| Rollback | Manual: "pin the tag in docker-compose.yml first" (README). CI then runs `docker image prune -af` after every deploy, which deletes the previous image, so with moving tags the old version may not be recoverable at all | **GAP** (partial) |
| Zero-downtime | None (container recreate). Fine at our traffic | OK |
| CI supply chain | Actions pinned by tag (`checkout@v5`, `tailscale/github-action@v4`), not SHA; repo setting `sha_pinning_required: false`, `allowed_actions: all`. The five Environments have **no protection rules**, and `main` is **not protected** (GitHub API). `StrictHostKeyChecking=no` on the deploy SSH. The `tag:ci` ACL in Tailscale is UNVERIFIED (no Tailscale API token) | Minor gap |
| Docker socket | Traefik mounts `/var/run/docker.sock:ro` on every host. `:ro` on a socket file doesn't limit API calls (my reading). Traefik recommends a socket proxy | Minor gap |
| Docker Manager hazard | hPanel/API Docker Manager sees bpvps1's stacks, and its `down` deletes volumes (§1.2). Not documented in CLAUDE.md | **GAP** (docs, low effort) |

**Where a PaaS would help:** per-PR preview environments and a UI for non-operators. Vercel already gives us
previews for every frontend. **Where it would hurt:** see §6.

---

## 6. Recommendation

Ranked by value ÷ effort. None of these were applied. Each one is a change for a separate ticket.

1. **Actually disable SSH password authentication** (high value, ~30 min).
   - On each host, as root, add `/etc/ssh/sshd_config.d/00-hardening.conf` with `PasswordAuthentication no`,
     `KbdInteractiveAuthentication no` and `PermitRootLogin prohibit-password`. Sorting first means it wins.
   - On vps1-staging, also add the missing `Include /etc/ssh/sshd_config.d/*.conf` at the top of `sshd_config`.
   - Then run `sshd -t && systemctl reload ssh`.
   - Verify from a laptop: `ssh -o PreferredAuthentications=none -o PubkeyAuthentication=no bp-<host>` must list only
     `(publickey)`. Then run `sshd -T | grep -i passwordauth` as root.
   - Bake the same into `vps/shared/setup-vps.sh`, and correct CLAUDE.md's "verified 2026-08-27" line.
   - The Hostinger console still works for break-glass because it isn't SSH.
2. **Adopt a reboot routine** (high value, low effort). Pick one:
   - **Automatic:** `Unattended-Upgrade::Automatic-Reboot "true"` with staggered `Automatic-Reboot-Time` outside
     the backup windows (bpvps2 backs up at 03:30 KL, bpvps1 at 04:30).
   - **Manual:** a monthly reboot window, with `hypervisor-backups.py snapshot` first on bpvps1/bpvps2.

   Mail tolerates a few minutes down because SMTP senders retry. Add a "reboot required" textfile metric to the
   existing `probes` so it alerts on bpvps1/2. All five hosts need a reboot today.
3. **Cap logs everywhere and turn on `live-restore`** (medium value, low effort).
   - On bpvps2, add `daemon.json` with `"log-driver": "local"` (or json-file 10m×3) and `"live-restore": true`.
   - Recreate `traefik`, `alloy`, `probes` and `backup`, because existing containers keep their old log config.
   - Recreate vps1-staging's containers and vps2-prod's `site-db` so they pick up the caps already in their
     `daemon.json`.
   - Alternatively, put `logging:` in those compose files so the repo is the source of truth.
4. **Make deploys verifiable and reversible** (medium value, medium effort).
   - Replace moving tags with immutable ones, starting with production: `n8nio/n8n:latest` on vps3-prod,
     `postgres:alpine`, and `teeko-website-*:latest`. booking-system's `${IMAGE_TAG}` is the model.
   - Add healthchecks, and switch CI's `docker compose up -d` to `up -d --wait --wait-timeout 120`.
   - Change `docker image prune -af` to keep recent images, e.g. `--filter "until=168h"`.
5. **Tighten the CI and hPanel blast radius** (low-medium value, low effort).
   - Pin `actions/checkout` and `tailscale/github-action` to full SHAs. The Tailscale action holds the OAuth secret.
   - Confirm in the Tailscale console that `tag:ci` can reach only `tag:server:22`.
   - Add one CLAUDE.md line: **never use hPanel/API Docker Manager "Delete" or `down` on bpvps1, because it removes
     volumes**.
   - Consider a Traefik socket proxy later.

**The decision to revisit (not a ranked fix):** the Teeko hosts' "no backups, no monitoring" scope. If revisiting
it is off the table, the cheapest step consistent with the decision is for whoever holds the third Hostinger
login to confirm in hPanel that weekly VM backups are running on vps1/2/3. A daily upgrade there is $6/month per VM.

### Should we switch to Coolify or Dokploy? **No.**

1. **It would undo the thing we're best at.** Our repo is the source of truth, and CI enforces backup coverage,
   monitoring coverage and secret completeness on every push. A PaaS keeps apps, env vars and domains in its own
   database. Our drift checks couldn't see that state, and Git would stop being the truth.
2. **It doesn't fit next to what we run.** Both want a fresh server and their own proxy on 80/443. Coolify: "best
   to use a fresh server". Dokploy: "will fail if any of these ports are already in use". bpvps1 runs public mail
   ports, a custom Traefik with a `le-tls` resolver for one Vercel-DNS name, and a root-owned stack layout.
   bpvps2 has 1 vCPU/4 GB, and the panel itself wants 2 GB.
3. **It wouldn't buy zero-downtime for us.** Our apps are Compose stacks, and Coolify says "Rolling updates are not
   supported for Docker Compose applications".
4. **Its backups are weaker than ours.** Coolify backs up databases to S3. We already back up volumes, Stalwart and
   Postgres with restic, and run restore drills.
5. **It adds a root-on-every-server web panel with a heavy CVE history.** Coolify has 21 critical advisories
   (16 in 2026) and Dokploy 34 (33 in 2026), mostly authenticated command injection running as root on managed
   hosts. Our current attack surface is SSH keys over a private network.
6. **What it offers that we lack** is a UI, per-PR previews and git-push deploys for people who aren't the
   operator. Vercel already covers previews for the frontends, and the backends are deployed by their own repos'
   CI.

**When it *would* make sense:** a separate, disposable VPS built from Hostinger's Coolify template (id 1087). For
example, client demo sites or a non-technical teammate who needs to ship without touching this repo. Keep it off
the tailnet's `tag:server` and away from production data.

---

## Unverified / could not confirm

- **Effective sshd config.** `sshd -T` needs root. The `password` method is *observed* on all five. The cause (the
  27-byte `50-cloud-init.conf`) is inferred from file sizes and sort order, not read.
- **bpvps2's ufw rules** and **bpvps1's `daemon.json` contents** are root-only.
- **Why Docker Manager works on bpvps1 but not bpvps2** when both run the same template.
- **Snapshot expiry: 1 day (support page) vs 20 days (API example).** Taking a snapshot would settle it, which is a write.
- **Hostinger API token scoping.** Docs say tokens "inherit the permissions of the user". No per-VM scope was found.
- **Whether Hostinger's weekly backups run on vps1/2/3** (no token for that account).
- **Monarx coverage of container filesystems.**
- **Stalwart auto-ban configuration on bpvps1.**
- **Tailscale ACL for `tag:ci`** (no Tailscale API token).
- **Grafana Cloud tier after the trial ended 2026-09-27.**
- **Whether vps3-prod running `ehailing-be:staging` is intentional.**
- **Per-container log file sizes** (`/var/lib/docker/containers` is root-only). Disks are 5-41 % used, so nothing is urgent.

---

## Sources

Hostinger
- OpenAPI spec v1.60.1: https://github.com/hostinger/api/blob/c8c9b3862bbcecff653ffc84991b6af5dc2ad874/openapi.json
  (rendered at https://developers.hostinger.com): Docker Manager, firewall, backups, snapshot, Monarx, recovery,
  root-password paths and `VPS.V1.Snapshot.SnapshotResource`, `VPS.V1.VirtualMachine.DockerManager.UpRequest`
- Live, read-only, Blueprint token, 2026-10-09: `GET /api/vps/v1/templates`, `/templates/{1121,1210}`,
  `/virtual-machines`, `/virtual-machines/{1778283,1831058}/{docker,backups,snapshot,monarx}`
- https://docs.hostinger.com/api-reference/overview (token permissions, expiry, 90 req/min)
- https://www.hostinger.com/support/1583232-how-to-back-up-or-restore-a-vps-server/
- https://www.hostinger.com/support/1665153-how-to-activate-daily-backups/
- https://www.hostinger.com/support/12040815-how-to-deploy-your-first-container-with-hostinger-docker-manager/
- https://www.hostinger.com/support/12040789-hostinger-docker-manager-for-vps-simplify-your-container-deployments/
- https://www.hostinger.com/support/8450363-hostinger-vps-malware-scanner/
- https://www.hostinger.com/support/10840865-what-is-hostinger-api/
- https://www.hostinger.com/tutorials/vps-security
- https://github.com/hostinger/deploy-on-vps (commit `78d5707ddc6bd4e4763a4cd7b722a86c6509ec8b`): `action.yaml`, `README.md`
- https://api.github.com/orgs/hostinger/repos (official SDKs, CLI, MCP server, Terraform provider, Ansible collection)

Tools
- https://docs.docker.com/engine/network/packet-filtering-firewalls/
- https://docs.docker.com/engine/logging/configure/
- https://docs.docker.com/engine/daemon/live-restore/
- https://docs.docker.com/engine/install/linux-postinstall/
- https://docs.docker.com/reference/cli/docker/compose/up/
- https://docs.docker.com/compose/how-tos/production/
- https://doc.traefik.io/traefik/reference/install-configuration/providers/docker/
- https://coolify.io/docs/get-started/installation
- https://coolify.io/docs/knowledge-base/docker/compose
- https://coolify.io/docs/knowledge-base/rolling-updates
- https://coolify.io/docs/databases/backups
- https://docs.dokploy.com/docs/core/installation
- https://docs.dokploy.com/docs/core/backups
- https://caprover.com/docs/get-started.html
- https://kamal-deploy.org/docs/installation/
- https://kamal-deploy.org/docs/commands/rollback/
- https://docs.k3s.io/installation/requirements
- https://docs.github.com/en/actions/reference/security/secure-use
- https://tailscale.com/kb/1276/tailscale-github-action
- https://tailscale.com/kb/1193/tailscale-ssh
- https://ubuntu.com/server/docs/how-to/software/automatic-updates/
- https://stalw.art/docs/server/auto-ban/
- GitHub security-advisory and repo APIs, 2026-10-09: `repos/{coollabsio/coolify,Dokploy/dokploy,caprover/caprover,basecamp/kamal}/security-advisories`, `/releases/latest`

Community (opinion only, §2.5)
- https://news.ycombinator.com/item?id=47962032 ("Should I run plain Docker Compose in production in 2026?")
- https://news.ycombinator.com/item?id=43555996 ("Coolify: Open-source and self-hostable Heroku / Netlify / Vercel alternative")

This repo and our hosts
- `CLAUDE.md`, `README.md`, `vps/hosts.json`, `.github/workflows/deploy-infra.yml`, `.claude/skills/provision/SKILL.md`,
  `vps/shared/setup-vps.sh`, `scripts/hypervisor-backups.py`, `docs/backup-restore.md`, `docs/monitoring.md`,
  `vps/*/stacks/*/docker-compose.yml`, `docs/research/serverless-vs-vps-scaling.md`
- Read-only SSH probe as `deploy` on `bp-bpvps1`, `bp-bpvps2`, `bp-vps1-staging`, `bp-vps2-prod`, `bp-vps3-prod`,
  2026-10-08 16:38 UTC: OS/kernel/uptime, `reboot-required`, `apt list --upgradable`, unattended-upgrades status and
  config, fail2ban/ufw package and service state, `/etc/ssh` file listing and readable config lines,
  `docker version`/`info`/`inspect` (log config, restart policy, published ports), `ss -tln`, `df`, `docker system df`,
  `journalctl --disk-usage`, `tailscale debug prefs`
- `ssh -o PreferredAuthentications=none -o PubkeyAuthentication=no bp-<host> true` (lists offered auth methods; no login)
- TCP connect tests: port 22 on all five public IPs; 110/143/4190/993/443 on bpvps1 from a laptop and from `bp-vps3-prod`
- GitHub API (PAT, read-only): `repos/Blueprint-Agency/infrastructure/{environments,branches/main/protection,actions/permissions}`
