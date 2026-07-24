-- R9 #160: who changed what. Inserts and status moves were already audited;
-- plain field edits were invisible. This diff trigger writes one compact
-- line per HUMAN update ("rate: 1000 → 1200; driver_id: 3 → 4") into the
-- activity_log the entity pages already render. Robot writers (QBO mirror,
-- geocoder, ELD sync — no auth.uid()) are skipped on purpose: their jobs log
-- themselves, and mirror churn would bury the human trail. Geocode stamps,
-- timestamps and status (which has richer dedicated log lines) are ignored.
create or replace function public.log_update()
returns trigger
language plpgsql security definer set search_path = public
as $$
declare
  ign text[] := array['created_at','updated_at','enriched_at','status','cancel_reason','invoice_id',
                      'pickup_lat','pickup_lon','pickup_state','delivery_lat','delivery_lon','delivery_state'];
  o jsonb := to_jsonb(old); n jsonb := to_jsonb(new);
  k text; parts text[] := '{}'; cnt int := 0;
begin
  if auth.uid() is null then return new; end if;
  for k in select jsonb_object_keys(n) loop
    if k = any(ign) then continue; end if;
    if o->k is distinct from n->k then
      cnt := cnt + 1;
      if coalesce(array_length(parts, 1), 0) < 6 then
        parts := parts || (k || ': ' || left(coalesce(o->>k, '—'), 40) || ' → ' || left(coalesce(n->>k, '—'), 40));
      end if;
    end if;
  end loop;
  if cnt = 0 then return new; end if;
  insert into activity_log (entity_type, entity_id, user_id, action, detail)
  values (tg_argv[0], (n->>'id')::bigint, auth.uid(), 'updated',
          array_to_string(parts, '; ') || case when cnt > 6 then ' (+' || (cnt - 6) || ' more)' else '' end);
  return new;
end;
$$;

-- Supersedes the 2026-07-16 loads_audit_update trigger (field NAMES only,
-- fired for robots too) — one diff line with values replaces it.
drop trigger if exists loads_audit_update on public.loads;
drop trigger if exists loads_update_audit on public.loads;
create trigger loads_update_audit after update on public.loads
  for each row when (old.* is distinct from new.*)
  execute function public.log_update('load');
drop trigger if exists customers_update_audit on public.customers;
create trigger customers_update_audit after update on public.customers
  for each row when (old.* is distinct from new.*)
  execute function public.log_update('customer');
drop trigger if exists drivers_update_audit on public.drivers;
create trigger drivers_update_audit after update on public.drivers
  for each row when (old.* is distinct from new.*)
  execute function public.log_update('driver');
drop trigger if exists trucks_update_audit on public.trucks;
create trigger trucks_update_audit after update on public.trucks
  for each row when (old.* is distinct from new.*)
  execute function public.log_update('truck');
drop trigger if exists trailers_update_audit on public.trailers;
create trigger trailers_update_audit after update on public.trailers
  for each row when (old.* is distinct from new.*)
  execute function public.log_update('trailer');
drop trigger if exists maintenance_update_audit on public.maintenance_records;
create trigger maintenance_update_audit after update on public.maintenance_records
  for each row when (old.* is distinct from new.*)
  execute function public.log_update('maintenance');
