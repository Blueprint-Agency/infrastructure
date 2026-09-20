-- One-time database setup for Grafana Database Observability (booking-system#166).
-- Run ONCE PER INSTANCE (booking-db-staging, then booking-db-prod), by hand, as the owner.
-- Idempotent: running it again changes nothing but the password.
--
-- Prerequisite: the booking compose's `command:` (pg_stat_statements preloaded, query ids on)
-- is live on that instance -- i.e. booking-system has deployed since that change merged. The
-- first statement below refuses to continue otherwise.
--
-- On bpvps2, from /root/stacks/db-observability (CI puts this file there). The password is
-- the one set as DB_O11Y_STAGING_PASSWORD / DB_O11Y_PROD_PASSWORD in the bpvps2 GitHub
-- Environment. `read -s` keeps it out of shell history. POSTGRES_USER and POSTGRES_DB are
-- read from the container's own environment, so no database name is typed here:
--
--   read -rs PW
--   docker exec -i -e PW="$PW" booking-db-staging sh -c \
--     'psql -X -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d postgres -v pw="$PW" -v booking_db="$POSTGRES_DB"' \
--     < setup-db-o11y.sql
--
-- Run it as the container's $POSTGRES_USER, as the invocation above does: step 2's
-- `ALTER ROLE ... SET pg_stat_statements.track` writes a SUSET parameter and step 4 reads
-- pg_authid, both superuser-only. Rerunning this as a lesser role fails, by design.
--
-- What the role can and cannot do:
--   CAN   read pg_stat_statements, pg_stat_activity and the system catalogs (pg_monitor)
--   CANNOT read a single row of any booking table. No SELECT is granted, no pg_read_all_data,
--         and NOBYPASSRLS. That is why explain_plans is off in config.alloy.
--
-- Why no object grants (Grafana's setup page asks for `GRANT SELECT ON ALL TABLES`, or
-- `pg_read_all_data`, "for detailed data"): validated against **Alloy v1.19.2**, whose
-- schema_details collector reads pg_catalog only (pg_namespace, pg_class, pg_attribute,
-- pg_attrdef, pg_constraint, pg_index), which is world-readable, and discovers databases
-- through has_database_privilege(datname,'CONNECT') -- satisfied by the GRANT CONNECT below.
-- An Alloy bump must re-check that collector before the Dockerfile tag moves: were it to
-- read information_schema instead, it would return nothing without object grants.
--
-- And granting pg_read_all_data would not be harmless. It does NOT set BYPASSRLS, and
-- booking-system's migration 0033 puts ENABLE + FORCE ROW LEVEL SECURITY on every table
-- carrying tenant_id, so those tables would read back empty for this role. What the grant
-- WOULD expose is what 0033 leaves outside RLS -- the `tenants` / `tenant_settings` rows,
-- i.e. each Tenant's identity, premises and branding copy -- plus any table with no
-- tenant_id column. That, not "every Tenant's members and payments", is the reason to refuse.

-- 1. The preload is live, or nothing below is worth doing.
DO $$
BEGIN
  IF current_setting('shared_preload_libraries') !~ 'pg_stat_statements' THEN
    RAISE EXCEPTION 'pg_stat_statements is not in shared_preload_libraries on this instance. '
      'Deploy booking (its compose command sets it; a Postgres restart) and run this again.';
  END IF;
END
$$;

-- 2. The monitoring role. The name is Grafana's default, which its components already exclude
--    from what they report, so the agent never watches itself.
SELECT 'CREATE ROLE "db-o11y"'
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'db-o11y')
\gexec

-- A handful of connections: the exporter holds one per database it discovers, and the
-- Database Observability collectors a few more. The postgres-connections alert counts these.
ALTER ROLE "db-o11y" WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS
  CONNECTION LIMIT 10 PASSWORD :'pw';

GRANT pg_monitor TO "db-o11y";

-- Its own queries are not statistics worth keeping.
ALTER ROLE "db-o11y" SET pg_stat_statements.track = 'none';

-- 3. The extension, in `postgres` (where the agent connects) and in the booking database
--    (which the exporter's autodiscovery reaches).
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
GRANT CONNECT ON DATABASE :"booking_db" TO "db-o11y";

\connect :"booking_db"
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;

-- 4. Verify the grant actually took. NOT `count(*) > 0 FROM pg_stat_statements`: the
--    extension grants SELECT on that view to PUBLIC, so it returns true even when the
--    GRANT above silently did nothing -- the failure would then surface only as
--    `<insufficient privilege>` in place of every query text in the Grafana UI.
--
--    This is Alloy's own probe (v1.19.2 health_check.go, monitoringUserPrivilegesQuery),
--    which is also what Grafana's Database Observability troubleshooting page runs, plus
--    the password-hash check. ALL FOUR COLUMNS MUST BE `t`.
--
--    Two statements, not one, because the two halves need different roles: pg_authid is
--    superuser-only, while the redaction of other users' query text is a property of the
--    CURRENT user and so has to be read as `db-o11y` itself.
SELECT pg_has_role('db-o11y', 'pg_monitor',        'MEMBER') AS has_pg_monitor,
       pg_has_role('db-o11y', 'pg_read_all_stats', 'MEMBER') AS has_pg_read_all_stats,
       (SELECT rolpassword LIKE 'SCRAM-SHA-256%'
          FROM pg_authid WHERE rolname = 'db-o11y')          AS password_is_scram;

SET ROLE "db-o11y";
SELECT NOT EXISTS (
         SELECT 1 FROM pg_stat_statements WHERE query = '<insufficient privilege>'
       ) AS no_redacted_query_text;
RESET ROLE;

SELECT current_setting('compute_query_id')          AS compute_query_id,          -- on
       current_setting('pg_stat_statements.track')  AS pg_stat_statements_track,  -- all
       current_setting('track_activity_query_size') AS track_activity_query_size; -- 4kB
