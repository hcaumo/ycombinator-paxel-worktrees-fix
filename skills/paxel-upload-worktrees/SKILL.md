---
name: paxel-upload-worktrees
description: Use when the user pushes a branch or opens/creates a pull request and works across git worktrees - uploads each live worktree's Claude Code / Codex / Cursor coding sessions to Paxel (paxel.ycombinator.com) so the builder profile stays current. Also triggers on "upload to paxel", "paxel worktrees", "upload my worktrees".
---

# Paxel upload for git worktrees

Upload each git worktree's coding sessions to Paxel — **one upload per worktree**.

## When to use
- The user pushed a branch or opened / created a PR (and uses git worktrees).
- The user asks to "upload to Paxel", refresh their builder profile, etc.

## Prerequisites (check first)
1. **Docker running** — `docker info >/dev/null 2>&1`. If not, ask the user to
   start Docker Desktop / colima / OrbStack; do not proceed without it.
2. **Paxel token** — `~/.paxel/token`. If missing/expired, the first run opens a
   browser to sign in; surface that URL to the user rather than letting it hang.

## Steps
1. **Discover worktrees:** `git worktree list`. These are the only valid targets —
   deleted worktrees are excluded automatically (you can't `cd` into them).
2. **Keep the ones with sessions.** For a worktree path, Claude Code transcripts
   live at `~/.claude/projects/<encoded-path>`, where `<encoded-path>` is the
   absolute path with every `/` and `.` replaced by `-`. Count `*.jsonl` files;
   skip worktrees with zero. (Paxel also picks up Codex/Cursor sessions for the
   same checkout when it runs.)
3. **Upload each, single-repo mode, sequentially:**
   ```bash
   cd <worktree-path> && curl -fsSL https://paxel.ycombinator.com/upload.sh | bash
   ```
   The first run pulls the Paxel Docker image; later runs reuse it and hit ~95%
   LLM cache, so they finish in minutes.
4. Each upload emails the user when its report is ready; profiles aggregate
   across all worktrees.

## Or just run the helper script (does steps 1–4 for you)
```bash
./upload-worktrees.sh            # all worktrees with sessions
./upload-worktrees.sh --dry-run  # preview the targets, upload nothing
./upload-worktrees.sh --since 2m # limit Paxel to the last 2 months
./upload-worktrees.sh --exclude-main
```

## Safety
- Never `cd` into a path that no longer exists on disk.
- Long runs (15–30 min for a busy worktree): run in the background and report as
  each finishes; watch for an auth-needed URL or a "Docker not running" error.
- The upload sends transcript excerpts to YC's proxy (logged) plus scores +
  metadata; file bodies and diffs stay local; redaction is best-effort regex. If
  transcripts may hold pasted secrets, review `https://paxel.ycombinator.com/upload.sh`
  first and tell the user before proceeding.
