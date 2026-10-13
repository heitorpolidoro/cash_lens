-- Provisions the unprivileged runtime role `cash_lens_app` (CL-53). Idempotent:
-- safe to run after every migration.
--
-- Run as the owner/migrator role, connected to the application database:
--
--   psql "$MIGRATION_DATABASE_URL" -v ON_ERROR_STOP=1 \
--        -v app_password="$APP_DB_PASSWORD" -f priv/repo/roles.sql
--
-- or, without psql, `mix cash_lens.db.provision` (reads CASH_LENS_APP_PASSWORD /
-- DATABASE_APP_PASSWORD). The password is a variable and is never committed.
--
-- Constraints that keep this runnable by both: every statement ends with a `;`
-- at the end of a line, and `;` appears inside a statement only within a
-- `$$ ... $$` body.

SELECT set_config('cash_lens.app_password', :'app_password', false);

-- The role: login only, no superuser/createdb/createrole/bypassrls/replication.
DO $$
DECLARE
  attrs text := 'LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS NOREPLICATION NOINHERIT';
  pw text := current_setting('cash_lens.app_password');
BEGIN
  IF pw IS NULL OR pw = '' THEN
    RAISE EXCEPTION 'app_password must not be empty';
  END IF;

  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'cash_lens_app') THEN
    EXECUTE format('CREATE ROLE cash_lens_app %s PASSWORD %L', attrs, pw);
  ELSE
    EXECUTE format('ALTER ROLE cash_lens_app %s PASSWORD %L', attrs, pw);
  END IF;
END $$;

-- Connection: only this database. PUBLIC loses CONNECT here and on the
-- maintenance databases, so the app role cannot wander into `postgres` or
-- `template1`.
DO $$
DECLARE
  db text;
BEGIN
  FOR db IN
    SELECT datname FROM pg_database
    WHERE datname IN ('postgres', 'template1') AND datname <> current_database()
  LOOP
    EXECUTE format('REVOKE CONNECT, TEMPORARY ON DATABASE %I FROM PUBLIC', db);
    EXECUTE format('REVOKE ALL ON DATABASE %I FROM cash_lens_app', db);
  END LOOP;

  EXECUTE format('REVOKE CONNECT, TEMPORARY ON DATABASE %I FROM PUBLIC', current_database());
  EXECUTE format('REVOKE ALL ON DATABASE %I FROM cash_lens_app', current_database());
  EXECUTE format('GRANT CONNECT ON DATABASE %I TO cash_lens_app', current_database());
END $$;

-- Schema: use it, never create in it.
REVOKE CREATE ON SCHEMA public FROM PUBLIC;

REVOKE CREATE ON SCHEMA public FROM cash_lens_app;

GRANT USAGE ON SCHEMA public TO cash_lens_app;

-- Data: DML on tables, use of sequences. No TRUNCATE, REFERENCES or TRIGGER.
REVOKE ALL ON ALL TABLES IN SCHEMA public FROM cash_lens_app;

GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO cash_lens_app;

GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO cash_lens_app;

-- Tables and sequences created by later migrations (run by this role) are
-- granted automatically.
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO cash_lens_app;

ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT USAGE, SELECT ON SEQUENCES TO cash_lens_app;

-- The migration ledger is the owner's business.
DO $$
BEGIN
  IF to_regclass('public.schema_migrations') IS NOT NULL THEN
    REVOKE ALL ON TABLE public.schema_migrations FROM cash_lens_app;
  END IF;
END $$;
