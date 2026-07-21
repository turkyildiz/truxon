-- Shadow review (Phase 3 of the dispatch shadow): the owner reviews what Trux
-- WOULD have done on dispatch@. The feed reads trux_observations directly under
-- RLS; this RPC serves the header stats in one round-trip.

create or replace function public.shadow_summary()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select case
    when auth.uid() is not null and public.my_role() not in ('admin','dispatcher')
      then null
    else (
      select jsonb_build_object(
        'total',        count(*),
        'unreviewed',   count(*) filter (where not reviewed),
        'last_7d',      count(*) filter (where created_at > now() - interval '7 days'),
        'last_email_at', max(received_at),
        'by_classification', (
          select coalesce(jsonb_object_agg(classification, n), '{}'::jsonb)
          from (select classification, count(*) n from trux_observations
                group by classification) c),
        'by_would_action', (
          select coalesce(jsonb_object_agg(would_action, n), '{}'::jsonb)
          from (select would_action, count(*) n from trux_observations
                group by would_action) a)
      )
      from trux_observations
    )
  end;
$$;

revoke all on function public.shadow_summary() from public, anon;
grant execute on function public.shadow_summary() to authenticated, service_role;
