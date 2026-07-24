-- R9 #3/#4: A/B scores rank engines per doc type, the winner auto-routes, a
-- human pin is never clobbered, and the resolver defaults safely.
begin;
create extension if not exists pgtap with schema extensions;
select plan(8);

insert into auth.users (id, email) values ('00000000-0000-4000-8000-000000000195'::uuid, 'er-admin@test.local');
update public.profiles set role = 'admin' where id = '00000000-0000-4000-8000-000000000195';
insert into auth.users (id, email) values ('00000000-0000-4000-8000-000000000196'::uuid, 'er-drv@test.local');
update public.profiles set role = 'driver' where id = '00000000-0000-4000-8000-000000000196';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000195"}', true);

-- Rate Confirmation: nas-3b wins on accuracy; cloud accurate but slow+costly
insert into public.extraction_ab_scores (doc_type, engine, field_accuracy, latency_ms, cost_cents) values
  ('Rate Confirmation', 'nas-3b',  96, 1200, 0),
  ('Rate Confirmation', 'nas-3b',  94, 1300, 0),
  ('Rate Confirmation', 'nas-3b',  95, 1250, 0),
  ('Rate Confirmation', 'cloud',   97, 4000, 8),
  ('Rate Confirmation', 'cloud',   96, 4200, 8),
  ('Rate Confirmation', 'cloud',   98, 3900, 8),
  ('Rate Confirmation', 'lynx-7b', 88, 2000, 0),
  ('Rate Confirmation', 'lynx-7b', 90, 2100, 0),
  ('Rate Confirmation', 'lynx-7b', 89, 1950, 0);

-- 1. resolver defaults to nas-3b before any routing recorded
select is(public.best_extraction_engine('Unknown Type'), 'nas-3b',
  'unrouted doc type falls back to the house default');

-- 2-3. ranking marks the composite winner (nas-3b: fast+free beats slow cloud)
select is((select (public.extraction_engine_ranking(120, 3)->'by_doc_type'->'Rate Confirmation'->0->>'engine')),
  'nas-3b', 'nas-3b wins the composite (accuracy minus latency/cost penalty)');
select is((select (public.extraction_engine_ranking(120, 3)->'by_doc_type'->'Rate Confirmation'->0->>'winner')),
  'true', 'top row flagged as the winner');

-- 4-5. apply routes the winner
select is((select (public.apply_extraction_routing(120, 3)->>'routes_changed')::int), 1, 'one route promoted');
select is(public.best_extraction_engine('Rate Confirmation'), 'nas-3b', 'resolver now returns the measured winner');

-- 6. a human pin is never overwritten by auto-routing
update public.extraction_routing set engine = 'cloud', auto = false where doc_type = 'Rate Confirmation';
select is((select (public.apply_extraction_routing(120, 3)->>'routes_changed')::int), 0,
  'auto-routing leaves a human-pinned route alone');
select is(public.best_extraction_engine('Rate Confirmation'), 'cloud', 'human pin holds');

-- 7. driver cannot rank or apply
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000196"}', true);
select throws_ok($$ select public.apply_extraction_routing() $$,
  'Not enough permissions', 'driver cannot change routing');

select * from finish();
rollback;
