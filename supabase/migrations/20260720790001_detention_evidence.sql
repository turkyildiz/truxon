-- R3 #5 — detention evidence pack. eld_location_history keeps ~2 days, so
-- the dwell proof behind a detention charge EVAPORATES unless banked at
-- proposal time (same lesson as IFTA). Each proposed detention accessorial
-- now carries its exhibit: appointment, ELD arrival/departure, dwell math.
alter table public.load_accessorials
  add column if not exists evidence jsonb;

comment on column public.load_accessorials.evidence is
  'Dispute-ready proof banked at proposal time (ELD timestamps outlive the 2-day breadcrumb retention)';

-- Whole function reproduced from 20260720640001 with evidence banking added.
create or replace function public.propose_detention_accessorials(p_days int default 45)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare v_added int := 0;
begin
  if auth.uid() is not null and public.my_role() not in ('admin', 'dispatcher', 'accountant') then
    raise exception 'Not enough permissions';
  end if;
  insert into load_accessorials (load_id, atype, stop_type, amount, minutes, detail, evidence)
  select d.load_id, 'detention', d.stop_type, d.est_pay, d.detention_min,
         format('%s dwell %s min at %s — %s min over free time',
                d.stop_type, d.dwell_min, coalesce(d.stop_state, '?'), d.detention_min),
         jsonb_build_object(
           'appointment', d.appointment,
           'arrival', d.arrival,
           'departure', d.departure,
           'dwell_min', d.dwell_min,
           'free_min', d.free_min,
           'detention_min', d.detention_min,
           'stop_state', d.stop_state,
           'captured_at', now(),
           'source', 'ELD GPS breadcrumbs at the geocoded stop')
    from public.detention_events(p_days) d
   where d.est_pay > 0
  on conflict (load_id, atype, stop_type) do update
     set amount = excluded.amount, minutes = excluded.minutes, detail = excluded.detail,
         evidence = excluded.evidence
   where load_accessorials.status = 'proposed';  -- refresh frozen amounts (B-03)
  get diagnostics v_added = row_count;
  return v_added;
end;
$$;
