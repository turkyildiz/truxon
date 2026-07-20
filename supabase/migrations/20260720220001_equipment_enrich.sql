-- Equipment enrichment from documents.
-- Forest reads a registration/title emailed in, files it under the truck/trailer
-- (already built), and now also harvests the fields off the page — VIN, plate #,
-- plate expiration, make/model/year — and fills any that are BLANK on the record.
-- This migration is the WRITE CHOKE-POINT, mirroring apply_customer_enrichment:
--   (a) only ever fills EMPTY columns, (b) never touches unit_number (the
--   identity), (c) NEVER overwrites an existing value — a document that disagrees
--   with data on file is logged as a 'conflict' for a human to resolve, not applied,
--   and (d) logs every fill and every conflict with its source document.
--
--   equipment_enrichment_log     per-field provenance + conflicts
--   trucks/trailers.enriched_at  last time enrichment filled anything
--   apply_equipment_enrichment(type, id, fields, source_doc, model) -> {filled, conflicts}

alter table public.trucks   add column if not exists enriched_at timestamptz;
alter table public.trailers add column if not exists enriched_at timestamptz;

create table if not exists public.equipment_enrichment_log (
  id bigint generated always as identity primary key,
  equipment_type text not null check (equipment_type in ('truck', 'trailer')),
  equipment_id bigint not null,
  field text not null,
  old_value text,
  new_value text not null,
  action text not null check (action in ('filled', 'conflict')),
  source_document_id bigint references public.documents (id) on delete set null,
  model text,
  resolved_at timestamptz,      -- admin acknowledges/clears a conflict
  created_at timestamptz not null default now()
);
create index if not exists equipment_enrichment_log_equip_idx
  on public.equipment_enrichment_log (equipment_type, equipment_id);
create index if not exists equipment_enrichment_log_open_conflict_idx
  on public.equipment_enrichment_log (created_at)
  where action = 'conflict' and resolved_at is null;
alter table public.equipment_enrichment_log enable row level security;

-- Admins read the audit trail and clear conflicts; only the service-side RPC writes.
drop policy if exists equipment_enrichment_log_admin_read on public.equipment_enrichment_log;
create policy equipment_enrichment_log_admin_read on public.equipment_enrichment_log
  for select using (public.my_role() = 'admin');
drop policy if exists equipment_enrichment_log_admin_resolve on public.equipment_enrichment_log;
create policy equipment_enrichment_log_admin_resolve on public.equipment_enrichment_log
  for update using (public.my_role() = 'admin') with check (public.my_role() = 'admin');

-- ── the single write path ────────────────────────────────────────────────────
-- Fills only-empty, allow-listed columns from p_fields; logs each fill; logs (but
-- does NOT apply) any value that disagrees with existing data; stamps enriched_at.
-- unit_number is deliberately NOT allow-listed. Handles typed columns (year int,
-- plate_expiry date): an unparseable value is skipped, never allowed to error the
-- whole batch. Called by the trux-inbox edge function with the service role.
create or replace function public.apply_equipment_enrichment(
  p_equipment_type text,
  p_equipment_id bigint,
  p_fields jsonb,
  p_source_document_id bigint default null,
  p_model text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_allowed text[] := array['vin', 'plate_number', 'plate_expiry', 'make', 'model', 'year'];
  v_table text;
  v_key text;
  v_type text;
  v_val text;      -- incoming value (text)
  v_new text;      -- incoming value normalized through the column's type
  v_cur text;      -- current stored value as text
  v_filled int := 0;
  v_conflicts int := 0;
begin
  if auth.uid() is not null then
    raise exception 'Not enough permissions';
  end if;
  if p_equipment_type not in ('truck', 'trailer') or p_equipment_id is null or p_fields is null then
    return jsonb_build_object('filled', 0, 'conflicts', 0);
  end if;
  v_table := case p_equipment_type when 'truck' then 'trucks' else 'trailers' end;

  for v_key in select jsonb_object_keys(p_fields) loop
    if not (v_key = any (v_allowed)) then
      continue;   -- allow-list guard: unit_number, id, anything else ignored
    end if;
    v_val := nullif(btrim(coalesce(p_fields ->> v_key, '')), '');
    if v_val is null then
      continue;
    end if;

    select data_type into v_type
      from information_schema.columns
      where table_schema = 'public' and table_name = v_table and column_name = v_key;
    if v_type is null then
      continue;
    end if;

    -- normalize the incoming value through the column's type; a bad value
    -- (e.g. a plate_expiry that isn't a real date) is skipped, not fatal
    begin
      execute format('select ($1::%s)::text', v_type) into v_new using v_val;
    exception when others then
      continue;
    end;
    if v_new is null or btrim(v_new) = '' then
      continue;
    end if;

    execute format('select %I::text from public.%I where id = $1', v_key, v_table)
      into v_cur using p_equipment_id;

    if coalesce(btrim(v_cur), '') = '' then
      -- blank → fill it
      execute format('update public.%I set %I = $1::%s, updated_at = now() where id = $2', v_table, v_key, v_type)
        using v_val, p_equipment_id;
      insert into public.equipment_enrichment_log
        (equipment_type, equipment_id, field, old_value, new_value, action, source_document_id, model)
        values (p_equipment_type, p_equipment_id, v_key, v_cur, v_new, 'filled', p_source_document_id, p_model);
      v_filled := v_filled + 1;
    elsif lower(btrim(v_cur)) <> lower(btrim(v_new)) then
      -- already has a value and the document disagrees → flag, never overwrite
      insert into public.equipment_enrichment_log
        (equipment_type, equipment_id, field, old_value, new_value, action, source_document_id, model)
        values (p_equipment_type, p_equipment_id, v_key, v_cur, v_new, 'conflict', p_source_document_id, p_model);
      v_conflicts := v_conflicts + 1;
    end if;
    -- else: already matches — nothing to do
  end loop;

  if v_filled > 0 then
    execute format('update public.%I set enriched_at = now() where id = $1', v_table) using p_equipment_id;
  end if;
  return jsonb_build_object('filled', v_filled, 'conflicts', v_conflicts);
end;
$$;

revoke all on function public.apply_equipment_enrichment(text, bigint, jsonb, bigint, text) from public, anon, authenticated;
