# NAS vision enrichment (scanned rate cons → customer contact fields)

Customer rate confirmations are **scanned images** — text extraction and
QuickBooks can't read the phone/contact off them, but a **vision model can**.
This runs that pass on the NAS with a **local** vision model (Ollama on the CPU)
— no external LLM key, fully private.

```
NAS                                             customer-enrich edge fn (holds DB secrets)
  ── vision_targets ─────────────────────────►  customers missing contact + signed rate-con URL
  fetch signed URL → pdftoppm → JPEG pages
  local Ollama (minicpm-v) → JSON fields
  name-match guard → apply_fields ───────────►  blanks-only write
```

**Why local:** the configured cloud LLM (Groq) has no vision model, and edge
functions can't rasterize PDFs. The NAS rasterizes with poppler and runs the
vision model itself on the i5 CPU — slow but free, private, and unattended. The
edge still holds the DB secrets (storage access + the write); the NAS holds no
API keys.

## Setup on the NAS
1. Ollama container + a vision model (one-time):
   ```
   docker run -d --name truxon-ollama --restart unless-stopped \
     -v /volume1/docker/ollama:/root/.ollama -p 127.0.0.1:11434:11434 ollama/ollama
   docker exec truxon-ollama ollama pull minicpm-v
   ```
2. `deploy/vision-enrich/vision.env` (chmod 600):
   ```
   CUSTOMER_ENRICH_URL=https://okoeeyxxvzypjiumraxq.supabase.co/functions/v1/customer-enrich
   CRON_SECRET=<the CRON_SECRET edge env>   # customer-enrich is admin/cron-gated
   SUPABASE_ANON_JWT=<public JWT-format anon token>  # sent alongside; not sufficient alone
   OLLAMA_URL=http://127.0.0.1:11434
   OLLAMA_MODEL=minicpm-v
   CARRIER=Aida Logistics LLC
   MAX_CUSTOMERS=1000
   RASTER_DPI=130
   MAX_PAGES=2
   ```
   The job authenticates with `CRON_SECRET` via the `x-cron-key` header — the
   anon JWT alone gets 401 from customer-enrich (admin/cron gate).
3. **Recommended — self-scheduling container** (survives reboot, no host cron/sudo,
   load-gated so it only runs when the NAS isn't transcoding media):
   ```
   cd /volume1/docker/truxon-vision && docker compose up -d   # truxon-vision-enrich
   ```
   `docker-compose.yaml` runs `node:18` with `--network host` and loops
   `vision-loop.sh`: install poppler once, then every 30 min run the backfill
   **only when 1-min load < 6** (Jellyfin/Plex transcoding pins the CPU and
   starves minicpm-v). Logs to `logs/vision_cron.log`.

   One-shot alternatives:
   - `node vision-enrich.mjs` on the host (node 18 + poppler are installed there).
   - `run-vision-host.sh` — same, with the load guard, for host cron.
   - `run-vision.sh` — the original playwright-container path (hit a fetch quirk
     on this box; prefer the node paths above).

**Note on speed:** minicpm-v is CPU-only here (~1–2 tok/s under load). This is an
overnight backfill. For faster throughput swap `OLLAMA_MODEL=granite3.2-vision`
(2B) in vision.env. Watch progress: `docker logs -f truxon-vision-enrich` or
`tail -f logs/vision_cron.log`; results land in `customer_enrichment_log`
(model `vision:ratecon`) and on the customers page.

## Notes
- Blanks-only + a broker name-match guard. Every fill logged to
  `customer_enrichment_log` (model `vision:ratecon:nas`).
- CPU-only vision is slow — this is an overnight backfill. Set MAX_CUSTOMERS to
  cap a run; re-run to continue (blanks-only, safe to repeat).
- Swap `OLLAMA_MODEL` for a faster/smaller model (e.g. `granite3.2-vision`) if
  the CPU is too slow, or a larger one for better OCR.
