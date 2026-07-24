-- R9 #130/#136: customer onboarding checklist + prospect tracker.
-- #130 customer_onboarding_report: the setup list a new broker actually needs
--   — contact, billing, terms, authority numbers, FMCSA vet (read from
--   customer_fmcsa_checks, never re-fetched here), setup paperwork on file,
--   first invoice paid. Each item says what's missing, not just a red X.
-- #136 prospects: the leads shelf. Manual adds (or future miners) park here
--   with MC/DOT; convert_prospect() promotes one to a real customer row and
--   remembers the link. FMCSA vet fields exist but honest-empty until a vet
--   actually runs.
create or replace function public.customer_onboarding_report(p_customer_id bigint)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare
  c customers;
  v_fmcsa customer_fmcsa_checks;
  items jsonb := '[]'::jsonb;
begin
  if not (coalesce(auth.role(), '') = 'service_role'
          or public.my_role() in ('admin','dispatcher','accountant')) then
    raise exception 'Not enough permissions';
  end if;
  select * into c from customers where id = p_customer_id;
  if not found then raise exception 'Customer not found'; end if;
  select * into v_fmcsa from customer_fmcsa_checks where customer_id = p_customer_id;

  items := items || jsonb_build_object('item', 'Contact on file', 'ok', c.email <> '' or c.phone <> '',
    'detail', case when c.email = '' and c.phone = '' then 'no email or phone' else trim(both ' ·' from c.email || ' · ' || c.phone) end);
  items := items || jsonb_build_object('item', 'Billing address', 'ok', c.billing_address <> '',
    'detail', coalesce(nullif(c.billing_address, ''), 'missing'));
  items := items || jsonb_build_object('item', 'Payment terms', 'ok', c.payment_terms <> '',
    'detail', coalesce(nullif(c.payment_terms, ''), 'not set'));
  items := items || jsonb_build_object('item', 'MC / USDOT recorded', 'ok', c.mc_number <> '' or c.usdot_number <> '',
    'detail', case when c.mc_number = '' and c.usdot_number = '' then 'neither number on file'
                   else trim(both ' ·' from 'MC ' || c.mc_number || ' · DOT ' || c.usdot_number) end);
  items := items || jsonb_build_object('item', 'FMCSA vetted', 'ok',
    v_fmcsa.customer_id is not null and v_fmcsa.allowed_to_operate = 'Y'
      and v_fmcsa.oos_date is null and v_fmcsa.name_match,
    'detail', case
      when v_fmcsa.customer_id is null then 'never checked — weekly watcher covers customers with numbers on file'
      when v_fmcsa.allowed_to_operate <> 'Y' then 'FMCSA says NOT allowed to operate'
      when v_fmcsa.oos_date is not null then 'out-of-service date on record: ' || v_fmcsa.oos_date
      when not v_fmcsa.name_match then 'FMCSA legal name does not match ours (' || v_fmcsa.legal_name || ')'
      else 'clear as of ' || to_char(v_fmcsa.checked_at, 'Mon DD') end);
  items := items || jsonb_build_object('item', 'Setup paperwork on file', 'ok',
    exists (select 1 from documents d where d.entity_type = 'customer' and d.entity_id = p_customer_id
              and d.doc_type in ('Contract', 'Rate Agreement')),
    'detail', coalesce((select string_agg(distinct d.doc_type, ', ') from documents d
      where d.entity_type = 'customer' and d.entity_id = p_customer_id), 'no documents at all'));
  items := items || jsonb_build_object('item', 'First invoice paid', 'ok',
    exists (select 1 from invoices i where i.customer_id = p_customer_id and i.status = 'paid'),
    'detail', case when exists (select 1 from invoices i where i.customer_id = p_customer_id and i.status = 'paid')
                   then 'payment relationship proven'
                   when exists (select 1 from invoices i where i.customer_id = p_customer_id)
                   then 'invoiced, none paid yet' else 'no invoices yet' end);

  return jsonb_build_object(
    'customer', c.company_name,
    'items', items,
    'done', (select count(*) from jsonb_array_elements(items) x where (x->>'ok')::boolean),
    'total', jsonb_array_length(items),
    'as_of', now());
end;
$$;
revoke all on function public.customer_onboarding_report(bigint) from public, anon, authenticated;
grant execute on function public.customer_onboarding_report(bigint) to authenticated, service_role;

create table if not exists public.prospects (
  id bigserial primary key,
  company_name text not null check (length(trim(company_name)) between 1 and 120),
  contact_person text not null default '',
  email text not null default '',
  phone text not null default '',
  mc_number text not null default '',
  usdot_number text not null default '',
  source text not null default 'manual',
  status text not null default 'new' check (status in ('new','contacted','quoting','converted','dead')),
  notes text not null default '',
  fmcsa_checked_at timestamptz,
  fmcsa_ok boolean,
  fmcsa_note text not null default '',
  converted_customer_id bigint references public.customers(id) on delete set null,
  created_at timestamptz not null default now()
);
alter table public.prospects enable row level security;
revoke all on table public.prospects from anon, authenticated;
grant select, insert, update, delete on public.prospects to authenticated;
drop policy if exists prospects_select on public.prospects;
create policy prospects_select on public.prospects
  for select to authenticated using (public.my_role() in ('admin','dispatcher','accountant'));
drop policy if exists prospects_write on public.prospects;
create policy prospects_write on public.prospects
  for all to authenticated
  using (public.my_role() in ('admin','dispatcher'))
  with check (public.my_role() in ('admin','dispatcher'));
insert into app_private.security_baseline (kind, item) values
  ('grant', 'authenticated prospects SELECT'),
  ('grant', 'authenticated prospects INSERT'),
  ('grant', 'authenticated prospects UPDATE'),
  ('grant', 'authenticated prospects DELETE')
on conflict do nothing;

-- Promote a prospect to a customer (or link to an existing same-name one).
create or replace function public.convert_prospect(p_id bigint)
returns bigint
language plpgsql security definer set search_path = public
as $$
declare p prospects; cid bigint;
begin
  if public.my_role() not in ('admin','dispatcher') then
    raise exception 'Not enough permissions';
  end if;
  select * into p from prospects where id = p_id for update;
  if not found then raise exception 'Prospect not found'; end if;
  if p.converted_customer_id is not null then return p.converted_customer_id; end if;

  select id into cid from customers
   where lower(trim(company_name)) = lower(trim(p.company_name)) limit 1;
  if cid is null then
    insert into customers (company_name, contact_person, email, phone, mc_number, usdot_number, notes)
    values (p.company_name, p.contact_person, p.email, p.phone, p.mc_number, p.usdot_number,
            case when p.notes <> '' then 'From prospect tracker: ' || p.notes else '' end)
    returning id into cid;
  end if;
  update prospects set status = 'converted', converted_customer_id = cid where id = p_id;
  return cid;
end;
$$;
revoke all on function public.convert_prospect(bigint) from public, anon, authenticated;
grant execute on function public.convert_prospect(bigint) to authenticated;
