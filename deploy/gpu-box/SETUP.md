# RTX 5060 Ti box — setup runbook

The dedicated GPU box we parked the vision + heavier local-LLM work on (see [[nas-local-llm]], [[northstar-project]]). The **5060 Ti is NVIDIA Blackwell (GB206)** — new enough that it needs a **recent driver (R570+/575)** and **CUDA 12.8+**; anything older won't see the card.

> **Run these ON the 5060 Ti box** — not on `ikedev` (the Intel-iGPU laptop). Versions below move fast; sanity-check against current NVIDIA/Ubuntu docs. `sudo` steps are yours.

## 0. Assumptions
- Ubuntu 24.04+ (26.04 fine). 16 GB VRAM variant assumed (fits 7B–14B quantized LLMs + a vision model). If 8 GB, stick to ≤8B + smaller vision models.
- Secure Boot state: check `mokutil --sb-state`. If **enabled**, the driver install will make you set a one-time MOK password and confirm it in the blue MOK screen on reboot — or disable Secure Boot in BIOS.

## 1. NVIDIA driver (the gotcha step)
```bash
sudo apt update && sudo apt full-upgrade -y
sudo apt install -y build-essential dkms
# Preferred: let Ubuntu pick the recommended proprietary driver
sudo ubuntu-drivers list          # confirm it offers 570+/575 for the 5060 Ti
sudo ubuntu-drivers install       # or: sudo apt install nvidia-driver-575
sudo reboot                       # → on reboot: "Enroll MOK" → enter the password you set
```
If `ubuntu-drivers` is behind on Blackwell, use NVIDIA's CUDA apt repo (it carries the newest driver):
```bash
# https://developer.nvidia.com/cuda-downloads → Linux → Ubuntu → deb (network)
# then: sudo apt install cuda-drivers    (pulls the latest signed driver)
```
**Verify:**
```bash
nvidia-smi     # must show the RTX 5060 Ti, driver 570+/575, and VRAM
```
If `nvidia-smi` errors after reboot: MOK not enrolled (redo), Secure Boot blocking an unsigned module, or driver too old for Blackwell.

## 2. CUDA toolkit (optional)
Only needed if you compile CUDA code. **Ollama bundles its own CUDA runtime**, so for inference you usually just need the *driver*. If you want it:
```bash
sudo apt install -y cuda-toolkit-12-8   # match your driver; add /usr/local/cuda/bin to PATH
```

## 3. Ollama — GPU-accelerated local inference (the actual goal)
```bash
curl -fsSL https://ollama.com/install.sh | sh
systemctl status ollama            # runs as a service on :11434
# Models (16 GB VRAM):
ollama pull qwen2.5:14b            # strong general LLM, replaces the NAS qwen2.5:3b for heavy work
ollama pull qwen2.5vl:7b          # or: ollama pull minicpm-v  — the parked VISION model, now on real GPU
ollama run qwen2.5:14b "hello"    # first run should say it loaded on the GPU
nvidia-smi                        # confirm the model is resident in VRAM while running
```
Bind: by default Ollama listens on `127.0.0.1:11434`. To let the NAS/edge reach it, set `OLLAMA_HOST=0.0.0.0:11434` (systemd drop-in) **and firewall it to the Tailscale interface only** — never expose it to the internet. Keep it on the tailnet like the NAS Ollama.

## 4. Wire into Truxon
The Truxon [[nas-local-llm]] proxy fronts an Ollama endpoint (token-gated, cloud fallback). Point the heavy/vision route at this box:
- Add this box to the tailnet; note its Tailscale IP.
- In the proxy/edge config, set the vision + heavy-LLM upstream to `http://<gpu-box-tailscale-ip>:11434`.
- The **vision rate-con scan** (parked for the iGPU) now runs here fast — move `deploy/vision-enrich` to call this endpoint instead of the CPU/iGPU path.
- Keep the NAS 3B for cheap/bulk classify; use the 5060 Ti for vision + 14B reasoning.

## 5. (Optional) also a dev workstation? Full bootstrap
If this box replaces/augments `ikedev` as a dev box, reproduce it:
```bash
# toolchain
sudo apt install -y git curl unzip zsh
# Flutter, Android SDK, Deno, Node (nvm), Supabase CLI — mirror ~/sdk layout (see [[user-ilker]])
# repo
git clone git@github.com:turkyildiz/truxon.git ~/src/truxon
# re-link Claude memory into the vault (see [[obsidian-vault]])
rm -rf ~/.claude/projects/-home-ilker-DEV/memory
ln -s ~/src/truxon/vault/Memory ~/.claude/projects/-home-ilker-DEV/memory
# apps
#   Obsidian + KeePassXC AppImages (same no-sudo pattern as ~/Applications on ikedev)
# secrets
deploy/secrets/secrets-sync.sh pull     # bring the vault down; open with your master password
# restore signing key from the vault attachment (or NAS release-signing bundle)
```

## 6. Verify done
- `nvidia-smi` shows the 5060 Ti + driver 570+.
- `ollama run qwen2.5vl:7b` answers and loads in VRAM.
- The Truxon vision route hits this box (proxy log shows the GPU upstream).
- (If dev box) `supabase test db` green, memory symlink resolves.
