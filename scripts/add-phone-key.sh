#!/bin/sh
# Add one public SSH key as a read-only deploy key on the private feed repo.
# Usage: add-phone-key.sh --repo OWNER/NAME [--title TITLE] [keyfile]
# With no keyfile, read the public key from stdin. Rejects private keys.
# Never passes --allow-write. Read-only is gh's default; --read-only is added
# when this gh version has that flag.
set -eu

# gh must talk to github.com, not another host.
unset GH_HOST GH_REPO

REPO=
TITLE=omalauncher-phone
KEYFILE=

usage() {
  echo "usage: add-phone-key.sh --repo OWNER/NAME [--title TITLE] [keyfile]" >&2
  echo "Pass the public key file, or pipe the single .pub line on stdin." >&2
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
    --title)
      [ $# -ge 2 ] || usage
      TITLE=$2
      shift 2
      ;;
    -h|--help)
      usage
      ;;
    --)
      shift
      break
      ;;
    -*)
      echo "error: unknown argument" >&2
      usage
      ;;
    *)
      if [ -n "$KEYFILE" ]; then
        echo "error: only one key file" >&2
        usage
      fi
      KEYFILE=$1
      shift
      ;;
  esac
done

if [ -z "$REPO" ]; then
  usage
fi

umask 077
tmp=$(mktemp)
pub=$(mktemp)
cleanup() {
  rm -f "$tmp" "$pub"
}
trap cleanup EXIT

if [ -n "$KEYFILE" ]; then
  if [ ! -f "$KEYFILE" ]; then
    echo "error: key file not found" >&2
    exit 1
  fi
  # Copy so a later step cannot publish a different path than the one we checked.
  cat < "$KEYFILE" > "$tmp"
else
  if [ -t 0 ]; then
    echo "error: pass a public key file or pipe the .pub line." >&2
    exit 2
  fi
  cat > "$tmp"
fi

# Private keys are refused before gh is called, and the key text is not echoed.
if grep -q -E -e 'PRIVATE KEY' -e 'OPENSSH PRIVATE' -e 'PuTTY-User-Key-File' -e 'openssh-key-v1' "$tmp"; then
  echo "error: that looks like a private key. Paste only the .pub line. The private key stays on the phone." >&2
  exit 1
fi

# One public-key line. Comments and blank lines are ignored.
keyline=$(awk '
  /^[[:space:]]*#/ || NF == 0 { next }
  { lines++; line = $0 }
  END {
    if (lines == 1) print line
    exit (lines == 1 ? 0 : 1)
  }
' "$tmp") || {
  echo "error: need exactly one public SSH key line (the .pub line)." >&2
  exit 1
}

case "$keyline" in
  "ssh-ed25519 "*|\
  "ssh-rsa "*|\
  "ssh-dss "*|\
  "ecdsa-sha2-nistp256 "*|\
  "ecdsa-sha2-nistp384 "*|\
  "ecdsa-sha2-nistp521 "*|\
  "sk-ssh-ed25519@openssh.com "*|\
  "sk-ecdsa-sha2-nistp256@openssh.com "*)
    ;;
  *)
    echo "error: that is not a public SSH key line. Paste only the .pub line." >&2
    exit 1
    ;;
esac

material=$(printf '%s\n' "$keyline" | awk '{ print $2 }')
case "$material" in
  [A-Za-z0-9+/][A-Za-z0-9+/=]*) ;;
  *)
    echo "error: that is not a public SSH key line. Paste only the .pub line." >&2
    exit 1
    ;;
esac
if [ "${#material}" -lt 20 ]; then
  echo "error: that is not a public SSH key line. Paste only the .pub line." >&2
  exit 1
fi

case "$TITLE" in
  ""|*'
'*|*'	'*)
    echo "error: title must be a single line" >&2
    exit 2
    ;;
esac

if ! valid_repo "$REPO"; then
  echo "error: --repo must look like OWNER/NAME" >&2
  exit 2
fi

printf '%s\n' "$keyline" > "$pub"

export GH_PROMPT_DISABLED=1
export GIT_TERMINAL_PROMPT=0

if ! command -v gh >/dev/null 2>&1; then
  echo "error: GitHub CLI (gh) is not installed on this computer." >&2
  exit 1
fi

if ! gh auth status >/dev/null 2>&1; then
  echo "error: GitHub CLI is not logged in on this computer." >&2
  echo "Hand yourself the computer and run: gh auth login" >&2
  echo "Use the browser or device code. Do not paste a token." >&2
  exit 4
fi

view_out=$(mktemp)
view_err=$(mktemp)
trap 'rm -f "$tmp" "$pub" "$view_out" "$view_err"' EXIT

if ! gh repo view "$REPO" --json visibility,isPrivate >"$view_out" 2>"$view_err"; then
  echo "error: could not confirm that $REPO is private. Not adding a key." >&2
  exit 1
fi
python3 - "$view_out" "$REPO" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
vis = str(data.get("visibility") or "").upper()
if data.get("isPrivate") is not True or vis != "PRIVATE":
    repo = sys.argv[2]
    print(f"error: {repo} is {vis or 'not private'}. Refusing to add a deploy key.", file=sys.stderr)
    sys.exit(1)
PY

# Never pass --allow-write. Add --read-only when this gh accepts it.
ro=
if gh repo deploy-key add --help 2>&1 | grep -q -- '--read-only'; then
  ro=--read-only
fi
# shellcheck disable=SC2086
gh repo deploy-key add "$pub" --repo "$REPO" --title "$TITLE" $ro

python3 - "$REPO" "$material" <<'PY'
import json, subprocess, sys
repo, material = sys.argv[1], sys.argv[2]
raw = subprocess.check_output(
    ["gh", "repo", "deploy-key", "list", "--repo", repo, "--json", "id,key,readOnly,title"],
    text=True,
)
matched = [k for k in json.loads(raw) if material in (k.get("key") or "")]
if not matched:
    print("error: could not confirm the new deploy key is read-only.", file=sys.stderr)
    sys.exit(1)
for key in matched:
    # gh documents the field as readOnly, but gh 2.103 returns the REST name read_only.
    ro = key["readOnly"] if "readOnly" in key else key.get("read_only")
    if ro is not True:
        print(f"error: deploy key {key.get('id')} is not read-only. Remove it with gh repo deploy-key delete.", file=sys.stderr)
        sys.exit(1)
PY

echo "read-only deploy key added"
