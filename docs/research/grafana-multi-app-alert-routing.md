# One stack, several Discord channels: routing infra and app alerts apart

Researched 2026-09-20. Question: with **one** Grafana Cloud stack carrying infrastructure plus
several applications, is it conventional to (a) give each app its own Discord channel — one
contact point per channel — while keeping the single stack, and (b) organise rules, folders and
labels per app? And what is the documented mechanism?

Sources are primary only: `grafana.com/docs`, Grafana's own blog, and the upstream Alertmanager
configuration reference where Grafana inherits the behaviour. Every claim below carries its URL.

---

## Verdict

**Yes — and it is the shape Grafana documents rather than merely tolerates.** One stack, one
notification policy tree, one child policy per app matching a label, one contact point per
Discord channel. Grafana's routing best-practice guide states the pattern directly:

> "Use notification policies to define a routing tree that matches the context of your service or
> scope by defining a parent policy for default routing within the scope and defining nested
> policies for specific cases or higher-priority issues."
> — <https://grafana.com/docs/grafana/latest/alerting/guides/best-practices/>

> "This routing and tree structure makes it convenient to organize and handle alerts for dedicated
> teams, while also narrowing down specific cases within the team by applying additional labels."
> — <https://grafana.com/docs/grafana/latest/alerting/fundamentals/notifications/notification-policies/>

> "Use your alerting tool to route alerts to team-specific … integrations." … "Order routes from
> most specific to least specific: Specific routes first, Broader routes next, Default route last."
> — <https://grafana.com/docs/grafana-cloud/alerting-and-irm/irm/guides/best-practices/routing/>

A contact point is only a delivery address. A second Discord webhook is a second **address on the
same integration type**, exactly as a second email address would be — not a second alerting
system. Grafana still owns evaluation, routing, grouping, silences and templates. So this does
**not** conflict with decision #22 ("one alerting path, no second alerting vendor"); #22 rules out
a parallel notifier (Telegram, ntfy, Pushover) that would route and silence on its own. Two
webhooks under one policy tree keep the single path #22 asks for. The honest cost is one more
credential in `.env`, and one more place a webhook can be revoked without anyone noticing.

---

## 1. The mechanism: notification policies with label matchers

Routing is label matching down a tree, not per-folder configuration. There is no "route by
folder" feature; the folder reaches routing only as the reserved label `grafana_folder`.

- Matchers have "a label name, value, and operator (`=`, `!=`, `=~`, `!~`)", combined with AND.
  <https://grafana.com/docs/grafana/latest/alerting/fundamentals/notifications/notification-policies/>
- The root is the **Default notification policy**, which "matches all alert instances. It always
  handles alert instances if there are no child policies or if none of the child policies match."
  (same page)
- Child policies inherit the **contact point, grouping options and timing options** from their
  parent, and may override any of them. (same page)
- Reserved labels Grafana adds itself: `alertname` and `grafana_folder`, "the title of the folder
  containing the alert".
  <https://grafana.com/docs/grafana/latest/alerting/fundamentals/alert-rules/annotation-label/>

So "per-folder routing" is achievable — match `grafana_folder = Apps` — but it couples delivery to
where a rule file happens to be filed. An explicit label on the rule is the documented unit of
routing (§3), and a rule can then move folders without changing who is paged.

### The alternative: simplified routing ("Select contact point")

Grafana offers two modes on a rule: send to a contact point directly, or "route them through
notification policies for greater flexibility". The policy tree is what provides "nested policy
inheritance, label-based alert matching, and grouping capabilities".
<https://grafana.com/docs/grafana/latest/alerting/fundamentals/notifications/>

Simplified routing pins the destination inside every rule, so adding an app means editing every
rule rather than adding one route, and the severity timings would have to be repeated per rule.
It is the wrong tool here. One further fact matters operationally: provisioning the policy tree
"does not affect internal policies created when alert rules directly select a contact point"
(<https://grafana.com/docs/grafana/latest/alerting/set-up/provision-alerting-resources/file-provisioning/>)
— i.e. a rule that picks its own contact point is invisible to the tree in this repo's file.

---

## 2. Pitfalls, each documented

### 2a. Order matters, and the first match wins

> "Once a matching policy is found, the system does not continue to look for sibling policies."
> — <https://grafana.com/docs/grafana/latest/alerting/fundamentals/notifications/notification-policies/>

Upstream Alertmanager, whose semantics Grafana inherits: the alert enters at the root and
traverses child nodes "depth-first, left-to-right"; with `continue` false — **the default** — "it
stops after the first matching child".
<https://prometheus.io/docs/alerting/latest/configuration/>

**Consequence for this repo.** The existing tree's first three children match `severity=critical`,
`=warning`, `=info` — which every app alert will also carry. An `app` route appended *after* them
would never be reached. The app route must come **first**, or the severity routes must each grow
an `app != …` matcher, which would need editing on every new app. First-position app routes, with
severity nested underneath, is the documented "most specific first" ordering:
<https://grafana.com/docs/grafana-cloud/alerting-and-irm/irm/guides/best-practices/routing/>

### 2b. `continue` is a trap for "also send to the infra channel"

Enabling "Continue matching subsequent sibling nodes" means "multiple policies can handle the same
alert"
(<https://grafana.com/docs/grafana/latest/alerting/configure-notifications/create-notification-policy/>),
i.e. the same alert delivered twice. Useful for a deliberate duplicate feed; here it would double
every app alert into the infra channel. Leave it off.

### 2c. Grouping does not cross routes, and `group_by` multiplies groups

> "Routing always happens before grouping." … "Alerts on different routes never group together,
> even if they would produce the same grouping ID."
> — <https://grafana.com/docs/grafana-cloud/alerting-and-irm/irm/guides/best-practices/routing/>

So an app's alerts can never be bundled into the same Discord message as an infra alert once they
are on separate routes — which is the point, but it also means the infra `group_by` is not doing
double duty.

Default grouping is by `alertname` and `grafana_folder`, "as alert rule names are not unique across
folders", and "grouping happens within notification policies". Adding a label to `Group by`
produces a separate group per distinct value of it.
<https://grafana.com/docs/grafana/latest/alerting/fundamentals/notifications/group-alert-notifications/>

This repo's root `group_by` is `[grafana_folder, alertname, host]`, inherited by children unless
overridden. An app alert with no `host` label simply groups under the empty value — harmless — and
`grafana_folder` already separates `Apps` from `Monitoring`. Adding `app` to `group_by` would buy
nothing while splitting existing infra groups; so: inherit, do not override.

Upstream, `group_by: ['...']` disables aggregation entirely — every alert its own notification.
<https://prometheus.io/docs/alerting/latest/configuration/> Not wanted.

### 2d. Timings are inherited; mute timings are not

`group_wait` (30s), `group_interval` (5m) and `repeat_interval` (4h) cascade from parent to child
unless overridden (<https://prometheus.io/docs/alerting/latest/configuration/>), which is why an
app's severity tiers must state their own numbers if they are to match the infra tiers rather than
fall back to Grafana's defaults.

Mute timings are the exception: they "are not inherited from a parent notification policy, and they
have to be configured on each level".
<https://grafana.com/docs/grafana/latest/alerting/configure-notifications/create-notification-policy/>
A future maintenance window mute must therefore be repeated on each app route — it will not
cascade.

### 2e. The policy tree is one resource, and provisioning replaces all of it

> "In Grafana, the entire notification policy tree is considered a single, large resource." …
> "Since specific policies may depend on each other, you cannot provision subsets of the policy
> tree; the entire tree must be defined in a single place." … "Since the policy tree is a single
> resource, provisioning it will overwrite all policies in the notification policy tree."
> — <https://grafana.com/docs/grafana/latest/alerting/set-up/provision-alerting-resources/file-provisioning/>

This is the hard limit on "each app owns its own routing file": it cannot. One file holds the whole
tree, and every app's route lives in it. `grafana/alerting/notifications.yml` is already that file.

Provisioned resources are read-only in the UI — "You cannot edit imported alerting resources in the
Grafana UI in the same way as alerting resources that were not imported"
(<https://grafana.com/docs/grafana/latest/alerting/set-up/provision-alerting-resources/>) — unless
the `X-Disable-Provenance` header is used, which "instructs Grafana to allow changes to be made to
the policy in the UI after it has been provisioned". Two caveats from the same post: "If used in
updates, the header will only work if the policy was originally provisioned with it", and it "is
not possible when provisioning via a configuration file; it can only be accomplished via API
provisioning".
<https://grafana.com/blog/how-to-provision-a-notification-policy-in-grafana-alerting-and-keep-it-editable-in-the-ui/>

`scripts/grafana-apply.py` already sends contact points and the policy over the HTTP API with
`X-Disable-Provenance`, and the tree was first created that way, so both caveats are already
satisfied. Nothing here changes that.

---

## 3. Label conventions

Grafana names the custom labels it expects people to set: "`severity`, `priority`, `team`, and
`service`", described as labels "you manually configure in the alert rule to identify the generated
alert instances and manage the alerts".
<https://grafana.com/docs/grafana/latest/alerting/fundamentals/alert-rules/annotation-label/>

The Cloud labelling guide splits them by purpose — routing labels (`team_name` or owner, `domain`,
`namespace`), investigation labels (`cluster`, `region`, `pod`/`instance`, `runbook_url`), analytics
labels (`severity`, `service_name`, `category`) — and advises "Use consistent label keys across
teams", "Standardize label names across teams", and that "4-5 labels total is sufficient for most
organizations".
<https://grafana.com/docs/grafana-cloud/alerting-and-irm/irm/guides/best-practices/labeling/>

**So there is no single mandated key.** Grafana documents *consistency* and *a routing label that
identifies the owner or scope*; `team`, `team_name`, `service`, `service_name` and `domain` all
appear as its own examples. What it does not do is bless one spelling.

**This repo should use `app`.** `docs/grafana-organization.md` already declares `app` as the metric
and log label for exactly this axis (`booking`, `kaiteki`, `mail`, `traefik`), and one key across
metrics, logs and alerts is worth more than matching a Grafana example verbatim — which is itself
what the labelling guide asks for. `team` would be wrong here (one team owns everything);
`service` would be a second spelling of a distinction the repo has already named.

Two behaviours to keep in mind for the rules that will carry it:

- Configured (static) labels win: "When configured labels conflict with data source labels, the
  configured label takes precedence", and "Static labels override dynamic labels".
  (annotation-label; labelling guide, above) So `app: booking` written on the rule is reliable even
  if a series carries its own `app`.
- "Two alert rules cannot produce alert instances with the same labels." (annotation-label) Adding
  `app` widens the label set, so it cannot cause a collision — it can only prevent one.

### The cardinality caveat still applies

`docs/grafana-organization.md` already forbids tenant, user and request ids as labels. Nothing here
changes that: `app` has one value per application, which is the cheapest possible label.

---

## 4. What this argues for, concretely

1. A second contact point per Discord channel — same `discord` integration type, a different
   webhook URL. Contact points are delivery addresses; one per channel is how you get one channel
   per app.
2. One **parent** route per app, matching `app = <name>`, placed **before** the severity routes
   (2a), with the severity tiers nested under it so the timings match infra's (2d).
3. Rules labelled `app: <name>` statically, filed in the `Apps` folder that
   `docs/grafana-organization.md` already specifies. The label, not the folder, does the routing.
4. No `continue`, no `group_by` override (2b, 2c).
5. The whole tree stays in one file, because Grafana permits nothing else (2e).

Adding the *next* app is then: a webhook, a contact point, one route block, and rules labelled
`app=<name>`. No redesign.

---

## Sources

- Notification policies (fundamentals) — <https://grafana.com/docs/grafana/latest/alerting/fundamentals/notifications/notification-policies/>
- Configure notification policies — <https://grafana.com/docs/grafana/latest/alerting/configure-notifications/create-notification-policy/>
- Notifications (routing modes) — <https://grafana.com/docs/grafana/latest/alerting/fundamentals/notifications/>
- Group alert notifications — <https://grafana.com/docs/grafana/latest/alerting/fundamentals/notifications/group-alert-notifications/>
- Labels and annotations — <https://grafana.com/docs/grafana/latest/alerting/fundamentals/alert-rules/annotation-label/>
- Alerting best practices — <https://grafana.com/docs/grafana/latest/alerting/guides/best-practices/>
- Best practices for alert routing (Cloud) — <https://grafana.com/docs/grafana-cloud/alerting-and-irm/irm/guides/best-practices/routing/>
- Best practices for labels (Cloud) — <https://grafana.com/docs/grafana-cloud/alerting-and-irm/irm/guides/best-practices/labeling/>
- Provision alerting resources — <https://grafana.com/docs/grafana/latest/alerting/set-up/provision-alerting-resources/>
- File provisioning (policy tree is one resource) — <https://grafana.com/docs/grafana/latest/alerting/set-up/provision-alerting-resources/file-provisioning/>
- Grafana blog, provisioning a notification policy and keeping it editable — <https://grafana.com/blog/how-to-provision-a-notification-policy-in-grafana-alerting-and-keep-it-editable-in-the-ui/>
- Alertmanager configuration, `<route>` — <https://prometheus.io/docs/alerting/latest/configuration/>
