-- R3 #3 — Driver NPS instrument. One of the last two not_captured gaps: a
-- quarterly 2-question survey in the driver app (0-10 + optional comment).
-- Raw rows are visible to the driver (own) and admin only; the office-facing
-- summary is aggregated and comments ride WITHOUT names, so drivers can be
-- honest without dispatch knowing who said what.
create table public.driver_nps (
  id bigint generated always as identity primary key,
  driver_user_id uuid not null references public.profiles (id) on delete cascade,
  quarter text not null,                -- e.g. 2026-Q3
  score int not null check (score between 0 and 10),
  comment text not null default '',
  created_at timestamptz not null default now(),
  unique (driver_user_id, quarter)
);
alter table public.driver_nps enable row level security;

create policy driver_nps_select on public.driver_nps
  for select to authenticated
  using (driver_user_id = auth.uid() or public.my_role() = 'admin');
create policy driver_nps_insert on public.driver_nps
  for insert to authenticated
  with check (driver_user_id = auth.uid());

grant select, insert on public.driver_nps to authenticated;

-- Aggregate view for the office: NPS math per quarter, comments anonymized.
create function public.driver_nps_summary()
returns table (
  quarter text,
  responses int,
  promoters int,
  passives int,
  detractors int,
  nps numeric,
  comments jsonb
)
language plpgsql security definer set search_path = public stable
as $$
begin
  if auth.uid() is not null and public.my_role() not in ('admin', 'dispatcher', 'accountant') then
    raise exception 'Not enough permissions';
  end if;
  return query
  select n.quarter,
         count(*)::int,
         count(*) filter (where n.score >= 9)::int,
         count(*) filter (where n.score between 7 and 8)::int,
         count(*) filter (where n.score <= 6)::int,
         round(100.0 * (count(*) filter (where n.score >= 9)
                        - count(*) filter (where n.score <= 6)) / count(*), 0),
         coalesce(jsonb_agg(n.comment order by n.created_at) filter (where n.comment <> ''), '[]'::jsonb)
  from public.driver_nps n
  group by n.quarter
  order by n.quarter desc;
end;
$$;
revoke all on function public.driver_nps_summary() from public, anon;
grant execute on function public.driver_nps_summary() to authenticated, service_role;

-- The instrument exists and the pipeline computes — playbook #537 goes live
-- (value stays null until the first quarter's responses land; that's honest).
update public.playbook_metrics
   set status = 'live', source = 'driver_nps — quarterly in-app survey (companion app)'
 where number = 537;
