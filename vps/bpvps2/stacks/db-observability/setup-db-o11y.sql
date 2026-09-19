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
-- What the role can and cannot do:
--   CAN   read pg_stat_statements, pg_stat_activity and the system catalogs (pg_monitor)
--   CANNOT read a single row of any booking table. No SELECT is granted, no pg_read_all_data,
--         and NOBYPASSRLS. That is why explain_plans is off in config.alloy.

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

-- 4. Verify, as the role: statistics readable, one row of booking data not.
SET ROLE "db-o11y";
SELECT count(*) > 0 AS pg_stat_statements_readable FROM pg_stat_statements;
RESET ROLE;

SELECT current_setting('compute_query_id')          AS compute_query_id,          -- on
       current_setting('pg_stat_statements.track')  AS pg_stat_statements_track,  -- all
       current_setting('track_activity_query_size') AS track_activity_query_size; -- 4kB
