-- R4 #9 — the Monday digest gains a "what needs you today" section built
-- from the new instruments: the top collection call, customers near/over
-- their credit limit, the fire list count, and PM alerts. Shipped before
-- today's 12:00 UTC fire so the first enriched digest is THIS morning's.
-- Whole function reproduced from 20260720690001 with the actions block.
create or replace function public.weekly_digest_observation()
returns bigint
language plpgsql
security definer
set search_path = public
as $$
declare
  fl jsonb;
  v_obs int; v_filed int; v_filled int;
  v_open int; v_crit int;
  v_summary text;
  v_actions text := '';
  v_id bigint;
  r record;
  v_fire int; v_near int; v_pm int;
begin
  if auth.uid() is not null and public.my_role() <> 'admin' then
    raise exception 'Not enough permissions';
  end if;

  fl := public.weekly_flash(-1);  -- the week that just closed (negative offsets look back)

  select count(*),
         count(*) filter (where would_detail like 'FILED:%'),
         count(*) filter (where would_detail like 'FILLED:%')
    into v_obs, v_filed, v_filled
    from trux_observations
   where created_at >= (fl->'week'->>'start')::date
     and created_at < (fl->'week'->>'start')::date + 7;

  select count(*), count(*) filter (where severity = 'critical')
    into v_open, v_crit
    from trux_insights where status = 'open';

  -- ===== what needs you today =====
  select * into r from public.collections_queue() limit 1;
  if found then
    v_actions := format('CALL FIRST: %s — $%s overdue (%s inv, oldest %sd)%s. ',
      r.company_name, round(r.overdue_total), r.overdue_count, r.oldest_days,
      case when r.phone is not null and r.phone <> '' then ', ' || r.phone else '' end);
  end if;
  select count(*) into v_fire
    from public.customer_keep_fire(365) k where k.recommendation = 'fire';
  -- only customers with work in motion — the exposure call is per-customer,
  -- so shrink the set before calling it
  select count(*) into v_near
    from (select distinct l.customer_id as cid from loads l
           where l.status in ('pending', 'assigned', 'in_transit')) ac
    cross join lateral (select public.customer_exposure(ac.cid) as e) x
   where (x.e->>'exposure')::numeric > 0.75 * (x.e->>'limit')::numeric;
  select count(*) into v_pm from public.maintenance_alerts();
  v_actions := v_actions || format('%s customers on the fire list; %s active customers past 75%% of credit limit; %s maintenance alerts.',
                                   v_fire, v_near, v_pm);

  v_summary := format(
    'Week %s: revenue %s, net %s, %s loads, collected %s, AR open %s. Forest read %s emails (%s docs filed, %s customer fields filled). Sentinel: %s open, %s critical. TODAY → %s',
    fl->'week'->>'label',
    coalesce('$' || round((fl->'ops'->>'revenue')::numeric)::text, '—'),
    coalesce('$' || round((fl->'ops'->>'net')::numeric)::text, '—'),
    coalesce(fl->'ops'->>'loads', '0'),
    coalesce('$' || round((fl->'cash'->>'collected_this_week')::numeric)::text, '—'),
    coalesce('$' || round((fl->'cash'->>'ar_outstanding')::numeric)::text, '—'),
    v_obs, v_filed, v_filled, v_open, v_crit, v_actions);

  insert into trux_observations (message_id, received_at, sender_email, sender_name,
                                 subject, classification, summary, extracted, would_action, would_detail, confidence)
  values ('digest:' || (fl->'week'->>'label'),
          now(), 'forest@truxon.com', 'Forest',
          '🌲 Weekly digest — ' || (fl->'week'->>'label'),
          'other', v_summary, fl, 'none',
          'Weekly digest. Full numbers attached in extracted.', 'high')
  on conflict (message_id) do update set summary = excluded.summary, extracted = excluded.extracted
  returning id into v_id;
  return v_id;
end;
$$;
