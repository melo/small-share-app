#!/usr/bin/env bash
#
# run.sh — the browser end-to-end suite.
#
# Playwright drives a real Chromium against a real instance of the app. It is
# the only way to check the things HTTP cannot: that mermaid actually DRAWS,
# that the drop zone accepts files, that the clipboard button copies, and that
# "recent uploads" survives a reload.
#
# It runs against a THROWAWAY instance, never production. share.<tailnet>.ts.net
# holds other people's files; this suite uploads and deletes freely, so it gets
# its own container, its own port and its own empty data directory, all torn
# down at the end.
#
#   local  : docker compose on this machine (default when docker is here)
#   remote : docker compose on an ssh target, reached through a local tunnel
#
# Usage:
#   ./run.sh                 # auto: local docker if present, else REMOTE=beebop
#   REMOTE=beebop ./run.sh   # force the remote path
#   HEADED=1 ./run.sh        # watch it happen
#   ./run.sh --ui            # any extra args go to playwright
#
set -euo pipefail

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
APP=$(cd "$HERE/.." && pwd)

PORT=${PORT:-8099}
PROJECT=share-e2e
REMOTE=${REMOTE:-}
KEEP=${KEEP:-0}

say()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

if [[ -z $REMOTE ]] && ! docker compose version >/dev/null 2>&1; then
  REMOTE=beebop
  warn "no local docker — running the app on '$REMOTE' and tunnelling to it"
fi

# Playwright and Chromium are already in this dev container (ccc installs them
# at /ms-playwright); the module lives in the global node path.
export PLAYWRIGHT_BROWSERS_PATH=${PLAYWRIGHT_BROWSERS_PATH:-/ms-playwright}
export NODE_PATH=${NODE_PATH:-/usr/local/lib/node_modules}
command -v playwright >/dev/null || die "playwright is not installed (expected from the ccc image)"

TUNNEL_PID=
cleanup() {
  local rc=$?
  [[ -n $TUNNEL_PID ]] && kill "$TUNNEL_PID" 2>/dev/null || true
  if [[ $KEEP == 1 ]]; then
    warn "KEEP=1 — leaving the throwaway instance up on port $PORT"
  else
    say "tearing the throwaway instance down"
    if [[ -n $REMOTE ]]; then
      ssh -n "$REMOTE" "cd ~/$PROJECT 2>/dev/null && docker compose -p $PROJECT down -v; rm -rf ~/$PROJECT" || true
    else
      (cd "$HERE" && docker compose -p $PROJECT -f compose.e2e.yml down -v) || true
      rm -rf "$HERE/data"
    fi
  fi
  exit $rc
}
trap cleanup EXIT

# The app under test. A fixed SHARE_BASE_URL matching the tunnel keeps every URL
# the app hands out clickable from the browser's point of view.
BASE_URL="http://127.0.0.1:$PORT"

if [[ -n $REMOTE ]]; then
  say "shipping the app to $REMOTE:~/$PROJECT"
  ssh -n "$REMOTE" "rm -rf ~/$PROJECT && mkdir -p ~/$PROJECT"
  rsync -a --delete --exclude '.git' --exclude data --exclude e2e --exclude test-results \
    "$APP/" "$REMOTE:$PROJECT/app/"
  scp -q "$HERE/compose.e2e.yml" "$REMOTE:$PROJECT/"

  say "building and starting it there"
  ssh -n "$REMOTE" "cd ~/$PROJECT && SHARE_BASE_URL='$BASE_URL' docker compose -p $PROJECT -f compose.e2e.yml up -d --build" \
    || die "the throwaway instance would not start"

  say "tunnelling 127.0.0.1:$PORT -> $REMOTE"
  ssh -N -L "$PORT:127.0.0.1:$PORT" "$REMOTE" &
  TUNNEL_PID=$!
else
  say "building and starting the throwaway instance"
  (cd "$HERE" && SHARE_BASE_URL="$BASE_URL" docker compose -p $PROJECT -f compose.e2e.yml up -d --build)
fi

say "waiting for it to answer"
for _ in $(seq 1 60); do
  curl -fsS "$BASE_URL/api/v1/health" >/dev/null 2>&1 && break
  sleep 1
done
curl -fsS "$BASE_URL/api/v1/health" >/dev/null || die "the app never answered on $BASE_URL"
printf '    %s\n' "$(curl -fsS "$BASE_URL/api/v1/health")"

say "running the browser suite"
cd "$HERE"
BASE_URL="$BASE_URL" playwright test ${HEADED:+--headed} "$@"
