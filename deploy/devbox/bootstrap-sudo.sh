#!/usr/bin/env bash
# Truxon dev box — ROOT half of the bootstrap. Run FIRST, once:  sudo bash bootstrap-sudo.sh
# Everything user-space (Flutter, Android SDK, Node, …) lives in bootstrap.sh — run that after.
set -euxo pipefail

apt-get update

# Editors, shell, build deps (clang..gtk = Flutter linux-desktop target)
apt-get install -y git curl unzip xz-utils zsh neovim \
  clang cmake ninja-build pkg-config libgtk-3-dev liblzma-dev

# Docker (local Supabase runs on it)
apt-get install -y docker.io docker-compose-v2
usermod -aG docker "${SUDO_USER:-$USER}"

# VS Code
snap install code --classic || true

# Chrome (skip silently if the deb isn't downloaded yet)
apt-get install -y /home/"${SUDO_USER:-$USER}"/Downloads/google-chrome-stable_current_amd64.deb 2>/dev/null || \
  echo "NOTE: Chrome deb not found in ~/Downloads — download from google.com/chrome and rerun, or skip."

# Obsidian (same deal)
apt-get install -y /home/"${SUDO_USER:-$USER}"/Downloads/obsidian_*_amd64.deb 2>/dev/null || \
  echo "NOTE: Obsidian deb not found in ~/Downloads — the vault is plain Markdown, install later if wanted."

# Tailscale — the door to the NAS and the rest of the fleet
curl -fsSL https://tailscale.com/install.sh | sh
tailscale up || true   # prints a login URL — owner opens it to join the tailnet

echo "DONE. Log out/in once (docker group). If tailscale printed a URL, open it. Then run: bash bootstrap.sh"
