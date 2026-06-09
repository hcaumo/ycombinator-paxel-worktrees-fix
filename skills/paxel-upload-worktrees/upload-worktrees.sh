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
# HEADLESS-HANG GUARD
# -------------------
# When Paxel runs non-interactively (backgrounded, no controlling TTY), its
# session-EXTRACTION phase can hang SILENTLY — no container, no output, no
# error. We observed a run wedge for ~1h on the Gemini extractor (the deleted-
# cwd "orphan recovery" git walk is another known offender). So every upload
# here runs under a stall watchdog: if the log freezes with no Paxel container
# for too long, we kill it and retry ONCE with the extra-tool extractors +
# orphan recovery disabled:
#
#   PAXEL_NO_ORPHAN_RECOVERY=1
#   GEMINI_DIR / OPENCODE_DIR / CURSOR_DIR / CURSOR_GLOBAL_DB -> /nonexistent
#
# That keeps Claude Code + Codex sessions (what most people care about) and
# drops only Cursor/opencode/Gemini for that worktree. Use --skip-extra-tools
# to start in that mode and skip the probe.
#
# bash 3.2 compatible (default macOS bash). No `mapfile`, no `set -u`.

set -o pipefail

PAXEL_URL="https://paxel.ycombinator.com/upload.sh"
CLAUDE_PROJECTS_DIR="${CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects}"

SINCE=""
DRY_RUN=0
INCLUDE_EMPTY=0
EXCLUDE_MAIN=0
SKIP_EXTRA_TOOLS=0
NO_RETRY=0
STALL_SECS=420        # frozen log + no Paxel container this long => kill
HARD_SECS=3000        # absolute per-run ceiling => kill

# A nonexistent path makes Paxel's collect_<tool>_sessions return immediately.
SKIP_ENV='GEMINI_DIR=/nonexistent-paxel OPENCODE_DIR=/nonexistent-paxel CURSOR_DIR=/nonexistent-paxel CURSOR_GLOBAL_DB=/nonexistent-paxel/x PAXEL_NO_ORPHAN_RECOVERY=1'

usage() {
  cat <<'EOF'
upload-worktrees.sh — upload each git worktree's coding sessions to Paxel.

Runs Paxel single-repo mode from inside every live worktree that has Claude
Code sessions, under a stall watchdog that survives Paxel's headless
extraction hang (auto-retries with Cursor/opencode/Gemini extractors disabled).

Usage: upload-worktrees.sh [options]
  --since <dur>        limit Paxel to a window (e.g. 2m, 4w, 7d)
  --include-empty      also run worktrees with no detected Claude sessions
  --exclude-main       skip the primary (main) worktree
  --skip-extra-tools   from the start, skip Cursor/opencode/Gemini + orphan
                       recovery (fastest; avoids the known extraction hang)
  --no-retry           do not auto-retry a stalled run with extractors disabled
  --stall-timeout <s>  frozen-log + no-container kill threshold (default 420)
  --hard-timeout <s>   absolute per-run kill ceiling (default 3000)
  --dry-run            list targets; upload nothing
  -h, --help           this help

Prereqs: Docker running; a Paxel account (the first run opens a browser to sign
in once; later runs reuse the token at ~/.paxel/token).
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --since)            SINCE="${2:-}"; shift 2 ;;
    --include-empty)    INCLUDE_EMPTY=1; shift ;;
    --exclude-main)     EXCLUDE_MAIN=1; shift ;;
    --skip-extra-tools) SKIP_EXTRA_TOOLS=1; shift ;;
    --no-retry)         NO_RETRY=1; shift ;;
    --stall-timeout)    STALL_SECS="${2:-420}"; shift 2 ;;
    --hard-timeout)     HARD_SECS="${2:-3000}"; shift 2 ;;
    --dry-run)          DRY_RUN=1; shift ;;
    -h|--help)          usage; exit 0 ;;
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

paxel_container_running() { docker ps --format '{{.Image}}' 2>/dev/null | grep -qi paxel; }

mtime_epoch() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || echo 0; }

# Run one Paxel upload under a watchdog. Echoes: ok | fail | stall
run_guarded() {
  local wt="$1" log="$2" envprefix="$3"
  : > "$log"
  local paxel_args=""
  [ -n "$SINCE" ] && paxel_args="--since $SINCE"

  script -q "$log" bash -lc "cd '$wt' && curl -fsSL '$PAXEL_URL' | ${envprefix} bash -s -- ${paxel_args}" &
  local rpid=$! secs=0 verdict=""
  while kill -0 "$rpid" 2>/dev/null; do
    sleep 15; secs=$((secs + 15))
    local age=$(( $(date +%s) - $(mtime_epoch "$log") ))
    if ! paxel_container_running && [ "$age" -gt "$STALL_SECS" ]; then
      verdict="stall"; kill -TERM "$rpid" 2>/dev/null; sleep 2; kill -9 "$rpid" 2>/dev/null; break
    fi
    if [ "$secs" -gt "$HARD_SECS" ]; then
      verdict="stall"; kill -9 "$rpid" 2>/dev/null; break
    fi
  done
  wait "$rpid" 2>/dev/null
  if [ -z "$verdict" ]; then
    if grep -aqiE "PIPELINE COMPLETE|Upload complete" "$log"; then verdict="ok"; else verdict="fail"; fi
  fi
  echo "$verdict"
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
  tag=""; skip=0
  if [ "$idx" -eq 0 ] && [ "$EXCLUDE_MAIN" -eq 1 ]; then tag="(main, excluded)"; skip=1; fi
  if [ "$skip" -eq 0 ] && [ "$n" -eq 0 ] && [ "$INCLUDE_EMPTY" -eq 0 ]; then tag="(no sessions, skipped)"; skip=1; fi
  printf "  %-5s %s %s\n" "$n" "$wt" "$tag"
  [ "$skip" -eq 0 ] && TARGETS+=("$wt")
  idx=$((idx + 1))
done

if [ "${#TARGETS[@]}" -eq 0 ]; then
  echo; echo "nothing to upload (use --include-empty to force)."
  exit 0
fi

echo; echo "Will upload ${#TARGETS[@]} worktree(s)."
if [ "$DRY_RUN" -eq 1 ]; then echo "(dry-run: nothing uploaded)"; exit 0; fi

# --- upload, sequentially, watchdog-guarded ----------------------------------
rc_all=0
for wt in "${TARGETS[@]}"; do
  name="$(basename "$wt")"
  log="/tmp/paxel-upload-$name.log"
  echo; echo "==> $name"

  envprefix=""
  [ "$SKIP_EXTRA_TOOLS" -eq 1 ] && envprefix="$SKIP_ENV"

  verdict="$(run_guarded "$wt" "$log" "$envprefix")"

  if [ "$verdict" = "stall" ] && [ "$NO_RETRY" -eq 0 ] && [ "$SKIP_EXTRA_TOOLS" -eq 0 ]; then
    echo "    stalled in extraction — retrying with Cursor/opencode/Gemini + orphan-recovery disabled..."
    verdict="$(run_guarded "$wt" "$log" "$SKIP_ENV")"
  fi

  case "$verdict" in
    ok)    echo "    done (uploaded). log: $log" ;;
    stall) echo "    STALLED even after retry — see $log" >&2; rc_all=1 ;;
    *)     echo "    FAILED — see $log" >&2; rc_all=1 ;;
  esac
done

echo; echo "All requested worktrees processed."
exit "$rc_all"
