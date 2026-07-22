-- Live run linked only 5/26: DriveHOS rosters names as "Last First Middle"
-- ("Johnson Rodney Tremaine") while Truxon holds "Rodney Tremaine Johnson",
-- and sometimes carries an extra middle name ("Bridges Siera Tempra" vs
-- "Siera Bridges"). Order-insensitive fix: match on the SET of name words —
-- equal sets, or every Truxon word present in the ELD name — but only when
-- exactly one driver qualifies (ambiguity links nothing). Fills NULLs only.
-- ("Charles Sutton" stays unlinked: the Truxon row says "Sultton" — that's a
-- typo for the data-hygiene queue, not something name-matching should paper
-- over.)
create or replace function public.eld_link_drivers()
returns int
language plpgsql security definer set search_path = public
as $$
declare n int := 0;
begin
  with ed_words as (
    select ed.driver_id,
           (select array_agg(w order by w) from unnest(string_to_array(
              lower(regexp_replace(trim(coalesce(ed.first_name,'')||' '||coalesce(ed.last_name,'')), '\s+', ' ', 'g')), ' ')) w
             where w <> '') as words
      from public.eld_drivers ed
     where ed.matched_driver_id is null
  ), d_words as (
    select d.id,
           (select array_agg(w order by w) from unnest(string_to_array(
              lower(regexp_replace(trim(d.full_name), '\s+', ' ', 'g')), ' ')) w
             where w <> '') as words
      from public.drivers d
  ), cand as (
    select e.driver_id, d.id as truxon_id,
           count(*) over (partition by e.driver_id) as n_cand
      from ed_words e
      join d_words d
        on array_length(d.words, 1) >= 2
       and (d.words = e.words or d.words <@ e.words)
  )
  update public.eld_drivers ed
     set matched_driver_id = c.truxon_id
    from cand c
   where ed.driver_id = c.driver_id and c.n_cand = 1;
  get diagnostics n = row_count;
  return n;
end;
$$;
revoke all on function public.eld_link_drivers() from public, anon;
grant execute on function public.eld_link_drivers() to service_role;

select public.eld_link_drivers();
