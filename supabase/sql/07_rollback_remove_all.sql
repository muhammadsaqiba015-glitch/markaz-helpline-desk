-- =====================================================================
-- 07_rollback_remove_all.sql  —  FULL ROLLBACK, LEVEL 2
--
-- Removes EVERYTHING added by 02_csat_core.sql and
-- 04_dashboard_functions.sql. WARNING: this permanently deletes all
-- CSAT ratings and tracking data collected since launch.
-- Use only if the feature is being withdrawn completely.
-- Existing tables, data, triggers and functions are not touched.
-- Safe to run more than once.
-- =====================================================================

begin;

-- 1. Triggers
drop trigger if exists csat_a_track_ticket_insert on public.tickets;
drop trigger if exists csat_track_ticket_status   on public.tickets;
drop trigger if exists csat_track_message_insert  on public.messages;

-- 2. Dashboard functions (04)
drop function if exists public.dashboard_overview(timestamptz, timestamptz, uuid, text, text);
drop function if exists public.dashboard_agents(timestamptz, timestamptz, text);
drop function if exists public.dashboard_csat(timestamptz, timestamptz, uuid, text, text);
drop function if exists public.dashboard_filter_options();
drop function if exists public.dash_overview_tiles(timestamptz, timestamptz, uuid, text);
drop function if exists public.dash_agent_tiles(timestamptz, timestamptz, text);
drop function if exists public.dash_csat_tiles(timestamptz, timestamptz, uuid, text);
drop function if exists public.dash_buckets(timestamptz, timestamptz, text);
drop function if exists public.dash_unit(timestamptz, timestamptz);
drop function if exists public.dash_ratings(timestamptz, timestamptz, uuid, text);
drop function if exists public.dash_base(timestamptz, timestamptz, uuid, text);
drop function if exists public.dash_require_agent();

-- 3. CSAT functions (02)
drop function if exists public.submit_csat(uuid, text, integer);
drop function if exists public.get_csat_status(uuid[], text);
drop function if exists public.csat_on_ticket_insert();
drop function if exists public.csat_on_ticket_status_change();
drop function if exists public.csat_on_message_insert();

-- 4. Tables (02)
drop table if exists public.csat_ratings;
drop table if exists public.ticket_metrics;
drop table if exists public.csat_settings;

commit;

-- Check: all three numbers should be 0
select
  (select count(*) from information_schema.tables
    where table_schema = 'public'
      and table_name in ('csat_settings', 'ticket_metrics', 'csat_ratings'))      as remaining_tables,
  (select count(*) from information_schema.routines
    where routine_schema = 'public'
      and (routine_name like 'dash%' or routine_name like 'csat_%'
           or routine_name in ('submit_csat', 'get_csat_status')))               as remaining_functions,
  (select count(*) from information_schema.triggers
    where trigger_schema = 'public' and trigger_name like 'csat_%')               as remaining_triggers;
