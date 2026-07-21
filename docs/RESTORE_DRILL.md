# Restore drill — db-backups bucket

The nightly `db-backup` edge function (03:37 UTC) dumps 26 tables as gzipped
JSON to the private `db-backups` bucket, one folder per UTC date, 30-day
retention. **A backup nobody has restored is a hope, not a backup** — this
drill was first run 2026-07-21 (UTC) and passed: 26/26 tables decompress and
parse, row counts match live within same-day drift, and a full table restored
into the real schema.

## Verify a backup (no writes)

```python
# service key required; list folders then files
POST {SUPABASE_URL}/storage/v1/object/list/db-backups   {"prefix": "", "limit": 10}
POST .../list/db-backups                                {"prefix": "<date>", "limit": 40}
GET  .../object/db-backups/<date>/<table>.json.gz       # then gunzip + json.loads
```

Compare `len(rows)` against live: `GET /rest/v1/<table>?limit=1` with
`Prefer: count=exact` and read the `Content-Range` total.

## Restore a table

```sql
begin;
create temp table _dump (j jsonb);
\copy _dump from program 'cat /path/table.json' csv quote e'\x01' delimiter e'\x02'
insert into public.<table> overriding system value
  select r.* from _dump d,
  lateral jsonb_populate_recordset(null::public.<table>, d.j) r;
-- verify count, then commit (or rollback for a drill)
commit;
```

**Lessons the first drill caught:**
- `overriding system value` is REQUIRED — most tables use
  `generated always as identity` and refuse explicit ids without it.
- After restoring, bump each identity sequence:
  `select setval(pg_get_serial_sequence('public.<table>', 'id'), (select max(id) from public.<table>));`
- Restore parents before children (customers → loads → invoices →
  invoice_payments → load_accessorials) or defer FK checks.

Re-run this drill quarterly or after any backup-pipeline change.
