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

## ⚠️ Known hang: Paxel's extraction stalls when run headless
When Paxel runs **non-interactively (backgrounded, no controlling TTY)** — i.e.
exactly how an agent runs it — its session-**extraction** phase can hang
**silently**: no Docker container, no output, no error, indefinitely. Observed
wedging a run for ~1 hour. Culprits seen: the **Gemini** extractor and the
deleted-cwd **orphan-recovery** git walk. A PTY does NOT fix it.

**So never fire-and-forget `curl … | bash`.** Run each upload under a watchdog
and detect the stall by its signature: **log frozen AND no `paxel` container
running**. On a stall, kill it and retry with the offending extractors disabled:

```
PAXEL_NO_ORPHAN_RECOVERY=1 \
GEMINI_DIR=/nonexistent OPENCODE_DIR=/nonexistent \
CURSOR_DIR=/nonexistent CURSOR_GLOBAL_DB=/nonexistent/x \
  bash   # (as the piped interpreter: curl … | <those env vars> bash)
```

That keeps Claude Code + Codex sessions and drops only Cursor/opencode/Gemini.
The bundled `upload-worktrees.sh` does all of this for you — **prefer it.**

## Steps (if doing it by hand)
1. **Discover worktrees:** `git worktree list`. Only valid targets — deleted
   worktrees are excluded automatically (you can't `cd` into them).
2. **Keep the ones with sessions.** For a worktree path, Claude Code transcripts
   live at `~/.claude/projects/<encoded-path>`, where `<encoded-path>` is the
   absolute path with every `/` and `.` replaced by `-`. Count `*.jsonl`; skip
   worktrees with zero.
3. **Upload each, single-repo mode, sequentially, under a watchdog** (see the
   hang section above). First run pulls the Paxel image; later runs reuse it and
   hit ~95% LLM cache, so they finish in minutes. A full uncached run is ~20 min.
4. Each upload emails the user when its report is ready; profiles aggregate.

## Or just run the helper script (does steps 1–4 + the watchdog/retry)
```bash
./upload-worktrees.sh                 # all worktrees with sessions, watchdog-guarded
./upload-worktrees.sh --dry-run       # preview the targets, upload nothing
./upload-worktrees.sh --since 2m      # limit Paxel to the last 2 months
./upload-worktrees.sh --skip-extra-tools   # fastest: Cursor/opencode/Gemini off from the start
./upload-worktrees.sh --exclude-main
```

## Safety
- Never `cd` into a path that no longer exists on disk.
- **Always run under the stall watchdog** (frozen log + no container ⇒ kill +
  retry with extractors disabled). Silence is NOT progress — a hang looks
  identical to "still working."
- The upload sends transcript excerpts to YC's proxy (logged) plus scores +
  metadata; file bodies and diffs stay local; redaction is best-effort regex. If
  transcripts may hold pasted secrets, review `https://paxel.ycombinator.com/upload.sh`
  first and tell the user before proceeding.
