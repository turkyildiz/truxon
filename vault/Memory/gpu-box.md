---
name: gpu-box
description: "Lynx — the RTX 5060 Ti (8 GB) GPU box for vision + local LLM; LIVE 2026-07-22 (driver 595 + Ollama tailnet-only). Separate from the ikedev laptop. SSH: ssh lynx (root@100.110.143.84)"
metadata:
  type: reference
---

The "GPU box" that Northstar/[[nas-local-llm]] were waiting on is **Lynx**, an **RTX 5060 Ti** desktop, **set up & LIVE 2026-07-22**. It is **separate** from `ikedev` — the box Claude runs on is `ikedev`, an Intel **Iris Xe iGPU** laptop (no NVIDIA).

**Hardware (verified):** RTX 5060 Ti **8 GB** variant (GB206, PCI `10de:2d04`) + Intel Arrow Lake iGPU; **Ubuntu 26.04 LTS**, kernel 7.0.0-28; 20 cores, 30 GiB RAM, 874 GB free; **Secure Boot DISABLED** (so no MOK dance — plain reboot after driver install). NOTE: it's **8 GB, not 16** — run **7B** models, not 14B. Ollama swaps models in/out on demand (`OLLAMA_KEEP_ALIVE=5m`), so vision + reasoning share the 8 GB fine one-at-a-time.

**Claude's access (LIVE):** `ssh lynx` from ikedev → `root@100.110.143.84` (tailnet IP), key `~/.ssh/lynx` (ed25519, IdentitiesOnly), key-only root login (`PermitRootLogin prohibit-password`). Config block in `~/.ssh/config`. USB bootstrap sheet the owner ran: `deploy/gpu-box/LYNX-SETUP-USB.txt`. **Gotcha:** connect via the `lynx` alias (or pass `IdentitiesOnly=yes`) — a bare `ssh -i` offers agent keys first and hits MaxAuthTries before the Lynx key.

**8 GB tuning (2026-07-22):** Ollama systemd override adds `OLLAMA_FLASH_ATTENTION=1` + `OLLAMA_KV_CACHE_TYPE=q8_0` + `OLLAMA_MAX_LOADED_MODELS=1` — flash-attn + 8-bit KV cache free enough VRAM that `qwen2.5vl:7b` runs at **num_ctx 8192** (was OOM at default). GPU **persistence mode** on via `nvidia-pm.service` (oneshot `nvidia-smi -pm 1`, enabled). `unattended-upgrades` already installed. **Vision cap:** `RASTER_DPI` stays **150** — at 200 the vision *encoder* activations (not KV) OOM the 8 GB card; the num_ctx headroom is for multi-page docs. Box is still `graphical.target` (GUI) — could go headless (`systemctl set-default multi-user.target`) to shave RAM/attack surface, GUI uses ~0 VRAM idle so low priority.

**Software installed:** NVIDIA **driver 595.71.05** (`nvidia-driver-595-open`, CUDA 13.2) — `nvidia-smi` sees the card. **Ollama 0.32.1** (systemd, enabled), bound `0.0.0.0:11434` but **firewalled tailnet-only** via `ufw` (allow OpenSSH + allow in on `tailscale0`, default-deny) → reachable only over the tailnet, never the internet/LAN. Models: `qwen2.5:7b` (reasoning) + `qwen2.5vl:7b` (vision) — both on **NVMe** (fast; 860 GB free), keep them there not on the HDD.

**Bulk storage:** a **28 TB (25.4 TB usable) external USB drive**, reformatted **ext4** (from factory exFAT) 2026-07-22, auto-mounts at **`/mnt/storage`** (fstab by UUID `a4412450-…`, `nofail` so USB loss never blocks boot; `-m 0` reclaimed the ~1.3 TB reserve). Layout: `datasets/ vision-cache/ backups/ scratch/ ollama-models/`. Use it for datasets, the vision doc cache, and local backups — **not** the live model store (that stays on NVMe for load speed). `tailnet` note: the box registered as tailscale node **`lynx-1`** (100.110.143.84); a stale `lynx` node (100.125.15.110) from first-join is offline — the `~/.ssh/config` alias hardcodes the IP so `ssh lynx` is unaffected.

**Key setup gotcha (historical):** the 5060 Ti is **Blackwell (GB206)** → needs driver **R570+**; Ubuntu 26.04 ships **595** as recommended (`-open` kernel module, required for Blackwell). Full runbook in `deploy/gpu-box/SETUP.md`.

**Truxon wiring:** front it with the existing token-gated [[nas-local-llm]] proxy; point the vision + 7B-reasoning route at `http://100.110.143.84:11434`, keep the NAS 3B for cheap bulk work. Related: [[nas-local-llm]], [[northstar-project]], [[user-ilker]], [[nas-access]].
