---
name: gpu-box
description: "Lynx — the RTX 5060 Ti GPU box (long-parked) for vision + heavier local LLM; separate from the ikedev Intel-iGPU laptop. Setup runbook in deploy/gpu-box"
metadata:
  type: reference
---

The "GPU box" that Northstar/[[nas-local-llm]] were waiting on is **Lynx**, an **RTX 5060 Ti** desktop, being set up 2026-07-22. It is **separate** from `ikedev` — the box Claude runs on is `ikedev`, an Intel **Iris Xe iGPU** laptop (TigerLake-LP, 8 cores, 14 GB, Secure Boot ON, no NVIDIA). So Claude can't configure the GPU box directly; it produces runbooks.

**Purpose:** move the parked **vision pipeline** (rate-con scan, minicpm-v — "iGPU parked for vision only") and heavier local-LLM work onto real CUDA. 16 GB VRAM (if the 16 GB variant) fits 7B–14B quantized LLMs + a vision model — a big step up from the NAS `qwen2.5:3b`.

**Key setup gotcha:** the 5060 Ti is **NVIDIA Blackwell (GB206)** → needs a **recent driver (R570+/575)** + CUDA 12.8+; older drivers won't see it. Secure Boot on the box → the driver's kernel module must be MOK-enrolled on reboot (or disable SB). Full step-by-step in `deploy/gpu-box/SETUP.md` (NVIDIA driver → optional CUDA → Ollama GPU + models → wire into the Truxon [[nas-local-llm]] proxy on the tailnet, never internet-exposed → optional dev-box bootstrap).

**Truxon wiring:** front it with the existing token-gated LLM proxy; point the vision + 14B-reasoning route at `http://<gpu-box-tailscale-ip>:11434`, keep the NAS 3B for cheap bulk work. Related: [[nas-local-llm]], [[northstar-project]], [[user-ilker]].
