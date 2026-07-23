---
name: user-ilker
description: Ilker Turkyildiz — solo dev/owner of Truxon TMS; machine and toolchain layout
metadata: 
  node_type: memory
  type: user
  originSessionId: a28d9126-d517-4423-90d2-26d2f9088c49
---

Ilker Turkyildiz (GitHub: turkyildiz, email turkyildiz@gmail.com) is the solo developer and business owner behind Truxon TMS ([[project-truxon]]). Ships very fast (whole product in days); appreciates honest, direct critique and lets Claude fix issues autonomously overnight.

Machine (Ubuntu 26.04 dev box, set up 2026-07-18): Flutter at `~/sdk/flutter`, Android SDK `~/sdk/android`, Supabase CLI `~/.local/bin/supabase`, Deno `~/.deno/bin/deno`, Node 24 via nvm, zsh + oh-my-zsh, VS Code + Neovim. Local Supabase DB password `postgres`, port 54322.

**New machine = the dev box now (2026-07-23, replaced the old slow-emulation box):** Ubuntu 26.04, AMD Ryzen AI 7 350 (16 threads), 28 GB RAM, ~940 GB NVMe, username `ike` (not `ilker`). Repo at `/home/ike/TRUXON`, with `~/src/truxon` symlinked to it so all documented paths still work. Memory symlink re-pointed per vault README: `~/.claude/projects/-home-ike-TRUXON/memory → /home/ike/TRUXON/vault/Memory`. Toolchain installed by Claude 2026-07-23: Flutter 3.44.7 (`~/sdk/flutter`), Temurin JDK 17 (`~/sdk/jdk17`), Android SDK (`~/sdk/android`, platforms 35+36, emulator, truxtab AVD — see [[android-emulator]]), Node 24 via nvm, Deno 2.9.4 (`~/.deno`), Supabase CLI (`~/.local/bin`); PATH exports in `~/.bashrc`. Pending owner sudo run of `~/setup-devbox-sudo.sh`: Docker (blocks local Supabase), zsh, Neovim, VS Code, Chrome, Obsidian, Flutter Linux-desktop deps, Tailscale (blocks NAS access).

**Provisioning completed 2026-07-23 (same day):** sudo script ran — Docker, zsh, Neovim, VS Code, Chrome, Obsidian, Tailscale all installed. Box joined the tailnet as **`lynxdev` (100.101.2.1)** — do not confuse with `lynx-1` (the GPU box) or `ikedev` (the old dev box, offline). NAS SSH works from here (key `ike@truxon-devbox-2026-07-23` authorized). **Signing restored ✓:** keystore at `~/dev-tools/truxon-release.jks` + `mobile/android/key.properties` (storeFile path fixed ilker→ike; both gitignored, chmod 600), cert SHA-256 verified = 3F:9D:34:BC…A5:83. NAS transfers: scp fails on UGOS — use tar-over-ssh.

**Migration COMPLETE 2026-07-23:** `google-services.json` re-downloaded by owner from Firebase console and installed (also staged for attaching to the KeePassXC vault's FCM/Firebase entry — KeePassXC 2.7.12 reinstalled here as extracted AppImage `~/Applications/keepassxc.AppDir`, no libfuse2 on this box; vault pulled from NAS to `~/dev-tools/secrets/`). Debug + release APK builds both PASS; release APK signature verified = fleet cert 3f9d34bc…a583, so OTA continuity is intact. Only remaining nit: docker group takes effect on ike's next logout/login (then `supabase start` works).
