-- AI worker memory (owner request 2026-07-20: "add memory to our AI workers so
-- they can be trained"). No model weights change — the system learns:
--
--   ai_corrections                ground truth captured automatically: a human
--                                 overwriting a value the AI wrote IS the lesson
--   capture_customer_correction   trigger that does the capturing (human edits
--                                 only — service writes are never corrections)
--   match_extraction_examples()   few-shot retrieval: the current document's
--                                 stored embedding → nearest documents whose
--                                 extractions were applied → their field maps.
--                                 Reuses the doc-search index; zero new
--                                 embedding calls. Gets smarter as more docs
--                                 are indexed and more extractions verified.

create table if not exists public.ai_corrections (
  id bigint generated always as identity primary key,
  entity_type text not null default 'customer',
  entity_id bigint not null,
  field text not null,
  model_value text not null,
  human_value text not null,
  model text,
  corrected_by uuid,
  created_at timestamptz not null default now()
);
create index if not exists ai_corrections_entity_idx on public.ai_corrections (entity_type, entity_id, field);
alter table public.ai_corrections enable row level security;
drop policy if exists ai_corrections_admin_read on public.ai_corrections;
create policy ai_corrections_admin_read on public.ai_corrections
  for select using (public.my_role() = 'admin');

-- ── capture: human overwrites an AI-written value → record the lesson ────────
create or replace function public.capture_customer_correction()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_cols text[] := array[
    'contact_person', 'phone', 'email', 'billing_address',
    'fax', 'toll_free', 'secondary_contact', 'secondary_phone', 'secondary_email',
    'notes', 'mc_number', 'usdot_number'
  ];
  v_col text;
  v_old text;
  v_new text;
  v_log record;
begin
  -- service-side writes (enrichment, merges, sync) are never corrections
  if auth.uid() is null then
    return new;
  end if;
  foreach v_col in array v_cols loop
    execute format('select ($1).%I, ($2).%I', v_col, v_col) into v_old, v_new using old, new;
    if coalesce(v_old, '') = coalesce(v_new, '') or coalesce(v_old, '') = '' then
      continue;
    end if;
    -- only a correction if the AI wrote the value being replaced
    select l.model, l.new_value into v_log from customer_enrichment_log l
      where l.customer_id = new.id and l.field = v_col
      order by l.id desc limit 1;
    if found and v_log.new_value = v_old then
      insert into ai_corrections (entity_type, entity_id, field, model_value, human_value, model, corrected_by)
      values ('customer', new.id, v_col, v_old, coalesce(v_new, ''), v_log.model, auth.uid());
    end if;
  end loop;
  return new;
end;
$$;
drop trigger if exists customers_capture_correction on public.customers;
create trigger customers_capture_correction
  after update on public.customers
  for each row execute function public.capture_customer_correction();

-- ── few-shot retrieval over already-indexed documents ────────────────────────
-- "Documents that read like this one, and what we correctly pulled from them."
create or replace function public.match_extraction_examples(
  p_document_id bigint,
  p_count int default 2
)
returns table (
  document_id bigint,
  customer_id bigint,
  company_name text,
  fields jsonb,
  similarity real
)
language plpgsql
security definer
set search_path = public, extensions
stable
as $$
declare
  v_emb extensions.vector(768);
begin
  if auth.uid() is not null then
    raise exception 'Not enough permissions';
  end if;
  select de.embedding into v_emb from document_embeddings de
    where de.document_id = p_document_id
    order by de.chunk_index limit 1;
  if v_emb is null then
    return; -- current doc not indexed yet: no examples, caller proceeds without
  end if;
  return query
  with candidates as (
    select de.document_id as doc_id, min(de.embedding <=> v_emb) as dist
    from document_embeddings de
    where de.document_id is not null
      and de.document_id <> p_document_id
      and exists (select 1 from customer_enrichment_log l where l.source_document_id = de.document_id)
    group by de.document_id
    order by min(de.embedding <=> v_emb)
    limit least(greatest(p_count, 1), 5)
  )
  select c.doc_id,
         max(l.customer_id),
         max(cu.company_name),
         jsonb_object_agg(l.field, l.new_value),
         (1 - c.dist)::real
  from candidates c
  join lateral (
    select distinct on (el.field) el.field, el.new_value, el.customer_id
    from customer_enrichment_log el
    where el.source_document_id = c.doc_id
    order by el.field, el.id desc
  ) l on true
  join customers cu on cu.id = l.customer_id
  group by c.doc_id, c.dist;
end;
$$;
revoke all on function public.match_extraction_examples(bigint, int) from public, anon, authenticated;
