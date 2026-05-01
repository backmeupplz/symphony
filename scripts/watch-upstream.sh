#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
LOG_DIR="$HOME/Library/Logs/symphony"
LOG_FILE="$LOG_DIR/upstream-watch.log"
UPSTREAM_URL="https://github.com/openai/symphony.git"
mkdir -p "$LOG_DIR"

exec >> "$LOG_FILE" 2>&1

timestamp() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

echo "[$(timestamp)] starting upstream watch"
cd "$ROOT"

if ! git remote get-url upstream >/dev/null 2>&1; then
  git remote add upstream "$UPSTREAM_URL"
  echo "[$(timestamp)] added upstream remote $UPSTREAM_URL"
fi

git fetch origin --prune
git fetch upstream --prune

git checkout main >/dev/null 2>&1 || true

git pull --ff-only origin main >/dev/null

counts_raw=$(git rev-list --left-right --count origin/main...upstream/main)
counts=(${(ps:\t:)counts_raw})
fork_only="${counts[1]}"
upstream_only="${counts[2]}"
head_sha=$(git rev-parse --short HEAD)
upstream_sha=$(git rev-parse --short upstream/main)

echo "[$(timestamp)] origin/main=$head_sha upstream/main=$upstream_sha fork_only=$fork_only upstream_only=$upstream_only"

if [ "$upstream_only" -gt 0 ]; then
  echo "[$(timestamp)] upstream has $upstream_only new commit(s) not in fork"
  git log --oneline --max-count "$upstream_only" origin/main..upstream/main | sed 's/^/[upstream] /'
  exit 20
fi

echo "[$(timestamp)] no upstream changes to review"
