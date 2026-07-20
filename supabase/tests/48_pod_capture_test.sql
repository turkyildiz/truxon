-- POD capture rate: delivered loads with a POD on file within 12h; late/missing
-- PODs drag the rate; the playbook metric flips live.
begin;
create extension if not exists pgtap with schema extensions;
select plan(5);

insert into auth.users (id, email) values ('00000000-0000-4000-8000-000000000f48'::uuid, 'pod2@test.local');
update public.profiles set role = 'admin' where id = '00000000-0000-4000-8000-000000000f48';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000f48"}', true);

insert into public.customers (company_name) values ('POD Rate Broker');
-- 4 delivered loads in-window: A pod at +2h (in), B pod at +20h (late), C pod at
-- -1h i.e. before delivery (in), D no pod.
insert into public.loads (load_number, customer_id, status, delivery_time)
  select v.ln, c.id, 'billed', timestamptz '2026-07-10 12:00:00'
    from public.customers c, (values ('PR-A'),('PR-B'),('PR-C'),('PR-D')) v(ln)
   where c.company_name='POD Rate Broker';

insert into public.documents (entity_type, entity_id, doc_type, filename, storage_path, content_type, uploaded_at)
  select 'load', id, 'POD', 'p.jpg', 'l/a.jpg', 'image/jpeg', timestamptz '2026-07-10 14:00:00' from public.loads where load_number='PR-A';
insert into public.documents (entity_type, entity_id, doc_type, filename, storage_path, content_type, uploaded_at)
  select 'load', id, 'pod', 'p.jpg', 'l/b.jpg', 'image/jpeg', timestamptz '2026-07-11 08:00:00' from public.loads where load_number='PR-B';
insert into public.documents (entity_type, entity_id, doc_type, filename, storage_path, content_type, uploaded_at)
  select 'load', id, 'bol', 'p.jpg', 'l/c.jpg', 'image/jpeg', timestamptz '2026-07-10 11:00:00' from public.loads where load_number='PR-C';

-- delivered=4, captured within 12h = A + C = 2 → 50%; pod on file = 3 → 75%
select is((public.pod_capture_rate('2026-07-01','2026-08-01')->>'delivered_loads')::int, 4, 'counts delivered loads in window');
select is((public.pod_capture_rate('2026-07-01','2026-08-01')->>'captured_within')::int, 2, 'POD within 12h (early counts, late does not)');
select is((public.pod_capture_rate('2026-07-01','2026-08-01')->>'capture_rate_pct')::numeric, 50.0::numeric, '12h capture rate = 2/4');
select is((public.pod_capture_rate('2026-07-01','2026-08-01')->>'pod_on_file_pct')::numeric, 75.0::numeric, 'POD-on-file (any time) = 3/4');

-- playbook metric flipped live
select is((select status from public.playbook_metrics where number=271), 'live', 'POD capture rate metric is now live');

select * from finish();
rollback;
