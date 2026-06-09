#!/usr/bin/env bash
#
# upload-worktrees.sh — upload each git worktree's coding sessions to Paxel.
# https://github.com/hcaumo/ycombinator-paxel-worktrees-fix
#
# Runs Paxel (https://paxel.ycombinator.com) in single-repo mode from inside
# every LIVE git worktree that has at least one Claude Code session, so each
# worktree's sessions land in your builder profile. Deleted worktrees are
# excluded automatically — `git worktree list` only reports existing ones.
#
# bash 3.2 compatible (default macOS bash). No `mapfile`, no `set -u`.

set -o pipefail

PAXEL_URL="https://paxel.ycombinator.com/upload.sh"
CLAUDE_PROJECTS_DIR="${CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects}"

SINCE=""
DRY_RUN=0
INCLUDE_EMPTY=0
EXCLUDE_MAIN=0

usage() {
  cat <<'EOF'
upload-worktrees.sh — upload each git worktree's coding sessions to Paxel.

Runs Paxel single-repo mode from inside every live worktree that has Claude
Code sessions. Deleted worktrees are excluded automatically.

Usage: upload-worktrees.sh [options]
  --since <dur>     limit Paxel to a window (e.g. 2m, 4w, 7d)
  --include-empty   also run worktrees with no detected Claude sessions
  --exclude-main    skip the primary (main) worktree
  --dry-run         list targets; upload nothing
  -h, --help        this help

Prereqs: Docker running; a Paxel account (the first run opens a browser to sign
in once; later runs reuse the token at ~/.paxel/token).
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --since)         SINCE="${2:-}"; shift 2 ;;
    --include-empty) INCLUDE_EMPTY=1; shift ;;
    --exclude-main)  EXCLUDE_MAIN=1; shift ;;
    --dry-run)       DRY_RUN=1; shift ;;
    -h|--help)       usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage; exit 2 ;;
  esac
done

# --- prereqs -----------------------------------------------------------------
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "error: run this from inside a git repository that has worktrees." >&2
  exit 1
fi
if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
  echo "error: Docker is not running. Start Docker Desktop / colima / OrbStack first." >&2
  exit 1
fi

# Encode an absolute path the way Claude Code names its ~/.claude/projects dirs:
# every '/' and '.' becomes '-'.
encode_path() { printf '%s' "$1" | sed 's#[/.]#-#g'; }

session_count() {
  local dir="$CLAUDE_PROJECTS_DIR/$(encode_path "$1")"
  if [ -d "$dir" ]; then
    find "$dir" -maxdepth 1 -name '*.jsonl' 2>/dev/null | wc -l | tr -d ' '
  else
    echo 0
  fi
}

# --- collect worktrees (first entry is the primary/main checkout) ------------
WORKTREES=()
while IFS= read -r line; do
  case "$line" in
    "worktree "*) WORKTREES+=("${line#worktree }") ;;
  esac
done < <(git worktree list --porcelain)

if [ "${#WORKTREES[@]}" -eq 0 ]; then
  echo "no worktrees found." >&2
  exit 1
fi

# --- plan --------------------------------------------------------------------
TARGETS=()
idx=0
echo "Worktrees (sessions / path):"
for wt in "${WORKTREES[@]}"; do
  n="$(session_count "$wt")"
  tag=""
  skip=0
  if [ "$idx" -eq 0 ] && [ "$EXCLUDE_MAIN" -eq 1 ]; then tag="(main, excluded)"; skip=1; fi
  if [ "$skip" -eq 0 ] && [ "$n" -eq 0 ] && [ "$INCLUDE_EMPTY" -eq 0 ]; then tag="(no sessions, skipped)"; skip=1; fi
  printf "  %-5s %s %s\n" "$n" "$wt" "$tag"
  [ "$skip" -eq 0 ] && TARGETS+=("$wt")
  idx=$((idx + 1))
done

if [ "${#TARGETS[@]}" -eq 0 ]; then
  echo
  echo "nothing to upload (use --include-empty to force)."
  exit 0
fi

echo
echo "Will upload ${#TARGETS[@]} worktree(s)."
if [ "$DRY_RUN" -eq 1 ]; then
  echo "(dry-run: nothing uploaded)"
  exit 0
fi

# --- upload, sequentially ----------------------------------------------------
PAXEL_ARGS=()
[ -n "$SINCE" ] && PAXEL_ARGS+=(--since "$SINCE")

rc_all=0
for wt in "${TARGETS[@]}"; do
  echo
  echo "==> $wt"
  if [ "${#PAXEL_ARGS[@]}" -gt 0 ]; then
    ( cd "$wt" && curl -fsSL "$PAXEL_URL" | bash -s -- "${PAXEL_ARGS[@]}" )
  else
    ( cd "$wt" && curl -fsSL "$PAXEL_URL" | bash )
  fi
  if [ $? -eq 0 ]; then
    echo "    done."
  else
    echo "    FAILED (continuing with the rest)." >&2
    rc_all=1
  fi
done

echo
echo "All requested worktrees processed."
exit "$rc_all"
