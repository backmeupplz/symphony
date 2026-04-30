#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
LOG_DIR="$HOME/Library/Logs/symphony"
LOG_FILE="$LOG_DIR/upstream-sync.log"
UPSTREAM_URL="https://github.com/openai/symphony.git"
LAUNCHD_LABEL="com.borodutch.symphony"
mkdir -p "$LOG_DIR"

exec >> "$LOG_FILE" 2>&1

timestamp() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

echo "[$(timestamp)] starting upstream sync"
cd "$ROOT"

if ! git remote get-url upstream >/dev/null 2>&1; then
  git remote add upstream "$UPSTREAM_URL"
  echo "[$(timestamp)] added upstream remote $UPSTREAM_URL"
fi

if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "[$(timestamp)] aborting: worktree is dirty"
  exit 10
fi

git fetch origin --prune
git fetch upstream --prune

git checkout main

git pull --ff-only origin main

if git merge-base --is-ancestor upstream/main HEAD; then
  echo "[$(timestamp)] already contains upstream/main"
else
  git merge --no-edit upstream/main
  echo "[$(timestamp)] merged upstream/main into local main"
fi

git push origin main

echo "[$(timestamp)] pushed main to origin"

launchctl kickstart -k "gui/$(id -u)/$LAUNCHD_LABEL"
echo "[$(timestamp)] restarted $LAUNCHD_LABEL"

echo "[$(timestamp)] upstream sync complete"
