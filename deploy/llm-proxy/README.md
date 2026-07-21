# NAS local LLM — token-gated Ollama proxy

Self-hosted text model on the NAS (aida-nas) for high-volume, cheap AI work:
document classification and field extraction. Free, no rate limit, data stays
in-building. The agent's *reasoning* stays on the strong cloud model; only the
bulk grunt work routes here. Vision stays on cloud (the local text model can't
see images).

## Why 3B, not 7B

Measured on the NAS (i5-1235U, CPU-only) with a rate-con classify prompt:

| Model        | Warm latency | Answer                        |
|--------------|--------------|-------------------------------|
| qwen2.5:3b   | ~1.4s        | `rate_con` / `load` ✅        |
| qwen2.5:7b   | ~32s         | `rate_con` / `unknown` ❌     |

The 3B is both faster and *more* accurate on this task, so it's the shipped
model. The 7B stays on disk as a fallback. `parseFields` (extract_llm.ts)
slices the first `{` … last `}`, so verbose output is fine.

### CPU prefill is the bottleneck — length gate + thread tuning

The CPU-only NAS processes a long prompt's tokens at only ~20 tok/s COLD (a
~2500-token email ≈ 120s); short prompts finish in ~1.5s. Every prod doc is
unique, so it's always the cold path. Two mitigations, both live:

1. **Length gate** (`extract_llm.ts`): `callTextLlm` only routes to local when
   the prompt is ≤ `LOCAL_LLM_MAX_CHARS` (default 1600); longer → cloud. Keeps
   local fast, never times out the 150s edge gateway.
2. **Thread-tuned model**: default Ollama under-used the cores (~20 tok/s). A
   variant with `num_thread 8` roughly doubles prefill (~43 tok/s). Recreate it:

   ```sh
   printf 'FROM qwen2.5:3b\nPARAMETER num_thread 8\n' > /tmp/Modelfile.t8
   docker cp /tmp/Modelfile.t8 truxon-ollama:/tmp/Modelfile.t8
   docker exec truxon-ollama ollama create qwen2.5:3b-t8 -f /tmp/Modelfile.t8
   supabase secrets set LOCAL_LLM_MODEL="qwen2.5:3b-t8"
   ```
   (A copy of the Modelfile is kept at `/volume1/docker/truxon-llm-proxy/Modelfile.t8`.)

> **To unlock long-doc local classification** (raise `LOCAL_LLM_MAX_CHARS`): the
> NAS has an Intel Iris Xe iGPU (`/dev/dri/renderD128`) — prefill is exactly
> what a GPU accelerates. Standard Ollama can't use it (CUDA/ROCm only); Intel
> accel needs the IPEX-LLM SYCL build (big image + `/dev/dri` passthrough).
> Risky to swap unattended since `truxon-ollama` also serves live embeddings
> (nomic-embed-text) and vision (minicpm-v). Owner decision. Same iGPU note
> applies if vision ever moves fully local.

## Pieces

- `proxy.mjs` — zero-dep Node http proxy. Requires `Authorization: Bearer
  $LOCAL_LLM_KEY`, forwards only `/v1/*` to `OLLAMA_URL`. Everything else 404s;
  wrong/missing key 401s.
- `docker-compose.yaml` — runs it as `truxon-llm-proxy` (host network) so it
  reaches Ollama on `127.0.0.1:11434`.
- `proxy.env.example` — copy to `/volume1/docker/truxon-llm-proxy/proxy.env`
  (chmod 600) and fill in the secret. The real file is **not** in git.

## Deploy (on the NAS)

```sh
mkdir -p /volume1/docker/truxon-llm-proxy
cp proxy.mjs docker-compose.yaml /volume1/docker/truxon-llm-proxy/
cp proxy.env.example /volume1/docker/truxon-llm-proxy/proxy.env
# edit proxy.env: set LOCAL_LLM_KEY (openssl rand -hex 32)
chmod 600 /volume1/docker/truxon-llm-proxy/proxy.env
cd /volume1/docker/truxon-llm-proxy && docker compose up -d

# expose publicly for the edge functions:
docker exec truxon-tailscale tailscale funnel --bg --https=8443 11435
```

Pull the model once: `docker exec truxon-ollama ollama pull qwen2.5:3b`

## Wire the edge functions

Set Supabase secrets so `callTextLlm` (extract_llm.ts) prefers the NAS:

```sh
supabase secrets set LOCAL_LLM_URL="https://aida-nas.tail2c5ca.ts.net:8443/v1"
supabase secrets set LOCAL_LLM_KEY="<same as proxy.env>"
supabase secrets set LOCAL_LLM_MODEL="qwen2.5:3b"
```

If any of the three is unset, `callTextLlm` falls back to cloud automatically.
