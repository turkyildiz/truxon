# Dev box migration — the whole playbook

**Goal: changing laptops is a ~30-minute routine, not a day of archaeology.**
Written 2026-07-23 after the ike→lynxdev swap surfaced every gap; kept current
by standing rule (below).

> **STANDING RULE — keep this kit up to date.** Any change to how the dev box is
> set up (new tool, new secret location, new manual step, changed path) must
> update `deploy/devbox/` **in the same commit** as the change. If a future
> migration hits a step this file doesn't cover, that's a bug — fix the kit.

## What lives where (the recovery map)

| Thing | Durable home | Restored by |
|---|---|---|
| Code + vault (memory, rules, reports, block lists) | GitHub `turkyildiz/truxon` | `git clone` |
| Claude's memory | `vault/Memory/` in the repo | bootstrap.sh (symlink) |
| Release keystore + key.properties | NAS `release-signing/` + B2 immutable + KeePassXC attachment | restore-signing.sh |
| google-services.json | KeePassXC → Truxon/Integrations/firebase-fcm attachment (fallback: Firebase console, project truxon-99a31) | manual (step 7) |
| All secrets (values) | `truxon-secrets.kdbx` — NAS primary + B2 sweep; master password: owner's head only | secrets-sync.sh pull |
| NAS job secrets (env files) | on the NAS itself + KeePassXC attachments | already in place |
| Session transcripts | each box's `~/.claude/projects/` — **archive at decommission** (below) | tar-over-ssh |
| Prod itself | Supabase + Vercel (cloud) | nothing to do |

## New box, in order

1. **OS + repo**
   ```bash
   sudo apt install -y git && git clone https://github.com/turkyildiz/truxon.git ~/TRUXON
   ```
2. **Root-level installs** — `sudo bash ~/TRUXON/deploy/devbox/bootstrap-sudo.sh`
   (apt tools, Docker, VS Code, Chrome/Obsidian debs if downloaded, Tailscale).
   Open the Tailscale login URL it prints; log out/in once for the docker group.
3. **User-space toolchain** — `bash ~/TRUXON/deploy/devbox/bootstrap.sh`
   (JDK, Flutter, Android SDK + truxtab AVD, Node, Deno, Supabase CLI,
   KeePassXC, memory symlink, git identity, SSH keypair, app deps). Idempotent.
4. **GitHub** — `gh auth login --web --git-protocol https && gh auth setup-git`
5. **NAS** — `ssh-copy-id turkyildiz@100.89.140.98` (NAS password, once).
   The new box's pubkey was printed by bootstrap.sh.
6. **Secrets vault** — `bash ~/TRUXON/deploy/secrets/secrets-sync.sh pull`,
   then open in KeePassXC (`keepassxc ~/dev-tools/secrets/truxon-secrets.kdbx`).
7. **Signing** — `bash ~/TRUXON/deploy/devbox/restore-signing.sh`
   (pulls newest bundle from NAS, fixes the storeFile path, verifies the
   fleet cert `3F:9D:34:BC…`). Then **google-services.json**: export the
   attachment from KeePassXC → `mobile/android/app/google-services.json`.
8. **Supabase** — `supabase login` then
   `supabase link --project-ref okoeeyxxvzypjiumraxq`. Then regenerate
   `frontend/.env.local` (gitignored, public values only):
   ```bash
   printf 'VITE_SUPABASE_URL=https://okoeeyxxvzypjiumraxq.supabase.co\nVITE_SUPABASE_ANON_KEY=%s\n' \
     "$(supabase projects api-keys --project-ref okoeeyxxvzypjiumraxq -o json | jq -r '.[]|select(.name=="anon")|.api_key')" \
     > ~/TRUXON/frontend/.env.local
   ```
9. **Verify** (nothing is done until this passes):
   ```bash
   flutter doctor                    # all green except optional linux-desktop
   cd ~/TRUXON/mobile && ./build-apk.sh debug && ./build-apk.sh release
   ```
   plus the connection audit: NAS ssh, `supabase migration list` (local=remote),
   emulator boots (`emulator -avd truxtab -no-window …` ~30 s with KVM),
   `git push` works.

## Known snags (each cost real time once)

- **UGOS NAS**: scp/rsync/SFTP fail on absolute paths — always tar-over-ssh.
- **KeePassXC AppImage** needs libfuse2 that modern Ubuntu lacks — bootstrap
  extracts it instead (`--appimage-extract`), no FUSE needed.
- **key.properties `storeFile`** is an absolute path — restore-signing.sh
  rewrites it; a stale `/home/<olduser>/` path fails the release build late.
- **storePassword must equal keyPassword** (PKCS12) or packageRelease dies
  with "final block not properly padded".
- **Claude memory path** derives from the repo path (`/home/X/TRUXON` →
  `-home-X-TRUXON`) — bootstrap computes it; a wrong symlink means Claude
  starts amnesiac. If Claude ever greets you like a stranger, check this first.
- **Cloudflare gates ITS login** — the assisted-harvest flow in
  `deploy/migration-its/` is the only capture path; never burn time on
  headless login again.
- **`gh auth` + git identity + supabase login are per-box** — steps 4/8 are
  not optional.
- **Auto-mode classifier** sometimes blocks `git push`/secret-touching
  commands — hand the exact command to the owner, don't fight it.

## Decommissioning the old box

1. `git -C ~/src/truxon status` — commit/push anything uncommitted FIRST.
2. Archive session transcripts (the R9 block list was nearly lost this way):
   ```bash
   cd ~/.claude/projects && tar czf - . | ssh turkyildiz@100.89.140.98 \
     'cat > /volume1/docker/truxon-backup/devbox-archive/claude-projects-$(hostname)-$(date +%F).tar.gz'
   ```
3. Sweep for strays: `~/dev-tools`, scratchpads, `~/Downloads`, local-only
   env files. Anything durable → vault/repo/NAS/KeePassXC, not the box.
4. Remove the box from the tailnet + revoke its GitHub session once cold.
