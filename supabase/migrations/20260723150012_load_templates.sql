-- R9 #118/#119: load templates + recurring scheduler. Repeat lanes get booked
-- from a saved template (one click instead of retyping the lane), and a
-- template with a cadence spawns its load automatically — as an honest
-- 'pending' + awaiting_paperwork draft (no invented rate con), tagged in
-- notes so dispatch knows a robot drafted it.
create table if not exists public.load_templates (
  id bigserial primary key,
  name text not null check (length(trim(name)) between 1 and 80),
  customer_id bigint references public.customers(id) on delete set null,
  equipment_type text not null default '',
  rate numeric(10,2),
  miles numeric(10,1),
  pickup_address text not null default '',
  delivery_address text not null default '',
  special_terms text not null default '',
  stops jsonb not null default '[]'::jsonb,
  -- recurrence: 'none' = plain template; weekly/biweekly spawn on cadence_dow
  cadence text not null default 'none' check (cadence in ('none','weekly','biweekly','monthly')),
  cadence_dow int check (cadence_dow between 0 and 6),
  next_run date,
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);
alter table public.load_templates enable row level security;
revoke all on public.load_templates from anon, authenticated;
grant select, insert, update, delete on public.load_templates to authenticated;
drop policy if exists lt_select on public.load_templates;
create policy lt_select on public.load_templates
  for select to authenticated using (public.my_role() in ('admin','dispatcher','accountant'));
drop policy if exists lt_write on public.load_templates;
create policy lt_write on public.load_templates
  for all to authenticated
  using (public.my_role() in ('admin','dispatcher'))
  with check (public.my_role() in ('admin','dispatcher'));
insert into app_private.security_baseline (kind, item) values
  ('grant', 'authenticated load_templates SELECT'),
  ('grant', 'authenticated load_templates INSERT'),
  ('grant', 'authenticated load_templates UPDATE'),
  ('grant', 'authenticated load_templates DELETE')
on conflict do nothing;

-- Daily spawner (pg_cron): due templates become pending drafts; next_run
-- advances by the cadence. Runs as definer; the loads trigger assigns numbers.
create or replace function public.spawn_recurring_loads()
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  t record;
  v_load_id bigint;
  spawned int := 0;
begin
  for t in select * from load_templates
            where is_active and cadence <> 'none'
              and next_run is not null and next_run <= current_date
  loop
    insert into loads (customer_id, status, rate, miles, equipment_type,
                       pickup_address, delivery_address, special_terms,
                       awaiting_paperwork, notes)
    values (t.customer_id, 'pending', coalesce(t.rate, 0), coalesce(t.miles, 0), t.equipment_type,
            t.pickup_address, t.delivery_address, t.special_terms,
            true, 'Auto-drafted from recurring template "'||t.name||'" — confirm with the broker and attach the rate con. [Template #'||t.id||']')
    returning id into v_load_id;

    insert into load_stops (load_id, stop_type, seq, facility, address)
    select v_load_id, coalesce(s->>'stop_type','pickup'), ord::int,
           coalesce(s->>'facility',''), coalesce(s->>'address','')
    from jsonb_array_elements(t.stops) with ordinality as x(s, ord);

    update load_templates
       set next_run = t.next_run + case t.cadence
             when 'weekly' then interval '7 days'
             when 'biweekly' then interval '14 days'
             else interval '1 month' end
     where id = t.id;
    spawned := spawned + 1;
  end loop;
  return jsonb_build_object('spawned', spawned, 'as_of', now());
end;
$$;
revoke all on function public.spawn_recurring_loads() from public, anon, authenticated;
grant execute on function public.spawn_recurring_loads() to service_role;

-- 06:10 daily, before dispatch starts the morning.
select cron.schedule('truxon-recurring-loads', '10 6 * * *',
  $$ select public.spawn_recurring_loads(); $$);
