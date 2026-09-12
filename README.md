# Infrastructure

Central infrastructure-as-code repo for Blueprint-Agency. Five Hostinger VPS, Docker Compose, Traefik, GitHub Actions CD.

> **[CLAUDE.md](CLAUDE.md) is the source of truth** for host inventory, SSH aliases, account boundaries,
> MCP servers, and CI semantics. This file is the short orientation; CLAUDE.md is what you act on.

## Architecture

```
push to main (vps/**) → GHA detect → matrix deploy → rsync compose + merge .env → docker compose up
                                          │
      ┌──────────────┬──────────────┬─────┴────────┬──────────────┐
      ▼              ▼              ▼              ▼              ▼
 vps1-staging    vps2-prod     vps3-prod       bpvps1         bpvps2
   (Teeko)        (Teeko)       (Teeko)    (Kaiteki + mail)  (Booking)
```

- **Reverse proxy**: Traefik on every host (Let's Encrypt via Cloudflare DNS-01)
- **Registry**: DockerHub — `blueprintagency/<app>:<tag>`
- **Databases**: local PostgreSQL per app (migrating to Supabase); n8n keeps local Postgres
- **Deploy target list**: [`vps/hosts.json`](vps/hosts.json) — adding a host is one entry there plus a
  GitHub Environment named after its `key`

See CLAUDE.md → *What's Running* for the per-host stack inventory.

## Repository Structure

```
├── vps/
│   ├── hosts.json                 Deploy targets — source of truth for CI
│   ├── <host>/stacks/<stack>/     docker-compose.yml per stack, per host
│   └── shared/                    select-hosts.py, expand-targets.py, snapshot-host.sh, setup-vps.sh
├── apps/registry.yml              App → VPS mapping, images, ports, domains
├── scripts/backup.sh              Volume backup (run ON a host, not from here)
├── .env.example                   Credentials template
└── .mcp.json.example              MCP server config template
```

## Setup (New DevOps Member)

```bash
git clone <repo-url> && cd infrastructure
cp .env.example .env            # credentials — ask @chriskke
cp .mcp.json.example .mcp.json  # MCP tokens; Claude Code starts the servers automatically
```

**SSH**: ask @chriskke for the host entries. Every Blueprint host alias is prefixed `bp-`, logs in as
`deploy`, and uses `~/.ssh/infra_ed25519`.

> ⚠️ The bare aliases `vps1-staging` / `vps2-prod` in a shared `~/.ssh/config` belong to a
> **different client**. Always use the `bp-` prefix. See CLAUDE.md → *VPS Access*.

Verify: `ssh bp-vps1-staging "hostname"`

## Common Operations

```bash
# Deploy — push to main; changes under vps/<host>/ select that host automatically
git push origin main

# Manual deploy / rollback on a host (pin the tag in docker-compose.yml first to roll back)
ssh bp-vps1-staging
cd /root/stacks/<stack> && docker compose pull <service> && docker compose up -d <service>
docker compose ps && docker compose logs -f <service>

# Diff a host's docker state before/after a deploy
./vps/shared/snapshot-host.sh bp-vps1-staging
```

**Adding an app**: entry in `apps/registry.yml` → service in the target stack's compose file →
any app-specific GitHub Environment secrets.

## Firewall

Ports **22**, **80**, **443** open on all hosts; everything else closed (apps reach the world through
Traefik only). bpvps1 + bpvps2 share firewall group `319466` — editing it hits both, and rules must be
re-synced onto each VPS after editing. See CLAUDE.md → *Firewall* for the account split and the full
rule list.

## Team

| Member | Role |
|--------|------|
| @chriskke | DevOps Lead — sole devops, admin on all VPS and the GitHub org |
