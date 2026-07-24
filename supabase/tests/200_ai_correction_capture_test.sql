-- READINESS #190: the AI-correction feedback loop. capture_customer_correction()
-- is the trigger that measures how good the enrichment AI is: when a human
-- overwrites a customer field that the AI had previously written (per
-- customer_enrichment_log), it records the miss in ai_corrections — model_value
-- vs human_value. That table is the ground truth for model accuracy and the
-- few-shot corrections. The trigger must fire ONLY on a genuine human correction
-- of an AI-written value: not on human edits of human data, not on filling a
-- blank, and NEVER on a service-side write (enrichment/sync is not a correction).
begin;
create extension if not exists pgtap with schema extensions;
select plan(7);

insert into auth.users (id, email) values ('00000000-0000-4000-8000-00000000c0a1'::uuid, 'human@test.local');

-- a customer the AI has partly filled: phone + email were AI-written; contact_person is human
insert into public.customers (company_name, phone, email, contact_person, fax)
values ('Correction Co', 'AI-555-0100', 'ai@correction.co', 'Jane Human', '');
create temp table CC as select id from public.customers where company_name='Correction Co';

insert into public.customer_enrichment_log (customer_id, field, new_value, model) values
  ((select id from CC), 'phone', 'AI-555-0100',      'qwen2.5:3b'),
  ((select id from CC), 'email', 'ai@correction.co', 'qwen2.5:3b');

-- baseline
select is((select count(*)::int from public.ai_corrections where entity_id=(select id from CC)), 0,
  '0. no corrections captured yet');

-- ═══ a human corrects an AI-written field → captured ═══
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-00000000c0a1"}', true);
update public.customers set phone='555-9000' where id=(select id from CC);

select is((select count(*)::int from public.ai_corrections where entity_id=(select id from CC) and field='phone'), 1,
  '1. correcting an AI-written phone is captured');
select is((select model_value from public.ai_corrections where entity_id=(select id from CC) and field='phone'),
  'AI-555-0100', '2. the model value the AI wrote is recorded');
select is((select human_value from public.ai_corrections where entity_id=(select id from CC) and field='phone'),
  '555-9000', '3. the human replacement is recorded');
select is((select model from public.ai_corrections where entity_id=(select id from CC) and field='phone'),
  'qwen2.5:3b', '4. the responsible model is attributed');

-- ═══ editing a human-written field is NOT a correction ═══
update public.customers set contact_person='Jane Doe' where id=(select id from CC);
select is((select count(*)::int from public.ai_corrections where entity_id=(select id from CC) and field='contact_person'), 0,
  '5. editing a field the AI never wrote is not captured');

-- ═══ a service-side write of an AI field is NOT a correction ═══
select set_config('request.jwt.claims', '{}', true);  -- auth.uid() is null → service write
update public.customers set email='ops@correction.co' where id=(select id from CC);
select is((select count(*)::int from public.ai_corrections where entity_id=(select id from CC) and field='email'), 0,
  '6. a service-side overwrite (no auth.uid) is never a correction');

select * from finish();
rollback;
