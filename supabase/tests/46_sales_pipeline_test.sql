-- Sales pipeline: quote_requests funnel → win rate + open pipeline, spam excluded.
begin;
create extension if not exists pgtap with schema extensions;
select plan(4);

insert into auth.users (id, email) values ('00000000-0000-4000-8000-000000000f46'::uuid, 'sales@test.local');
update public.profiles set role = 'admin' where id = '00000000-0000-4000-8000-000000000f46';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000f46"}', true);

-- 3 won, 1 lost, 2 open (new/quoted), 1 spam — all in July 2026
insert into public.quote_requests (contact_name, email, origin_city, origin_state, dest_city, dest_state, status, created_at) values
  ('A','a@x.com','Dallas','TX','Chicago','IL','won',   '2026-07-05'),
  ('B','b@x.com','Dallas','TX','Chicago','IL','won',   '2026-07-06'),
  ('C','c@x.com','Dallas','TX','Chicago','IL','won',   '2026-07-07'),
  ('D','d@x.com','Dallas','TX','Chicago','IL','lost',  '2026-07-08'),
  ('E','e@x.com','Dallas','TX','Chicago','IL','new',   '2026-07-09'),
  ('F','f@x.com','Dallas','TX','Chicago','IL','quoted','2026-07-10'),
  ('G','g@x.com','Dallas','TX','Chicago','IL','spam',  '2026-07-11');

select is((public.sales_pipeline('2026-07-01','2026-08-01')->>'quotes_received')::int, 6, 'quotes received excludes spam');
select is((public.sales_pipeline('2026-07-01','2026-08-01')->>'win_rate_pct')::numeric, 75.0::numeric, 'win rate = won / (won+lost) = 3/4');
select is((public.sales_pipeline('2026-07-01','2026-08-01')->>'open_pipeline')::int, 2, 'open pipeline = new + quoted');
select is((public.sales_pipeline('2026-06-01','2026-07-01')->>'quotes_received')::int, 0, 'a window with no quotes reads zero');

select * from finish();
rollback;
