-- =====================================================================
-- 04_dashboard_functions.sql  —  Support Analytics dashboard (part 2 of 2)
--
-- Run on the TEST project first; later runs unchanged on production,
-- AFTER 02_csat_core.sql.
--
-- Additive only: new read-only functions. Nothing existing is changed.
-- * Only logged-in CRM agents (a row in agent_profiles) can call them.
-- * They return totals, averages and medians only, never raw ratings.
-- * They count only tickets created after launch (ticket_metrics).
-- * A ticket belongs to the period in which it was created.
-- * Agent filter: ticket numbers follow the ticket's assigned agent;
--   CSAT numbers follow the agent who got the rating (at resolve time).
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- Helpers (not callable by users)
-- ---------------------------------------------------------------------

-- Caller must be a CRM agent
create function public.dash_require_agent()
returns void
language plpgsql stable security definer set search_path = public
as $$
begin
  if auth.uid() is null
     or not exists (select 1 from agent_profiles where id = auth.uid()) then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
end;
$$;

-- One row per post-launch ticket in the period, with every flag the
-- dashboard needs. Definitions:
--   is_ai            = MARKAZ AI sent at least one message ("Handled by AI")
--   is_human         = a human agent sent at least one message ("Human Handled")
--   is_resolved      = status is Resolved now
--   worked_by_agent  = a human agent replied, or an agent was assigned at resolve
--   first_reply_sec  = customer's last message before first agent reply -> that reply
--   resolution_sec   = created -> resolved
-- Agent filter = the ticket's assigned agent. Ratings are NOT here: use
-- dash_ratings, which filters by the agent who got the rating.
create function public.dash_base(p_from timestamptz, p_to timestamptz, p_agent uuid, p_issue text)
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
    extract(epoch from (m.first_agent_msg_at - m.first_reply_start_at))::float8,
    case when t.status = 'Resolved' and m.resolved_at is not null
         then extract(epoch from (m.resolved_at - m.ticket_created_at))::float8 end
  from ticket_metrics m
  join tickets t on t.id = m.ticket_id
  where m.ticket_created_at >= p_from
    and m.ticket_created_at <  p_to
    and (p_issue is null or t.issue_type = p_issue)
    and (p_agent is null or t.assigned_agent_id = p_agent);
$$;

-- One row per rating on a post-launch ticket created in the period.
-- Agent filter = the agent who got the rating (not the current assignee),
-- so a ticket reassigned after it was rated still counts for the right agent.
create function public.dash_ratings(p_from timestamptz, p_to timestamptz, p_agent uuid, p_issue text)
returns table (
  ticket_id   uuid,
  created_at  timestamptz,
  issue_type  text,
  rating      smallint,
  agent_id    uuid
)
language sql stable security definer set search_path = public
as $$
  select r.ticket_id, m.ticket_created_at, t.issue_type, r.rating, r.agent_id
  from csat_ratings r
  join ticket_metrics m on m.ticket_id = r.ticket_id
  join tickets t        on t.id = r.ticket_id
  where m.ticket_created_at >= p_from
    and m.ticket_created_at <  p_to
    and (p_issue is null or t.issue_type = p_issue)
    and (p_agent is null or r.agent_id = p_agent);
$$;

-- Chart block size: day up to 31 days, week up to 120 days, else month
create function public.dash_unit(p_from timestamptz, p_to timestamptz)
returns text
language sql immutable
as $$
  select case
    when p_to - p_from <= interval '31 days'  then 'day'
    when p_to - p_from <= interval '120 days' then 'week'
    else 'month'
  end;
$$;

-- Every chart block in the range (so empty days still show as 0)
create function public.dash_buckets(p_from timestamptz, p_to timestamptz, p_tz text)
returns setof timestamp
language sql stable set search_path = public
as $$
  select generate_series(
    date_trunc(dash_unit(p_from, p_to), p_from at time zone p_tz),
    date_trunc(dash_unit(p_from, p_to), (p_to - interval '1 microsecond') at time zone p_tz),
    ('1 ' || dash_unit(p_from, p_to))::interval
  );
$$;

-- Overview tiles for one period
create function public.dash_overview_tiles(p_from timestamptz, p_to timestamptz, p_agent uuid, p_issue text)
returns jsonb
language sql stable security definer set search_path = public
as $$
  select
    (select jsonb_build_object(
       'total',                      count(*),
       'handled_by_ai',              case when p_agent is null then count(*) filter (where is_ai) end,
       'assigned_resolved_by_agent', count(*) filter (where is_resolved and worked_by_agent),
       'first_reply_median_sec',     round((percentile_cont(0.5) within group (order by first_reply_sec))::numeric),
       'resolution_median_sec',      round((percentile_cont(0.5) within group (order by resolution_sec))::numeric))
     from dash_base(p_from, p_to, p_agent, p_issue))
    ||
    (select jsonb_build_object(
       'csat_avg',   round(avg(rating), 2),
       'csat_count', count(*))
     from dash_ratings(p_from, p_to, p_agent, p_issue));
$$;

-- Agents tiles for one period
create function public.dash_agent_tiles(p_from timestamptz, p_to timestamptz, p_issue text)
returns jsonb
language sql stable security definer set search_path = public
as $$
  select jsonb_build_object(
    'active_agents', count(distinct assigned_agent_id),
    'assigned',      count(assigned_agent_id),
    'resolved',      count(*) filter (where is_resolved and assigned_agent_id is not null)
  )
  from dash_base(p_from, p_to, null, p_issue);
$$;

-- CSAT tiles for one period (rating rate = ratings / Resolved tickets).
-- With an agent selected, both sides follow the agent who got the rating.
create function public.dash_csat_tiles(p_from timestamptz, p_to timestamptz, p_agent uuid, p_issue text)
returns jsonb
language sql stable security definer set search_path = public
as $$
  select jsonb_build_object(
    'csat_avg',    x.csat_avg,
    'csat_count',  x.csat_count,
    'resolved',    y.resolved,
    'rating_rate', case when y.resolved > 0 then round(x.csat_count::numeric / y.resolved, 4) end
  )
  from (select round(avg(rating), 2) as csat_avg, count(*) as csat_count
          from dash_ratings(p_from, p_to, p_agent, p_issue)) x,
       (select count(*) filter (where b.is_resolved) as resolved
          from dash_base(p_from, p_to, null, p_issue) b
         where p_agent is null or b.resolved_agent_id = p_agent) y;
$$;

-- ---------------------------------------------------------------------
-- Overview tab
-- ---------------------------------------------------------------------
create function public.dashboard_overview(
  p_from  timestamptz,
  p_to    timestamptz,
  p_agent uuid default null,
  p_issue text default null,
  p_tz    text default 'Asia/Karachi'
)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare
  v_len    interval;
  v_unit   text;
  v_volume jsonb;
  v_issues jsonb;
begin
  perform dash_require_agent();
  if p_from is null or p_to is null or p_to <= p_from then
    raise exception 'invalid_range';
  end if;
  v_len  := p_to - p_from;
  v_unit := dash_unit(p_from, p_to);

  -- Ticket volume: four groups that never overlap and add up to the total
  select coalesce(jsonb_agg(jsonb_build_object(
           'bucket',        to_char(s.bucket, 'YYYY-MM-DD'),
           'ai_only',       s.ai_only,
           'ai_then_agent', s.ai_then_agent,
           'agent_only',    s.agent_only,
           'no_reply',      s.no_reply) order by s.bucket), '[]'::jsonb)
    into v_volume
  from (
    select bk.bucket,
           count(b.ticket_id) filter (where b.is_ai and not b.is_human)     as ai_only,
           count(b.ticket_id) filter (where b.is_ai and b.is_human)         as ai_then_agent,
           count(b.ticket_id) filter (where not b.is_ai and b.is_human)     as agent_only,
           count(b.ticket_id) filter (where not b.is_ai and not b.is_human) as no_reply
    from dash_buckets(p_from, p_to, p_tz) as bk(bucket)
    left join dash_base(p_from, p_to, p_agent, p_issue) b
           on date_trunc(v_unit, b.created_at at time zone p_tz) = bk.bucket
    group by bk.bucket
  ) s;

  -- Tickets by issue: tickets resolved by agents
  select coalesce(jsonb_agg(jsonb_build_object('issue', x.issue_type, 'count', x.cnt)
                            order by x.cnt desc, x.issue_type), '[]'::jsonb)
    into v_issues
  from (
    select b.issue_type, count(*) as cnt
    from dash_base(p_from, p_to, p_agent, p_issue) b
    where b.is_resolved and b.worked_by_agent
    group by b.issue_type
  ) x;

  return jsonb_build_object(
    'current',  dash_overview_tiles(p_from, p_to, p_agent, p_issue),
    'previous', dash_overview_tiles(p_from - v_len, p_from, p_agent, p_issue),
    'bucket',   v_unit,
    'volume',   v_volume,
    'by_issue', v_issues
  );
end;
$$;

-- ---------------------------------------------------------------------
-- Agents tab (no agent filter on this tab)
-- ---------------------------------------------------------------------
create function public.dashboard_agents(
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
           round((percentile_cont(0.5) within group (order by b.first_reply_sec))::numeric) as fr_sec,
           round((percentile_cont(0.5) within group (order by b.resolution_sec))::numeric)  as res_sec
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

-- ---------------------------------------------------------------------
-- CSAT tab
-- ---------------------------------------------------------------------
create function public.dashboard_csat(
  p_from  timestamptz,
  p_to    timestamptz,
  p_agent uuid default null,
  p_issue text default null,
  p_tz    text default 'Asia/Karachi'
)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare
  v_len   interval;
  v_unit  text;
  v_trend jsonb;
  v_dist  jsonb;
  v_issue jsonb;
begin
  perform dash_require_agent();
  if p_from is null or p_to is null or p_to <= p_from then
    raise exception 'invalid_range';
  end if;
  v_len  := p_to - p_from;
  v_unit := dash_unit(p_from, p_to);

  -- CSAT trend
  select coalesce(jsonb_agg(jsonb_build_object(
           'bucket',     to_char(s.bucket, 'YYYY-MM-DD'),
           'csat_avg',   s.avg_rating,
           'csat_count', s.cnt) order by s.bucket), '[]'::jsonb)
    into v_trend
  from (
    select bk.bucket,
           round(avg(r.rating), 2) as avg_rating,
           count(r.rating)         as cnt
    from dash_buckets(p_from, p_to, p_tz) as bk(bucket)
    left join dash_ratings(p_from, p_to, p_agent, p_issue) r
           on date_trunc(v_unit, r.created_at at time zone p_tz) = bk.bucket
    group by bk.bucket
  ) s;

  -- Rating distribution (5 to 1 stars)
  select jsonb_agg(jsonb_build_object('stars', g.stars, 'count', coalesce(x.cnt, 0)) order by g.stars desc)
    into v_dist
  from generate_series(1, 5) as g(stars)
  left join (
    select r.rating, count(*) as cnt
    from dash_ratings(p_from, p_to, p_agent, p_issue) r
    group by r.rating
  ) x on x.rating = g.stars;

  -- CSAT by issue
  select coalesce(jsonb_agg(jsonb_build_object('issue', x.issue_type, 'csat_avg', x.avg_rating, 'csat_count', x.cnt)
                            order by x.cnt desc, x.issue_type), '[]'::jsonb)
    into v_issue
  from (
    select r.issue_type, round(avg(r.rating), 2) as avg_rating, count(*) as cnt
    from dash_ratings(p_from, p_to, p_agent, p_issue) r
    group by r.issue_type
  ) x;

  return jsonb_build_object(
    'current',      dash_csat_tiles(p_from, p_to, p_agent, p_issue),
    'previous',     dash_csat_tiles(p_from - v_len, p_from, p_agent, p_issue),
    'bucket',       v_unit,
    'trend',        v_trend,
    'distribution', v_dist,
    'by_issue',     v_issue
  );
end;
$$;

-- ---------------------------------------------------------------------
-- Filter dropdown options (agents and issue types)
-- ---------------------------------------------------------------------
create function public.dashboard_filter_options()
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
begin
  perform dash_require_agent();
  return jsonb_build_object(
    'agents', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'name', full_name) order by full_name), '[]'::jsonb)
               from agent_profiles),
    'issues', (select coalesce(jsonb_agg(issue_type order by issue_type), '[]'::jsonb)
               from (select distinct issue_type from tickets where issue_type is not null) x)
  );
end;
$$;

-- ---------------------------------------------------------------------
-- Permissions: helpers closed; the 4 dashboard functions for agents only
-- ---------------------------------------------------------------------
revoke all on function public.dash_require_agent()                                   from public, anon, authenticated;
revoke all on function public.dash_base(timestamptz, timestamptz, uuid, text)         from public, anon, authenticated;
revoke all on function public.dash_ratings(timestamptz, timestamptz, uuid, text)      from public, anon, authenticated;
revoke all on function public.dash_unit(timestamptz, timestamptz)                     from public, anon, authenticated;
revoke all on function public.dash_buckets(timestamptz, timestamptz, text)            from public, anon, authenticated;
revoke all on function public.dash_overview_tiles(timestamptz, timestamptz, uuid, text) from public, anon, authenticated;
revoke all on function public.dash_agent_tiles(timestamptz, timestamptz, text)        from public, anon, authenticated;
revoke all on function public.dash_csat_tiles(timestamptz, timestamptz, uuid, text)   from public, anon, authenticated;

revoke all on function public.dashboard_overview(timestamptz, timestamptz, uuid, text, text) from public, anon;
revoke all on function public.dashboard_agents(timestamptz, timestamptz, text)               from public, anon;
revoke all on function public.dashboard_csat(timestamptz, timestamptz, uuid, text, text)     from public, anon;
revoke all on function public.dashboard_filter_options()                                     from public, anon;

grant execute on function public.dashboard_overview(timestamptz, timestamptz, uuid, text, text) to authenticated;
grant execute on function public.dashboard_agents(timestamptz, timestamptz, text)               to authenticated;
grant execute on function public.dashboard_csat(timestamptz, timestamptz, uuid, text, text)     to authenticated;
grant execute on function public.dashboard_filter_options()                                     to authenticated;

commit;

-- Check: should list the 4 dashboard functions
select routine_name
from information_schema.routines
where routine_schema = 'public' and routine_name like 'dashboard_%'
order by routine_name;
