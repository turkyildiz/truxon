#!/usr/bin/env bash
# Archive a Claude Code session transcript so it's never lost.
# - Raw JSONL → gzipped into vault/Sessions/raw/ (LOCAL only, gitignored:
#   large + may contain fetched keys, so it never goes to GitHub). This preserves
#   the ground-truth transcript even if ~/.claude prunes old sessions.
# - Then WRITE a readable log note in vault/Sessions/ and `git`-commit that
#   (small, secret-free, durable via GitHub). See vault/save.sh.
#
# Usage:  vault/save-session.sh [session-id]   (default: the newest transcript)
set -euo pipefail
PROJ="$HOME/.claude/projects/-home-ilker-DEV"
DEST="$(cd "$(dirname "$0")" && pwd)/Sessions/raw"
mkdir -p "$DEST"

ID="${1:-}"
if [ -z "$ID" ]; then
  SRC="$(ls -1t "$PROJ"/*.jsonl 2>/dev/null | head -1)"
  [ -n "$SRC" ] || { echo "no transcripts found in $PROJ"; exit 1; }
  ID="$(basename "$SRC" .jsonl)"
else
  SRC="$PROJ/$ID.jsonl"
  [ -f "$SRC" ] || { echo "no transcript: $SRC"; exit 1; }
fi

RAW_SZ="$(du -h "$SRC" | cut -f1)"
gzip -c "$SRC" > "$DEST/$ID.jsonl.gz"
GZ_SZ="$(du -h "$DEST/$ID.jsonl.gz" | cut -f1)"
echo "archived $ID  (raw $RAW_SZ → gz $GZ_SZ)  →  Sessions/raw/$ID.jsonl.gz  [local, gitignored]"

# Informational secret scan of the raw (it won't be pushed regardless).
HITS="$(grep -aoiE 'sk_live|sb_secret|service_role.{0,40}ey[A-Za-z0-9_-]{20}|-----BEGIN|ghp_[A-Za-z0-9]{20}|AKIA[0-9A-Z]{16}' "$SRC" 2>/dev/null | wc -l || true)"
[ "$HITS" -gt 0 ] && echo "note: raw contains ~$HITS secret-shaped string(s) — correct that it stays gitignored/local." || echo "raw secret-scan: clean"

echo
echo "next: write/append a readable log in vault/Sessions/ then run vault/save.sh"
