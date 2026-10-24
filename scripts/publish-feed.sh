#!/bin/sh
# Publish this computer's Grok Bot widget feed to a private GitHub repo.
# Usage: publish-feed.sh --repo OWNER/NAME [--agents-dir DIR] [--include-descriptions]
# Never prints tokens. Refuses a public repo. Commits and pushes only when the feed changed.
set -eu

FEED_DIR=${GROKBOT_FEED_DIR:-/workspace/grokbot-widget-feed}
AGENTS_DIR=
INCLUDE_DESC=0
REPO=
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)

usage() {
  echo "usage: publish-feed.sh --repo OWNER/NAME [--agents-dir DIR] [--include-descriptions]" >&2
  exit 2
}

valid_repo() {
  r=$1
  case "$r" in
    */*/*|*"@"*|*:*) return 1 ;;
  esac
  owner=${r%%/*}
  name=${r#*/}
  case "$owner" in
    ""|.*|*" "*) return 1 ;;
  esac
  case "$name" in
    ""|.*|*.git|*" "*) return 1 ;;
  esac
  case "$owner$name" in
    *[!A-Za-z0-9._-]*) return 1 ;;
  esac
  return 0
}

while [ $# -gt 0 ]; do
  case "$1" in
    --repo)
      [ $# -ge 2 ] || usage
      REPO=$2
      shift 2
      ;;
    --agents-dir)
      [ $# -ge 2 ] || usage
      AGENTS_DIR=$2
      shift 2
      ;;
    --include-descriptions)
      INCLUDE_DESC=1
      shift
      ;;
    -h|--help)
      usage
      ;;
    *)
      echo "error: unknown argument" >&2
      usage
      ;;
  esac
done

[ -n "$REPO" ] || usage
if ! valid_repo "$REPO"; then
  echo "error: --repo must look like OWNER/NAME" >&2
  exit 2
fi

export GH_PROMPT_DISABLED=1
export GIT_TERMINAL_PROMPT=0

if ! command -v gh >/dev/null 2>&1; then
  echo "error: GitHub CLI (gh) is not installed on this computer." >&2
  exit 1
fi

# Do not print gh auth output. It can include account details, and a token
# must never land in the transcript.
if ! gh auth status >/dev/null 2>&1; then
  echo "error: GitHub CLI is not logged in on this computer." >&2
  echo "Hand yourself the computer and run: gh auth login" >&2
  echo "Use the browser or device code. Do not paste a token." >&2
  exit 4
fi

tmp_out=$(mktemp)
tmp_err=$(mktemp)
cleanup() {
  rm -f "$tmp_out" "$tmp_err"
}
trap cleanup EXIT

repo_meta() {
  if gh repo view "$REPO" --json visibility,isEmpty,isPrivate >"$tmp_out" 2>"$tmp_err"; then
    return 0
  fi
  return 1
}

require_private() {
  python3 - "$tmp_out" "$REPO" <<'PY'
import json, sys
path, repo = sys.argv[1], sys.argv[2]
data = json.load(open(path))
vis = str(data.get("visibility") or "").upper()
if data.get("isPrivate") is not True or vis != "PRIVATE":
    print(f"error: {repo} is {vis or 'not private'}. Refusing to put a bot feed in a repo that is not private.", file=sys.stderr)
    sys.exit(1)
PY
}

if repo_meta; then
  require_private
else
  if grep -Eq 'Could not resolve to a Repository|HTTP 404|Not Found' "$tmp_err"; then
    if ! gh repo create "$REPO" --private --disable-wiki --disable-issues \
        --description "Private Grok Bot widget feed" >"$tmp_out" 2>"$tmp_err"; then
      echo "error: could not create a private repo named $REPO. Refusing to continue." >&2
      exit 1
    fi
    if ! repo_meta; then
      echo "error: could not confirm that $REPO is private. Refusing to continue." >&2
      exit 1
    fi
    require_private
  else
    echo "error: could not confirm that $REPO is private. Refusing to continue." >&2
    exit 1
  fi
fi

if [ -e "$FEED_DIR" ] && [ ! -d "$FEED_DIR/.git" ]; then
  echo "error: $FEED_DIR exists and is not the feed checkout. Refusing to replace it." >&2
  exit 1
fi

if [ ! -d "$FEED_DIR/.git" ]; then
  mkdir -p "$(dirname "$FEED_DIR")"
  if ! gh repo clone "$REPO" "$FEED_DIR" -- --depth 1 >"$tmp_out" 2>"$tmp_err"; then
    if [ -d "$FEED_DIR" ]; then
      echo "error: clone of $REPO failed and left $FEED_DIR in place. Refusing to delete it." >&2
      exit 1
    fi
    echo "error: could not clone $REPO." >&2
    exit 1
  fi
else
  # config --get, not remote get-url: get-url applies insteadOf and would hide the saved URL.
  origin=$(git -C "$FEED_DIR" config --get remote.origin.url 2>/dev/null || true)
  norm=$(printf '%s' "$origin" | sed -e 's#^git@github.com:#https://github.com/#' -e 's#\.git$##' -e 's#/$##')
  if [ "$norm" != "https://github.com/$REPO" ]; then
    echo "error: $FEED_DIR is a checkout of a different remote. Refusing to touch it." >&2
    exit 1
  fi
fi

# Local to the feed checkout only. Does not change global git config.
if ! git -C "$FEED_DIR" config --local --get-regexp '^credential\.helper$' >/dev/null 2>&1; then
  git -C "$FEED_DIR" config --local credential.helper ''
  git -C "$FEED_DIR" config --local --add credential.helper '!gh auth git-credential'
fi

if ! heads=$(git -C "$FEED_DIR" ls-remote --heads origin 2>"$tmp_err"); then
  echo "error: could not list branches for $REPO. Not publishing." >&2
  exit 1
fi

if [ -n "$heads" ]; then
  def=$(gh repo view "$REPO" --json defaultBranchRef --jq '.defaultBranchRef.name // "main"')
  case "$def" in
    ""|*[!A-Za-z0-9._-]*)
      echo "error: unexpected default branch name. Not publishing." >&2
      exit 1
      ;;
  esac
  # A depth-1 fetch does not contain enough history to fast-forward.
  # Move the local branch to the remote tip, then commit the new feed on top.
  git -C "$FEED_DIR" fetch --depth 1 origin "$def"
  git -C "$FEED_DIR" checkout -q -B "$def" "origin/$def"
fi

set -- --out "$FEED_DIR"
if [ -n "$AGENTS_DIR" ]; then
  set -- "$@" --agents-dir "$AGENTS_DIR"
fi
if [ "$INCLUDE_DESC" -eq 1 ]; then
  set -- "$@" --include-descriptions
fi
python3 "$ROOT/scripts/build-feed.py" "$@"

if ! git -C "$FEED_DIR" config user.name >/dev/null 2>&1; then
  git -C "$FEED_DIR" config user.name "Grok Bot widget feed"
fi
if ! git -C "$FEED_DIR" config user.email >/dev/null 2>&1; then
  git -C "$FEED_DIR" config user.email "widget-feed@localhost"
fi

git -C "$FEED_DIR" add -- index.json
if [ -d "$FEED_DIR/avatars" ] || git -C "$FEED_DIR" ls-files -- avatars | grep -q .; then
  git -C "$FEED_DIR" add -A -- avatars
fi

if git -C "$FEED_DIR" diff --cached --quiet; then
  echo "feed unchanged"
  exit 0
fi

# Re-check immediately before anything leaves this computer.
if ! repo_meta; then
  echo "error: could not re-check that $REPO is private. Not pushing." >&2
  exit 1
fi
require_private

git -C "$FEED_DIR" commit -m "Update Grok Bot widget feed"
git -C "$FEED_DIR" push -u origin HEAD
echo "feed pushed"
