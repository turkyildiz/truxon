-- R3 #9: complete quote observations promote to the pipeline once;
-- incomplete ones stay in the shadow feed.
begin;
create extension if not exists pgtap with schema extensions;
select plan(4);

insert into public.trux_observations
  (message_id, sender_email, sender_name, subject, classification, summary, extracted)
values
  ('qm-1', 'broker@x.test', 'Pat Broker', 'Quote: CHI to ATL', 'quote',
   'Wants dry van rate Chicago to Atlanta',
   '{"origin_city":"Chicago","origin_state":"IL","dest_city":"Atlanta","dest_state":"GA","equipment":"dry van","pickup_date":"2026-08-01"}'::jsonb),
  ('qm-2', 'vague@x.test', '', 'need a truck', 'quote', 'No lane details', '{}'::jsonb);

select is(public.mine_quote_observations(), 1, 'complete quote promotes, vague one does not');
select is((select q.origin_city from public.quote_requests q
            where q.email = 'broker@x.test'), 'Chicago', 'lane fields ride from the extraction');
select is((select q.pickup_date from public.quote_requests q
            where q.email = 'broker@x.test'), '2026-08-01'::date, 'pickup date parses');
select is(public.mine_quote_observations(), 0, 'second run mines nothing new');

select * from finish();
rollback;
