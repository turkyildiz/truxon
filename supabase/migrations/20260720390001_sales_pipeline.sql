-- Northstar night: resurrect bids/win-rate/pipeline. The public quote-request
-- form (quote_requests) is a real sales funnel — new → quoted → won/lost — so
-- pipeline health and win rate are computable now, no new capture needed.
-- Spam is excluded from every rate. Admin/dispatcher/accountant.
create or replace function public.sales_pipeline(p_start timestamptz, p_end timestamptz)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  received int; won int; lost int; quoted_open int; new_open int; decided int;
begin
  if auth.role() <> 'service_role' and public.my_role() not in ('admin','dispatcher','accountant') then
    raise exception 'Not enough permissions';
  end if;

  -- volume received in the window (excludes spam)
  select count(*) into received from public.quote_requests
   where status <> 'spam' and created_at >= p_start and created_at < p_end;

  -- outcomes on requests received in the window
  select count(*) filter (where status='won'),
         count(*) filter (where status='lost'),
         count(*) filter (where status='quoted'),
         count(*) filter (where status='new')
    into won, lost, quoted_open, new_open
    from public.quote_requests
   where status <> 'spam' and created_at >= p_start and created_at < p_end;
  decided := won + lost;

  return jsonb_build_object(
    'quotes_received', received,
    'won', won, 'lost', lost,
    'open_new', new_open, 'open_quoted', quoted_open,
    'open_pipeline', new_open + quoted_open,
    'win_rate_pct', case when decided > 0 then round(won::numeric / decided * 100, 1) end,
    'quoted_rate_pct', case when received > 0 then round((won + lost + quoted_open)::numeric / received * 100, 1) end);
end;
$$;
revoke all on function public.sales_pipeline(timestamptz, timestamptz) from public, anon;
grant execute on function public.sales_pipeline(timestamptz, timestamptz) to authenticated;
