-- R9 #124 PREP ONLY: radio transcript storage + search. The fleet radio is
-- Realtime broadcast — nothing is kept. This adds the shelf and the search,
-- NOT the recorder: no transcription job exists or is scheduled; the owner
-- has not approved recording drivers' voice traffic, and nothing here does.
-- Writes are service_role-only, so the table stays empty until that day.
create table if not exists public.radio_transcripts (
  id bigserial primary key,
  spoken_at timestamptz not null,
  channel text not null default 'fleet',
  speaker_user_id uuid,
  speaker_name text not null default '',
  duration_sec numeric(6,1),
  transcript text not null,
  lang text not null default 'en',
  fts tsvector generated always as (to_tsvector('english', transcript)) stored,
  created_at timestamptz not null default now()
);
create index if not exists radio_transcripts_fts_idx on public.radio_transcripts using gin (fts);
create index if not exists radio_transcripts_spoken_idx on public.radio_transcripts (spoken_at desc);

alter table public.radio_transcripts enable row level security;
revoke all on table public.radio_transcripts from anon, authenticated;
grant select on public.radio_transcripts to authenticated;
drop policy if exists radio_tx_select on public.radio_transcripts;
create policy radio_tx_select on public.radio_transcripts
  for select to authenticated using (public.my_role() in ('admin','dispatcher','accountant'));
insert into app_private.security_baseline (kind, item) values
  ('grant', 'authenticated radio_transcripts SELECT')
on conflict do nothing;

-- Search: websearch syntax ("detention -fuel"), newest-first within rank.
create or replace function public.search_radio_transcripts(p_query text, p_days int default 30, p_limit int default 50)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare v jsonb;
begin
  if not (coalesce(auth.role(), '') = 'service_role'
          or public.my_role() in ('admin','dispatcher','accountant')) then
    raise exception 'Not enough permissions';
  end if;
  select jsonb_build_object(
    'total_stored', (select count(*) from radio_transcripts),
    'hits', coalesce((select jsonb_agg(jsonb_build_object(
        'id', t.id, 'spoken_at', t.spoken_at, 'speaker', t.speaker_name,
        'duration_sec', t.duration_sec,
        'snippet', ts_headline('english', t.transcript, websearch_to_tsquery('english', p_query),
                               'MaxWords=30, MinWords=10, StartSel=[[, StopSel=]]'))
        order by ts_rank(t.fts, websearch_to_tsquery('english', p_query)) desc, t.spoken_at desc)
      from (select * from radio_transcripts
             where fts @@ websearch_to_tsquery('english', p_query)
               and spoken_at > now() - make_interval(days => p_days)
             order by ts_rank(fts, websearch_to_tsquery('english', p_query)) desc, spoken_at desc
             limit least(greatest(p_limit, 1), 200)) t), '[]'::jsonb),
    'as_of', now()) into v;
  return v;
end;
$$;
revoke all on function public.search_radio_transcripts(text, int, int) from public, anon, authenticated;
grant execute on function public.search_radio_transcripts(text, int, int) to authenticated, service_role;
