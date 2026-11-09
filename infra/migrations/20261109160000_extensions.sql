-- local-test: skip (pg_cron and pg_net exist only on Supabase)
-- C1. Extensions the nightly schedule needs (Block D uses them).
-- pg_cron runs the schedule. pg_net lets the schedule call the era-pull function.

create extension if not exists pg_cron with schema pg_catalog;
grant usage on schema cron to postgres;
grant all privileges on all tables in schema cron to postgres;

create extension if not exists pg_net with schema extensions;
