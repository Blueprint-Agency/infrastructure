# Grafana → Discord alert format: what to send so it reads at a glance

Researched 2026-09-16. Sources are primary only: Grafana docs, the `grafana/alerting` and
`grafana/grafana` source (pinned to the commit read), Discord's developer docs, the Prometheus
docs, and the Google SRE book. Nothing in the repo was changed apart from this note. The current
config is `grafana/alerting/notifications.yml`, and the rule annotations are in `grafana/rules/*.yml`.

Source pins:
- `grafana/alerting` @ `c49d89cd20569af393afae0f464dd003712bf04e` (main, 2026-09-16)
- `grafana/grafana` @ `ff1f066cd00baa23e1434160e40fc92f7b09dd56` (main, 2026-09-16)

---

## 1. What is confusing today, and why

### 1a. A green dot next to a sentence that says something is broken

Today's message template puts a dot in front of each alert's `summary`, based on that alert's status:

```
{{ range .Alerts -}}
{{ if eq .Status "firing" }}🔴{{ else }}🟢{{ end }} {{ .Annotations.summary }}
{{ end }}
```

The summaries are written as if the problem is still happening:

- `grafana/rules/textfile.yml` (`probes-stale-bpvps1`):
  `"bpvps1 probe {{ $labels.probe }} has not completed in time (no probe label: no probe heartbeat at all)"`
- `grafana/rules/hosts.yml` (`mail-port-down`):
  `"{{ $labels.target }}:{{ $labels.port }} failed {{ humanize $values.A.Value }} probes in a row from bpvps2"`
- `grafana/rules/containers.yml`:
  `"{{ $labels.container }} on {{ $labels.host }} has reported no metrics for 3 minutes"`

So a resolved alert shows "🟢 … has not completed in time". The dot is the only thing that
says "resolved", and the sentence says the opposite.

**"failed 0 probes in a row" happens because Grafana re-renders annotations on every
evaluation, including the one that resolves the alert.** In `pkg/services/ngalert/state/state.go`,
`newState` calls `expandAnnotationsAndLabels(ctx, log, alertRule, result, …)` with the
*current* evaluation result. `patch()` copies over from the previous state only the annotations
in `models.InternalAnnotationNameSet`. Its comment says: "Annotations can change over time,
however we also want to maintain certain annotations across evaluations".
([state.go](https://github.com/grafana/grafana/blob/ff1f066cd00baa23e1434160e40fc92f7b09dd56/pkg/services/ngalert/state/state.go#L84-L85),
[patch](https://github.com/grafana/grafana/blob/ff1f066cd00baa23e1434160e40fc92f7b09dd56/pkg/services/ngalert/state/state.go#L798-L820))
In the resolving evaluation `$values.A.Value` really is 0, so the resolved message says
"failed 0 probes". There is one exception: an alert whose series **disappears** is resolved as
stale, in `manager.go` (`StateReasonMissingSeries`). That path is not re-rendered, so it keeps the
annotations from its last firing evaluation
([manager.go](https://github.com/grafana/grafana/blob/ff1f066cd00baa23e1434160e40fc92f7b09dd56/pkg/services/ngalert/state/manager.go#L590-L610)).
**Result: a number in a summary is wrong or stale after the alert resolves.**

The "(no probe label: …)" text is always there, because it is plain text and not a conditional.
`absent_over_time(...{host="bpvps2"})` returns a series with only the labels taken from its
equality matchers, so `$labels.probe` is empty. The note in brackets tried to explain that
inside the sentence. The annotation language has `if`/`with` for this:
`{{ with $x }}…{{ else }}…{{ end }}`
([template language](https://grafana.com/docs/grafana/latest/alerting/alerting-rules/templates/language/)).

### 1b. Firing and resolved alerts arrive in the same message

- The notification data contains `Alerts`: "List of all firing and resolved alerts in this
  notification", along with the `.Alerts.Firing` and `.Alerts.Resolved` subsets
  ([template reference](https://grafana.com/docs/grafana/latest/alerting/configure-notifications/template-notifications/reference/)).
- The top-level `Status` "is `firing` if at least one alert is firing, otherwise `resolved`"
  (same page).
- Group interval is "the time to wait before sending a notification about changes in the alert
  group", and "An alert instance exits the group after being resolved and notified of its state
  change"
  ([grouping](https://grafana.com/docs/grafana/latest/alerting/fundamentals/notifications/group-alert-notifications/)).
  So when some instances in a group resolve while others still fire, the next group update holds both.
- In the Discord notifier, the embed colour comes from the **group** status:
  `receivers.GetAlertStatusColor(alerts.Status())`, which is `#D63232` when firing and `#36a64f`
  otherwise
  ([discord.go L175](https://github.com/grafana/alerting/blob/c49d89cd20569af393afae0f464dd003712bf04e/receivers/discord/v1/discord.go#L175),
  [colours](https://github.com/grafana/alerting/blob/c49d89cd20569af393afae0f464dd003712bf04e/receivers/util.go#L28-L43)).
  A mixed message therefore gets a red card, with 🟢 and 🔴 lines inside it.

**Why the description shows for only one alert.** The template prints
`.CommonAnnotations.description`, which holds "The annotations common to all alerts in this
notification" (reference page). It prints it only `if eq .Status "firing"`. Descriptions that use
`$labels` (for example `endpoints.yml`, `{{ $labels.instance }}`) differ between instances, so the
common value is empty. It is also empty when a resolved instance's re-rendered annotation differs
from a firing one's.

### 1c. "Probe stopped on bpvps2 (2)"

The title uses `len .Alerts`, which counts firing **and** resolved alerts. "(2)" can therefore
mean "one firing, one already fixed". The count also has no label, so it could mean
"2 incidents" or "2nd time". The comment in `notifications.yml` wants the count to diagnose
problems ("Container down on bpvps1 (11)" means the agent is gone). That only works if it counts
**firing** alerts and says so.

### 1d. The message renders above the coloured card

The Discord notifier places the templated `message` in the top-level `content`. The `title` goes
into the embed, and the colour goes on the embed
([discord.go L123-L176](https://github.com/grafana/alerting/blob/c49d89cd20569af393afae0f464dd003712bf04e/receivers/discord/v1/discord.go#L123-L176)).
The upstream commit that added the alternative says why this matters: "Discord renders top-level
message content above the embed, which caused alert messages to appear above the title instead
of inside the embed body"
([grafana/alerting#368](https://github.com/grafana/alerting/pull/368), merged 2026-07-02). The
fix is the opt-in `use_embed_description` ("Show Message in Embed"). With it, "mentions (@ or
<@ID>) in the message will not trigger Discord notifications"
([config.go](https://github.com/grafana/alerting/blob/c49d89cd20569af393afae0f464dd003712bf04e/receivers/discord/v1/config.go)).
We send no mentions, so we lose nothing.

---

## 2. Reference: the Discord contact point

Settings in `receivers/discord/v1/config.go`
([source](https://github.com/grafana/alerting/blob/c49d89cd20569af393afae0f464dd003712bf04e/receivers/discord/v1/config.go)):

| Setting (API key) | Effect |
|---|---|
| `url` | Webhook. Required. Stored as a secret. |
| `title` | Templated. Goes to the **embed title**, truncated to `discordMaxTitleLen = 256` runes. Default `{{ template "default.title" . }}`. |
| `message` | Templated. Goes to `content` (above the card), or to the embed description if `use_embed_description`. Truncated to `discordMaxMessageLen = 2000` runes either way. Default `{{ template "default.message" . }}`. |
| `avatar_url` | Templated. Sets the webhook avatar. |
| `use_discord_username` | Off means the username is forced to `"Grafana"`. On means the webhook's own name is used. |
| `use_embed_description` | Puts the message inside the coloured card. Mentions stop pinging. |
| `disableResolveMessage` (on the receiver, not in `settings`) | Suppresses resolved notifications ([file provisioning](https://grafana.com/docs/grafana/latest/alerting/set-up/provision-alerting-resources/file-provisioning/), [HTTP API](https://grafana.com/docs/grafana/latest/alerting/set-up/provision-alerting-resources/http-api-provisioning/)). |

Fixed by the notifier: the embed URL is `<ExternalURL>/alerting/list`, the footer is
`"Grafana v" + appVersion`, and at most `discordMaxEmbeds = 10` embeds are sent (the extras are
alert images) ([discord.go](https://github.com/grafana/alerting/blob/c49d89cd20569af393afae0f464dd003712bf04e/receivers/discord/v1/discord.go)).
Discord's own limits are 256 characters for an embed title, 4096 for the description, and 6000
across all embeds ([Discord message resource](https://docs.discord.com/developers/resources/message)).
Grafana's 2000-rune cap is the tighter one.

Grafana's default Discord output, `default.title`/`default.message`, is
`[FIRING:n, RESOLVED:m] <group label values>`. The body has separate **Firing** / **Resolved**
sections, each dumping every label and annotation
([default_template.go](https://github.com/grafana/alerting/blob/c49d89cd20569af393afae0f464dd003712bf04e/templates/default_template.go#L21-L45)).
Upstream also keeps the two states in separate sections. The current custom template dropped that.

### Template data used below

From the [notification template reference](https://grafana.com/docs/grafana/latest/alerting/configure-notifications/template-notifications/reference/):

- `.Status`, `.Alerts.Firing`, `.Alerts.Resolved`, `.GroupLabels`, `.CommonLabels`,
  `.CommonAnnotations`, `.ExternalURL`
- Per alert: `.Status`, `.Labels`, `.Annotations`, `.StartsAt` ("The time the alert fired"),
  `.EndsAt`, `.GeneratorURL`, `.SilenceURL`, `.DashboardURL` / `.PanelURL` (Grafana-managed rules
  only), `.Values`, `.ValueString`
- Functions: `toUpper`, `join`, `tz`, `date`. Documented examples include
  `{{ .StartsAt | tz "Europe/Paris" | date "15:04:05 MST" }}` and
  `There are {{ len .Alerts.Firing }} firing alerts`.

The standard annotations are `summary` ("Short summary of what happened and why"),
`description`, and `runbook_url` ("Webpage where you keep your runbook for the alert")
([configure notification message](https://grafana.com/docs/grafana/latest/alerting/alerting-rules/create-grafana-managed-rule/)).
Grafana's guidance is to put per-alert information in annotations or labels, not in notification
templates, "ensuring it's also visible in the alert state and alert history within Grafana"
([template notifications](https://grafana.com/docs/grafana/latest/alerting/configure-notifications/template-notifications/)).

### Managing templates as code

There are two supported routes:
- Inline Go template in the contact point's `title`/`message`, which is what we do now.
  `grafana-apply.py` already PUTs contact points to `/api/v1/provisioning/contact-points`.
- A named template group via `PUT /api/v1/provisioning/templates/:name`, with body
  `{"template": "{{ define \"…\" }}…{{ end }}"}`
  ([HTTP API](https://grafana.com/docs/grafana/latest/alerting/set-up/provision-alerting-resources/http-api-provisioning/)),
  or `templates:` in file provisioning
  ([file provisioning](https://grafana.com/docs/grafana/latest/alerting/set-up/provision-alerting-resources/file-provisioning/)).
  Names must be unique across all groups, and `default.title`, `default.message`, `__subject`
  and similar names are reserved. The UI preview works only with Grafana Alertmanager
  ([create templates](https://grafana.com/docs/grafana/latest/alerting/configure-notifications/template-notifications/create-notification-templates/)).

With one contact point, keeping the template inline is enough. A named group becomes worth the
extra apply step only if a second integration (the planned email) should reuse the same text.

---

## 3. Guidance: what a notification must say

- **Every page is actionable, and a person should not have to interpret it.** "Every page should
  be actionable." "Monitoring should never require a human to interpret any part of the alerting
  domain."
  ([SRE book, Monitoring](https://sre.google/sre-book/monitoring-distributed-systems/),
  [SRE book, Introduction](https://sre.google/sre-book/introduction/))
- **Link the playbook.** Recording best practices "in a 'playbook' produces roughly a 3x
  improvement in MTTR as compared to the strategy of 'winging it.'"
  ([SRE book, Introduction](https://sre.google/sre-book/introduction/))
- **Symptom first, and link to where the cause can be found.** "keep alerting simple, alert on
  symptoms, have good consoles to allow pinpointing causes, and avoid having pages where there is
  nothing to do"
  ([Prometheus, Alerting](https://prometheus.io/docs/practices/alerting/)).
- **Write for the first responder.** Grafana's best practices: "Alerts should be designed for the
  first responder, not the person who created the alert". An alert should "clearly explain why it
  exists, what triggered it, and how to investigate", with dashboards and runbooks linked in
  annotations. Use pending periods, `keep_firing_for` or recovery thresholds to "avoid rapid
  resolve-and-fire notifications"
  ([Grafana alerting best practices](https://grafana.com/docs/grafana/latest/alerting/guides/best-practices/)).

Put together, a notification that can be read on a lock screen answers these questions, in this order:

| Question | Where |
|---|---|
| Is it broken or fixed? | First word of the title (`FIRING`/`RESOLVED`) plus colour. Never the dot alone. |
| How urgent? | Severity in the title while firing. |
| What condition, where? | Rule title + `host` (a group label) in the title. |
| How many? | "*n* firing", counting firing alerts only. |
| Which instance, how bad, since when? | One line per alert: `summary` (state-neutral), `value` (firing only), start time in KL. |
| What do I do first? | `description` once, taken from a firing alert. |
| Where next? | Runbook · Silence · Rule links. |

**On the question of separate firing and resolved annotation text: don't.** Grafana has no
per-state annotation. You could branch on `$values` inside the annotation, but section 1a shows
this breaks. The resolving evaluation re-renders it, and a stale resolution does not. So write
`summary` as a **state-neutral noun phrase naming the thing that is checked**. Put the
measurement in a separate `value` annotation, and let the notification template print it only
for firing alerts. The template adds the state; the annotation never states it. This is an
inference from the sources above, not a Grafana recommendation.

Keep resolved messages (`disableResolveMessage: false`). The monitoring runbook's own tests, such
as "confirm it resolves" in `docs/monitoring.md`, depend on them. Handle flapping at the rule
(`for`, `keep_firing_for`), as Grafana recommends, not by muting resolution.

---

## 4. Recommendation

### 4a. Contact point (`grafana/alerting/notifications.yml`)

```yaml
contact_points:
  - name: discord
    type: discord
    settings:
      url: ${DISCORD_WEBHOOK_URL}
      # Message inside the coloured card, not above it. Nothing here @mentions anyone.
      # Added upstream 2026-07-02 (grafana/alerting#368): confirm "Show Message in Embed"
      # exists in the Grafana Cloud contact-point UI before relying on it.
      use_embed_description: true

      # "🔴 CRITICAL · Mail port unreachable · bpvps1 · 3 firing · 1 cleared"
      # "✅ RESOLVED · Mail port unreachable · bpvps1"
      title: >-
        {{- $f := len .Alerts.Firing -}}{{- $r := len .Alerts.Resolved -}}
        {{- if $f -}}
          🔴 {{ with .CommonLabels.severity }}{{ toUpper . }}{{ else }}FIRING{{ end }}
        {{- else -}}
          ✅ RESOLVED
        {{- end }} · {{ .CommonLabels.alertname }}
        {{- with .CommonLabels.host }} · {{ . }}{{ end }}
        {{- if gt $f 1 }} · {{ $f }} firing{{ end }}
        {{- if and $f $r }} · {{ $r }} cleared{{ end }}
        {{- if and (not $f) (gt $r 1) }} · {{ $r }} instances{{ end }}

      message: |-
        {{- if .Alerts.Firing }}**Firing**
        {{- range .Alerts.Firing }}
        • {{ .Annotations.summary }}{{ with .Annotations.value }} — **{{ . }}**{{ end }} · since {{ .StartsAt | tz "Asia/Kuala_Lumpur" | date "02 Jan 15:04" }}
        {{- end }}
        {{- with (index .Alerts.Firing 0) }}
        {{ with .Annotations.description }}
        > {{ . }}
        {{ end }}
        {{ with .Annotations.runbook_url }}[Runbook]({{ . }}) · {{ end }}[Silence]({{ .SilenceURL }}) · [Rule]({{ .GeneratorURL }})
        {{- end }}
        {{- end }}
        {{- if .Alerts.Resolved }}
        {{ if .Alerts.Firing }}
        {{ end }}**Resolved**
        {{- range .Alerts.Resolved }}
        • {{ .Annotations.summary }} · {{ .StartsAt | tz "Asia/Kuala_Lumpur" | date "02 Jan 15:04" }} → {{ .EndsAt | tz "Asia/Kuala_Lumpur" | date "15:04" }}
        {{- end }}
        {{- end }}
```

How this fixes each problem:
- State is a word at the start of the title and a section header, with the colour on top. It no
  longer depends on a 🟢 next to a sentence.
- The count is `firing` alerts, labelled. Resolved alerts are counted separately as `cleared`.
  "(2)" is gone.
- The description comes from a **firing** alert, not `CommonAnnotations`. It survives label
  templating and mixed groups, and is not shown in an all-resolved message (nothing to do).
- `value` is shown only for firing alerts, so re-rendered values like "0 probes" never reach Discord.
- Times are in `Asia/Kuala_Lumpur`, the repo's timezone (CLAUDE.md).
- Length: at ~90 characters per line, the 2000-rune cap
  ([discord.go](https://github.com/grafana/alerting/blob/c49d89cd20569af393afae0f464dd003712bf04e/receivers/discord/v1/discord.go#L33))
  fits about 15 instances plus links. The worst case today is `container-down` on a whole host
  (11). If a host grows past about 15 containers, add a cap with `range $i, $a := …` and
  "…and N more".

Whitespace in Go templates is fiddly, and newlines inside `{{- … -}}` blocks matter. Before
applying, render it once with the contact point's **Test** button in the Grafana UI, which works
because Grafana Cloud uses the Grafana Alertmanager. Or trigger the canary per `docs/monitoring.md`
"Canary tests". Adjust blank lines by eye.

### 4b. Annotations: state-neutral `summary`, separate `value`, `runbook_url`

The pattern: the **title** holds the condition (the rule title), a **`summary` line** says which
instance, and **`value`** says how bad (firing only). Examples against the current rules:

```yaml
# probes-stale-bpvps2 (textfile.yml)
summary: '{{ with $labels.probe }}Probe "{{ . }}"{{ else }}Every probe (no heartbeat series at all){{ end }} on bpvps2'
value: "no successful run within its max age"

# mail-port-down (hosts.yml)
summary: "{{ $labels.target }}:{{ $labels.port }}, probed from bpvps2"
value: "{{ humanize $values.A.Value }} failures in a row"

# container-down-<host> (containers.yml)
summary: "{{ $labels.container }} on {{ $labels.host }}"
value: "no metrics for 3+ min"

# disk-warning / disk-critical (hosts.yml)
summary: "{{ $labels.mountpoint }} on {{ $labels.host }}"
value: "{{ humanize $values.A.Value }}% full"

# every rule
runbook_url: "https://github.com/Blueprint-Agency/infrastructure/blob/main/docs/monitoring.md#what-each-alert-means-and-the-first-three-things-to-check"
```

This is how they then read on Discord:

```
🔴 WARNING · Probe stopped · bpvps2
Firing
• Probe "mail" on bpvps2 — no successful run within its max age · since 16 Sep 03:12
> `ssh bp-bpvps2 'docker ps --filter name=probes; docker logs --tail 50 probes'` -- a failing job logs why. …
Runbook · Silence · Rule

✅ RESOLVED · Mail port unreachable · bpvps1
Resolved
• mail.blueprintdigital.my:465, probed from bpvps2 · 16 Sep 04:30 → 04:43
```

`description` stays as it is: it is already written as "what it means + first command", and it
now appears only while firing. The trailing "Runbook: docs/monitoring.md." inside each
description becomes redundant once `runbook_url` exists. The repo is public (per the header of
`notifications.yml`), so the GitHub link opens on a phone.

A follow-up to consider, not covered by these sources: CI (`vps/shared/check-monitoring.py`)
could require `summary`, `value` (where the rule has a numeric value) and `runbook_url` on every
rule, the same way they already require per-host rules.
