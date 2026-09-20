# Grafana Database Observability: is the `db-o11y` Postgres login right?

Researched 2026-09-20. Reviews PR #33 (`booking-observability-166`) — `vps/bpvps2/stacks/db-observability/`
(`config.alloy`, `setup-db-o11y.sql`, `docker-compose.yml`, `Dockerfile`, `ci/env.ci`),
`vps/bpvps2/stacks/booking/docker-compose.yml`, `.github/workflows/deploy-infra.yml`, `docs/monitoring.md`.

Primary sources only: Grafana Cloud Database Observability docs, Grafana Alloy component references,
Alloy source pinned to the tag the stack runs, and the PostgreSQL 16 manual (the containers run
`postgres:16-alpine`).

Source pins:
- Alloy image and source: `grafana/alloy` **v1.19.2** (the `FROM` line in the stack's `Dockerfile`).
  Files read: `internal/component/database_observability/postgres/collector/{schema_details,health_check,explain_plans,connection_info,dsn}.go`.
- `prometheus-community/postgres_exporter` `collector/pg_stat_statements.go` (main, read 2026-09-20).
- Grafana Alloy docs: "latest" channel. `remote.vault` page shows _Last reviewed: September 11, 2026_.
- PostgreSQL docs: the **16** branch, matching `postgres:16-alpine`.

**Overall verdict: the design is sound and matches the documented setup on every point that matters.
Three things to fix before deploy** (§4.3 connection limit sanity-check, §5.2 weak verification query,
§7.1 a comment that is factually wrong), and one version-coupling risk to record (§2.2).

---

## 1. What privileges does Database Observability actually require?

Grafana's self-managed Postgres setup page prescribes exactly this:

```sql
CREATE USER "db-o11y" WITH PASSWORD '<DB_O11Y_PASSWORD>';
GRANT pg_monitor TO "db-o11y";
GRANT pg_read_all_stats TO "db-o11y";
```

— <https://grafana.com/docs/grafana-cloud/observe-and-act/monitor-applications/database-observability/set-up/postgres/postgres/>

### 1.1 `pg_read_all_stats` is not separately needed

PostgreSQL 16, Table 22.1: "`pg_monitor` — Read/execute various monitoring views and functions.
**This role is a member of `pg_read_all_settings`, `pg_read_all_stats` and `pg_stat_scan_tables`.**"
— <https://www.postgresql.org/docs/16/predefined-roles.html>

Alloy's own health check probes membership transitively, with
`pg_has_role(current_user, 'pg_read_all_stats', 'MEMBER')`
(`collector/health_check.go`, `monitoringUserPrivilegesQuery` —
<https://github.com/grafana/alloy/blob/v1.19.2/internal/component/database_observability/postgres/collector/health_check.go>),
and `pg_has_role(..., 'MEMBER')` follows indirect membership. So `GRANT pg_monitor` alone makes both
Grafana's documented checks return `t`.

**Verdict: correct as done.** Adding `GRANT pg_read_all_stats TO "db-o11y";` would be a no-op that
matches the docs verbatim; optional, not required.

### 1.2 What each feature needs

| Feature | What it reads | Works with `pg_monitor` only? |
|---|---|---|
| Queries overview / Query details (`query_details`) | `pg_stat_statements` | Yes. Query text of *other users* is visible only to "superusers and roles with privileges of the `pg_read_all_stats` role" (<https://www.postgresql.org/docs/16/pgstatstatements.html>) — which `pg_monitor` confers |
| Query samples + Wait events (`query_samples`) | `pg_stat_activity` | Yes. Grafana: "Verify that the monitoring user has the `pg_monitor` or `pg_read_all_stats` role, which grants access to `pg_stat_activity`" (<https://grafana.com/docs/grafana-cloud/observe-and-act/monitor-applications/database-observability/reference/postgres-configuration/>) |
| Table schema details (`schema_details`) | see §2 | Yes in v1.19.2 — but the docs say otherwise |
| Explain plan tab (`explain_plans`) | `EXPLAIN (FORMAT JSON) EXECUTE …` | **No** — needs `SELECT` on every planned table |
| Errors views (`logs` collector) | parsed Postgres server log | N/A — needs `enable_error_logs_processing` and a log source |

`explain_plans.go` issues `EXPLAIN (FORMAT JSON) EXECUTE ` and carries `"pq: permission denied"` in its
handled-error list — the repo's stated reason for disabling it is correct as written.

**Verdict on disabling `explain_plans`: correct as done**, and it is the only collector that would have
forced a data-read grant. Note the consequence, which `docs/monitoring.md` already records: the Explain
plan tab stays empty. Cost of enabling it would be minimal otherwise — "Explain plans run `EXPLAIN`, not
`EXPLAIN ANALYZE`, so overhead is minimal" (<https://grafana.com/docs/grafana-cloud/observe-and-act/monitor-applications/database-observability/configure/tune-alloy-collection/>).

### 1.3 What else is silently off

`database_observability_pg_errors_total`, the `error_message` log op and the per-query **Errors** views
require `enable_error_logs_processing` plus a Postgres log source
(<https://grafana.com/docs/grafana-cloud/observe-and-act/monitor-applications/database-observability/reference/telemetry-reference/>).
The stack does not set it. `docs/monitoring.md` records this as deliberate ("Not collected"). The `logs`
collector itself is **"Always on"** and cannot be disabled (tune-alloy-collection, Collectors overview) —
it is simply inert without the flag. No change needed; the repo is consistent with the source.

---

## 2. Schema details vs the documented object grants — the one real divergence

Grafana's setup page has a step the repo deliberately skips:

> "**Grant object privileges for detailed data.** To allow collecting schema details and table
> information, connect to each logical database and grant access to each schema. […]
> `GRANT USAGE ON SCHEMA public TO "db-o11y"; GRANT SELECT ON ALL TABLES IN SCHEMA public TO "db-o11y";`
> Alternatively […] `GRANT pg_read_all_data TO "db-o11y";`"

and the troubleshooting page expects `SELECT pg_has_role('db-o11y','pg_read_all_data','MEMBER')` to return `t`
(<https://grafana.com/docs/grafana-cloud/observe-and-act/monitor-applications/database-observability/troubleshoot/postgres/>).

### 2.1 In v1.19.2 the grant is not actually needed

`schema_details.go` queries **`pg_catalog` only** — `pg_catalog.pg_namespace`, `pg_class`, `pg_attribute`,
`pg_attrdef`, `pg_constraint`, `pg_index`, and `pg_catalog.pg_get_expr()`. It never touches
`information_schema` and never selects a row of user data. `pg_catalog` is world-readable, so the
`schema_details` collector will populate the Table schema details tab with `pg_monitor` alone.

Database discovery is gated on `has_database_privilege(datname, 'CONNECT')` (`selectAllDatabases` in the
same file), which the setup SQL's `GRANT CONNECT ON DATABASE :"booking_db"` satisfies.

**Verdict: correct as done, for this Alloy version.** The stack gets full schema details with no read
access to application data.

### 2.2 Version-coupling risk — record it

The divergence only holds because `schema_details` happens to use `pg_catalog`. Had it used
`information_schema`, it would return nothing: "The view `tables` contains all tables and views defined in
the current database. **Only those tables and views are shown that the current user has access to** (by way
of being the owner or having some privilege)." — <https://www.postgresql.org/docs/16/infoschema-tables.html>

**Change to make:** add a line to `setup-db-o11y.sql` (and to `docs/monitoring.md`, "Database
Observability") saying that skipping Grafana's object-privilege step is validated against Alloy **v1.19.2**
`schema_details` reading `pg_catalog` only, and that an Alloy bump must re-check that collector before the
`Dockerfile` tag moves. The `Dockerfile` already pins an exact tag, so this is a documentation gap, not a
config one.

---

## 3. Is a dedicated monitoring role the documented recommendation?

### 3.1 Dedicated role: yes

PostgreSQL 16, §22.5: "These roles are intended to allow administrators to **easily configure a role for
the purpose of monitoring the database server**. They grant a set of common privileges allowing the role to
read various useful configuration settings, statistics, and other system information normally restricted to
superusers." With the warning: "**Care should be taken when granting these roles** to ensure they are only
used where needed and with the understanding that these roles grant access to privileged information."
— <https://www.postgresql.org/docs/16/predefined-roles.html>

Grafana's setup page assumes a purpose-built user throughout: it names it `db-o11y`, says "Alloy must
connect as this same user", and `ALTER ROLE "db-o11y" SET pg_stat_statements.track = 'none'` only makes
sense for a role that does nothing else.

### 3.2 Reusing the app or owner role would break things, by design

- Alloy's default `exclude_users` is `["azuresu", "cloudsqladmin", "db-o11y", "rdsadmin"]` and
  `exclude_current_user` defaults to `true`
  (<https://grafana.com/docs/alloy/latest/reference/components/database_observability/database_observability.postgres/>).
  Reusing the application role would exclude the application's own queries — the thing being monitored.
- `ALTER ROLE … SET pg_stat_statements.track='none'` on a shared role would blank the app's statistics.
- Connecting as the table owner would defeat `0033_row_level_security.sql`: RLS exempts the owner unless
  `FORCE` is set, and nothing constrains a superuser. That is the repo's own rule in
  `booking-system/CLAUDE.md` ("The app must not connect as the table owner").

**Verdict: correct as done.** Name `db-o11y` matched to Grafana's default `exclude_users` is exactly right,
and `setup-db-o11y.sql` says so for the right reason.

---

## 4. Cluster scope, one role per container, settings

### 4.1 Roles are cluster-scoped — one per container is necessary

PostgreSQL 16, §21.1: "**Database roles are global across a database cluster installation (and not per
individual database).**" — <https://www.postgresql.org/docs/16/database-roles.html>

`booking-db-staging` and `booking-db-prod` are separate containers, therefore separate clusters, therefore
separate `pg_roles` catalogs. One role literally cannot span both; two `CREATE ROLE` runs are not a choice.
`setup-db-o11y.sql`'s "Run ONCE PER INSTANCE" is the only possible shape.

**Verdict: correct as done, and not optional.**

### 4.2 Separate passwords per cluster

No PostgreSQL or Grafana document forbids reusing one password across clusters — this is general credential
hygiene (blast radius, independent rotation), not a cited rule. The repo's choice of two secrets,
`DB_O11Y_STAGING_PASSWORD` and `DB_O11Y_PROD_PASSWORD`, is strictly better than one and costs nothing.
The `openssl rand -hex 24` form is also what makes `config.alloy`'s "needs no URL escaping" comment true:
libpq URIs otherwise need percent-encoding for special characters
(<https://www.postgresql.org/docs/16/libpq-connect.html#LIBPQ-CONNSTRING>).

**Verdict: correct as done. State in `docs/monitoring.md` that this is hygiene, not a documented
requirement,** so nobody hunts for the rule later.

### 4.3 Required PostgreSQL settings — all four are present and exact

Grafana's required table (setup page): `shared_preload_libraries = pg_stat_statements` (restart),
`compute_query_id = on` (restart), `pg_stat_statements.track = all`, `track_activity_query_size = 4096`
(restart). `vps/bpvps2/stacks/booking/docker-compose.yml` lines 110–119 set all four, as startup `-c` flags.
`CREATE EXTENSION IF NOT EXISTS pg_stat_statements` is created in `postgres` and in the booking database,
as the docs require ("repeat across all logical databases"). `ALTER ROLE … SET pg_stat_statements.track =
'none'` is present ("optional but recommended", postgres-configuration reference).

Version floors also met: Grafana requires **PostgreSQL 14.0 or later** and **Alloy 1.17.0 or later**; the
stack runs `postgres:16-alpine` and `grafana/alloy:v1.19.2`.

**Verdict: correct as done. Nothing Grafana lists as required is missing.**

Three items Grafana does *not* require, worth a decision:

| Item | Finding | Recommendation |
|---|---|---|
| `track_io_timing` | Not mentioned by Grafana. Without it, `shared_blk_read_time` / `shared_blk_write_time` are zero (<https://www.postgresql.org/docs/16/pgstatstatements.html>), so `pg_stat_statements_block_read_seconds_total` is flat. None of the five metrics the DBO dashboards use (`calls_total`, `seconds_total`, `rows_total`, `blks_read_total`, `blks_hit_total` — telemetry reference) depends on it; the buffer-hit-ratio panel uses block *counts*, not times | Leave off. Cheap `-c track_io_timing=on` later if I/O time is ever wanted |
| `CONNECTION LIMIT 10` | Valid `CREATE ROLE` option (<https://www.postgresql.org/docs/16/sql-createrole.html>); no Grafana guidance. Alloy opens more than one: the exporter with `autodiscovery.enabled = true` "scrapes from all databases" (<https://grafana.com/docs/alloy/latest/reference/components/prometheus/prometheus.exporter.postgres/>), and `schema_details` opens a **separate connection per discovered database** via `replaceDatabaseNameInDSN` (`collector/dsn.go`), on top of the component's own pool | **Check after step 5 of the runbook**: `docker logs db-observability` for `too many connections for role`. With two databases (`postgres`, booking) 10 should hold; raise to 20 if it doesn't. Add that check to `docs/monitoring.md` step 5 |
| `NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS` | All are `CREATE ROLE` defaults; stating them explicitly is belt-and-braces, not a requirement | Keep. Explicit is right for a file people read |

### 4.4 `sslmode=disable` departs from every Grafana example

Grafana's DSN examples all use `sslmode=require`
(`"postgresql://DB_USER:DB_PASSWORD@DB_HOST:DB_PORT/DB_DATABASE?sslmode=require"`, and `sslmode: require`
in the Helm values). libpq: "`disable` — only try a non-SSL connection"
(<https://www.postgresql.org/docs/16/libpq-connect.html#LIBPQ-CONNECT-SSLMODE>).

`postgres:16-alpine` ships no server certificate, so `require` would fail outright until TLS is configured
on each Postgres. The traffic never leaves a Docker bridge network on one host, which `config.alloy`
already states. This is a justified deviation, not a defect.

**Verdict: acceptable as done.** If you want a free upgrade path, `sslmode=prefer` (libpq's own default)
negotiates TLS the moment a server cert exists and silently falls back today; `disable` never will. Either
is defensible — but the comment should say "departs from Grafana's `require` example because the image has
no server certificate", not just "No TLS".

### 4.5 Password encryption

`PASSWORD` is hashed per `password_encryption` at the time the password is set
(<https://www.postgresql.org/docs/16/auth-password.html>), and `scram-sha-256` is "the most secure of the
currently provided methods". PostgreSQL ≥ 14 defaults to `scram-sha-256`, and the official image's default
`POSTGRES_HOST_AUTH_METHOD` matches. Nothing to change — but the one-line proof belongs in the setup
script's verification block (§5.2).

---

## 5. Secret handling

### 5.1 Grafana's documented mechanism is `local.file`, not an env var

The custom-configuration path says: "Create a `local.file` with the data source name string", and shows

```alloy
local.file "postgres_secret_<DB_NAME>" {
  filename  = "/var/lib/alloy/postgres_secret_<DB_NAME>"
  is_secret = true
}
```

— setup page, Option 3. `local.file` exists for exactly this: "The most common use of `local.file` is to
load secrets (for example, API keys) from files", with `is_secret bool — Marks the file as containing a
secret` (<https://grafana.com/docs/alloy/latest/reference/components/local/local.file/>).
`remote.vault` is the Vault equivalent — "connects to a HashiCorp Vault server to retrieve secrets"
(<https://grafana.com/docs/alloy/latest/reference/components/remote/remote.vault/>, last reviewed
2026-09-11). Neither is mandatory.

The stack's `sys.env("DB_O11Y_STAGING_PASSWORD")` is legal and does not lose redaction:
`database_observability.postgres.data_source_name` is typed `secret` and
`prometheus.exporter.postgres.data_source_names` is `list(secret)`, and Alloy's type rules say "You **can
assign string values to an attribute expecting a secret**, but not the inverse […] Alloy replaces secret
values with `(secret)` in the component graph, Arguments, Exports, and Debug info sections"
(<https://grafana.com/docs/alloy/latest/get-started/configuration-syntax/expressions/types_and_values/>).
So the password is still redacted in the Alloy debug UI on `127.0.0.1:12345`.

Exposure is the same class as the `GRAFANA_CLOUD_API_TOKEN` the monitoring stack already handles this way:
the value lands in `/root/stacks/db-observability/.env` (root-owned) and in the container environment,
readable via `docker inspect` by anyone who can reach the Docker socket — which on this host is root.
Rendering via `ci/env.ci` + `render-ci.py` also keeps the raw `@@MARKER@@` template off the host
(`deploy-infra.yml` excludes `ci/` from the first rsync and removes `env.ci` after merging).

**Verdict: acceptable as done, not the documented example.** Switching to `local.file` would trade one
root-readable file for another and lose the existing CI rendering path; no primary source says env vars are
wrong. Keep it, and add one line to `config.alloy` noting that Grafana's example uses `local.file` and why
this stack does not.

### 5.2 The setup script's verification cannot detect a missing grant — fix this

`setup-db-o11y.sql` step 4 runs, as `db-o11y`:

```sql
SELECT count(*) > 0 AS pg_stat_statements_readable FROM pg_stat_statements;
```

The extension grants `SELECT` on that view to `PUBLIC`: "Other users can see the statistics, however, if
the view has been installed in their database" — only the *SQL text and queryid* of other users' queries
are restricted to `pg_read_all_stats` (<https://www.postgresql.org/docs/16/pgstatstatements.html>).
So this check returns `t` even if `GRANT pg_monitor` silently failed; the failure would surface later as
`<insufficient privilege>` in place of every query text in the Grafana UI.

**Change to make** — replace it with Alloy's own privilege probe (`health_check.go`,
`monitoringUserPrivilegesQuery`), which is also what Grafana's troubleshooting page runs:

```sql
SELECT pg_has_role('db-o11y', 'pg_monitor',        'MEMBER') AS has_pg_monitor,
       pg_has_role('db-o11y', 'pg_read_all_stats', 'MEMBER') AS has_pg_read_all_stats,
       NOT EXISTS (
         SELECT 1 FROM pg_stat_statements WHERE query = '<insufficient privilege>'
       ) AS no_redacted_query_text,
       (SELECT rolpassword LIKE 'SCRAM-SHA-256%%'
          FROM pg_authid WHERE rolname = 'db-o11y') AS password_is_scram;
```

All four must be `t`. Update the pass criteria in `docs/monitoring.md` step 4 to match.

Note for the runbook: `ALTER ROLE … SET pg_stat_statements.track` sets a `SUSET` parameter and therefore
requires superuser — which the documented invocation satisfies, since it connects as the container's
`$POSTGRES_USER`. Worth one comment line so nobody "helpfully" reruns the script as a lesser role.

---

## 6. Cardinality and the keep-list

Grafana names the exact metrics its dashboards read
(<https://grafana.com/docs/grafana-cloud/observe-and-act/monitor-applications/database-observability/reference/telemetry-reference/>):

| Metric | Powers | Survives the keep-list? |
|---|---|---|
| `database_observability_connection_info` | Configuration page instance list | yes (`database_observability_.+`) |
| `database_observability_pg_errors_total` | error-rate PromQL | yes (never emitted — §1.3) |
| `database_observability_logs_processing_enabled` | logs status | yes |
| `pg_stat_statements_calls_total` | Queries overview rate, list sorting | yes (`pg_stat_statements_.+`) |
| `pg_stat_statements_seconds_total` | latency, average duration | yes |
| `pg_stat_statements_rows_total` | rows panels | yes |
| `pg_stat_statements_blks_read_total` | buffer cache hit ratio | yes |
| `pg_stat_statements_blks_hit_total` | buffer cache hit ratio | yes |

Every metric Grafana documents as load-bearing matches `prometheus.relabel "keep"`. Everything else the
page calls "Additional exporter metrics […] available in Grafana Cloud Mimir for custom dashboards and
alerting" — i.e. explicitly not required by the UI.

Query samples, wait events, explain plans, schema details and the health status are **Loki log lines**, not
series (`op = query_sample | query_association | wait_event | explain_plan_output | create_statement |
health_status`), so no relabel rule can starve those tabs. That is the reason the keep-list is safe.

Grafana's own cardinality advice is `statements_limit`, schema exclusion, collection-interval tuning and
`exclude_databases` / `exclude_users` (telemetry reference → tune-alloy-collection). A metric keep-list is
not mentioned, but nothing contradicts it, and the exporter's `stat_statements { limit = 100 }` the repo
sets is the documented lever (also the component default —
<https://grafana.com/docs/alloy/latest/reference/components/prometheus/prometheus.exporter.postgres/>).
`disable_settings_metrics = true` suppresses `pg_settings_*`, which appears in no documented dashboard.

**Verdict: correct as done and documented-safe.** `config.alloy`'s own warning — "If a Database
Observability view is empty after deploy, check here before anything else" — is the right mitigation for
the one residual risk, a future Alloy adding a metric the UI needs.

Two minor cardinality/label notes:

- The telemetry reference says `instance` is "Database instance (`host:port`)". The stack overwrites it
  with `booking-staging` / `booking-prod`. Grafana's own custom-config example does exactly this
  (`<INSTANCE_LABEL>` in both `loki.relabel` and `discovery.relabel`), and requires only that the two be
  **consistent** — which they are. Correct as done.
- Grafana's example carries one rule the stack omits: `source_labels = ["instance"] → target_label =
  "dsn"`, placed *before* the `instance` overwrite, commented "the `dsn` label is used in the integration
  with the knowledge graph". Optional; adding it costs one series per target and preserves that
  integration. Worth adding if the knowledge-graph feature is ever wanted.

---

## 7. Where the repo contradicts a primary source

### 7.1 `config.alloy` — the stated reason for disabling `explain_plans` is wrong in its second half

> "explain_plans OFF: EXPLAIN needs SELECT on the tables it plans, and **that grant would let the
> monitoring role read every Tenant's members and payments**."

The first clause is right. The second is not. Grafana's alternative grant, `pg_read_all_data`, is defined as
"Read all data (tables, views, sequences), as if having SELECT rights on those objects, and USAGE rights on
all schemas […] **This role does not have the role attribute `BYPASSRLS` set.** If RLS is being used, an
administrator may wish to set `BYPASSRLS` on roles which this role is GRANTed to."
(<https://www.postgresql.org/docs/16/predefined-roles.html>)

`booking-system` `be/src/db/migrations/0033_row_level_security.sql` puts `ENABLE` + `FORCE ROW LEVEL
SECURITY` and a `tenant_isolation` policy on every table carrying `tenant_id`, keyed on
`nullif(current_setting('app.tenant_id', true), '')::uuid` — deliberately written to yield **no rows**,
not an error, when the context is unset. `db-o11y` is `NOBYPASSRLS`, owns nothing, and never sets
`app.tenant_id`. A `pg_read_all_data` grant would therefore return **zero rows** from members, payments and
the other 51 tenant-scoped tables.

What it *would* expose is the tables 0033 deliberately excludes — `tenants` and `tenant_settings`, i.e.
studio names, premises and branding — plus any table with no `tenant_id` column. That is still a good
reason to refuse the grant, and it is a *better* one because it is true.

**Change to make:** rewrite that comment in `config.alloy` (and the matching `docs/monitoring.md` row and
the `setup-db-o11y.sql` "What the role can and cannot do" block) to say: EXPLAIN needs SELECT on the tables
it plans; RLS would blank the tenant-scoped tables, but `tenants` and `tenant_settings` are outside RLS by
design, so the grant would expose studio identity and branding. Do not claim RLS is the only guard, and do
not claim the grant reads tenant data.

### 7.2 `config.alloy` — "schema_details need only pg_monitor and the system catalogs"

True for Alloy v1.19.2 (§2.1) but directly contrary to Grafana's setup and troubleshooting pages, which
both ask for object privileges. Leaving the claim unqualified invites someone to "fix" it by granting
`pg_read_all_data`. Qualify it with the version, as in §2.2.

### 7.3 Everything else in the repo's comments checks out

- "The name is Grafana's default, which its components already exclude" — confirmed: `exclude_users`
  defaults to `["azuresu", "cloudsqladmin", "db-o11y", "rdsadmin"]`, and `exclude_current_user` defaults to
  `true`.
- "query_samples REDACTS literals by default (`disable_query_redaction = false`); keep it so" — confirmed:
  "Only disable redaction (`disable_query_redaction = true`) in non-production or when parameters don't
  contain sensitive data" (tune-alloy-collection).
- "Database `postgres`, as Grafana recommends" — confirmed: the Helm example uses `database: postgres` with
  `autoDiscovery.enabled: true`.
- `job = "integrations/db-o11y"` — confirmed as the required job label, both in the setup example's
  `discovery.relabel` and in the telemetry reference ("`job` — Always `integrations/db-o11y`").
- "Database Observability needs >= 1.17.0" — confirmed verbatim: "Alloy `1.17.0` or later is required for
  Database Observability."
- Direct container-name connection rather than a pooler — matches Grafana's note: "Alloy should connect
  directly to the database host. Avoid connecting Alloy to the database through a load balancer or
  connection pooler such as PgBouncer as it would limit Alloy's ability to collect accurate telemetry."

---

## Fix list before the stack deploys

1. **`setup-db-o11y.sql` step 4** — replace the `count(*) > 0 FROM pg_stat_statements` check with the
   four-column privilege probe in §5.2; update the pass criteria in `docs/monitoring.md` step 4. The current
   check passes even when `GRANT pg_monitor` did not take effect.
2. **`config.alloy` + `setup-db-o11y.sql` + `docs/monitoring.md`** — correct the RLS claim (§7.1). The grant
   would not expose tenant rows; it would expose `tenants` / `tenant_settings`.
3. **`docs/monitoring.md` step 5** — add `docker logs db-observability | grep -i 'too many connections'` to
   the verification, because `CONNECTION LIMIT 10` is an unvalidated guess against a per-database
   connection pattern (§4.3).
4. **`config.alloy` + `setup-db-o11y.sql`** — qualify the "only `pg_monitor` is needed" claims with
   "validated against Alloy v1.19.2 `schema_details`, which reads `pg_catalog` only; re-check on an Alloy
   bump" (§2.2), and note that `sslmode=disable` departs from Grafana's `require` example because the image
   ships no server certificate (§4.4).

Optional, no functional effect: add `GRANT pg_read_all_stats TO "db-o11y";` for verbatim parity with the
docs (§1.1); add the `instance → dsn` relabel rule if the knowledge-graph integration is wanted (§6).
