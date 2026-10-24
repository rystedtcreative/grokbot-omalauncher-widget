#!/bin/sh
# Fill the setup skill's commit and checksums placeholders from a git tag.
# Usage: scripts/release-skill.sh TAG
# Writes dist/SKILL.md (gitignored) for the bot template. The repo copy of
# setup-bot/SKILL.md keeps __EXPECTED_COMMIT__ and __EXPECTED_CHECKSUMS_SHA256__.
# Refuses a dirty tree, a missing tag, or a skill that lacks either placeholder.
set -eu

if [ $# -ne 1 ] || [ -z "$1" ]; then
  echo "usage: release-skill.sh TAG" >&2
  exit 2
fi
TAG=$1
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
cd "$ROOT"

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "error: $ROOT is not a git checkout. Refusing to release." >&2
  exit 1
fi

# Untracked files count. dist/ is gitignored, so a previous filled skill does not.
if [ -n "$(git status --porcelain)" ]; then
  echo "error: refusing to release from a dirty tree" >&2
  exit 1
fi

if ! commit=$(git rev-parse --verify "${TAG}^{commit}" 2>/dev/null); then
  echo "error: cannot resolve tag $TAG" >&2
  exit 1
fi

if ! git cat-file -e "${commit}:setup-bot/SKILL.md" 2>/dev/null; then
  echo "error: $TAG has no setup-bot/SKILL.md" >&2
  exit 1
fi
if ! git cat-file -e "${commit}:checksums.txt" 2>/dev/null; then
  echo "error: $TAG has no checksums.txt" >&2
  exit 1
fi

skill=$(mktemp)
sums=$(mktemp)
cleanup() {
  rm -f "$skill" "$sums"
}
trap cleanup EXIT
git cat-file blob "${commit}:setup-bot/SKILL.md" > "$skill"
git cat-file blob "${commit}:checksums.txt" > "$sums"
digest=$(sha256sum "$sums" | awk 'NR==1 { print $1 }')

mkdir -p dist
python3 - "$skill" "$commit" "$digest" dist/SKILL.md <<'PY'
import pathlib, sys
src, commit, digest, dest = sys.argv[1:]
text = pathlib.Path(src).read_text()
missing = [token for token in ("__EXPECTED_COMMIT__", "__EXPECTED_CHECKSUMS_SHA256__") if token not in text]
if missing:
    print("error: placeholder missing from setup-bot/SKILL.md: " + ", ".join(missing), file=sys.stderr)
    sys.exit(1)
if len(commit) != 40 or any(c not in "0123456789abcdef" for c in commit):
    print("error: tag did not resolve to a commit sha", file=sys.stderr)
    sys.exit(1)
if len(digest) != 64 or any(c not in "0123456789abcdef" for c in digest):
    print("error: checksums digest is not sha256", file=sys.stderr)
    sys.exit(1)
filled = text.replace("__EXPECTED_COMMIT__", commit).replace("__EXPECTED_CHECKSUMS_SHA256__", digest)
if "__EXPECTED_COMMIT__" in filled or "__EXPECTED_CHECKSUMS_SHA256__" in filled:
    print("error: placeholders remain in the filled skill", file=sys.stderr)
    sys.exit(1)
pathlib.Path(dest).write_text(filled)
print(f"wrote {dest}")
print(f"commit {commit}")
print(f"checksums {digest}")
PY
