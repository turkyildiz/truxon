# NAS vision enrichment (scanned rate cons → customer contact fields)

The customer rate confirmations are **scanned images** — text extraction and
QuickBooks can't read the phone/contact off them, but **vision AI can**. This
runs that pass on the NAS: it rasterizes each customer's rate cons with poppler
and sends the page images to the `customer-enrich` edge function, which runs the
cloud vision model and fills blanks-only.

```
NAS (poppler only, NO secrets)                 customer-enrich edge fn (holds secrets)
  ── vision_targets ───────────────────────►   customers missing contact + signed rate-con URL
  fetch signed URL → pdftoppm → JPEG pages
  ── vision_apply (page images) ───────────►   cloud vision model → blanks-only write
```

**Why the NAS:** edge functions can't rasterize PDFs (no canvas), and the in-app
button is rate-limited (30/hr) + needs a browser tab open. The NAS does the
rasterizing on its CPU and runs the whole sweep unattended — no rate cap (the
`vision_*` path is cron-gated, not per-user). The NAS holds **no** secrets: the
edge function does storage access, the LLM call, and the DB write. This box only
needs the **public** anon token + `poppler-utils`.

## Setup on the NAS
1. `deploy/vision-enrich/vision.env` (chmod 600):
   ```
   CUSTOMER_ENRICH_URL=https://okoeeyxxvzypjiumraxq.supabase.co/functions/v1/customer-enrich
   SUPABASE_ANON_JWT=<public JWT-format anon token>
   MAX_CUSTOMERS=1000
   RASTER_DPI=130
   MAX_PAGES=2
   ```
2. Run it (poppler is installed into the container at runtime):
   ```
   /volume1/docker/truxon-vision/run-vision.sh
   ```
   Or wire a cron line into the truxon-scheduler crontab (blanks-only, safe to
   repeat). One-time backfill: set MAX_CUSTOMERS high and let it run.

## Notes
- Blanks-only + a broker name-match guard (a mis-filed rate con can't poison
  another customer). Every fill logged to `customer_enrichment_log`
  (model `vision:ratecon:nas`).
- Cost: ~1 cloud vision call per customer (1-2 pages). Pennies for the whole book.
- The vision model is `LLM_VISION_MODEL` on the edge (same one extract-pdf uses).
