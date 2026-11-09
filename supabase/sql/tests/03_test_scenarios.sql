-- =====================================================================
-- 03_test_scenarios.sql
-- TEST PROJECT ONLY (markaz-helpline-test). DO NOT RUN ON PRODUCTION.
--
-- Creates 6 NEW (post-launch) sample tickets, runs every CSAT and
-- tracking rule against them and against the OLD tickets, and shows one
-- PASS/FAIL row per check. Safe to run again: it cleans up its own data.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 0. Clean up any previous run
-- ---------------------------------------------------------------------
delete from public.messages where id = 'dddddddd-0000-0000-0000-000000000001';
delete from public.tickets  where id::text like 'cccccccc-%';

drop table if exists test_results;
create temp table test_results (n serial, test text, expected text, actual text);

-- ---------------------------------------------------------------------
-- 1. Six new tickets (created now, i.e. after launch)
--    N1 AI only, closed by customer   N2 AI then agent (Sana)
--    N3 agent only (Ahmed)            N4 still open (Ayesha)
--    N5 window will expire (Sana)     N6 reopened before rating (Ahmed)
-- ---------------------------------------------------------------------
insert into public.tickets
  (id, reseller_id, reseller_name, reseller_phone, order_id, issue_type, description, status, ticket_source, ai_handled)
values
  ('cccccccc-0000-0000-0000-000000000001', 'aaaaaaaa-0000-0000-0000-000000000101', 'New Reseller 1', '03100000001', 'ORD-2001', 'Delivery Issues', 'Where is my parcel?',      'Pending', 'manual', true),
  ('cccccccc-0000-0000-0000-000000000002', 'aaaaaaaa-0000-0000-0000-000000000102', 'New Reseller 2', '03100000002', 'ORD-2002', 'Delivery Issues', 'Parcel shows delivered.',  'Pending', 'manual', true),
  ('cccccccc-0000-0000-0000-000000000003', 'aaaaaaaa-0000-0000-0000-000000000103', 'New Reseller 3', '03100000003', 'ORD-2003', 'Payment Issues',  'Payment missing.',         'Pending', 'manual', false),
  ('cccccccc-0000-0000-0000-000000000004', 'aaaaaaaa-0000-0000-0000-000000000104', 'New Reseller 4', '03100000004', 'ORD-2004', 'App/OTP',         'Cannot log in.',           'Pending', 'manual', false),
  ('cccccccc-0000-0000-0000-000000000005', 'aaaaaaaa-0000-0000-0000-000000000105', 'New Reseller 5', '03100000005', 'ORD-2005', 'Return Issues',   'Return not picked up.',    'Pending', 'auto',   false),
  ('cccccccc-0000-0000-0000-000000000006', 'aaaaaaaa-0000-0000-0000-000000000106', 'New Reseller 6', '03100000006', 'ORD-2006', 'Other',           'General question.',        'Pending', 'manual', false);

-- ---------------------------------------------------------------------
-- 2. Messages (description message at +0 is added by the existing trigger)
-- ---------------------------------------------------------------------
insert into public.messages (ticket_id, sender_type, sender_name, message, created_at) values
  -- N1: AI only
  ('cccccccc-0000-0000-0000-000000000001', 'agent',    'Markaz AI',      'Checking your parcel.',     now() + interval '2 minutes'),
  -- N2: AI, customer, AI, then Sana. First reply clock starts at the customer's +10m message.
  ('cccccccc-0000-0000-0000-000000000002', 'agent',    'Markaz AI',      'Let me check.',             now() + interval '2 minutes'),
  ('cccccccc-0000-0000-0000-000000000002', 'reseller', 'New Reseller 2', 'It is not here.',           now() + interval '10 minutes'),
  ('cccccccc-0000-0000-0000-000000000002', 'agent',    'Markaz AI',      'Escalating to an agent.',   now() + interval '12 minutes'),
  ('cccccccc-0000-0000-0000-000000000002', 'agent',    'Sana',           'I am looking into it.',     now() + interval '40 minutes'),
  -- N3: customer +5m, Ahmed +20m, customer +25m (must NOT move the clock)
  ('cccccccc-0000-0000-0000-000000000003', 'reseller', 'New Reseller 3', 'Any update?',               now() + interval '5 minutes'),
  ('cccccccc-0000-0000-0000-000000000003', 'agent',    'Ahmed',          'Checking with finance.',    now() + interval '20 minutes'),
  ('cccccccc-0000-0000-0000-000000000003', 'reseller', 'New Reseller 3', 'Thanks.',                   now() + interval '25 minutes'),
  -- N4, N5, N6: one agent reply each
  ('cccccccc-0000-0000-0000-000000000004', 'agent',    'Ayesha',         'Please update the app.',    now() + interval '10 minutes'),
  ('cccccccc-0000-0000-0000-000000000005', 'agent',    'Sana',           'Pickup rescheduled.',       now() + interval '15 minutes'),
  ('cccccccc-0000-0000-0000-000000000006', 'agent',    'Ahmed',          'Here is the answer.',       now() + interval '10 minutes');

-- A new message on an OLD ticket: must still not be tracked
insert into public.messages (id, ticket_id, sender_type, sender_name, message)
values ('dddddddd-0000-0000-0000-000000000001', 'bbbbbbbb-0000-0000-0000-000000000002', 'agent', 'Sana', 'Follow-up on old ticket.');

-- ---------------------------------------------------------------------
-- 3. Assign agents, then resolve
-- ---------------------------------------------------------------------
update public.tickets set assigned_agent_id = '11111111-1111-1111-1111-111111111111' where id in ('cccccccc-0000-0000-0000-000000000002', 'cccccccc-0000-0000-0000-000000000005');
update public.tickets set assigned_agent_id = '22222222-2222-2222-2222-222222222222' where id in ('cccccccc-0000-0000-0000-000000000003', 'cccccccc-0000-0000-0000-000000000006');
update public.tickets set assigned_agent_id = '33333333-3333-3333-3333-333333333333', status = 'In Progress' where id = 'cccccccc-0000-0000-0000-000000000004';

-- N1 closed by the customer, no agent
update public.tickets set status = 'Resolved', closed_by = 'reseller' where id = 'cccccccc-0000-0000-0000-000000000001';
-- N2, N3, N5, N6 resolved by their agents
update public.tickets set status = 'Resolved', resolved_by = assigned_agent_id
 where id in ('cccccccc-0000-0000-0000-000000000002', 'cccccccc-0000-0000-0000-000000000003',
              'cccccccc-0000-0000-0000-000000000005', 'cccccccc-0000-0000-0000-000000000006');

-- ---------------------------------------------------------------------
-- 4. Tracking checks
-- ---------------------------------------------------------------------
insert into test_results (test, expected, actual) values
  ('Old tickets are not tracked (incl. new message on old ticket)', '0',
     (select count(*)::text from public.ticket_metrics where ticket_id::text like 'bbbbbbbb-%')),
  ('All 6 new tickets are tracked', '6',
     (select count(*)::text from public.ticket_metrics where ticket_id::text like 'cccccccc-%')),
  ('N1 Handled by AI', 'true',
     (select (first_ai_msg_at is not null)::text from public.ticket_metrics where ticket_id = 'cccccccc-0000-0000-0000-000000000001')),
  ('N1 not Human Handled', 'false',
     (select (first_agent_msg_at is not null)::text from public.ticket_metrics where ticket_id = 'cccccccc-0000-0000-0000-000000000001')),
  ('N1 resolved with no agent', 'null',
     (select coalesce(resolved_agent_id::text, 'null') from public.ticket_metrics where ticket_id = 'cccccccc-0000-0000-0000-000000000001')),
  ('N2 Handled by AI and Human Handled', 'true',
     (select (first_ai_msg_at is not null and first_agent_msg_at is not null)::text from public.ticket_metrics where ticket_id = 'cccccccc-0000-0000-0000-000000000002')),
  ('N2 first reply = 30 min (AI messages do not restart clock)', '30',
     (select round(extract(epoch from first_agent_msg_at - first_reply_start_at) / 60)::text from public.ticket_metrics where ticket_id = 'cccccccc-0000-0000-0000-000000000002')),
  ('N3 first reply = 15 min (later customer message ignored)', '15',
     (select round(extract(epoch from first_agent_msg_at - first_reply_start_at) / 60)::text from public.ticket_metrics where ticket_id = 'cccccccc-0000-0000-0000-000000000003')),
  ('N3 not Handled by AI', 'false',
     (select (first_ai_msg_at is not null)::text from public.ticket_metrics where ticket_id = 'cccccccc-0000-0000-0000-000000000003')),
  ('N4 open ticket has no resolve time', 'true',
     (select (resolved_at is null)::text from public.ticket_metrics where ticket_id = 'cccccccc-0000-0000-0000-000000000004'));

-- Re-resolving an already Resolved ticket must not restart the window
update public.ticket_metrics set resolved_at = now() - interval '1 hour' where ticket_id = 'cccccccc-0000-0000-0000-000000000002';
update public.tickets set status = 'Resolved' where id = 'cccccccc-0000-0000-0000-000000000002';
insert into test_results (test, expected, actual) values
  ('N2 re-resolve keeps original resolve time', 'true',
     (select (resolved_at = now() - interval '1 hour')::text from public.ticket_metrics where ticket_id = 'cccccccc-0000-0000-0000-000000000002'));

-- ---------------------------------------------------------------------
-- 5. Rating rules
-- ---------------------------------------------------------------------

-- N3: reassign AFTER resolve (rating must still go to Ahmed)
update public.tickets set assigned_agent_id = '33333333-3333-3333-3333-333333333333' where id = 'cccccccc-0000-0000-0000-000000000003';

insert into test_results (test, expected, actual) values
  ('N3 status before rating', 'can_rate',
     (select state from public.get_csat_status(array['cccccccc-0000-0000-0000-000000000003']::uuid[], 'aaaaaaaa-0000-0000-0000-000000000103'))),
  ('N3 other customer cannot see status', '0',
     (select count(*)::text from public.get_csat_status(array['cccccccc-0000-0000-0000-000000000003']::uuid[], 'aaaaaaaa-0000-0000-0000-000000000999'))),
  ('N3 other customer cannot rate', 'not_found',
     (select public.submit_csat('cccccccc-0000-0000-0000-000000000003', 'aaaaaaaa-0000-0000-0000-000000000999', 5) ->> 'reason')),
  ('N3 rating 6 rejected', 'invalid_rating',
     (select public.submit_csat('cccccccc-0000-0000-0000-000000000003', 'aaaaaaaa-0000-0000-0000-000000000103', 6) ->> 'reason'));

insert into test_results (test, expected, actual) values
  ('N3 valid rating accepted', 'true',
     (select public.submit_csat('cccccccc-0000-0000-0000-000000000003', 'aaaaaaaa-0000-0000-0000-000000000103', 3) ->> 'ok'));

insert into test_results (test, expected, actual) values
  ('N3 rating saved for agent at resolve time (Ahmed, not Ayesha)', '22222222-2222-2222-2222-222222222222',
     (select agent_id::text from public.csat_ratings where ticket_id = 'cccccccc-0000-0000-0000-000000000003')),
  ('N3 second rating rejected', 'already_rated',
     (select public.submit_csat('cccccccc-0000-0000-0000-000000000003', 'aaaaaaaa-0000-0000-0000-000000000103', 5) ->> 'reason'));

-- N3: reopen and resolve again after rating -> still rated, cannot rate again
update public.tickets set status = 'Pending'  where id = 'cccccccc-0000-0000-0000-000000000003';
update public.tickets set status = 'Resolved' where id = 'cccccccc-0000-0000-0000-000000000003';
insert into test_results (test, expected, actual) values
  ('N3 after reopen + resolve: still shows rated', 'rated',
     (select state from public.get_csat_status(array['cccccccc-0000-0000-0000-000000000003']::uuid[], 'aaaaaaaa-0000-0000-0000-000000000103'))),
  ('N3 after reopen + resolve: rated stars kept (3)', '3',
     (select rating::text from public.get_csat_status(array['cccccccc-0000-0000-0000-000000000003']::uuid[], 'aaaaaaaa-0000-0000-0000-000000000103'))),
  ('N3 after reopen + resolve: cannot rate again', 'already_rated',
     (select public.submit_csat('cccccccc-0000-0000-0000-000000000003', 'aaaaaaaa-0000-0000-0000-000000000103', 5) ->> 'reason'));

-- N1: customer-closed, no agent -> can rate, saved with no agent
insert into test_results (test, expected, actual) values
  ('N1 customer-closed ticket can be rated', 'true',
     (select public.submit_csat('cccccccc-0000-0000-0000-000000000001', 'aaaaaaaa-0000-0000-0000-000000000101', 5) ->> 'ok'));
insert into test_results (test, expected, actual) values
  ('N1 rating saved with no agent', 'null',
     (select coalesce(agent_id::text, 'null') from public.csat_ratings where ticket_id = 'cccccccc-0000-0000-0000-000000000001'));

-- N2: rated for Sana
insert into test_results (test, expected, actual) values
  ('N2 rating accepted', 'true',
     (select public.submit_csat('cccccccc-0000-0000-0000-000000000002', 'aaaaaaaa-0000-0000-0000-000000000102', 4) ->> 'ok'));
insert into test_results (test, expected, actual) values
  ('N2 rating saved for Sana', '11111111-1111-1111-1111-111111111111',
     (select agent_id::text from public.csat_ratings where ticket_id = 'cccccccc-0000-0000-0000-000000000002'));

-- N4: not resolved
insert into test_results (test, expected, actual) values
  ('N4 open ticket cannot be rated', 'not_resolved',
     (select public.submit_csat('cccccccc-0000-0000-0000-000000000004', 'aaaaaaaa-0000-0000-0000-000000000104', 5) ->> 'reason')),
  ('N4 open ticket status', 'none',
     (select state from public.get_csat_status(array['cccccccc-0000-0000-0000-000000000004']::uuid[], 'aaaaaaaa-0000-0000-0000-000000000104')));

-- N5: simulate 25 hours passing since resolve
update public.ticket_metrics set resolved_at = now() - interval '25 hours' where ticket_id = 'cccccccc-0000-0000-0000-000000000005';
insert into test_results (test, expected, actual) values
  ('N5 after 24 hours: rating rejected', 'window_ended',
     (select public.submit_csat('cccccccc-0000-0000-0000-000000000005', 'aaaaaaaa-0000-0000-0000-000000000105', 5) ->> 'reason')),
  ('N5 after 24 hours: Rate Chat hidden', 'none',
     (select state from public.get_csat_status(array['cccccccc-0000-0000-0000-000000000005']::uuid[], 'aaaaaaaa-0000-0000-0000-000000000105')));

-- N6: reopen BEFORE rating -> option cancelled, new window at next resolve
update public.tickets set status = 'Pending' where id = 'cccccccc-0000-0000-0000-000000000006';
insert into test_results (test, expected, actual) values
  ('N6 reopened: resolve time cleared', 'true',
     (select (resolved_at is null)::text from public.ticket_metrics where ticket_id = 'cccccccc-0000-0000-0000-000000000006')),
  ('N6 reopened: reopen counted', '1',
     (select reopen_count::text from public.ticket_metrics where ticket_id = 'cccccccc-0000-0000-0000-000000000006')),
  ('N6 reopened: cannot rate', 'not_resolved',
     (select public.submit_csat('cccccccc-0000-0000-0000-000000000006', 'aaaaaaaa-0000-0000-0000-000000000106', 5) ->> 'reason'));
update public.tickets set status = 'Resolved' where id = 'cccccccc-0000-0000-0000-000000000006';
insert into test_results (test, expected, actual) values
  ('N6 resolved again: new window open', 'can_rate',
     (select state from public.get_csat_status(array['cccccccc-0000-0000-0000-000000000006']::uuid[], 'aaaaaaaa-0000-0000-0000-000000000106')));

-- OLD ticket (resolved before launch): never ratable
insert into test_results (test, expected, actual) values
  ('Old resolved ticket cannot be rated', 'not_eligible',
     (select public.submit_csat('bbbbbbbb-0000-0000-0000-000000000002', 'aaaaaaaa-0000-0000-0000-000000000002', 5) ->> 'reason')),
  ('Old resolved ticket shows nothing', 'none',
     (select state from public.get_csat_status(array['bbbbbbbb-0000-0000-0000-000000000002']::uuid[], 'aaaaaaaa-0000-0000-0000-000000000002')));

-- Existing behaviour unchanged: latest-message trigger and ticket numbers still work
insert into test_results (test, expected, actual) values
  ('Existing: latest message still updated', 'Here is the answer.',
     (select latest_message from public.tickets where id = 'cccccccc-0000-0000-0000-000000000006')),
  ('Existing: ticket number still generated', 'true',
     (select (ticket_number like 'TKT%')::text from public.tickets where id = 'cccccccc-0000-0000-0000-000000000001'));

-- ---------------------------------------------------------------------
-- 6. Results: every row should say PASS
-- ---------------------------------------------------------------------
select n, test, expected, actual,
       case when expected is not distinct from actual then 'PASS' else 'FAIL' end as result
from test_results
order by n;
