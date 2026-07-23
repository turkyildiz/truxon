#!/usr/bin/env bash
# Truxon dev box — USER-SPACE bootstrap. Idempotent: safe to rerun anytime.
# Prereq: bootstrap-sudo.sh ran once (git/curl/unzip/docker/tailscale present).
# Installs the full toolchain exactly as the working dev box has it, wires the
# Claude memory symlink into the vault, and preps both app trees.
#
#   bash deploy/devbox/bootstrap.sh
#
# What it deliberately does NOT do (owner-interactive; see MIGRATION.md):
# tailscale login, gh auth, NAS ssh-copy-id, secrets pull, signing restore,
# google-services.json, supabase login/link.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
log() { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }

log "git identity + ~/src/truxon symlink"
git config --global user.name  >/dev/null 2>&1 || git config --global user.name  "Ilker Turkyildiz"
git config --global user.email >/dev/null 2>&1 || git config --global user.email "turkyildiz@gmail.com"
mkdir -p ~/src && ln -sfn "$REPO" ~/src/truxon

log "Claude memory symlink → vault/Memory (survives any username/path)"
proj="$(echo "$REPO" | tr '/' '-')"                       # /home/ike/TRUXON → -home-ike-TRUXON
mkdir -p ~/.claude/projects/"$proj"
mem=~/.claude/projects/"$proj"/memory
if [ -e "$mem" ] && [ ! -L "$mem" ]; then
  echo "  merging stray local memories into the vault first…"
  cp -n "$mem"/*.md "$REPO/vault/Memory/" 2>/dev/null || true
  rm -rf "$mem"
fi
ln -sfn "$REPO/vault/Memory" "$mem"
echo "  $mem → $REPO/vault/Memory"

log "Temurin JDK 17 → ~/sdk/jdk17"
if [ ! -x ~/sdk/jdk17/bin/java ]; then
  mkdir -p ~/sdk/jdk17
  curl -fsSL "https://api.adoptium.net/v3/binary/latest/17/ga/linux/x64/jdk/hotspot/normal/eclipse" \
    | tar xzf - -C ~/sdk/jdk17 --strip-components=1
fi
~/sdk/jdk17/bin/java -version 2>&1 | head -1

log "Flutter (current stable) → ~/sdk/flutter"
if [ ! -x ~/sdk/flutter/bin/flutter ]; then
  url=$(curl -fsSL https://storage.googleapis.com/flutter_infra_release/releases/releases_linux.json \
    | python3 -c 'import json,sys; d=json.load(sys.stdin); h=d["current_release"]["stable"]; r=[x for x in d["releases"] if x["hash"]==h][0]; print(d["base_url"]+"/"+r["archive"])')
  curl -fSL "$url" | tar xJf - -C ~/sdk
fi
~/sdk/flutter/bin/flutter --version | head -1
~/sdk/flutter/bin/flutter config --no-analytics >/dev/null 2>&1 || true

log "Android SDK → ~/sdk/android (cmdline-tools, platform-tools, emulator, API 35+36, truxtab AVD)"
export JAVA_HOME=~/sdk/jdk17 ANDROID_HOME=~/sdk/android
SDKM="$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager"
if [ ! -x "$SDKM" ]; then
  mkdir -p "$ANDROID_HOME" && cd "$ANDROID_HOME"
  curl -fSLo ct.zip "https://dl.google.com/android/repository/commandlinetools-linux-13114758_latest.zip"
  unzip -q ct.zip && rm ct.zip
  mkdir -p latest.tmp && mv cmdline-tools/* latest.tmp/ && mv latest.tmp cmdline-tools/latest
  cd - >/dev/null
fi
yes | "$SDKM" --licenses >/dev/null 2>&1 || true
"$SDKM" "platform-tools" "emulator" "platforms;android-35" "platforms;android-36" \
        "build-tools;35.0.0" "build-tools;36.0.0" \
        "system-images;android-35;google_apis;x86_64" >/dev/null
if ! "$ANDROID_HOME/cmdline-tools/latest/bin/avdmanager" list avd 2>/dev/null | grep -q truxtab; then
  echo no | "$ANDROID_HOME/cmdline-tools/latest/bin/avdmanager" create avd -n truxtab \
    -k "system-images;android-35;google_apis;x86_64" -d pixel_tablet
fi
echo "  AVD: $("$ANDROID_HOME"/cmdline-tools/latest/bin/avdmanager list avd 2>/dev/null | grep -c 'Name: truxtab') truxtab present"

log "nvm + Node 24"
if [ ! -d ~/.nvm ]; then
  curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | PROFILE="$HOME/.bashrc" bash >/dev/null
fi
export NVM_DIR="$HOME/.nvm"; . "$NVM_DIR/nvm.sh"
nvm install 24 >/dev/null 2>&1 && nvm alias default 24 >/dev/null
node -v

log "Deno"
[ -x ~/.deno/bin/deno ] || curl -fsSL https://deno.land/install.sh | DENO_INSTALL="$HOME/.deno" sh -s -- -y >/dev/null 2>&1
~/.deno/bin/deno --version | head -1

log "Supabase CLI → ~/.local/bin"
mkdir -p ~/.local/bin
if [ ! -x ~/.local/bin/supabase ]; then
  v=$(curl -fsSL https://api.github.com/repos/supabase/cli/releases/latest | grep -oP '"tag_name": "\K[^"]+')
  curl -fsSL "https://github.com/supabase/cli/releases/download/$v/supabase_linux_amd64.tar.gz" \
    | tar xzf - -C ~/.local/bin supabase
fi
~/.local/bin/supabase --version

log "KeePassXC (extracted AppImage — no libfuse2 needed) → ~/Applications"
if [ ! -x ~/Applications/keepassxc.AppDir/AppRun ]; then
  mkdir -p ~/Applications && cd ~/Applications
  url=$(curl -fsSL https://api.github.com/repos/keepassxreboot/keepassxc/releases/latest \
    | grep -oP '"browser_download_url": "\K[^"]+x86_64\.AppImage(?=")' | head -1)
  curl -fsSLo kp.AppImage "$url" && chmod +x kp.AppImage
  ./kp.AppImage --appimage-extract >/dev/null && mv squashfs-root keepassxc.AppDir && rm kp.AppImage
  cd - >/dev/null
fi
printf '#!/bin/sh\nexec %s "$@"\n'     "$HOME/Applications/keepassxc.AppDir/AppRun" > ~/.local/bin/keepassxc
printf '#!/bin/sh\nexec %s cli "$@"\n' "$HOME/Applications/keepassxc.AppDir/AppRun" > ~/.local/bin/keepassxc-cli
chmod +x ~/.local/bin/keepassxc ~/.local/bin/keepassxc-cli
~/.local/bin/keepassxc-cli --version 2>&1 | tail -1

log ".bashrc toolchain block"
if ! grep -q "Truxon dev toolchain" ~/.bashrc; then
  cat >> ~/.bashrc <<'EOF'

# --- Truxon dev toolchain (bootstrap.sh) ---
export JAVA_HOME="$HOME/sdk/jdk17"
export ANDROID_HOME="$HOME/sdk/android"
export DENO_INSTALL="$HOME/.deno"
export PATH="$HOME/sdk/flutter/bin:$JAVA_HOME/bin:$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools:$ANDROID_HOME/emulator:$DENO_INSTALL/bin:$HOME/.local/bin:$PATH"
EOF
fi

log "SSH keypair (new per machine — authorize on the NAS per MIGRATION.md)"
[ -f ~/.ssh/id_ed25519 ] || ssh-keygen -t ed25519 -C "$(whoami)@truxon-devbox-$(date +%F)" -f ~/.ssh/id_ed25519 -N ""
echo "  pubkey: $(cat ~/.ssh/id_ed25519.pub)"

log "App dependencies"
( cd "$REPO/frontend" && "$NVM_DIR/versions/node/$(nvm version default)/bin/npm" install --no-audit --no-fund >/dev/null && echo "  frontend node_modules OK" )
( cd "$REPO/mobile" && ~/sdk/flutter/bin/flutter pub get >/dev/null && echo "  mobile pub OK" )
( cd "$REPO/deploy/migration-its" && "$NVM_DIR/versions/node/$(nvm version default)/bin/npm" install --no-audit --no-fund >/dev/null 2>&1 || true )

log "DONE — user-space toolchain complete"
echo "Next (owner-interactive, in order — full detail in MIGRATION.md):"
echo "  1. gh auth login --web --git-protocol https   && gh auth setup-git"
echo "  2. ssh-copy-id turkyildiz@100.89.140.98        (NAS; needs the NAS password once)"
echo "  3. bash $REPO/deploy/secrets/secrets-sync.sh pull"
echo "  4. bash $REPO/deploy/devbox/restore-signing.sh (keystore + key.properties from NAS)"
echo "  5. google-services.json: KeePassXC → Truxon/Integrations/firebase-fcm attachment → mobile/android/app/"
echo "  6. supabase login   && supabase link --project-ref okoeeyxxvzypjiumraxq"
echo "  7. verify: flutter doctor && cd mobile && ./build-apk.sh debug"
