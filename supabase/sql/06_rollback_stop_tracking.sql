-- =====================================================================
-- 06_rollback_stop_tracking.sql  —  EMERGENCY ROLLBACK, LEVEL 1
--
-- Use if saving tickets or messages misbehaves after release.
-- Removes ONLY our 3 triggers, so tickets and messages are handled
-- exactly as before release. Keeps all CSAT data and functions.
-- Existing triggers (ticket number, latest message, AI bot,
-- notifications, ai_handled) are not touched.
-- Safe to run more than once.
-- =====================================================================

begin;

drop trigger if exists csat_a_track_ticket_insert on public.tickets;
drop trigger if exists csat_track_ticket_status   on public.tickets;
drop trigger if exists csat_track_message_insert  on public.messages;

commit;

-- Check: only the original triggers should remain (none starting with csat_)
select event_object_table, trigger_name
from information_schema.triggers
where trigger_schema = 'public'
  and event_object_table in ('tickets', 'messages')
order by event_object_table, trigger_name;
