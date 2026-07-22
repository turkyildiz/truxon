-- The decoy views execute their backing functions with the CALLER's
-- privileges (view ownership confers table access, not function EXECUTE),
-- so the API roles need execute or the decoy returns "permission denied"
-- instead of serving fakes. Side bonus: the functions also become
-- /rpc/_hp_* endpoints, and RPC calls run in read-write transactions —
-- those probes get the full-capture direct path.
grant execute on function public._hp_api_keys() to anon, authenticated, service_role;
grant execute on function public._hp_bank_accounts() to anon, authenticated, service_role;
