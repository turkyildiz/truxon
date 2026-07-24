---
name: frontend-build-check
description: "Verify frontend with `npm run build` (tsc -b), NOT `tsc --noEmit` — the latter is a no-op against the solution tsconfig and lets broken builds reach Vercel"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 4b4fd76a-1f63-4724-97f4-f2aa2d6ed5cc
  modified: 2026-07-24T13:06:04.505Z
---

`frontend/tsconfig.json` is a references-only **solution file** (it lists `references` to tsconfig.app.json + tsconfig.node.json and includes no files of its own). Running `npx tsc --noEmit` against it compiles **zero files and exits 0** — it verifies nothing.

The real check, and exactly what Vercel runs on deploy, is `npm run build` = **`tsc -b && vite build`**. Always verify frontend changes with `cd frontend && npm run build`.

**Why:** On 2026-07-24 ~15 "tsc-ok" checks this session were no-ops while the actual build was broken — a `Connecting to db 5432` line the Supabase CLI leaked into `database.types.ts` (from `gen types > file`; the message goes to stdout) plus 9 accumulated type errors. Every Vercel deploy failed for ~9h (error-email flood). The live site stayed up on the last-good build (Vercel keeps a working deploy when a new one fails), so no customer impact, but production was frozen. Fixed in commit `6049c03`.

**How to apply:** (1) after ANY frontend edit, run `npm run build`, not `tsc --noEmit`. (2) After `supabase gen types typescript --local > frontend/src/database.types.ts`, check `head -1` — strip any leading `Connecting to db …` line the CLI leaks in. Related: [[project-truxon]].
