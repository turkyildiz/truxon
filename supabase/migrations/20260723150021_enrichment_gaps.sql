-- R9 #138 close-out: enrichment round 2 (docs + email mining) already runs —
-- QBO fill, doc-text fill, the 2h owner-approved mail miner, vision rate-cons
-- on click. What was missing is the honest residue: WHICH fields are still
-- blank and WHY nothing could fill them (no docs, no matched mail, no QBO
-- link). This report is that residue — the difference between "the miner ran"
-- and "the data is done".
create or replace function public.customer_enrichment_gaps()
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare v jsonb;
begin
  if not (coalesce(auth.role(), '') = 'service_role'
          or public.my_role() in ('admin','dispatcher','accountant')) then
    raise exception 'Not enough permissions';
  end if;
  with active as (
    select c.*,
           (c.contact_person = '') ::int + (c.phone = '')::int + (c.email = '')::int
             + (c.billing_address = '')::int as blanks,
           exists (select 1 from documents d where d.entity_type = 'customer' and d.entity_id = c.id) as has_docs,
           exists (select 1 from loads l join documents d on d.entity_type = 'load' and d.entity_id = l.id
                    where l.customer_id = c.id) as has_load_docs,
           exists (select 1 from trux_observations o where o.matched_customer_id = c.id) as has_mail,
           c.qbo_id is not null as has_qbo
      from customers c
     where c.is_active and not c.do_not_use
  )
  select jsonb_build_object(
    'customers_active', (select count(*) from active),
    'fully_filled', (select count(*) from active where blanks = 0),
    'blank_fields', jsonb_build_object(
      'contact_person', (select count(*) from active where contact_person = ''),
      'phone', (select count(*) from active where phone = ''),
      'email', (select count(*) from active where email = ''),
      'billing_address', (select count(*) from active where billing_address = '')),
    'worklist', coalesce((select jsonb_agg(jsonb_build_object(
        'customer_id', a.id, 'customer', a.company_name, 'blanks', a.blanks,
        'sources_left', array_remove(array[
          case when not a.has_docs and not a.has_load_docs then null else 'docs (mined or minable)' end,
          case when a.has_mail then 'mail (observed)' end,
          case when a.has_qbo then 'qbo (linked)' end], null),
        'dead_end', not (a.has_docs or a.has_load_docs or a.has_mail or a.has_qbo))
        order by a.blanks desc, a.company_name)
      from active a where a.blanks > 0), '[]'::jsonb),
    'dead_ends', (select count(*) from active a
                   where a.blanks > 0 and not (a.has_docs or a.has_load_docs or a.has_mail or a.has_qbo)),
    'note', 'dead_end = blanks remain and NO source exists to mine (no docs on them or their loads, no observed mail, no QBO link) — those need a phone call, not more AI',
    'as_of', now()) into v;
  return v;
end;
$$;
revoke all on function public.customer_enrichment_gaps() from public, anon, authenticated;
grant execute on function public.customer_enrichment_gaps() to authenticated, service_role;
