-- =====================================================================
-- 05_test_dashboard.sql
-- TEST PROJECT ONLY (markaz-helpline-test). DO NOT RUN ON PRODUCTION.
--
-- Uses the 8 new tickets from 03_test_scenarios.sql. Run 03 again first
-- if more than a day has passed. Checks every dashboard number against
-- a known expected value, and checks who can and cannot read the data.
-- =====================================================================

drop table if exists test_results;
create temp table test_results (n serial, test text, expected text, actual text);

drop table if exists dash_out;
create temp table dash_out (name text primary key, data jsonb);

-- ---------------------------------------------------------------------
-- 1. Give the resolved test tickets clear resolution times:
--    N1 1h, N2 2h, N3 3h, N7 3h, N5 4h, N6 5h  -> median 3h (10800 sec)
-- ---------------------------------------------------------------------
update public.ticket_metrics set resolved_at = ticket_created_at + interval '3 hours' where ticket_id = 'cccccccc-0000-0000-0000-000000000007';
update public.ticket_metrics set resolved_at = ticket_created_at + interval '1 hour'  where ticket_id = 'cccccccc-0000-0000-0000-000000000001';
update public.ticket_metrics set resolved_at = ticket_created_at + interval '2 hours' where ticket_id = 'cccccccc-0000-0000-0000-000000000002';
update public.ticket_metrics set resolved_at = ticket_created_at + interval '3 hours' where ticket_id = 'cccccccc-0000-0000-0000-000000000003';
update public.ticket_metrics set resolved_at = ticket_created_at + interval '4 hours' where ticket_id = 'cccccccc-0000-0000-0000-000000000005';
update public.ticket_metrics set resolved_at = ticket_created_at + interval '5 hours' where ticket_id = 'cccccccc-0000-0000-0000-000000000006';

-- ---------------------------------------------------------------------
-- 2. Call the dashboard as agent Sana (logged in)
-- ---------------------------------------------------------------------
do $$
declare v jsonb;
begin
  perform set_config('request.jwt.claims', '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}', true);
  set local role authenticated;
  v := jsonb_build_object(
    'overview',      public.dashboard_overview(now() - interval '1 day', now() + interval '1 day'),
    'overview_sana', public.dashboard_overview(now() - interval '1 day', now() + interval '1 day', '11111111-1111-1111-1111-111111111111'),
    'overview_ahmed', public.dashboard_overview(now() - interval '1 day', now() + interval '1 day', '22222222-2222-2222-2222-222222222222'),
    'csat_ayesha',   public.dashboard_csat(now() - interval '1 day', now() + interval '1 day', '33333333-3333-3333-3333-333333333333'),
    'agents',        public.dashboard_agents(now() - interval '1 day', now() + interval '1 day'),
    'csat',          public.dashboard_csat(now() - interval '1 day', now() + interval '1 day'),
    'options',       public.dashboard_filter_options()
  );
  reset role;
  perform set_config('request.jwt.claims', '', true);
  insert into dash_out values ('agent', v);
end $$;

-- ---------------------------------------------------------------------
-- 3. Security checks (each records "allowed" or "blocked")
-- ---------------------------------------------------------------------
do $$
declare r text;
begin
  -- Logged in, but not an agent
  begin
    perform set_config('request.jwt.claims', '{"sub":"99999999-9999-9999-9999-999999999999","role":"authenticated"}', true);
    set local role authenticated;
    perform public.dashboard_overview(now() - interval '1 day', now() + interval '1 day');
    r := 'allowed';
  exception when others then r := 'blocked';
  end;
  reset role;
  insert into test_results (test, expected, actual) values ('Security: logged-in non-agent cannot read dashboard', 'blocked', r);

  -- Not logged in (public key only)
  begin
    perform set_config('request.jwt.claims', '', true);
    set local role anon;
    perform public.dashboard_overview(now() - interval '1 day', now() + interval '1 day');
    r := 'allowed';
  exception when others then r := 'blocked';
  end;
  reset role;
  insert into test_results (test, expected, actual) values ('Security: public key cannot read dashboard', 'blocked', r);

  -- Public key cannot read raw ratings
  begin
    set local role anon;
    perform 1 from public.csat_ratings limit 1;
    r := 'allowed';
  exception when others then r := 'blocked';
  end;
  reset role;
  insert into test_results (test, expected, actual) values ('Security: public key cannot read raw ratings', 'blocked', r);

  -- Public key cannot insert a rating directly
  begin
    set local role anon;
    insert into public.csat_ratings (ticket_id, reseller_id, rating)
    values ('cccccccc-0000-0000-0000-000000000006', 'x', 5);
    r := 'allowed';
  exception when others then r := 'blocked';
  end;
  reset role;
  insert into test_results (test, expected, actual) values ('Security: public key cannot insert ratings directly', 'blocked', r);

  -- Even an agent cannot read raw ratings directly (only totals via functions)
  begin
    perform set_config('request.jwt.claims', '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}', true);
    set local role authenticated;
    perform 1 from public.csat_ratings limit 1;
    r := 'allowed';
  exception when others then r := 'blocked';
  end;
  reset role;
  insert into test_results (test, expected, actual) values ('Security: agent cannot read raw ratings directly', 'blocked', r);

  -- Public key cannot read tracking data
  begin
    perform set_config('request.jwt.claims', '', true);
    set local role anon;
    perform 1 from public.ticket_metrics limit 1;
    r := 'allowed';
  exception when others then r := 'blocked';
  end;
  reset role;
  insert into test_results (test, expected, actual) values ('Security: public key cannot read tracking data', 'blocked', r);

  -- The MARKAZ App (public key) CAN use the two app functions
  begin
    set local role anon;
    perform * from public.get_csat_status(array['cccccccc-0000-0000-0000-000000000006']::uuid[], 'aaaaaaaa-0000-0000-0000-000000000106');
    r := 'allowed';
  exception when others then r := 'blocked';
  end;
  reset role;
  insert into test_results (test, expected, actual) values ('Security: app can call get_csat_status', 'allowed', r);

  perform set_config('request.jwt.claims', '', true);
end $$;

-- ---------------------------------------------------------------------
-- 4. Number checks (expected values worked out from the 8 test tickets)
--    Ratings: N1 5 (no agent), N2 4 (Sana), N3 3 (Ahmed), N7 2 (Ayesha)
-- ---------------------------------------------------------------------
insert into test_results (test, expected, actual)
select t.test, t.expected, t.actual
from dash_out d,
lateral (values
  -- Overview tiles
  ('Overview: Total tickets',                    '8',     d.data->'overview'->'current'->>'total'),
  ('Overview: Handled by AI',                    '2',     d.data->'overview'->'current'->>'handled_by_ai'),
  ('Overview: Assigned and Resolved by Agent',   '5',     d.data->'overview'->'current'->>'assigned_resolved_by_agent'),
  ('Overview: First reply median (15 min)',      '900',   d.data->'overview'->'current'->>'first_reply_median_sec'),
  ('Overview: Resolution median (3 h)',          '10800', d.data->'overview'->'current'->>'resolution_median_sec'),
  ('Overview: CSAT average (blended)',           '3.50',  d.data->'overview'->'current'->>'csat_avg'),
  ('Overview: CSAT ratings count',               '4',     d.data->'overview'->'current'->>'csat_count'),
  ('Overview: previous period total',            '0',     d.data->'overview'->'previous'->>'total'),
  -- Ticket volume groups (never overlap, add up to total)
  ('Volume: AI only',        '1', (select sum((e->>'ai_only')::int)::text       from jsonb_array_elements(d.data->'overview'->'volume') e)),
  ('Volume: AI then agent',  '1', (select sum((e->>'ai_then_agent')::int)::text from jsonb_array_elements(d.data->'overview'->'volume') e)),
  ('Volume: Agent only (unanswered N8 excluded)', '5', (select sum((e->>'agent_only')::int)::text from jsonb_array_elements(d.data->'overview'->'volume') e)),
  ('Volume: No reply yet (N8)', '1', (select sum((e->>'no_reply')::int)::text   from jsonb_array_elements(d.data->'overview'->'volume') e)),
  ('Volume: groups add up to total', '8', (select sum((e->>'ai_only')::int + (e->>'ai_then_agent')::int + (e->>'agent_only')::int + (e->>'no_reply')::int)::text
                                             from jsonb_array_elements(d.data->'overview'->'volume') e)),
  ('Tickets by issue: 4 issues resolved by agents', '4', jsonb_array_length(d.data->'overview'->'by_issue')::text),
  -- Single agent selected (Sana)
  ('Agent filter (Sana): total',            '2',    d.data->'overview_sana'->'current'->>'total'),
  ('Agent filter (Sana): AI number = dash', 'null', coalesce(d.data->'overview_sana'->'current'->>'handled_by_ai', 'null')),
  ('Agent filter (Sana): CSAT',             '4.00', d.data->'overview_sana'->'current'->>'csat_avg'),
  -- Agent filter follows the rated agent: N3 was reassigned to Ayesha after Ahmed's rating
  ('Agent filter (Ahmed): CSAT keeps N3 rating', '3.00', d.data->'overview_ahmed'->'current'->>'csat_avg'),
  ('Agent filter (Ahmed): CSAT count',           '1',    d.data->'overview_ahmed'->'current'->>'csat_count'),
  ('CSAT tab filter (Ayesha): only her N7 rating, not N3', '2.00', d.data->'csat_ayesha'->'current'->>'csat_avg'),
  -- Agents tab tiles
  ('Agents: Active agents',      '3', d.data->'agents'->'current'->>'active_agents'),
  ('Agents: Tickets assigned',   '5', d.data->'agents'->'current'->>'assigned'),
  ('Agents: Resolved tickets',   '4', d.data->'agents'->'current'->>'resolved'),
  ('Agents: Open tickets (live)','1', d.data->'agents'->'current'->>'open_tickets'),
  -- Agent comparison rows
  ('Row Sana: assigned',   '2',    (select e->>'assigned'   from jsonb_array_elements(d.data->'agents'->'rows') e where e->>'agent' = 'Sana')),
  ('Row Sana: CSAT',       '4.00', (select e->>'csat_avg'   from jsonb_array_elements(d.data->'agents'->'rows') e where e->>'agent' = 'Sana')),
  ('Row Ayesha: open',     '1',    (select e->>'open'       from jsonb_array_elements(d.data->'agents'->'rows') e where e->>'agent' = 'Ayesha')),
  ('Row Ayesha: CSAT only from her own N7 (N3 went to Ahmed)', '2.00', (select e->>'csat_avg' from jsonb_array_elements(d.data->'agents'->'rows') e where e->>'agent' = 'Ayesha')),
  ('Row Ayesha: CSAT count',  '1', (select e->>'csat_count' from jsonb_array_elements(d.data->'agents'->'rows') e where e->>'agent' = 'Ayesha')),
  ('Row Ahmed: CSAT',      '3.00', (select e->>'csat_avg'   from jsonb_array_elements(d.data->'agents'->'rows') e where e->>'agent' = 'Ahmed')),
  -- CSAT tab
  ('CSAT: average',                 '3.50',   d.data->'csat'->'current'->>'csat_avg'),
  ('CSAT: Rating rate (4 of 6)',    '0.6667', d.data->'csat'->'current'->>'rating_rate'),
  ('CSAT: 3-star count',            '1',  (select e->>'count' from jsonb_array_elements(d.data->'csat'->'distribution') e where e->>'stars' = '3')),
  ('CSAT: 2-star count',            '1',  (select e->>'count' from jsonb_array_elements(d.data->'csat'->'distribution') e where e->>'stars' = '2')),
  ('CSAT: 1-star count',            '0',  (select e->>'count' from jsonb_array_elements(d.data->'csat'->'distribution') e where e->>'stars' = '1')),
  ('CSAT by issue: Delivery Issues average', '4.50', (select e->>'csat_avg' from jsonb_array_elements(d.data->'csat'->'by_issue') e where e->>'issue' = 'Delivery Issues')),
  ('CSAT by issue: Payment Issues average',  '2.50', (select e->>'csat_avg' from jsonb_array_elements(d.data->'csat'->'by_issue') e where e->>'issue' = 'Payment Issues')),
  -- Filter options
  ('Filters: agent list (all agent profiles)', (select count(*)::text from public.agent_profiles), jsonb_array_length(d.data->'options'->'agents')::text),
  ('Filters: issue list has Delivery Issues', 'true', (d.data->'options'->'issues' ? 'Delivery Issues')::text)
) as t(test, expected, actual)
where d.name = 'agent';

-- ---------------------------------------------------------------------
-- 5. Results: every row should say PASS
-- ---------------------------------------------------------------------
select n, test, expected, actual,
       case when expected is not distinct from actual then 'PASS' else 'FAIL' end as result
from test_results
order by n;
