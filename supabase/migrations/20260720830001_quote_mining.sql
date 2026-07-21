-- R3 #9 — quote capture: the CRO pipeline is empty because quotes live in
-- email. Forest already classifies them; this promotes quote observations
-- with a complete-enough extraction (locatable origin AND destination) into
-- quote_requests as 'new' drafts, so win-rate starts measuring itself.
-- Incomplete quote emails stay in the shadow feed for a human — the table's
-- locatable/reachable constraints are the quality bar, not an obstacle.
alter table public.quote_requests
  add column if not exists source_observation_id bigint unique;

create function public.mine_quote_observations()
returns int
language plpgsql security definer set search_path = public
as $$
declare v_n int;
begin
  if auth.uid() is not null and public.my_role() <> 'admin' then
    raise exception 'Not enough permissions';
  end if;
  insert into quote_requests
    (contact_name, company, email, origin_city, origin_state, origin_zip,
     dest_city, dest_state, dest_zip, equipment, pickup_date, notes, status,
     source_observation_id)
  select coalesce(nullif(o.extracted->>'contact_name', ''), nullif(o.sender_name, ''), o.sender_email),
         coalesce(o.extracted->>'company', ''),
         o.sender_email,
         coalesce(o.extracted->>'origin_city', ''),
         coalesce(o.extracted->>'origin_state', ''),
         coalesce(o.extracted->>'origin_zip', ''),
         coalesce(o.extracted->>'dest_city', ''),
         coalesce(o.extracted->>'dest_state', ''),
         coalesce(o.extracted->>'dest_zip', ''),
         coalesce(o.extracted->>'equipment', ''),
         case when (o.extracted->>'pickup_date') ~ '^\d{4}-\d{2}-\d{2}$'
              then (o.extracted->>'pickup_date')::date end,
         'From email: ' || o.subject || ' — ' || o.summary,
         'new',
         o.id
    from trux_observations o
   where o.classification = 'quote'
     and o.sender_email <> ''
     and (coalesce(o.extracted->>'origin_zip', '') <> ''
          or (coalesce(o.extracted->>'origin_city', '') <> ''
              and coalesce(o.extracted->>'origin_state', '') <> ''))
     and (coalesce(o.extracted->>'dest_zip', '') <> ''
          or (coalesce(o.extracted->>'dest_city', '') <> ''
              and coalesce(o.extracted->>'dest_state', '') <> ''))
     and not exists (select 1 from quote_requests q where q.source_observation_id = o.id)
  on conflict (source_observation_id) do nothing;
  get diagnostics v_n = row_count;
  return v_n;
end;
$$;
revoke all on function public.mine_quote_observations() from public, anon, authenticated;
grant execute on function public.mine_quote_observations() to service_role;

do $$ begin perform cron.unschedule('truxon-quote-mining'); exception when others then null; end $$;
select cron.schedule('truxon-quote-mining', '40 */2 * * *',
  $job$select public.mine_quote_observations()$job$);
