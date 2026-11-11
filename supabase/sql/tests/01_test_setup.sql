-- =====================================================================
-- 01_test_setup.sql
-- TEST PROJECT ONLY (markaz-helpline-test). DO NOT RUN ON PRODUCTION.
--
-- Recreates the parts of the production database our features touch,
-- with the same columns, triggers and access rules, plus a few "old"
-- (pre-launch) sample tickets. Contains no real customer data.
--
-- Left out on purpose:
--   * notify_reseller_on_agent_message (would call the real api.markaz.app)
--   * ai_responder_trigger            (would start the real AI bot)
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1. Tables (columns copied from production)
-- ---------------------------------------------------------------------

create table public.agent_profiles (
  id          uuid primary key,
  full_name   text not null,
  email       text not null,
  avatar_url  text,
  role        text,
  created_at  timestamptz default now()
);

create table public.tickets (
  id                        uuid primary key default gen_random_uuid(),
  ticket_number             text not null,
  reseller_id               text not null,
  reseller_name             text not null,
  reseller_phone            text not null,
  order_id                  text,
  issue_type                text not null,
  description               text not null,
  status                    text default 'Pending',
  partner_name              text,
  attachment_urls           text[],
  created_at                timestamptz default now(),
  updated_at                timestamptz default now(),
  assigned_agent_id         uuid references public.agent_profiles(id),
  last_read_at              timestamp,
  resolved_by               uuid,
  latest_message            text,
  latest_message_at         timestamptz,
  latest_message_sender     text,
  unread_by_agent           boolean,
  closed_by                 text,
  ticket_source             text,
  whatsapp_enabled          boolean,
  last_whatsapp_message_at  timestamptz,
  webchat_enabled           boolean,
  chat_session_id           uuid,
  reseller_email            varchar,
  ai_escalated              boolean,
  ai_handled                boolean
);

create table public.messages (
  id                   uuid primary key default gen_random_uuid(),
  ticket_id            uuid references public.tickets(id) on delete cascade,
  sender_type          text,
  sender_name          text not null,
  message              text not null,
  attachment_url       text,
  created_at           timestamptz default now(),
  whatsapp_message_id  varchar,
  sent_via_whatsapp    boolean,
  source               varchar default 'crm'
);

create table public.ticket_activities (
  id             uuid primary key default gen_random_uuid(),
  ticket_id      uuid not null references public.tickets(id) on delete cascade,
  activity_type  text not null,
  actor_name     text not null,
  details        text not null,
  created_at     timestamptz default now()
);

create table public.internal_notes (
  id          uuid primary key default gen_random_uuid(),
  ticket_id   uuid references public.tickets(id) on delete cascade,
  agent_id    uuid,
  agent_name  text not null,
  note_text   text not null,
  created_at  timestamptz default now()
);

create table public.reseller_profiles (
  id               uuid primary key default gen_random_uuid(),
  reseller_id      uuid not null unique,
  reseller_status  text,
  ticket_quota     integer,
  created_at       timestamptz default now(),
  updated_at       timestamptz default now()
);

create table public.canned_messages (
  id             uuid primary key default gen_random_uuid(),
  agent_id       uuid,
  message_text   text not null,
  created_at     timestamptz default now(),
  title          text not null,
  shortcut_name  text
);


-- ---------------------------------------------------------------------
-- 2. Existing triggers (copied from production)
-- ---------------------------------------------------------------------

-- Ticket number. The production definition was not read, so this is a
-- simple stand-in that produces the same TKT###### format.
create sequence public.ticket_number_seq start 900001;

create function public.set_ticket_number()
returns trigger language plpgsql as $$
begin
  if new.ticket_number is null or new.ticket_number = '' then
    new.ticket_number := 'TKT' || nextval('public.ticket_number_seq');
  end if;
  return new;
end;
$$;

create trigger gen_ticket_num
  before insert on public.tickets
  for each row execute function public.set_ticket_number();

-- Clear ai_handled when an agent is assigned (same as production).
create function public.clear_ai_handled_on_assign()
returns trigger language plpgsql as $$
begin
  if new.assigned_agent_id is not null
     and new.assigned_agent_id is distinct from old.assigned_agent_id then
    new.ai_handled := false;
  end if;
  return new;
end;
$$;

create trigger clear_ai_handled_on_assign_trigger
  before update on public.tickets
  for each row execute function public.clear_ai_handled_on_assign();

-- Save the ticket description as the first customer message (same as production).
create function public.insert_description_as_message()
returns trigger language plpgsql as $$
begin
  if new.description is not null and trim(new.description) != '' then
    insert into public.messages (ticket_id, sender_type, sender_name, message, created_at)
    values (new.id, 'reseller', new.reseller_name, new.description, new.created_at);
  end if;
  return new;
end;
$$;

create trigger on_ticket_created_insert_description
  after insert on public.tickets
  for each row execute function public.insert_description_as_message();

-- Update the ticket's latest-message fields (same as production).
create function public.update_ticket_latest_message()
returns trigger language plpgsql as $$
begin
  update public.tickets
  set latest_message        = new.message,
      latest_message_at     = new.created_at,
      latest_message_sender = new.sender_type,
      unread_by_agent       = case when new.sender_type = 'reseller' then true else false end
  where id = new.ticket_id;
  return new;
end;
$$;

create trigger trigger_update_latest_message
  after insert on public.messages
  for each row execute function public.update_ticket_latest_message();

-- New login account -> agent profile (same as production), so test agents
-- created under Authentication get a profile automatically.
create function public.create_agent_profile()
returns trigger language plpgsql security definer as $$
begin
  insert into public.agent_profiles (id, full_name, email, role)
  values (
    new.id,
    coalesce(new.raw_user_meta_data->>'name', split_part(new.email, '@', 1)),
    new.email,
    'agent'
  );
  return new;
end;
$$;

create trigger create_agent_profile_trigger
  after insert on auth.users
  for each row execute function public.create_agent_profile();


-- ---------------------------------------------------------------------
-- 3. Access rules (same as production, so tests behave the same)
-- ---------------------------------------------------------------------

grant select, insert, update, delete on all tables in schema public to anon, authenticated;
grant usage, select on all sequences in schema public to anon, authenticated;

alter table public.agent_profiles enable row level security;
create policy "Allow authenticated read" on public.agent_profiles
  for select to authenticated using (true);
create policy "Allow agents to update own profile" on public.agent_profiles
  for update to authenticated using (auth.uid() = id);

alter table public.tickets enable row level security;
create policy "Agents full access" on public.tickets
  for all to authenticated
  using (exists (select 1 from public.agent_profiles where agent_profiles.id = auth.uid()));
create policy "Public temporary access" on public.tickets
  for all to public using (true);

alter table public.messages enable row level security;
create policy "Allow all" on public.messages
  for all to public using (true) with check (true);

alter table public.canned_messages enable row level security;
create policy "All agents manage all canned messages" on public.canned_messages
  for all to authenticated using (true) with check (true);

-- ticket_activities, internal_notes, reseller_profiles: row-level security
-- is OFF in production, so it is left off here too.

-- Live updates, as the CRM listens to these two tables.
alter publication supabase_realtime add table public.tickets, public.messages;


-- ---------------------------------------------------------------------
-- 4. Sample data: 3 agents and 5 OLD (pre-launch) tickets
--    Our features must ignore all of these.
-- ---------------------------------------------------------------------

insert into public.agent_profiles (id, full_name, email, role) values
  ('11111111-1111-1111-1111-111111111111', 'Sana',   'sana@test.local',   'agent'),
  ('22222222-2222-2222-2222-222222222222', 'Ahmed',  'ahmed@test.local',  'agent'),
  ('33333333-3333-3333-3333-333333333333', 'Ayesha', 'ayesha@test.local', 'agent');

insert into public.tickets
  (id, reseller_id, reseller_name, reseller_phone, order_id, issue_type, description,
   status, assigned_agent_id, resolved_by, closed_by, ticket_source, ai_handled,
   created_at, updated_at)
values
  -- Old 1: AI only, still with AI
  ('bbbbbbbb-0000-0000-0000-000000000001', 'aaaaaaaa-0000-0000-0000-000000000001',
   'Test Reseller A', '03000000001', 'ORD-1001', 'Delivery Issues', 'My parcel is late.',
   'In Progress', null, null, null, 'manual', true,
   now() - interval '10 days', now() - interval '10 days'),
  -- Old 2: AI then agent (Sana), resolved by agent
  ('bbbbbbbb-0000-0000-0000-000000000002', 'aaaaaaaa-0000-0000-0000-000000000002',
   'Test Reseller B', '03000000002', 'ORD-1002', 'Delivery Issues', 'Parcel not received.',
   'Resolved', '11111111-1111-1111-1111-111111111111', '11111111-1111-1111-1111-111111111111',
   null, 'manual', false,
   now() - interval '8 days', now() - interval '8 days' + interval '4 hours'),
  -- Old 3: agent only (Ahmed), closed by customer
  ('bbbbbbbb-0000-0000-0000-000000000003', 'aaaaaaaa-0000-0000-0000-000000000003',
   'Test Reseller C', '03000000003', 'ORD-1003', 'Payment Issues', 'Payment not received.',
   'Resolved', '22222222-2222-2222-2222-222222222222', null,
   'reseller', 'manual', false,
   now() - interval '6 days', now() - interval '6 days' + interval '5 hours'),
  -- Old 4: auto return ticket, unassigned
  ('bbbbbbbb-0000-0000-0000-000000000004', 'aaaaaaaa-0000-0000-0000-000000000004',
   'Test Reseller D', '03000000004', 'ORD-1004', 'Return Issues', 'Return request.',
   'Pending', null, null, null, 'auto', false,
   now() - interval '4 days', now() - interval '4 days'),
  -- Old 5: agent (Ayesha), in progress
  ('bbbbbbbb-0000-0000-0000-000000000005', 'aaaaaaaa-0000-0000-0000-000000000005',
   'Test Reseller E', '03000000005', 'ORD-1005', 'App/OTP', 'OTP not arriving.',
   'In Progress', '33333333-3333-3333-3333-333333333333', null, null, 'manual', false,
   now() - interval '2 days', now() - interval '2 days');

-- Messages after the description (the description message is added by the trigger).
insert into public.messages (ticket_id, sender_type, sender_name, message, created_at) values
  ('bbbbbbbb-0000-0000-0000-000000000001', 'agent',    'Markaz AI',       'Let me check your parcel.',  now() - interval '10 days' + interval '2 minutes'),
  ('bbbbbbbb-0000-0000-0000-000000000002', 'agent',    'Markaz AI',       'Checking your order.',       now() - interval '8 days' + interval '2 minutes'),
  ('bbbbbbbb-0000-0000-0000-000000000002', 'reseller', 'Test Reseller B', 'Still not received.',        now() - interval '8 days' + interval '10 minutes'),
  ('bbbbbbbb-0000-0000-0000-000000000002', 'agent',    'Sana',            'I will escalate this now.',  now() - interval '8 days' + interval '2 hours'),
  ('bbbbbbbb-0000-0000-0000-000000000003', 'agent',    'Ahmed',           'Payment is being processed.', now() - interval '6 days' + interval '1 hour'),
  ('bbbbbbbb-0000-0000-0000-000000000005', 'agent',    'Ayesha',          'Please try again now.',      now() - interval '2 days' + interval '30 minutes');


-- ---------------------------------------------------------------------
-- 5. Check: should show agents 3, tickets 5, messages 11
-- ---------------------------------------------------------------------
select
  (select count(*) from public.agent_profiles) as agents,
  (select count(*) from public.tickets)        as tickets,
  (select count(*) from public.messages)       as messages;
