# Serverless vs our VPS fleet: does on-demand scaling make sense for us?

Researched 2026-10-09. Primary sources only: the `monorist/monorise` source, the `sst/sst` source,
AWS / Cloudflare / Vercel / Fly.io / Hetzner / DigitalOcean official pricing and docs pages,
Hostinger's published OpenAPI spec and its official Terraform provider, ansible collection and MCP
server, and **read-only** calls against our own Hostinger account (Blueprint token) and SSH
`uptime`/`free` on the three Teeko hosts. Nothing was bought, changed or restarted.

Source pins:
- `monorist/monorise` commit `6267ed12c2f3a2209c67953fd725187221045937` (2026-09-23), abbreviated `monorise:<path>` =
  `https://github.com/monorist/monorise/blob/6267ed12c2f3a2209c67953fd725187221045937/<path>`.
- `hostinger/api` commit `c8c9b3862bbcecff653ffc84991b6af5dc2ad874` (2026-10-08), `openapi.json` version **1.60.1**,
  abbreviated `hapi:` = `https://github.com/hostinger/api/blob/c8c9b3862bbcecff653ffc84991b6af5dc2ad874/openapi.json`.
- `hostinger/terraform-provider-hostinger` commit `037693e1baea22524f3a370433fd6715e15ca061` (2026-09-09), abbreviated `tf:<path>`.

All prices are USD and exclude tax unless stated. AWS prices are US East (the pages' worked examples);
Asia-Pacific regions are usually somewhat higher.

---

## TL;DR (plain English)

- **monorise is not an alternative to AWS. It runs *on* AWS.** It is a small open-source TypeScript
  framework that deploys your app as Lambda functions + one DynamoDB table + EventBridge + SQS,
  using the SST tool. It is cheap when nobody is using the app, because AWS bills per request.
  It is very young (7 GitHub stars, essentially one maintainer) and would mean rewriting our Postgres apps.
- **"Serverless" = you rent compute by the request or by the millisecond instead of by the month.**
  Nobody visiting → you pay ~nothing. Lots of steady traffic → you pay more than a server would cost.
- **Our servers are almost asleep.** Over the last 30 days bpvps1 used a median **4 %** CPU (max 19 %)
  and bpvps2 a median **11 %** (max 38 %). The three Teeko hosts showed load averages of 0.01-0.25 and
  1-2.7 GB of RAM used on 8-16 GB boxes. There are no traffic spikes that need extra machines.
- **Hostinger cannot scale on demand in any useful way.** The API *can* buy a new VPS, but the shortest term
  is one month, there is no hourly billing, **stopping a VM does not stop the bill**, there is no API to cancel
  or resize, and there is no load balancer or autoscaling product.
- **Clouds that do bill by the hour or second exist** (Hetzner, DigitalOcean, AWS EC2, Fly.io, Cloudflare Workers,
  Vercel). None of them is cheaper than our Hostinger boxes for always-on work, and Hetzner's prices went up
  ~2.4x in June 2026.
- **Mail (Stalwart), n8n, Postgres, Traefik and the WordPress blog have to stay on a server.** They are always-on,
  hold state, or need fixed IPs and open ports. Serverless can't run them.
- **What could move:** the Teeko marketing website (Next.js) to Vercel, where Teeko's other frontends already are.
  That is the one move that could retire a whole VPS (vps2-prod), and only if its Postgres moves too.
- **Verdict: for our traffic, the VPS fleet is already the cheapest option.** If we want to save money,
  right-size the over-sized Teeko hosts at renewal. Don't build autoscaling.

---

## 1. monorise

### What it is

- Tagline: "The Fullstack Serverless Data Framework … Define schemas once — API, processors, React hooks, and
  Athena analytics on a single DynamoDB table." You define entities with Zod schemas and get "a ready-made REST
  API", "event-driven processors that keep denormalized data in sync", React hooks, and "SST v4 integration for
  one-command deployment to AWS". `monorise:README.md`
- Packages: `@monorise/base` (Zod config), `@monorise/core` (Hono API, DynamoDB repositories, processors),
  `@monorise/cli`, `@monorise/react`, `@monorise/sst` (the infrastructure). `monorise:README.md` ("Package map")
- Data model: Entities, Mutuals (relationships that carry data), Tags and Trees, all stored denormalised in **one**
  DynamoDB table. `monorise:docs/CONCEPT.MD`, `monorise:README.md` ("Data layout")

### Alternative to AWS, or runs on AWS? **Runs on AWS.**

- Every scaffolded `sst.config.ts` sets `home: "aws"`. `monorise:examples/*/sst.config.ts`
- The FAQ says that without SST you must still provision "A DynamoDB table … An EventBridge bus … SQS queues for
  processors … Lambda functions for the API and processors". `monorise:www/docs/faq.md`
- monorise.dev never claims to replace AWS (fetched 2026-10-09).

So the request "instead of AWS, look into monorise" rests on a misunderstanding. Choosing monorise means
choosing AWS (Lambda + DynamoDB), plus SST as the deploy tool.

### What AWS resources it creates (from the SST module source)

| Resource | Where |
|---|---|
| API Gateway **HTTP API** (`sst.aws.ApiGatewayV2`) fronting a Lambda "app handler" | `monorise:packages/sst/components/monorise-core.ts` |
| **EventBridge** bus (`sst.aws.Bus`) | same file |
| **DynamoDB** single table with 2 GSIs, a stream (`new-and-old-images`), TTL on `expiresAt` | `monorise:packages/sst/components/single-table.ts` |
| A **replicator Lambda** subscribed to the table stream (512 MB, 60 s) + an SQS DLQ | same file |
| 3 **SQS queue + Lambda** processors (mutual, tag, tree; 512 MB, 30 s each) + DLQs + CloudWatch alarms → SNS | `monorise-core.ts`, `q-function.ts` |
| Optional **API Gateway WebSocket** API with connect/disconnect/default Lambdas | `monorise-core.ts` |
| Optional CloudWatch dashboard (on by default) | `monorise-core.ts`; `www/docs/sst.md` says "each one adds cost" |
| Optional analytics: Kinesis Firehose → S3 → Glue → Athena, PITR on the table | `monorise:packages/sst/components/analytics.ts`, `www/docs/concepts/analytics.md` |

Runtime is `nodejs22.x` (`monorise-core.ts`). SST's `Dynamo` component creates tables with
`billingMode: "PAY_PER_REQUEST"` (on-demand). https://github.com/sst/sst/blob/dev/platform/src/components/aws/dynamo.ts

### How it claims to save money, and whether the architecture backs it up

The claims are in the FAQ (`monorise:www/docs/faq.md`):
- DynamoDB is "Pay-per-request (can scale to zero)", while PostgreSQL has an "Always-on instance cost even at zero traffic".
- Single-table design "Reduces costs — fewer tables means fewer indexes to maintain".
- It also says plainly: "If your app will always run on a single server with predictable traffic, PostgreSQL is a great choice."

Is that backed by the architecture?
- **Yes for idle cost.** Every piece is pay-per-use: on-demand DynamoDB (SST default above), Lambda, HTTP API,
  EventBridge and SQS. With no traffic, the only standing costs are storage, the CloudWatch dashboard and alarms.
- **But each write fans out.** Every entity create/update publishes an EventBridge event
  (`ENTITY_CREATED` / `ENTITY_UPDATED`: `monorise:packages/core/services/entity-service-lifecycle.ts`,
  `entity.service.ts`). That event is routed to the tag queue and its Lambda (`monorise-core.ts`,
  `subscribeQueue(... tag-queue-rule ...)`), and the table stream also triggers the replicator Lambda.
  Relationships ("mutuals") are written with `TransactWriteItems`, which the docs say costs "2x the write
  capacity of a plain write" (`monorise:www/docs/concepts/mutuals.md`). So one user action becomes several
  billed requests: DynamoDB writes, an EventBridge event at $1.00/M, SQS requests, and Lambda invocations.
  At our volumes that is still pennies, but "one request" is not one billed request.
- "Fewer tables means fewer indexes" is weakly argued. On-demand DynamoDB bills per request unit and per GB stored,
  not per table (https://aws.amazon.com/dynamodb/pricing/on-demand/).

### Maturity (checked 2026-10-09)

| | |
|---|---|
| GitHub | `monorist/monorise`: **7 stars, 7 forks**, 6 open issues, created 2025-03-06, last push 2026-09-23, 473 commits (GitHub API) |
| License | MIT at the repo root (`@monorise/sst`'s `package.json` says `ISC`, a minor inconsistency) |
| Maintainers | One org member. Commits by author: `wengkhing` 302, `github-actions[bot]` 73, `yeuharn96` 36, `jyungtong` 32, `jovanimal` 23, others ≤5. npm `monorise` has one maintainer, `wengkhing` |
| Releases | npm `monorise@1.12.0` (latest), 62 versions, first published 2026-03-17; **1,052 downloads** in the month to 2026-10-04 (npm API). `@monorise/sst@4.5.0` targets `sst ^4.7.3` |

Read: an actively developed but very small project with a bus factor of one. It isn't something to bet a
production data layer on.

### Fit for us

All our apps use **Postgres + Drizzle** (`apps/registry.yml`), and booking-system relies on Postgres RLS for
tenant isolation (`docs/research/grafana-postgres-monitoring-role.md`). Moving to monorise means replacing the
data layer and the hosting together. For a brand-new small app that is AWS-native from the start, monorise on
AWS could run for a few dollars a month (§2). For our existing apps, the cost of the migration far outweighs
anything it saves.

---

## 2. What serverless is

**Plain version:** with a VPS you rent a whole computer for a month, whether it is busy or not. With serverless
you upload a function, and the provider starts copies of it when requests arrive and bills you for the requests
and the milliseconds they run. No requests means (almost) no bill. Lots of requests means the provider adds
copies automatically, and the bill grows with them.

### Billing models (official pricing pages)

| Service | What you pay for | Free allowance |
|---|---|---|
| **AWS Lambda** | $0.20 per 1M requests + $0.0000166667 per GB-second (x86). Init (cold start) code is billed too: "Duration charges apply to code that runs in the handler of a function as well as initialization code." https://aws.amazon.com/lambda/pricing/ | 1M requests and 400,000 GB-s per month (same page) |
| **API Gateway** (Lambda's usual front door) | HTTP API ≈ $1.00 per 1M requests; WebSocket $1.00 per 1M messages + $0.25 per 1M connection-minutes https://aws.amazon.com/api-gateway/pricing/ | REST: 1M calls; WebSocket: 1M messages + 750k connection-min, for 12 months |
| **DynamoDB on-demand** | $0.625 per 1M writes, $0.125 per 1M reads, $0.25/GB-month storage (US East) https://aws.amazon.com/dynamodb/pricing/on-demand/ | 25 GB storage, 2.5M stream reads |
| **EventBridge / SQS** | $1.00 per 1M custom events https://aws.amazon.com/eventbridge/pricing/ ; SQS bills per 64 KB request chunk https://aws.amazon.com/sqs/pricing/ | SQS: 1M requests/month; no EventBridge custom-event free tier |
| **Cloudflare Workers** | Paid: $5/month minimum, includes 10M requests + 30M CPU-ms; then $0.30/M requests and $0.02/M CPU-ms. "No charge or limit for duration", no egress charges https://developers.cloudflare.com/workers/platform/pricing/ | Free: 100,000 requests/day, 10 ms CPU per invocation |
| **Vercel Functions (Fluid compute)** | Active CPU per hour + Provisioned Memory per GB-hour + invocations ($0.60/M on Pro). Singapore `sin1`: **$0.160/CPU-h, $0.0133/GB-h**; Washington `iad1`: $0.128 / $0.0106. CPU billing pauses during I/O, memory billing does not https://vercel.com/docs/functions/usage-and-pricing | Hobby: 4 CPU-h, 360 GB-h, 1M invocations, but **Hobby is "non-commercial, personal use only"** https://vercel.com/docs/plans/hobby. Pro: $20 per developer seat per month (same page) |

### Cold starts and limits

- **Cold start:** the first request to a new copy has to download the code and run its initialisation. AWS:
  "You are charged for this time, and it adds latency." Cold starts "typically occur in under 1% of invocations"
  and take "under 100 ms to over 1 second". Copies are frozen when idle, and Lambda "terminates execution
  environments every few hours … even for functions that are invoked continuously."
  https://docs.aws.amazon.com/lambda/latest/dg/lambda-runtime-environment.html
- **Lambda limits:** 15-minute maximum timeout, 128 MB-10,240 MB of memory, "At 1,769 MB, a function has the
  equivalent of one vCPU", 1,000 concurrent executions by default, 6 MB sync payload. Lambda "is designed for
  short-lived compute tasks that do not retain or rely upon state between invocations."
  https://docs.aws.amazon.com/lambda/latest/dg/gettingstarted-limits.html
- **Workers limits:** 128 MB memory per isolate. CPU per request is 10 ms on Free and up to 5 min on Paid
  (default 30 s). No hard wall-clock limit for HTTP requests; cron triggers run up to 15 min.
  https://developers.cloudflare.com/workers/platform/limits/
- **Vercel limits:** max duration is 300 s on Hobby and 800 s on Pro (1,800 s in beta). Memory is 2 GB (Hobby)
  or 4 GB / 2 vCPU (Pro). Body size 4.5 MB. WebSockets are in public beta.
  https://vercel.com/docs/functions/limitations

### When serverless is cheaper, and when it is more expensive

**Cheaper:** low or spiky traffic, apps that sit idle most of the day, and many small sites.

*Example A: a small API* (1M requests/month, 100 ms each, 512 MB, Lambda + HTTP API + DynamoDB):
compute is 1M × 0.1 s × 0.5 GB = 50,000 GB-s, which is inside the free tier. Lambda requests are free too.
HTTP API ≈ $1.00. DynamoDB with 3M reads and 1M writes ≈ $0.375 + $0.625 = $1.00.
**About $2/month**, against $12.99/month for our KVM 1 (bpvps2). (My arithmetic, using the prices above.)

**More expensive:** steady, high or always-on load.

*Example B: the same work as one fully busy KVM 4* (4 vCPU, 16 GB, $28.99/month on a 2-year term):
4 vCPU-equivalents on Lambda = 4 × 1,769 MB ≈ 6.9 GB. Running all month that is 6.9 GB × 2,592,000 s ≈ 17.9M GB-s,
or **≈ $290/month** after the free tier, before request fees. That is **about 10× the VPS.**

*Example C: an always-busy 1 vCPU / 2 GB Vercel function in Singapore* for 720 h:
720 × $0.160 + 720 × 2 × $0.0133 ≈ **$134/month**, against $12.99 for a KVM 1.

*Break-even, roughly:* at 100 ms / 512 MB, each Lambda request behind an HTTP API costs about $2.03 per million
($0.83 compute + $0.20 Lambda + $1.00 API Gateway). A $12.99 KVM 1 therefore buys about **6-7M requests a month**
(about 2.5 requests per second on average) before Lambda becomes the more expensive option, and that is before
counting the database. (My arithmetic.)

**Workloads serverless can't run, or runs badly:**

| Workload | Why |
|---|---|
| **Postgres** (our 7+ instances) | A database is a stateful, always-on process. Functions also open many short-lived connections. AWS sells RDS Proxy precisely because surges cause "oversubscribing connections or new connections being created at a fast rate" https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/rds-proxy.html ; Cloudflare's equivalent is Hyperdrive, which keeps a connection pool to "existing databases" https://developers.cloudflare.com/hyperdrive/ |
| **WebSockets / long connections** | API Gateway bills per connection-minute ($0.25/M), so you pay while sockets sit idle. On Vercel WebSockets are still beta |
| **Background workers, schedulers** | 15-min cap on Lambda; cron on Workers is capped at 15 min |
| **Self-hosted mail (Stalwart)** | SMTP needs a fixed IP with a PTR record listening on port 25, plus IMAP/JMAP sessions held open and a local RocksDB store. Functions are invoked per HTTP request or event and don't listen on raw TCP ports (my reading of the limits pages above) |
| **n8n** | Runs as long-lived Node.js processes with Postgres and, in queue mode, Redis: "Each worker is its own Node.js instance", "Redis acts as the message broker, and the database persists data" https://docs.n8n.io/hosting/scaling/queue-mode/ |

---

## 3. Our current infrastructure

Sources: `CLAUDE.md`, `README.md`, `apps/registry.yml`, `vps/hosts.json`, `docs/running-services.md`.

- **Five Hostinger KVM VPS, all fixed-price and prepaid.** Each runs Docker Compose stacks behind its own Traefik v3.3.
  CI is `.github/workflows/deploy-infra.yml`, one matrix job that reaches hosts over Tailscale (port 22 is closed
  to the internet). App images come from DockerHub and are built by each app's repo.
- **Vercel already hosts frontends**: `teeko-ehailing-*`, `booking-system-*`, `blueprint-marketing-website`,
  `vatti-web`, `persistence-chiro` (`CLAUDE.md`, "Two Accounts").

| Host | Size | Hostinger plan / term (from API, 2026-10-09) | What runs there |
|---|---|---|---|
| `bp-vps1-staging` | 2 vCPU / 8 GB / 100 GB | UNVERIFIED (third Hostinger login); specs match **KVM 2** | Teeko staging: site-fe, site-be, site-db, n8n-dev + db, drizzle-gateway, Traefik |
| `bp-vps2-prod` | 4 vCPU / 16 GB / 200 GB | UNVERIFIED; specs match **KVM 4** | teeko.ai production: site-fe, site-be, site-db, drizzle-gateway, Traefik |
| `bp-vps3-prod` | 4 vCPU / 16 GB / 200 GB | UNVERIFIED; specs match **KVM 4** | n8n-prod + db, waba-db, ehailing-be + PostGIS + Redis, ga4/gsc MCP (6 containers), drizzle-gateway, Traefik |
| `bp-bpvps1` | 2 vCPU / 8 GB / 100 GB | **KVM 2, 2-year term, $359.76** ($14.99/mo), auto-renews 2028-06-09 | Kaiteki (prod + staging Next.js), WordPress + MariaDB, **mail platform** (Stalwart, Bulwark, unbound), backup, monitoring |
| `bp-bpvps2` | 1 vCPU / 4 GB / 50 GB | **KVM 1, 1-year term, $155.88** ($12.99/mo), auto-renews 2027-07-01 | booking-staging + booking-prod (Hono + Postgres 16 each), db-observability, backup, monitoring |

The plan, term and price for bpvps1/bpvps2 come from `GET /api/vps/v1/virtual-machines` and
`GET /api/billing/v1/subscriptions` (Blueprint token, read-only). The Blueprint hosts cost **≈ $28/month** combined.
At Hostinger's renewal prices for the plans their specs match, the Teeko hosts would cost roughly $73/month
(2-year terms) to $110/month (monthly), so ≈ **$100-140/month for all five**. The Teeko figures are UNVERIFIED
because no token we hold can see those VMs.

### Hostinger KVM prices (official catalog, `GET /api/billing/v1/catalog?category=VPS`, 2026-10-09)

Prices are in cents in the API ("`17.99` is displayed as integer `1799`", `hapi:` catalog endpoint). Converted:

| Plan | vCPU / RAM / NVMe / traffic | 1-month term (first / renewal) | 12-month term, per month (first / renewal) | 24-month term, per month (first / renewal) |
|---|---|---|---|---|
| KVM 1 | 1 / 4 GB / 50 GB / 4 TB | $9.99 / **$19.49** | $6.99 / $12.99 | $6.49 / **$11.99** |
| KVM 2 | 2 / 8 GB / 100 GB / 8 TB | $13.99 / **$24.49** | $9.99 / $16.99 | $8.99 / **$14.99** |
| KVM 4 | 4 / 16 GB / 200 GB / 16 TB | $25.99 / **$42.99** | $14.99 / $30.99 | $12.99 / **$28.99** |
| KVM 8 | 8 / 32 GB / 400 GB / 32 TB | $50.99 / **$73.99** | $28.49 / $53.99 | $25.99 / **$49.99** |

The public page (https://www.hostinger.com/vps-hosting) matches the 24-month column and the specs, and states:
"All plans are paid upfront. The monthly rate reflects the total plan price divided by the number of months in
your plan." and "Renews at [price]/mo for 2 years." It mentions no hourly billing.

**Billing terms that matter for scaling** (https://www.hostinger.com/legal/refund-policy):
- A VPS is refundable only if the refund is started "within 30 days from the date of the transaction" **and**
  "more than 180 days have passed" since the last refund of any other VPS plan.
- "a refund will only be issued if cancellation is requested within the refund timeframe". No pro-rata refund is described.
- "KVM VPS upgrades" are listed as non-refundable.

### Measured load: is our traffic spiky?

From `GET /api/vps/v1/virtual-machines/{id}/metrics`, 2026-09-09 → 2026-10-09, 1,425 samples per host (about one
every 30 min, so short bursts are averaged away):

| Host | CPU median / p95 / p99 / max | RAM median / max |
|---|---|---|
| bpvps1 (2 vCPU / 8 GB) | 4.0 % / 8.7 % / 13.2 % / 19.0 % | 2.5 GB / 6.5 GB (single peak) |
| bpvps2 (1 vCPU / 4 GB) | 11.1 % / 13.1 % / 16.9 % / 38.0 % | 1.4 GB / 1.7 GB |

Teeko hosts, point-in-time over SSH at 2026-10-09 16:26 MYT (`uptime`, `free -m`):

| Host | Load avg (1/5/15 min) | RAM used / total |
|---|---|---|
| vps1-staging (2 vCPU) | 0.01 / 0.05 / 0.02 | 1.2 / 7.9 GB |
| vps2-prod (4 vCPU) | 0.24 / 0.05 / 0.02 | 1.1 / 16 GB |
| vps3-prod (4 vCPU) | 0.20 / 0.25 / 0.19 | 2.7 / 16 GB |

**Read:** nothing is close to its limits, and the Blueprint hosts' p99 is barely above their median. There is no
load pattern for autoscaling to respond to. vps2-prod in particular is a 16 GB host using about 1 GB.
(The Teeko figures are one snapshot, not a trend. Those hosts are unmonitored by decision, #22.)

---

## 4. Can we scale on demand programmatically with Hostinger?

Checked against the published OpenAPI spec v1.60.1 (`hapi:`), which is what https://developers.hostinger.com
renders, plus Hostinger's own Terraform provider, Ansible collection and MCP server.

### What the API can do

| Need | Endpoint | Notes |
|---|---|---|
| **Buy a new VPS** | `POST /api/vps/v1/virtual-machines` "Purchase new virtual machine" | Body: `item_id` (a catalog price ID such as `hostingercom-vps-kvm2-usd-1m`), optional `payment_method_id`, `setup`, `coupons`. "If the response is `202 Accepted`, the payment is still being processed and the virtual machine was not set up. Login to hPanel and complete the setup manually." |
| Buy anything | `POST /api/billing/v1/orders` | Places the order only: "Product-specific provisioning (e.g. VPS setup …) is not performed here" |
| Set up a purchased VM | `POST /api/vps/v1/virtual-machines/{id}/setup` | Template, data centre, keys, post-install script |
| Start / stop / restart | `POST …/{id}/start`, `/stop`, `/restart` | **Stop: "This is a compute-only power state change and does not affect billing. To stop future charges, disable auto-renewal on the owning subscription."** |
| Reinstall | `POST …/{id}/recreate` | Wipes the VM: "irreversible and will result in the loss of all data" |
| Stop paying | `DELETE /api/billing/v1/subscriptions/{id}/auto-renewal/disable` | The term already paid still runs out. `expires_at` is "Set when a cancellation is scheduled (e.g. after auto-renewal is disabled)" |
| Renew | `POST /api/billing/v1/subscriptions/{id}/renew` | |
| Run Compose on a VM | `/api/vps/v1/virtual-machines/{id}/docker…` (create, start, stop, update, logs, down) | "Docker Manager": deploys a `docker-compose.yaml` to an **existing** VM. It does not scale anything |
| Snapshots, backups, firewall, metrics, PTR, keys | various | Already used by `scripts/hypervisor-backups.py` |

### What the API cannot do

- **No hourly or per-second billing.** The catalog offers only 1-month, 1-year and 2-year price items per plan
  (live catalog call above). The spec contains no occurrence of "hourly".
- **No delete, cancel, resize or upgrade endpoint for a VM.** The spec defines a `Billing.V1.Subscription.CancelRequest`
  schema (`cancel_option: "immediately"`), but **no path in v1.60.1 references it**. Upgrades are done in hPanel
  ("click the **Upgrade** button", vps-hosting page) and are non-refundable.
- **No load balancer and no autoscaling.** The spec has zero matches for "load balancer" or "autoscal".
- Hostinger's **Terraform provider** says `hostinger_vps` supports "destroy (via subscription cancelation)" (`tf:docs/resources/vps.md`).
  Its client sends `DELETE /api/billing/v1/subscriptions/{id}` (`tf:hostinger/client.go` line 137, called from
  `tf:hostinger/vps_resource.go` line 267), an endpoint **absent from the current published spec**. Whether
  it still works, and whether it refunds anything, is UNVERIFIED.
- The **Ansible collection** (`hostinger/ansible-collection-hostinger`, pushed 2026-10-02) has modules for
  provision, power, snapshot, firewall, reinstall and so on, but none for cancellation (module list in `plugins/modules/`).
- The **MCP server** (`hostinger/api-mcp-server` v2.9.1, also hosted at `https://mcp.hostinger.com`) wraps the
  same paths: purchase, setup, start/stop, recreate, auto-renewal, Docker. Nothing beyond the spec.

### Other Hostinger products

- **Cloud hosting** is managed web hosting ("combines the power of a VPS and the simplicity of managed web hosting"),
  sold on 48-month terms (Startup $7.99/mo, renews at $25.99). It supports Node.js. It does not mention Docker,
  root access, autoscaling or load balancing. https://www.hostinger.com/cloud-hosting
- **Horizons** has been merged into Hostinger's AI website builder. It offers "A built-in back end" with no
  containers, serverless or custom backends. https://www.hostinger.com/horizons

### Bottom line for Hostinger

Programmatic scale-out *is* technically possible (buy a VM, set it up with a post-install script, join it to
Tailscale, deploy). But every added server costs **at least one month at the 1-month price** ($19.49-$73.99
at renewal, or $9.99-$50.99 for a first-time purchase). Powering it off saves nothing, and you can only stop
paying by letting the term expire. A refund is possible once per 180 days, within 30 days. That suits "add a box
for a month-long campaign". It does not suit "absorb an afternoon spike".

---

## 5. Alternatives that do scale on demand

| Provider | Billing | Scaling primitive | Price reference (official) |
|---|---|---|---|
| **Hetzner Cloud** | Hourly with a monthly cap, rounded up to the hour. Billed "until you delete them, independent of their state" (powered-off still costs) https://docs.hetzner.com/cloud/billing/faq/ | API + Kubernetes cluster-autoscaler (`--nodes=<min>:<max>:<type>:<region>:<name>`) https://github.com/kubernetes/autoscaler/blob/master/cluster-autoscaler/cloudprovider/hetzner/README.md | **Prices rose on 15 June 2026.** CPX22 (2 vCPU/4 GB): $22.99/mo DE/FI, **$30.99/mo ($0.0497/h) Singapore**. CPX32 (4/8): $41.99 DE, $57.99 SIN https://docs.hetzner.com/general/infrastructure-and-availability/price-adjustment/ . On 2026-10-09 the plan page's Create buttons read "This product is currently unavailable" https://www.hetzner.com/cloud/regular-performance |
| **DigitalOcean** | Per-second (60 s minimum) since 2026-01-01, capped at the monthly price | API, Droplet autoscale pools (UNVERIFIED, not fetched) | Basic 2 vCPU/4 GB $24/mo ($0.03571/h); 4 vCPU/8 GB $48/mo https://www.digitalocean.com/pricing/droplets . Powered-off billing isn't stated on that page (UNVERIFIED) |
| **AWS EC2 + Auto Scaling** | "by the hour or second (minimum of 60 seconds)" for Linux https://aws.amazon.com/ec2/pricing/on-demand/ | Auto Scaling groups: "no additional fees" beyond the instances https://aws.amazon.com/ec2/autoscaling/pricing/ | Instance prices not captured (the page is JS-rendered): UNVERIFIED |
| **Fly.io** | "Machines are billed by the second while they're running". When stopped, "Only the Machine's root file system is billed" ($0.15/GB-mo) https://docs.fly.io/about/pricing | `auto_stop_machines` (`stop`/`suspend`), `auto_start_machines`, `min_machines_running`: idle apps scale to zero, and "you don't pay for their CPU and RAM when they're in a stopped or suspended state" https://docs.fly.io/launch/autostop-autostart | shared-cpu-1x 1 GB $6.70/mo; performance-1x 2 GB $33.00/mo (US East). No free tier for new orgs. APAC egress $0.04/GB |
| **Cloudflare Workers** | Per request + CPU-ms, $5/mo minimum (§2) | Automatic | Cheapest for HTTP at scale, but 128 MB per isolate and a non-Node runtime |
| **Vercel** (already used) | Active CPU + memory GB-h + invocations (§2); Pro $20/seat | Automatic, up to 30,000 concurrency (Hobby/Pro) https://vercel.com/docs/functions/limitations | Hobby is non-commercial only |

Compare that with Hostinger KVM 2 (2 vCPU / **8 GB**) at $14.99/mo on a 2-year term. Since Hetzner's June 2026
increase, no hourly-billed VM here beats Hostinger for a box that runs all month. Hourly billing only wins if a
machine is switched off (or deleted) most of the time.

---

## 6. Recommendation

| Workload (host) | Serverless? | Why |
|---|---|---|
| Teeko site **frontend**, Next.js (vps1, vps2) | **Good candidate → Vercel** | Teeko's ehailing frontends are already on the same Vercel team. Low traffic means pennies on a Pro seat we likely already pay for (plan tier UNVERIFIED) |
| Teeko site **backend** + `site-db` (vps1, vps2) | Possible, not free | The API could run as Vercel/Lambda functions only if Postgres moves to a managed service (the registry already says "TODO: migrate to Supabase"). **This is the one move that could retire a whole VPS (vps2-prod, KVM 4-sized, using ~1 GB)** |
| Kaiteki web, Next.js (bpvps1) | Could move to Vercel, **saves nothing** | bpvps1 must stay for mail anyway |
| WordPress + MariaDB (bpvps1) | No | PHP + MariaDB, always on |
| **Stalwart / Bulwark / unbound** (bpvps1) | **No** | Port 25 + PTR + fixed IP, long-lived IMAP/JMAP, on-disk store |
| booking-be ×2 + Postgres (bpvps2) | Not now | Hono can run on Workers/Lambda, but Postgres (with RLS and the real tenant data) must stay on a server or a managed DB, and functions would need a pooler (RDS Proxy / Hyperdrive). The whole host costs $12.99/mo |
| ehailing-be + PostGIS + Redis (vps3) | No | Stateful DBs; a ride-hailing backend likely needs persistent connections (UNVERIFIED) |
| n8n ×2 + Postgres, waba-db (vps1, vps3) | **No** | Long-running processes; queue mode needs Redis + Postgres |
| ga4/gsc MCP + Dex + gateway (vps3) | Not worth it | Dex is a stateful IdP; six small containers on a host that exists anyway |
| Traefik, drizzle-gateway, backup, monitoring | No | Host infrastructure |

**Is our traffic spiky enough to justify autoscaling? No.** Measured CPU tops out at 19 % on bpvps1 and 38 % on
bpvps2, and the Teeko hosts are near-idle (§3). Autoscaling adds a load balancer, shared state and cost, and it
would have nothing to do here.

**Honest answer: the VPS fleet is already the cheapest way to run this workload.** At ~$100-140/month for five
hosts, any always-on equivalent on Lambda, Vercel or an hourly cloud costs the same or more (Examples B and C).
Serverless only wins for *new*, small, mostly-idle apps, and we already put those frontends on Vercel.

Cheaper levers, in order:
1. **Right-size at renewal.** vps2-prod (16 GB, ~1 GB used) and vps3-prod (16 GB, ~2.7 GB used) look like KVM 4s
   that would fit on KVM 2s, saving about $14/month each at 2-year renewal prices ($28.99 → $14.99). Whether
   Hostinger allows a *downgrade* is UNVERIFIED (only "Upgrade" is documented), and the Teeko account isn't
   visible to us, so we can't see their renewal dates.
2. **Move the Teeko marketing site to Vercel and its DB to managed Postgres**, then let vps2-prod expire. This is
   the only path that removes a host.
3. **Prefer 24-month terms at renewal** (KVM 1 $11.99 vs $19.49 month-to-month).
4. Treat monorise / AWS as a candidate for a **future greenfield** app only, and only after its maintainer base grows.

---

## Unverified / could not confirm

- **Teeko hosts' Hostinger plan, term and price.** They are in a Hostinger account we hold no token for (CLAUDE.md).
  Plans are inferred from specs, and prices are catalog renewal prices.
- **Whether `DELETE /api/billing/v1/subscriptions/{id}` (used by the Terraform provider's destroy) still works,
  and whether it refunds.** It isn't in spec v1.60.1.
- **Whether Hostinger allows VPS downgrades** (only upgrades are documented).
- **Our Vercel team's plan tier.** The Vercel API `get_team` result didn't include it. Hobby would be a
  commercial-use violation per the fair-use guidelines.
- **AWS Arm (Graviton) Lambda price, EC2 instance prices, SQS per-request price.** These tables didn't render on
  the pricing pages. Only x86 Lambda and worked-example figures were captured.
- **DigitalOcean powered-off Droplet billing and Droplet autoscale pools.** Not on the fetched page.
- **Fly.io Singapore machine prices.** Only US East figures were captured.
- **Asia-Pacific prices for Lambda/DynamoDB.** All AWS figures are US East examples.
- **Sub-30-minute spikes.** Hostinger's metrics are ~30-minute samples, so brief bursts are averaged out. Grafana
  monitoring for bpvps1/bpvps2 is not yet deployed (CLAUDE.md), and the Teeko hosts are unmonitored by decision.
- **Whether ehailing-be uses WebSockets.** Not checked in its repo.

---

## Sources

monorise
- https://github.com/monorist/monorise (repo; files pinned at `6267ed12c2f3a2209c67953fd725187221045937`): `README.md`,
  `docs/CONCEPT.MD`, `www/docs/faq.md`, `www/docs/sst.md`, `www/docs/concepts/mutuals.md`, `www/docs/concepts/analytics.md`,
  `packages/sst/components/{monorise-core,single-table,q-function,analytics}.ts`, `packages/core/services/{entity.service,entity-service-lifecycle}.ts`,
  `examples/*/sst.config.ts`
- https://api.github.com/repos/monorist/monorise and `/contributors` (stars, dates, commit counts)
- https://registry.npmjs.org/monorise ; https://api.npmjs.org/downloads/point/last-month/monorise
- https://monorise.dev
- https://github.com/sst/sst/blob/dev/platform/src/components/aws/dynamo.ts (`billingMode: "PAY_PER_REQUEST"`)

Serverless pricing and limits
- https://aws.amazon.com/lambda/pricing/
- https://docs.aws.amazon.com/lambda/latest/dg/gettingstarted-limits.html
- https://docs.aws.amazon.com/lambda/latest/dg/lambda-runtime-environment.html
- https://aws.amazon.com/dynamodb/pricing/on-demand/
- https://aws.amazon.com/api-gateway/pricing/
- https://aws.amazon.com/eventbridge/pricing/
- https://aws.amazon.com/sqs/pricing/
- https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/rds-proxy.html
- https://developers.cloudflare.com/workers/platform/pricing/
- https://developers.cloudflare.com/workers/platform/limits/
- https://developers.cloudflare.com/hyperdrive/
- https://vercel.com/docs/functions/usage-and-pricing
- https://vercel.com/docs/functions/limitations
- https://vercel.com/docs/plans/hobby
- https://docs.n8n.io/hosting/scaling/queue-mode/

Hostinger
- Hostinger API OpenAPI spec v1.60.1: https://github.com/hostinger/api/blob/c8c9b3862bbcecff653ffc84991b6af5dc2ad874/openapi.json
  (rendered at https://developers.hostinger.com)
- Live, read-only, Blueprint token, 2026-10-09: `GET /api/billing/v1/catalog?category=VPS`, `GET /api/billing/v1/subscriptions`,
  `GET /api/vps/v1/virtual-machines`, `GET /api/vps/v1/virtual-machines/{1778283,1831058}/metrics`
- https://www.hostinger.com/vps-hosting
- https://www.hostinger.com/legal/refund-policy
- https://www.hostinger.com/cloud-hosting
- https://www.hostinger.com/horizons
- https://github.com/hostinger/terraform-provider-hostinger (commit `037693e1baea22524f3a370433fd6715e15ca061`): `docs/resources/vps.md`,
  `docs/data-sources/vps_plans.md`, `hostinger/client.go`, `hostinger/vps_resource.go`
- https://github.com/hostinger/ansible-collection-hostinger (`plugins/modules/`)
- https://github.com/hostinger/api-mcp-server (v2.9.1, `src/core/tools/all.ts`)

Alternatives
- https://docs.hetzner.com/cloud/billing/faq/
- https://docs.hetzner.com/general/infrastructure-and-availability/price-adjustment/
- https://www.hetzner.com/cloud/regular-performance
- https://github.com/kubernetes/autoscaler/blob/master/cluster-autoscaler/cloudprovider/hetzner/README.md
- https://www.digitalocean.com/pricing/droplets
- https://aws.amazon.com/ec2/pricing/on-demand/
- https://aws.amazon.com/ec2/autoscaling/pricing/
- https://docs.fly.io/about/pricing
- https://docs.fly.io/launch/autostop-autostart

This repo
- `CLAUDE.md`, `README.md`, `apps/registry.yml`, `vps/hosts.json`, `docs/running-services.md`, `docs/monitoring.md`,
  `scripts/hypervisor-backups.py`, `docs/research/grafana-postgres-monitoring-role.md`
- SSH `uptime` / `free -m` / `nproc` on `bp-vps1-staging`, `bp-vps2-prod`, `bp-vps3-prod`, 2026-10-09 16:26 MYT
