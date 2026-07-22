#!/usr/bin/env bash
# Snapshot the vault (memory + rules + reports) to git so nothing is ever lost.
# Memory writes land in vault/Memory/ via the symlink; this commits + pushes them.
# Usage:  vault/save.sh ["optional commit message"]
set -euo pipefail
cd "$(dirname "$0")/.."          # repo root (~/src/truxon)

if git diff --quiet -- vault && git diff --cached --quiet -- vault \
   && [ -z "$(git ls-files --others --exclude-standard -- vault)" ]; then
  echo "vault: nothing to save (already committed)."
  exit 0
fi

MSG="${1:-vault: memory snapshot $(date +%F' '%H:%M)}"
git add -A vault
git commit -q -m "$MSG"
echo "committed: $MSG"
if git remote get-url origin >/dev/null 2>&1; then
  git push -q origin HEAD && echo "pushed to origin ✓ (off-box backup)"
else
  echo "no 'origin' remote — committed locally only."
fi
