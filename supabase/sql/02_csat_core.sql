-- =====================================================================
-- 02_csat_core.sql  —  CSAT + tracking (feature SQL, part 1 of 2)
--
-- Run on the TEST project first. After testing and approval, the same
-- file runs unchanged on production; the moment it runs is "launch".
--
-- Additive only:
--   * 3 new tables: csat_settings, ticket_metrics, csat_ratings
--   * 3 new triggers that only write to ticket_metrics
--   * 2 new functions for the MARKAZ App: submit_csat, get_csat_status
-- No existing table, column, row, trigger or function is changed.
-- Tickets created before launch are never touched or tracked.
-- The triggers can never block saving a ticket or a message: any error
-- inside them is logged as a warning and skipped.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 1. Settings (one row). Values can be changed later without a rebuild.
-- ---------------------------------------------------------------------
create table public.csat_settings (
  id                   smallint primary key default 1 check (id = 1),
  launch_at            timestamptz not null default now(),      -- only tickets created after this
  rating_window_hours  integer not null default 24 check (rating_window_hours > 0),
  min_agent_messages   integer not null default 0  check (min_agent_messages >= 0),
  ai_sender_name       text not null default 'Markaz AI',       -- how MARKAZ AI messages are named
  updated_at           timestamptz not null default now()
);

insert into public.csat_settings (id) values (1);

-- ---------------------------------------------------------------------
-- 2. Per-ticket tracking (new tickets only)
-- ---------------------------------------------------------------------
create table public.ticket_metrics (
  ticket_id             uuid primary key references public.tickets(id) on delete cascade,
  ticket_created_at     timestamptz not null,
  last_customer_msg_at  timestamptz,           -- frozen once an agent first replies
  first_ai_msg_at       timestamptz,           -- set = "Handled by AI"
  first_agent_msg_at    timestamptz,           -- set = "Human Handled" (never changes)
  first_reply_start_at  timestamptz,           -- customer's last message before first agent reply
  human_msg_count       integer not null default 0,
  resolved_at           timestamptz,           -- cleared on reopen, set again on next resolve
  resolved_agent_id     uuid,                  -- agent who gets the rating (see trigger 6)
  reopen_count          integer not null default 0,
  updated_at            timestamptz not null default now()
);

create index ticket_metrics_created_idx  on public.ticket_metrics (ticket_created_at);
create index ticket_metrics_resolved_idx on public.ticket_metrics (resolved_at);

-- ---------------------------------------------------------------------
-- 3. Ratings (one per ticket, ever)
-- ---------------------------------------------------------------------
create table public.csat_ratings (
  id           uuid primary key default gen_random_uuid(),
  ticket_id    uuid not null unique references public.tickets(id) on delete cascade,
  reseller_id  text not null,
  agent_id     uuid,                            -- null = no agent (AI-only or customer-closed)
  rating       smallint not null check (rating between 1 and 5),
  created_at   timestamptz not null default now()
);

create index csat_ratings_created_idx on public.csat_ratings (created_at);
create index csat_ratings_agent_idx   on public.csat_ratings (agent_id);

-- ---------------------------------------------------------------------
-- 4. Lock the new tables: no direct access at all, only via functions
-- ---------------------------------------------------------------------
alter table public.csat_settings  enable row level security;
alter table public.ticket_metrics enable row level security;
alter table public.csat_ratings   enable row level security;

revoke all on public.csat_settings, public.ticket_metrics, public.csat_ratings
  from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 5. Trigger: new ticket -> start tracking (post-launch tickets only)
--    Named "csat_a_..." so it runs before the existing
--    "on_ticket_created_insert_description" trigger.
-- ---------------------------------------------------------------------
create function public.csat_on_ticket_insert()
returns trigger
language plpgsql security definer set search_path = public
as $$
declare
  v_launch timestamptz;
begin
  begin
    select launch_at into v_launch from csat_settings where id = 1;
    if v_launch is not null and coalesce(new.created_at, now()) >= v_launch then
      insert into ticket_metrics (ticket_id, ticket_created_at)
      values (new.id, coalesce(new.created_at, now()))
      on conflict (ticket_id) do nothing;
    end if;
  exception when others then
    raise warning 'csat_on_ticket_insert skipped for ticket %: %', new.id, sqlerrm;
  end;
  return new;
end;
$$;

create trigger csat_a_track_ticket_insert
  after insert on public.tickets
  for each row execute function public.csat_on_ticket_insert();

-- ---------------------------------------------------------------------
-- 6. Trigger: status change -> resolve / reopen
--    Only a change INTO Resolved stamps the time, so re-resolving an
--    already Resolved ticket (e.g. bulk resolve) never restarts the window.
--    The rating goes to the assigned agent; if nobody is assigned, to the
--    agent who resolved it (resolved_by) — unless the customer closed it.
-- ---------------------------------------------------------------------
create function public.csat_on_ticket_status_change()
returns trigger
language plpgsql security definer set search_path = public
as $$
begin
  begin
    if new.status = 'Resolved' and old.status is distinct from 'Resolved' then
      update ticket_metrics
         set resolved_at       = now(),
             resolved_agent_id = coalesce(
                                   new.assigned_agent_id,
                                   case when new.closed_by is distinct from 'reseller' then new.resolved_by end),
             updated_at        = now()
       where ticket_id = new.id;
    elsif old.status = 'Resolved' and new.status is distinct from 'Resolved' then
      update ticket_metrics
         set resolved_at       = null,
             resolved_agent_id = null,
             reopen_count      = reopen_count + 1,
             updated_at        = now()
       where ticket_id = new.id;
    end if;
  exception when others then
    raise warning 'csat_on_ticket_status_change skipped for ticket %: %', new.id, sqlerrm;
  end;
  return new;
end;
$$;

create trigger csat_track_ticket_status
  after update of status on public.tickets
  for each row execute function public.csat_on_ticket_status_change();

-- ---------------------------------------------------------------------
-- 7. Trigger: new message -> first AI / first agent / first-reply clock
--    Customer = 'reseller'; MARKAZ AI = 'agent' named ai_sender_name;
--    human agent = any other 'agent' message.
-- ---------------------------------------------------------------------
create function public.csat_on_message_insert()
returns trigger
language plpgsql security definer set search_path = public
as $$
declare
  v_ai   text;
  v_time timestamptz := coalesce(new.created_at, now());
begin
  begin
    select ai_sender_name into v_ai from csat_settings where id = 1;

    if new.sender_type = 'reseller' then
      update ticket_metrics
         set last_customer_msg_at = v_time,
             updated_at           = now()
       where ticket_id = new.ticket_id
         and first_agent_msg_at is null;

    elsif new.sender_type = 'agent' and new.sender_name = v_ai then
      update ticket_metrics
         set first_ai_msg_at = v_time,
             updated_at      = now()
       where ticket_id = new.ticket_id
         and first_ai_msg_at is null;

    elsif new.sender_type = 'agent' then
      update ticket_metrics
         set first_agent_msg_at   = coalesce(first_agent_msg_at, v_time),
             first_reply_start_at = coalesce(first_reply_start_at, last_customer_msg_at, ticket_created_at),
             human_msg_count      = human_msg_count + 1,
             updated_at           = now()
       where ticket_id = new.ticket_id;
    end if;
  exception when others then
    raise warning 'csat_on_message_insert skipped for message %: %', new.id, sqlerrm;
  end;
  return new;
end;
$$;

create trigger csat_track_message_insert
  after insert on public.messages
  for each row execute function public.csat_on_message_insert();

-- ---------------------------------------------------------------------
-- 8. submit_csat — called by the MARKAZ App when the customer taps Submit
--    Returns {"ok": true} or {"ok": false, "reason": "..."}.
--    Ownership check: p_reseller_id must match the ticket's reseller_id
--    (to be confirmed with the MARKAZ App developer).
-- ---------------------------------------------------------------------
create function public.submit_csat(p_ticket_id uuid, p_reseller_id text, p_rating integer)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  s csat_settings%rowtype;
  t record;
  m ticket_metrics%rowtype;
begin
  if p_rating is null or p_rating < 1 or p_rating > 5 then
    return jsonb_build_object('ok', false, 'reason', 'invalid_rating');
  end if;

  select * into s from csat_settings where id = 1;

  select id, status, reseller_id into t from tickets where id = p_ticket_id;
  if not found or t.reseller_id is distinct from p_reseller_id then
    return jsonb_build_object('ok', false, 'reason', 'not_found');
  end if;

  select * into m from ticket_metrics where ticket_id = p_ticket_id for update;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'not_eligible');   -- created before launch
  end if;

  if t.status is distinct from 'Resolved' or m.resolved_at is null then
    return jsonb_build_object('ok', false, 'reason', 'not_resolved');
  end if;

  if now() > m.resolved_at + make_interval(hours => s.rating_window_hours) then
    return jsonb_build_object('ok', false, 'reason', 'window_ended');
  end if;

  if m.human_msg_count < s.min_agent_messages then
    return jsonb_build_object('ok', false, 'reason', 'not_eligible');
  end if;

  if exists (select 1 from csat_ratings where ticket_id = p_ticket_id) then
    return jsonb_build_object('ok', false, 'reason', 'already_rated');
  end if;

  insert into csat_ratings (ticket_id, reseller_id, agent_id, rating)
  values (p_ticket_id, t.reseller_id, m.resolved_agent_id, p_rating);

  return jsonb_build_object('ok', true);

exception when unique_violation then
  return jsonb_build_object('ok', false, 'reason', 'already_rated');
end;
$$;

-- ---------------------------------------------------------------------
-- 9. get_csat_status — called by the MARKAZ App for the Resolved Issues
--    list and the ticket screen. One call can check many tickets.
--    state: 'can_rate' (show Rate Chat / rating panel),
--           'rated'    (show locked stars + "Thanks for your feedback!"),
--           'none'     (show nothing extra / "This ticket is resolved").
-- ---------------------------------------------------------------------
create function public.get_csat_status(p_ticket_ids uuid[], p_reseller_id text)
returns table (ticket_id uuid, state text, rating smallint, window_ends_at timestamptz)
language sql stable security definer set search_path = public
as $$
  select
    x.id,
    case
      when x.rated_value is not null then 'rated'
      when x.can_rate then 'can_rate'
      else 'none'
    end,
    x.rated_value,
    case when x.rated_value is null and x.can_rate then x.ends_at end
  from (
    select
      t.id,
      r.rating as rated_value,
      m.resolved_at + make_interval(hours => s.rating_window_hours) as ends_at,
      (    m.ticket_id is not null
       and t.status = 'Resolved'
       and m.resolved_at is not null
       and now() <= m.resolved_at + make_interval(hours => s.rating_window_hours)
       and m.human_msg_count >= s.min_agent_messages) as can_rate
    from tickets t
    cross join csat_settings s
    left join ticket_metrics m on m.ticket_id = t.id
    left join csat_ratings   r on r.ticket_id = t.id
    where s.id = 1
      and t.id = any (p_ticket_ids)
      and t.reseller_id = p_reseller_id
  ) x;
$$;

-- ---------------------------------------------------------------------
-- 10. Function permissions: only the two app functions are callable
-- ---------------------------------------------------------------------
revoke all on function public.csat_on_ticket_insert()        from public, anon, authenticated;
revoke all on function public.csat_on_ticket_status_change() from public, anon, authenticated;
revoke all on function public.csat_on_message_insert()       from public, anon, authenticated;

revoke all on function public.submit_csat(uuid, text, integer)  from public;
revoke all on function public.get_csat_status(uuid[], text)     from public;
grant execute on function public.submit_csat(uuid, text, integer) to anon, authenticated;
grant execute on function public.get_csat_status(uuid[], text)    to anon, authenticated;

commit;

-- ---------------------------------------------------------------------
-- Check: launch time is set, and no old ticket is tracked (expect 0)
-- ---------------------------------------------------------------------
select
  (select launch_at           from public.csat_settings where id = 1) as launch_at,
  (select rating_window_hours from public.csat_settings where id = 1) as window_hours,
  (select count(*) from public.ticket_metrics)                       as tracked_tickets,
  (select count(*) from public.csat_ratings)                         as ratings;
