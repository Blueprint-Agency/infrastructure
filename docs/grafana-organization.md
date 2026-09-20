# Organising Grafana Cloud

How one Grafana Cloud account holds both **infrastructure** monitoring (#22) and, later,
**application** monitoring, without the two fighting each other or producing a surprise bill.

`docs/monitoring.md` is the runbook for what we monitor and how to operate it. This file is the
shape underneath it: what goes where, and why. Read it before adding the first app.

## Three layers, and the one people confuse

```
Account          your login, your bill
  └─ Stack       one Grafana + its Prometheus + Loki + Synthetics
       └─ Labels where separation actually happens
```

A **stack is not a folder**. It is an entire separate Grafana: separate login, separate
dashboards, separate alert rules — and **you cannot query across two of them**. Splitting is
expensive and mostly irreversible in practice.

The free tier allows exactly **one stack** (self-service paid allows three). That constraint
matches the right answer anyway: **one stack, separated by labels.**

## Labels

Every metric and every log stream carries these. They are what make one stack feel like several.

| Label | Values | Set by |
|---|---|---|
| `host` | `bpvps1`, `bpvps2` | `MONITORING_HOST` in the monitoring stack's compose — the `vps/hosts.json` key, checked by CI |
| `env` | `staging`, `prod` | `ENV_NAME`, per fanout destination |
| `compose_project` | the stack directory — `booking-staging` vs `booking-prod` | Docker |
| `container` | container name | Docker |
| `app` | `booking`, `kaiteki`, `mail`, `traefik` | add when apps start shipping |

Anything is then one query: `{app="booking", env="prod"}`.

`host`, `env`, `compose_project` and `container` are already in place (#23). `app` is the one to
add when the first application ships its own metrics.

## ⚠️ Never label by tenant

`booking-system` is **multi-tenant**: one deployment serves every studio, and a studio is a
`Tenant` row. It is very tempting to add `tenant="yoga-sadhana"` to its metrics.

Do not. Labels multiply:

```
200 series per app  ×  50 studios  =  10,000 series
```

That is the entire free tier, consumed by one label. The same applies to `user_id`,
`booking_id`, `request_id`, and to any URL path with an id in it.

**Where per-tenant detail goes instead:** inside the **log line**, not the label. Loki still
searches it — `{app="booking"} |= "tenant=yoga-sadhana"` — and it multiplies nothing. Metrics
stay aggregate; logs carry the detail.

This is the single most common way a small team gets a large Grafana bill, and this platform's
architecture walks straight into it.

## Folders

```
Infra/   hosts, containers, endpoints, backups
Apps/    booking, kaiteki, ...
```

Alert rules keep the naming already in use: **symptom + scope** — `container-down-bpvps2`,
`backup-stale-bpvps2`, `endpoint-down`, `tls-expiry`. Do not drift from it; consistency here is
what makes an alert readable at 2am by someone who did not write it.

The folder is filing, not routing. Grafana routes on labels; a folder reaches the routing tree
only as the reserved label `grafana_folder`. Which is why the next section is about a label.

## A new app = a webhook, a contact point, a route, a label

Each app gets **its own Discord channel**, so an application alert never buries a host running out
of disk — and one Grafana stack still owns every rule, every silence and one message format. That
is Grafana's own documented shape (a parent policy per scope, nested policies for the specific
cases), not a local invention: `docs/research/grafana-multi-app-alert-routing.md` cites it.

It is also not a second alerting vendor, so it does not touch decision #22. A second webhook is a
second *address* on the same Discord integration, exactly as a second email address would be.

Four steps, every time, and nothing else:

1. **A Discord webhook** for the new channel. Server Settings → Integrations → Webhooks → New
   Webhook. Its URL is a credential and this repo is public, so it goes in `.env` as
   `DISCORD_<APP>_WEBHOOK_URL` and is listed (blank) in `.env.example`. Never share one webhook
   between two contact points — `test_grafana_apply.py` fails if two do.
2. **A contact point** in `grafana/alerting/notifications.yml`, merging the `&discord_format`
   anchor and overriding only `url`. Merging is what keeps every channel's messages identical.
3. **One route** at the **top** of `policy.routes`, matching `[[app, "=", <name>]]`, with the
   three severity tiers nested under it merging `*critical_timing`, `*warning_timing`,
   `*info_timing`. Above the infra severity routes, always: matching stops at the first matching
   sibling, so a route below them is dead config that looks alive.
4. **Rules labelled `app: <name>`** in `grafana/rules/<name>.yml`, folder `Apps`. Static labels
   beat anything a series carries, so the label is reliable. A rule that forgets it lands in the
   infra channel — wrong room, not silence.

`app` is the key for this, not `service` or `team`: it is already the metric and log label above,
and Grafana's labelling guidance asks for one consistent key across teams rather than any
particular spelling. One team owns everything here, so `team` would carry no information.

Currently routed: `booking` → `discord-booking`. Everything unlabelled → `discord`.

## The budget is shared

Infra and apps draw on the same active-series and log allowances. Two hosts of infrastructure is
comfortable. **One Node application with default Prometheus client settings can ship 500–1,000
series on its own** — histograms are the expensive part, because every bucket is a series.

So when apps start shipping: give each app its own **allowlist**, exactly as the hosts have
(`docs/monitoring.md`, "Metrics: the allowlist"). Collect what backs a panel or a rule; drop the
rest at the agent, before it leaves the host. Measure after a week.

A metric nobody reads is budget spent on nothing. A dashboard panel nobody opens is the same
thing wearing a nicer hat.

## Credentials

One service account or access policy **per purpose**, never one shared token:

| Credential | Scope | Lives in |
|---|---|---|
| `vps-agents-write` access policy | `metrics:write`, `logs:write` | per-host **GitHub Environment** secret |
| `grafana-apply` service account | Editor | local `.env` |
| Synthetics access token | Synthetics | local `.env` |

Per-Environment, never org-level: an org secret is readable by every other repo in the org, and
this org also holds a different client's repositories. A credential you can revoke without
taking everything else down is worth the extra five minutes.

## When to actually split into a second stack

Only two good reasons:

1. A client contractually requires their data isolated.
2. Teeko and Blueprint genuinely separate as businesses.

**Not** for tidiness. Splitting costs cross-querying and doubles the alerting configuration.
Labels do tidiness better, and reversibly.

## Setting it up

The ordered runbook is `docs/monitoring.md`, "First-time setup (once per Grafana Cloud stack)".

One thing worth knowing before you start, because it causes most of the confusion: **there are
two different websites.**

| | What lives there |
|---|---|
| **grafana.com** (the portal) | account, billing, **access policies**, and the Prometheus / Loki push URLs and instance IDs |
| **`<slug>.grafana.net`** (the stack) | dashboards, alerting, **service accounts**, Synthetics |

Grafana does not publish stable deep links into either, and menu labels shift between versions,
so the runbook names the path rather than a URL.
