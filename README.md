# ycombinator-paxel-worktrees-fix

A small, repo-agnostic add-on that makes [**Paxel**](https://paxel.ycombinator.com)
work cleanly when you develop across **multiple git worktrees** — so every
worktree's coding sessions get into your builder profile when you push or open a PR.

It ships two things you can drop into any project:

1. **A skill** — [`skills/paxel-upload-worktrees/`](skills/paxel-upload-worktrees/) —
   that your coding agent (Claude Code / Codex / Cursor) invokes when you push a
   branch or create a PR, plus a plain-bash helper script you can run yourself.
2. **A CLAUDE.md guideline** — [`CLAUDE.md`](CLAUDE.md) — a copy-paste block that
   tells the agent to do the upload as part of your push / PR workflow.

## The problem it fixes

Paxel reads the AI session transcripts on your machine and builds a profile from
them. It has two modes:

- **All repos** — run from a parent folder, analyzes every project at once.
- **Single repo** — `cd` into a project and run, analyzes just that checkout.

If you use **git worktrees**, each worktree is a *separate checkout at its own
path*, and Claude Code / Codex / Cursor store transcripts **per path**. So:

- A single "all repos" sweep can collapse or miss per-worktree sessions.
- "Single repo" mode only sees the worktree you happen to be standing in.
- Worktrees you've since **deleted** still have transcripts lingering under
  `~/.claude/projects/`, but you can't `cd` into them — naively iterating that
  folder breaks.

The fix: enumerate **live** worktrees with `git worktree list`, skip the ones
with no sessions, and run Paxel single-repo mode inside each remaining one — one
upload per worktree. That's exactly what the skill and the helper script do.

## Install

### Option A — the skill (agent-driven)

Copy the skill into your skills directory:

```bash
# Personal (all your projects):
cp -R skills/paxel-upload-worktrees ~/.claude/skills/

# …or per-project:
mkdir -p .claude/skills && cp -R skills/paxel-upload-worktrees .claude/skills/
```

Now when you tell your agent to push or open a PR, it can invoke
`paxel-upload-worktrees` and upload each worktree.

> Codex / Cursor users: the same `SKILL.md` body works as plain instructions, and
> the helper script below is tool-agnostic.

### Option B — the CLAUDE.md guideline (workflow rule)

This repo ships [`CLAUDE.md`](CLAUDE.md) and [`AGENTS.md`](AGENTS.md) as
**byte-identical twins** (Claude Code reads `CLAUDE.md`; Codex and other agents
read `AGENTS.md`). Paste the block into your project's `CLAUDE.md` **and**
`AGENTS.md`. It adds a step: *when you push or open a PR, upload the worktree to
Paxel.*

### Option C — just run the script

```bash
skills/paxel-upload-worktrees/upload-worktrees.sh            # upload every worktree with sessions
skills/paxel-upload-worktrees/upload-worktrees.sh --dry-run  # show what it would do
skills/paxel-upload-worktrees/upload-worktrees.sh --since 2m # limit to the last 2 months
```

## Prerequisites

- **Docker** running (Paxel's analysis runs locally in a container).
- A **Paxel account** — the first run opens a browser to sign in once; later runs
  reuse the token cached at `~/.paxel/token`.

## What leaves your machine

The upload sends Paxel **transcript excerpts + tool-call snippets** (to YC's LLM
proxy, which logs them server-side) plus scores, narratives, and session
metadata (file paths your agent touched, bash commands it ran, per-commit line
counts). **File bodies and diffs stay local.** Redaction is best-effort regex
inside Paxel's container. If a repo's transcripts may contain secrets you've
pasted into chat, review the upstream script first:

```bash
curl -fsSL https://paxel.ycombinator.com/upload.sh -o paxel-upload.sh && less paxel-upload.sh
```

## License

See [`LICENSE`](LICENSE).
