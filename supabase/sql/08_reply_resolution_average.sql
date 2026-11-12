-- =====================================================================
-- 08_reply_resolution_average.sql  —  First reply + Resolution as AVERAGES
--
-- * Resolution  = average time from ticket creation to Resolved.
-- * First reply = average time to the first human agent reply, counted from:
--     - AI replied before the agent: the customer's last message before that reply
--     - agent replied directly:      ticket creation (the customer's first message)
-- Applies to the Overview tiles and the Agents table. Undo: 09_undo_reply_resolution_average.sql
--
-- Replaces 3 dashboard functions in place (create or replace): same names,
-- same inputs and outputs, so nothing else needs to change. Read-only
-- functions only: no table, ticket, message, rating or trigger is touched.
-- Safe to run more than once. Run on the TEST project first, then production.
-- =====================================================================

begin;

create or replace function public.dash_base(p_from timestamptz, p_to timestamptz, p_agent uuid, p_issue text)
returns table (
  ticket_id         uuid,
  created_at        timestamptz,
  issue_type        text,
  assigned_agent_id uuid,
  resolved_agent_id uuid,
  is_ai             boolean,
  is_human          boolean,
  is_resolved       boolean,
  worked_by_agent   boolean,
  first_reply_sec   float8,
  resolution_sec    float8
)
language sql stable security definer set search_path = public
as $$
  select
    m.ticket_id,
    m.ticket_created_at,
    t.issue_type,
    t.assigned_agent_id,
    m.resolved_agent_id,
    m.first_ai_msg_at is not null,
    m.first_agent_msg_at is not null,
    (t.status = 'Resolved' and m.resolved_at is not null),
    (m.first_agent_msg_at is not null or m.resolved_agent_id is not null),
    extract(epoch from (m.first_agent_msg_at -
      case when m.first_ai_msg_at is not null and m.first_ai_msg_at < m.first_agent_msg_at
           then m.first_reply_start_at   -- AI first: customer's last message before the agent's reply
           else m.ticket_created_at      -- agent direct: customer's first message (ticket creation)
      end))::float8,
    case when t.status = 'Resolved' and m.resolved_at is not null
         then extract(epoch from (m.resolved_at - m.ticket_created_at))::float8 end
  from ticket_metrics m
  join tickets t on t.id = m.ticket_id
  where m.ticket_created_at >= p_from
    and m.ticket_created_at <  p_to
    and (p_issue is null or t.issue_type = p_issue)
    and (p_agent is null or t.assigned_agent_id = p_agent);
$$;

create or replace function public.dash_overview_tiles(p_from timestamptz, p_to timestamptz, p_agent uuid, p_issue text)
returns jsonb
language sql stable security definer set search_path = public
as $$
  select
    (select jsonb_build_object(
       'total',                      count(*),
       'handled_by_ai',              case when p_agent is null then count(*) filter (where is_ai) end,
       'assigned_resolved_by_agent', count(*) filter (where is_resolved and worked_by_agent),
       'first_reply_median_sec',     round(avg(first_reply_sec)::numeric),   -- average (key name kept)
       'resolution_median_sec',      round(avg(resolution_sec)::numeric))    -- average (key name kept)
     from dash_base(p_from, p_to, p_agent, p_issue))
    ||
    (select jsonb_build_object(
       'csat_avg',   round(avg(rating), 2),
       'csat_count', count(*))
     from dash_ratings(p_from, p_to, p_agent, p_issue));
$$;

create or replace function public.dashboard_agents(
  p_from  timestamptz,
  p_to    timestamptz,
  p_issue text default null
)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare
  v_len  interval;
  v_open bigint;
  v_rows jsonb;
begin
  perform dash_require_agent();
  if p_from is null or p_to is null or p_to <= p_from then
    raise exception 'invalid_range';
  end if;
  v_len := p_to - p_from;

  -- Open tickets: live count of open assigned tickets, whatever the range
  select count(*) into v_open
  from ticket_metrics m
  join tickets t on t.id = m.ticket_id
  where t.status is distinct from 'Resolved'
    and t.assigned_agent_id is not null
    and (p_issue is null or t.issue_type = p_issue);

  -- Agent comparison table
  with b as (
    select * from dash_base(p_from, p_to, null, p_issue)
  ),
  per as (
    select b.assigned_agent_id as agent_id,
           count(*)                                   as assigned_count,
           count(*) filter (where not b.is_resolved)  as open_count,
           count(*) filter (where b.is_resolved)      as resolved_count,
           round(avg(b.first_reply_sec)::numeric) as fr_sec,    -- average
           round(avg(b.resolution_sec)::numeric)  as res_sec    -- average
    from b
    where b.assigned_agent_id is not null
    group by b.assigned_agent_id
  ),
  rt as (
    select r.agent_id,
           round(avg(r.rating), 2) as csat_avg,
           count(*)                as csat_count
    from dash_ratings(p_from, p_to, null, p_issue) r
    where r.agent_id is not null
    group by r.agent_id
  ),
  ids as (
    select agent_id from per
    union
    select agent_id from rt
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'agent_id',               a.id,
           'agent',                  a.full_name,
           'assigned',               coalesce(per.assigned_count, 0),
           'open',                   coalesce(per.open_count, 0),
           'resolved',               coalesce(per.resolved_count, 0),
           'first_reply_median_sec', per.fr_sec,
           'resolution_median_sec',  per.res_sec,
           'csat_avg',               rt.csat_avg,
           'csat_count',             coalesce(rt.csat_count, 0))
         order by coalesce(per.assigned_count, 0) desc, a.full_name), '[]'::jsonb)
    into v_rows
  from ids
  join agent_profiles a on a.id = ids.agent_id
  left join per on per.agent_id = ids.agent_id
  left join rt  on rt.agent_id  = ids.agent_id;

  return jsonb_build_object(
    'current',  dash_agent_tiles(p_from, p_to, p_issue) || jsonb_build_object('open_tickets', v_open),
    'previous', dash_agent_tiles(p_from - v_len, p_from, p_issue),
    'rows',     v_rows
  );
end;
$$;

-- Permissions (unchanged; repeated so this file is complete on its own)
revoke all on function public.dash_base(timestamptz, timestamptz, uuid, text)            from public, anon, authenticated;
revoke all on function public.dash_overview_tiles(timestamptz, timestamptz, uuid, text)  from public, anon, authenticated;
revoke all on function public.dashboard_agents(timestamptz, timestamptz, text)           from public, anon;
grant execute on function public.dashboard_agents(timestamptz, timestamptz, text)        to authenticated;

commit;

-- Check: should list the 3 replaced functions
select routine_name
from information_schema.routines
where routine_schema = 'public'
  and routine_name in ('dash_base', 'dash_overview_tiles', 'dashboard_agents')
order by routine_name;
