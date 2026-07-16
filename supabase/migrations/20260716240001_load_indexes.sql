-- Stress test (2026-07-16) flagged the loads board query (order by created_at
-- desc limit 200, with joins) as the one vector whose latency climbs under
-- concurrency. Index the ORDER BY column and the pickup date-range filter so
-- the sort/range are index-driven instead of scanning all rows each request.

create index if not exists loads_created_idx on public.loads (created_at desc);
create index if not exists loads_pickup_time_idx on public.loads (pickup_time);
