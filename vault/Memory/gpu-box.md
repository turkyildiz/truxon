---
name: gpu-box
description: "Lynx — the RTX 5060 Ti (8 GB) GPU box for vision + local LLM; LIVE 2026-07-22 (driver 595 + Ollama tailnet-only). Separate from the ikedev laptop. SSH: ssh lynx (root@100.110.143.84)"
metadata:
  type: reference
---

The "GPU box" that Northstar/[[nas-local-llm]] were waiting on is **Lynx**, an **RTX 5060 Ti** desktop, **set up & LIVE 2026-07-22**. It is **separate** from `ikedev` — the box Claude runs on is `ikedev`, an Intel **Iris Xe iGPU** laptop (no NVIDIA).

**Hardware (verified):** RTX 5060 Ti **8 GB** variant (GB206, PCI `10de:2d04`) + Intel Arrow Lake iGPU; **Ubuntu 26.04 LTS**, kernel 7.0.0-28; 20 cores, 30 GiB RAM, 874 GB free; **Secure Boot DISABLED** (so no MOK dance — plain reboot after driver install). NOTE: it's **8 GB, not 16** — run **7B** models, not 14B. Ollama swaps models in/out on demand (`OLLAMA_KEEP_ALIVE=5m`), so vision + reasoning share the 8 GB fine one-at-a-time.

**Claude's access (LIVE):** `ssh lynx` from ikedev → `root@100.110.143.84` (tailnet IP), key `~/.ssh/lynx` (ed25519, IdentitiesOnly), key-only root login (`PermitRootLogin prohibit-password`). Config block in `~/.ssh/config`. USB bootstrap sheet the owner ran: `deploy/gpu-box/LYNX-SETUP-USB.txt`. **Gotcha:** connect via the `lynx` alias (or pass `IdentitiesOnly=yes`) — a bare `ssh -i` offers agent keys first and hits MaxAuthTries before the Lynx key.

**Software installed:** NVIDIA **driver 595.71.05** (`nvidia-driver-595-open`, CUDA 13.2) — `nvidia-smi` sees the card. **Ollama 0.32.1** (systemd, enabled), bound `0.0.0.0:11434` but **firewalled tailnet-only** via `ufw` (allow OpenSSH + allow in on `tailscale0`, default-deny) → reachable only over the tailnet, never the internet/LAN. Models: `qwen2.5:7b` (reasoning) + `qwen2.5vl:7b` (vision).

**Key setup gotcha (historical):** the 5060 Ti is **Blackwell (GB206)** → needs driver **R570+**; Ubuntu 26.04 ships **595** as recommended (`-open` kernel module, required for Blackwell). Full runbook in `deploy/gpu-box/SETUP.md`.

**Truxon wiring:** front it with the existing token-gated [[nas-local-llm]] proxy; point the vision + 7B-reasoning route at `http://100.110.143.84:11434`, keep the NAS 3B for cheap bulk work. Related: [[nas-local-llm]], [[northstar-project]], [[user-ilker]], [[nas-access]].
