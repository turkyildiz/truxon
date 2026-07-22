---
name: nas-local-llm
description: Self-hosted qwen2.5:3b on the NAS handles bulk doc classify/extract; token-gated proxy; cloud fallback
metadata: 
  node_type: memory
  type: project
  originSessionId: a28d9126-d517-4423-90d2-26d2f9088c49
---

Bulk, cheap text AI (document classification + field extraction) runs on a
self-hosted **qwen2.5:3b** on the NAS via Ollama, LIVE since 2026-07-21. Free,
no rate limit, data stays in-building. The agent's *reasoning* stays on the
strong cloud model; **vision stays on cloud** (local text model can't see
images).

- **Path**: edge fn → Tailscale Funnel `https://aida-nas.tail2c5ca.ts.net:8443`
  → `truxon-llm-proxy` (deploy/llm-proxy, bearer-gated, /v1/* only, host net) →
  Ollama `127.0.0.1:11434`.
- **Wiring**: `callTextLlm()` in `supabase/functions/_shared/extract_llm.ts`
  prefers `LOCAL_LLM_URL/KEY/MODEL` secrets (90s timeout for cold-load), falls
  back to cloud `callLlm` on ANY error. `doc_filing.ts` routes its two
  text-classify branches through it. `parseFields` slices first-`{`…last-`}` so
  verbose output is fine.
- **Model choice — 3B beat 7B on measurement** (NAS i5-1235U, CPU-only): 3B
  classified a rate-con in ~1.4s warm and got it right; 7B took ~32s and got it
  wrong (entity_kind "unknown"). 7B stays on disk as a fallback only.
- **CPU prefill is the real bottleneck (measured 2026-07-21):** long prompts
  process at only ~20 tok/s COLD (a ~2500-token email ≈ 120s); the identical
  prompt re-run hits the KV cache and returns in ~1.6s, but prod docs are all
  unique so it's always the cold path. Short prompts (~200 tok) stay ~1.4s.
  This blew the 150s edge-gateway timeout (dispatch-watch observe → 504). FIX:
  `callTextLlm` now length-gates — only prompts ≤ `LOCAL_LLM_MAX_CHARS`
  (default 1600) go local; longer → cloud (logs `[localllm] skip`). So local
  only handles SHORT text today; long docs/emails still use cloud. To unlock
  long-doc local: Intel iGPU via IPEX-LLM (prefill is GPU-friendly) OR Ollama
  thread tuning, THEN raise LOCAL_LLM_MAX_CHARS. Host load was ~7.5/12 during
  the test (other NAS jobs starve Ollama too).
- **iGPU parked**: NAS has Intel Iris Xe (`/dev/dri/renderD128`) but standard
  Ollama can't use it (CUDA/ROCm only); Intel accel needs the IPEX-LLM SYCL
  build. Not worth it for a 3B text model. Revisit ONLY if vision (minicpm-v)
  moves local — prefill is where iGPU would pay off.
- **Secret**: `LOCAL_LLM_KEY` == the bearer in NAS `proxy.env` (chmod 600, not
  in git). Rotate: change both, `docker compose up -d` the proxy,
  `supabase secrets set`.

Related: [[nas-access]] (NAS is the host), [[project-truxon]], [[security-posture]].
