-- "Awaiting paperwork" — a load can be booked/covered on preliminary paperwork
-- before the signed rate con + final stops arrive (owner: load 1169 case). This
-- is a real freight state, first-classed so dispatch sees booked-not-ready at a
-- glance and Trux can chase the missing docs. Orthogonal to load status — a
-- pending OR assigned load can be awaiting paperwork.

alter table public.loads add column if not exists awaiting_paperwork boolean not null default false;
create index if not exists loads_awaiting_paperwork_idx on public.loads (awaiting_paperwork) where awaiting_paperwork;

-- Toggle it without tripping the load-edit guard (which blocks bare updates on
-- billed loads and auto-flips pending→assigned). SECURITY DEFINER + the load_rpc
-- GUC = this one column moves, nothing else. Admin/dispatcher only.
create or replace function public.set_load_paperwork(p_id bigint, p_awaiting boolean)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_old boolean;
begin
  if public.my_role() not in ('admin', 'dispatcher') then
    raise exception 'Not enough permissions';
  end if;
  select awaiting_paperwork into v_old from loads where id = p_id;
  if not found then raise exception 'Load % not found', p_id; end if;
  if v_old is not distinct from p_awaiting then return; end if;
  perform set_config('app.load_rpc', '1', true);
  update loads set awaiting_paperwork = p_awaiting, updated_at = now() where id = p_id;
  perform set_config('app.load_rpc', '', true);
  insert into activity_log (entity_type, entity_id, user_id, action, detail)
    values ('load', p_id, auth.uid(), 'paperwork',
            case when p_awaiting then 'flagged awaiting final paperwork'
                 else 'final paperwork received' end);
end;
$$;
revoke all on function public.set_load_paperwork(bigint, boolean) from public, anon;
