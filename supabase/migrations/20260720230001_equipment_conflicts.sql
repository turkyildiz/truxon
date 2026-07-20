-- Resolving equipment-enrichment conflicts.
-- When a registration/title disagrees with a value already on the truck/trailer
-- record, apply_equipment_enrichment logs it as a 'conflict' and leaves the record
-- untouched. This migration gives an admin the two ways to close one out:
--   keep    — the value on file is right; dismiss the conflict, change nothing
--   accept  — the document is right; overwrite the field with the document's value
-- This is the ONE sanctioned overwrite path, and it only fires on an explicit
-- admin choice. Every resolution is stamped with who did it and which way.

alter table public.equipment_enrichment_log
  add column if not exists resolved_by uuid references auth.users (id) on delete set null,
  add column if not exists resolution text check (resolution in ('kept', 'accepted'));

-- Open conflicts, with a readable unit label and the source document's filename.
-- Admin-only; non-admins simply get no rows.
create or replace function public.equipment_conflicts()
returns table (
  log_id bigint,
  equipment_type text,
  equipment_id bigint,
  unit_number text,
  field text,
  old_value text,
  new_value text,
  source_document_id bigint,
  source_filename text,
  model text,
  created_at timestamptz
)
language sql
security definer
set search_path = public
stable
as $$
  select l.id, l.equipment_type, l.equipment_id,
         case l.equipment_type
           when 'truck' then (select t.unit_number from public.trucks t where t.id = l.equipment_id)
           else (select tr.unit_number from public.trailers tr where tr.id = l.equipment_id)
         end,
         l.field, l.old_value, l.new_value, l.source_document_id,
         (select d.filename from public.documents d where d.id = l.source_document_id),
         l.model, l.created_at
  from public.equipment_enrichment_log l
  where l.action = 'conflict' and l.resolved_at is null
    and public.my_role() = 'admin'
  order by l.created_at desc;
$$;
revoke all on function public.equipment_conflicts() from public, anon;
grant execute on function public.equipment_conflicts() to authenticated;

-- Resolve one conflict. 'accept' overwrites the field with the document's value
-- (the only place enrichment is allowed to overwrite existing data); 'keep' just
-- dismisses it. Admin-only; typed columns cast safely.
create or replace function public.resolve_equipment_conflict(p_log_id bigint, p_action text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row public.equipment_enrichment_log;
  v_table text;
  v_type text;
begin
  if public.my_role() <> 'admin' then
    raise exception 'Not enough permissions';
  end if;
  if p_action not in ('keep', 'accept') then
    raise exception 'Invalid action';
  end if;

  select * into v_row from public.equipment_enrichment_log
    where id = p_log_id and action = 'conflict' and resolved_at is null;
  if not found then
    raise exception 'Conflict not found or already resolved';
  end if;

  if p_action = 'accept' then
    if v_row.field not in ('vin', 'plate_number', 'plate_expiry', 'make', 'model', 'year') then
      raise exception 'Field not updatable';
    end if;
    v_table := case v_row.equipment_type when 'truck' then 'trucks' else 'trailers' end;
    select data_type into v_type from information_schema.columns
      where table_schema = 'public' and table_name = v_table and column_name = v_row.field;
    execute format('update public.%I set %I = $1::%s, updated_at = now() where id = $2', v_table, v_row.field, v_type)
      using v_row.new_value, v_row.equipment_id;
  end if;

  update public.equipment_enrichment_log
    set resolved_at = now(),
        resolved_by = auth.uid(),
        resolution = case p_action when 'accept' then 'accepted' else 'kept' end
    where id = p_log_id;
end;
$$;
revoke all on function public.resolve_equipment_conflict(bigint, text) from public, anon;
grant execute on function public.resolve_equipment_conflict(bigint, text) to authenticated;
