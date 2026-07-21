-- R12 #9 — Monday-morning Forest digest, straight into the Shadow feed.
-- 12:00 UTC (7am local) each Monday: LAST week's flash + what Forest did all
-- week (observations by class, docs filed, fields filled) + open sentinel
-- counts, logged as one 'other'-class observation. No emails are sent —
-- the shadow ledger is the delivery channel the owner already reviews.
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
  v_id bigint;
begin
  if auth.uid() is not null and public.my_role() <> 'admin' then
    raise exception 'Not enough permissions';
  end if;

  fl := public.weekly_flash(1);  -- the week that just closed

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

  v_summary := format(
    'Week %s: revenue %s, net %s, %s loads, collected %s, AR open %s. Forest read %s emails (%s docs filed, %s customer fields filled). Sentinel: %s open, %s critical.',
    fl->'week'->>'label',
    coalesce('$' || round((fl->'ops'->>'revenue')::numeric)::text, '—'),
    coalesce('$' || round((fl->'ops'->>'net')::numeric)::text, '—'),
    coalesce(fl->'ops'->>'loads', '0'),
    coalesce('$' || round((fl->'cash'->>'collected_this_week')::numeric)::text, '—'),
    coalesce('$' || round((fl->'cash'->>'ar_outstanding')::numeric)::text, '—'),
    v_obs, v_filed, v_filled, v_open, v_crit);

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
revoke all on function public.weekly_digest_observation() from public, anon, authenticated;
grant execute on function public.weekly_digest_observation() to service_role;

do $$ begin perform cron.unschedule('truxon-weekly-digest'); exception when others then null; end $$;
select cron.schedule('truxon-weekly-digest', '0 12 * * 1',
  $job$select public.weekly_digest_observation()$job$);
