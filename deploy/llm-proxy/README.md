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

> The NAS has an Intel Iris Xe iGPU (`/dev/dri/renderD128`). Standard Ollama
> can't use it (CUDA/ROCm only); Intel accel needs the IPEX-LLM SYCL build.
> Not worth it for the 3B text model. If we ever move **vision** (minicpm-v)
> local, revisit — that's where iGPU prefill would actually pay off.

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
