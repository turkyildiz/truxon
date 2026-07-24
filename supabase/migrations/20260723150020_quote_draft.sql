-- R9 #128: auto quote-response drafts — PROPOSE-ONLY. For a quote request,
-- pull our own lane history (recent book first, full year as fallback), fold
-- in the pricing lesson from won/lost premiums (#129), and hand the
-- dispatcher a suggested rate + a reply draft. Nothing sends; the human
-- quotes. No lane history = says so plainly, never invents a number.
create or replace function public.draft_quote_response(p_quote_id bigint)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare
  q quote_requests;
  v_o text; v_d text;
  n90 int; avg90 numeric; n365 int; avg365 numeric; rpm365 numeric;
  won_prem numeric; lost_prem numeric;
  base numeric; suggested numeric; basis text;
  draft text;
begin
  if public.my_role() not in ('admin','dispatcher') then
    raise exception 'Not enough permissions';
  end if;
  select * into q from quote_requests where id = p_quote_id;
  if not found then raise exception 'Quote not found'; end if;
  v_o := upper(trim(q.origin_state)); v_d := upper(trim(q.dest_state));

  if v_o <> '' and v_d <> '' then
    select count(*), round(avg(rate), 0) into n90, avg90 from loads
     where status in ('completed','billed') and upper(pickup_state) = v_o and upper(delivery_state) = v_d
       and created_at > now() - interval '90 days';
    select count(*), round(avg(rate), 0),
           round(sum(rate) / nullif(sum(miles) filter (where miles > 0), 0), 2)
      into n365, avg365, rpm365 from loads
     where status in ('completed','billed') and upper(pickup_state) = v_o and upper(delivery_state) = v_d
       and created_at > now() - interval '365 days';
  end if;

  select round(avg((qq.quoted_rate - la.a) / la.a * 100), 1)
    into won_prem
    from quote_requests qq
    join lateral (select avg(l.rate) a from loads l
                   where l.status in ('completed','billed')
                     and upper(l.pickup_state) = upper(qq.origin_state)
                     and upper(l.delivery_state) = upper(qq.dest_state)) la on la.a > 0
   where qq.status = 'won' and qq.quoted_rate is not null;
  select round(avg((qq.quoted_rate - la.a) / la.a * 100), 1)
    into lost_prem
    from quote_requests qq
    join lateral (select avg(l.rate) a from loads l
                   where l.status in ('completed','billed')
                     and upper(l.pickup_state) = upper(qq.origin_state)
                     and upper(l.delivery_state) = upper(qq.dest_state)) la on la.a > 0
   where qq.status = 'lost' and qq.quoted_rate is not null;

  if coalesce(n90, 0) >= 3 then base := avg90; basis := n90 || ' loads on this lane in the last 90 days';
  elsif coalesce(n365, 0) >= 1 then base := avg365; basis := n365 || ' loads on this lane in the last year';
  end if;
  if base is not null then
    if won_prem is not null and won_prem between -20 and 20 then
      suggested := round(base * (1 + won_prem / 100) / 25) * 25;
    else
      suggested := round(base / 25) * 25;
    end if;
    draft := 'Hi ' || split_part(trim(q.contact_name), ' ', 1) || ',' || E'\n\n'
      || 'Thanks for reaching out about ' || coalesce(nullif(q.origin_city,''), q.origin_zip) || ', ' || v_o
      || ' to ' || coalesce(nullif(q.dest_city,''), q.dest_zip) || ', ' || v_d
      || case when q.equipment <> '' then ' (' || q.equipment || ')' else '' end
      || case when q.pickup_date is not null then ' picking up ' || to_char(q.pickup_date, 'Mon DD') else '' end || '.'
      || E'\n\n' || 'We can cover this for $' || suggested::int
      || ' all-in. We run this lane regularly (' || basis || ') and can share references on request.'
      || E'\n\n' || 'Rate is good for 48 hours — reply or call and we''ll get it booked.'
      || E'\n\n' || 'Aida Logistics dispatch';
  end if;

  return jsonb_build_object(
    'quote_id', p_quote_id,
    'lane', case when v_o <> '' and v_d <> '' then v_o || '→' || v_d end,
    'basis', jsonb_build_object('loads_90d', coalesce(n90, 0), 'avg_90d', avg90,
                                'loads_365d', coalesce(n365, 0), 'avg_365d', avg365, 'rpm_365d', rpm365),
    'pricing_lesson', jsonb_build_object('won_avg_premium_pct', won_prem, 'lost_avg_premium_pct', lost_prem),
    'suggested_rate', suggested,
    'draft_text', draft,
    'no_history', base is null,
    'note', case when base is null
      then 'No booked history on this lane (or states unknown) — price it by hand; nothing was invented.'
      else 'Propose-only: suggested = our lane average' ||
           case when won_prem is not null and won_prem between -20 and 20
                then ' adjusted by the won-quote premium (' || won_prem || '%)' else '' end
           || ', rounded to $25. The human quotes.' end,
    'as_of', now());
end;
$$;
revoke all on function public.draft_quote_response(bigint) from public, anon, authenticated;
grant execute on function public.draft_quote_response(bigint) to authenticated;
