# Running Services — All VPS

Snapshot: 2026-07-21, after the pgAdmin/Portainer/webapp teardown.
Source: `docker ps` + Traefik `Host()` labels on each VPS.

## bp-vps1-staging (`staging`) — 2 vCPU / 8GB

| Container | Image | Domain |
|---|---|---|
| traefik | traefik:v3.3 | traefik.teeko.ai |
| site-fe | (local build) | staging.teeko.ai |
| site-be | (local build) | stagingapi.teeko.ai |
| site-db | postgres:alpine | — |
| n8n-dev | n8nio/n8n:latest | stagingn8n.teeko.ai |
| n8n-db | postgres:alpine | — |
| drizzle-gateway | ghcr.io/drizzle-team/gateway:latest | stagingpg.teeko.ai |

drizzle-gateway reaches `db-site:5432` and `db-n8n:5432` in-network.

> **VPS1 outage 2026-05-10 → 2026-07-21, now fixed.** Traefik had loaded zero routes for ~2.5
> months: Docker 29.3.1 raised `MinAPIVersion` to 1.40 and Traefik v3.3 hardcodes API 1.24.
> VPS1 runs the **snap** Docker, so it has no `docker.service` — the drop-in path used on
> VPS2/VPS3 was inert here. Fixed via
> `/etc/systemd/system/snap.docker.dockerd.service.d/min-api.conf`
> (`DOCKER_MIN_API_VERSION=1.24`); `MinAPIVersion` is now 1.24 and all four VPS1 domains
> return 200. See CLAUDE.md → "Docker 29.x breaks Traefik's Docker provider".

## bp-vps2-prod (`prod1`) — 4 vCPU / 16GB

| Container | Image | Domain |
|---|---|---|
| traefik | traefik:v3.3 | traefik-vps2.teeko.ai |
| site-fe | (local build) | teeko.ai, www.teeko.ai |
| site-be | (local build) | api.teeko.ai |
| site-db | postgres:alpine | — |
| drizzle-gateway | ghcr.io/drizzle-team/gateway:latest | pg.teeko.ai |

drizzle-gateway reaches Postgres in-network at `db-site:5432`. Login with `MASTERPASS`
(`GATEWAY_MASTERPASS` secret, shared with VPS3).

## bp-vps3-prod (`prod2`) — 4 vCPU / 16GB

| Container | Image | Domain |
|---|---|---|
| traefik | traefik:v3.3 | traefik-vps3.teeko.ai |
| n8n-prod | n8nio/n8n:latest | n8n.teeko.ai |
| n8n-db | postgres:alpine | — |
| ehailing-be | blueprintagency/ehailing-be:staging | ehailingapi.teeko.ai |
| ehailing-db | postgis/postgis:16-3.4-alpine | — |
| ehailing-redis | redis:7-alpine | — |
| ga4-mcp | blueprintagency/ga4-mcp:latest | — (internal) |
| ga4-gateway | ghcr.io/hyprmcp/mcp-gateway:0.4.0 | ga4.teeko.ai (priority 1) |
| ga4-dex | ghcr.io/hyprmcp/dex:2.44.0-alpine | ga4.teeko.ai (priority 100, OAuth paths) |
| gsc-mcp | blueprintagency/gsc-mcp:latest | — (internal) |
| gsc-gateway | ghcr.io/hyprmcp/mcp-gateway:0.4.0 | gsc.teeko.ai (priority 1) |
| gsc-dex | ghcr.io/hyprmcp/dex:2.44.0-alpine | gsc.teeko.ai (priority 100, OAuth paths) |
| drizzle-gateway | ghcr.io/drizzle-team/gateway:latest | pg3.teeko.ai |
| waba-db | postgres:alpine | — |

**All 6 MCP containers are required.** `https://ga4.teeko.ai/mcp` needs ga4-mcp + ga4-gateway
+ ga4-dex; `https://gsc.teeko.ai/mcp` needs the gsc trio. The `*-mcp` backends have no public
route — the gateway proxies to them in-network and enforces OAuth Bearer; Dex is the IdP.
Removing any one breaks that URL's auth. Nothing here is redundant.

`waba-db` has no app container running against it.

## bp-bpvps1 (`bpvps1`)

| Container | Image | Domain |
|---|---|---|
| traefik | traefik:v3.3 | traefik-bpvps1.teeko.ai |
| kaiteki | blueprintagency/kaiteki-main-old:latest | kaiteki.my, www.kaiteki.my |
| kaiteki-staging | blueprintagency/kaiteki-web:staging | staging.kaiteki.my |
| wordpress | wordpress:php8.2-apache | blog.kaiteki.my |
| wp-db | mariadb:11.4 | — |
| stalwart | stalwartlabs/stalwart:latest | mail ports 25/110/143/465/587/993/995/4190 |
| bulwark | ghcr.io/bulwarkmail/webmail:latest | — (no Host label) |

## bp-bpvps2 (`bpvps2`) — 187.127.207.82

| Container | Image | Domain |
|---|---|---|
| traefik | traefik:v3.3 | traefik-bpvps2.teeko.ai |
| booking-be-staging | blueprintagency/booking-be:staging | api.dev.reservetoday.app |
| booking-db-staging | postgres:16-alpine | — |
| booking-be-prod | blueprintagency/booking-be:latest | api.reservetoday.app |
| booking-db-prod | postgres:16-alpine | — |
| stalwart | stalwartlabs/stalwart:v0.16.21 | mail ports |
| unbound | klutchell/unbound:latest | — (resolver for stalwart) |
| bulwark | ghcr.io/bulwarkmail/webmail:latest | — (no Host label) |

booking-system is a **multi-tenant** platform: one deployment serves every studio, and a
studio is a Tenant row in `tenants` — never its own stack, container or database. The two
instances here are *environments* (staging / prod), not customers.

Both come from `vps/bpvps2/stacks/booking/docker-compose.yml`, deployed twice under
`/root/stacks/booking-staging` and `/root/stacks/booking-prod`, keyed off `ENV_NAME`. The
Traefik rule reads a full `BOOKING_FQDN` from each stack's `.env`, because booking lives on
`reservetoday.app` and the host-wide `BASE_DOMAIN` is `teeko.ai`. Certificates come from the
`le-tls` resolver (TLS-ALPN-01) — see [`tls-wildcard-constraint.md`](./tls-wildcard-constraint.md)
for why DNS-01 and wildcards are not available for this zone.

Moved here from VPS3 on 2026-07-21. Deploys are driven by `deploy-be.yml` in
`Blueprint-Agency/booking-system`, not from this repo.

## Removed 2026-07-21

| What | Where | Notes |
|---|---|---|
| pgadmin | VPS1, VPS2 | Replaced by drizzle-gateway (now on all 3 Teeko VPS) |
| portainer (CE UI) | VPS1 | — |
| portainer_agent | VPS2, VPS3 | Port 9001 can now be closed in the Hostinger firewall |
| webapp-fe/-be/-db | VPS1 | Staging webapp retired |

**Volumes kept** (declared `external`, not deleted): `pgadmin-data` (VPS1, VPS2),
`portainer_data` (VPS1), `teeko-webapp-db` (VPS1). Purge when you're sure:

```bash
ssh bp-vps1-staging 'docker volume rm pgadmin-data portainer_data teeko-webapp-db'
ssh bp-vps2-prod    'docker volume rm pgadmin-data'
```

**DNS deleted** from Cloudflare (zone `teeko.ai`): `port`, `stagingapp`, `stagingappapi`.
`pg.teeko.ai` was **kept** and `stagingpg.teeko.ai` re-created (A → 72.61.114.7, proxied) —
drizzle-gateway took over both.
Traefik needed no changes: routes are container labels and vanished with the containers.
