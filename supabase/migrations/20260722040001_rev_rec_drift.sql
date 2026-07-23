-- R9 #35: revenue-recognition drift. Per month: revenue by DELIVERY date
-- (earned) vs revenue by INVOICE date (booked), plus the loads billed in a
-- different month than they delivered — the reason a "great month" on the
-- books can be last month's freight.
create or replace function public.rev_rec_drift(p_months int default 6)
returns jsonb
language sql stable security definer set search_path = public
as $$
  select case when auth.role() = 'service_role' or public.my_role() in ('admin','accountant')
  then jsonb_build_object(
    'months', coalesce((select jsonb_agg(jsonb_build_object(
        'month', m.mo,
        'delivered', coalesce(d.amt, 0), 'delivered_loads', coalesce(d.n, 0),
        'invoiced', coalesce(i.amt, 0),
        'cross_month_loads', coalesce(x.n, 0), 'cross_month_amount', coalesce(x.amt, 0))
        order by m.mo)
      from (select to_char(date_trunc('month', current_date) - make_interval(months => g), 'YYYY-MM') mo
              from generate_series(0, greatest(p_months, 1) - 1) g) m
      left join (select to_char(date_trunc('month', l.delivery_time), 'YYYY-MM') mo,
                        count(*) n, round(sum(l.rate), 2) amt
                   from loads l
                  where l.status in ('completed','billed') and l.delivery_time is not null
                  group by 1) d on d.mo = m.mo
      left join (select to_char(date_trunc('month', i.invoice_date), 'YYYY-MM') mo,
                        round(sum(i.total), 2) amt
                   from invoices i where i.status <> 'void'
                  group by 1) i on i.mo = m.mo
      left join (select to_char(date_trunc('month', l.delivery_time), 'YYYY-MM') mo,
                        count(*) n, round(sum(l.rate), 2) amt
                   from loads l
                   join invoices inv on inv.id = l.invoice_id and inv.status <> 'void'
                  where l.delivery_time is not null
                    and date_trunc('month', inv.invoice_date) <> date_trunc('month', l.delivery_time)
                  group by 1) x on x.mo = m.mo), '[]'::jsonb),
    'as_of', now())
  end;
$$;
revoke all on function public.rev_rec_drift(int) from public, anon;
grant execute on function public.rev_rec_drift(int) to authenticated, service_role;
