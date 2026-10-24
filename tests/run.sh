#!/bin/sh
# Build the fixture feed and check the feed, the phone-key guard, and checksums.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
cd "$ROOT"

echo "checksums"
sha256sum -c checksums.txt

# The kit's own publisher URL (rystedtcreative/grokbot-omalauncher-widget) is allowed; nothing else personal.
if grep -R -n -E -e 'rystedt' -e 'Lifty' -e 'lifty' -e 'Joshua' \
  widget scripts setup-bot README.md SECURITY.md LICENSE docs .github \
  | grep -v 'rystedtcreative/grokbot-omalauncher-widget'; then
  echo "personal value in a shipped file" >&2
  exit 1
fi

python3 - <<'PY'
from pathlib import Path
text = Path("setup-bot/SKILL.md").read_text()
assert text.startswith("---\n"), "skill frontmatter"
end = text.index("\n---\n", 4)
fields = {}
for line in text[4:end].splitlines():
    key, value = line.split(": ", 1)
    fields[key] = value
assert fields["name"] == "omalauncher-widget-setup"
assert fields["description"].startswith("use this when"), fields["description"]
size = len(text.encode())
assert size < 6144, f"SKILL.md is {size} bytes"
print(f"skill ok ({size} bytes)")
PY

for needle in \
  'git@github.com:YOUR_USER/grokbot-widget-feed.git' \
  'let pinnedName = ""' \
  'every 10m' \
  'BatchMode=yes' \
  'GIT_TERMINAL_PROMPT=0' \
  'schemaVersion' \
  'unknown feed schema'
do
  if ! grep -q -F "$needle" widget/grokbot.owl; then
    echo "widget is missing: $needle" >&2
    exit 1
  fi
done

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
FEED_BEFORE=0
if [ -e /workspace/grokbot-widget-feed ]; then
  FEED_BEFORE=1
fi

python3 scripts/build-feed.py \
  --agents-dir tests/fixtures/agents \
  --out "$TMP/feed" \
  >"$TMP/build.out" 2>"$TMP/build.err"

python3 - "$ROOT" "$TMP/feed" "$TMP/build.err" <<'PY'
import importlib.util
import json
import sys
from pathlib import Path

root, feed, err_path = map(Path, sys.argv[1:])
err = err_path.read_text()
spec = importlib.util.spec_from_file_location("build_feed", root / "scripts/build-feed.py")
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

text = (feed / "index.json").read_text()
data = json.loads(text)
again = json.dumps(data, indent=2, sort_keys=True, ensure_ascii=False) + "\n"
if text != again:
    raise SystemExit("index.json is not canonical sorted JSON")
if data["schemaVersion"] != 1:
    raise SystemExit("schemaVersion")
bots = data["bots"]
names = [b["name"] for b in bots]
if names != ["Harbor", "North Team", "Pebble"]:
    raise SystemExit(f"name order {names}")
if data["generatedAt"] != max(b["updatedAt"] for b in bots):
    raise SystemExit("generatedAt is not the newest updatedAt")

allowed = {
    "avatar", "color", "id", "kind", "link", "memberIds",
    "name", "shape", "title", "updatedAt",
}
forbidden_keys = {"serverId", "harness", "voiceId", "secrets", "skills", "memory", "description"}
for bot in bots:
    extra = set(bot) - allowed
    if extra:
        raise SystemExit(f"unexpected keys {sorted(extra)}")
    if set(bot) & forbidden_keys:
        raise SystemExit(f"forbidden key on {bot['id']}")
    if not str(bot["updatedAt"]).endswith("+00:00"):
        raise SystemExit(f"updatedAt {bot['updatedAt']}")
    if bot["link"] != f"grokbot://app/v1/agent?id={bot['id']}":
        raise SystemExit(f"link {bot['link']}")

by_id = {b["id"]: b for b in bots}
harbor, group, pebble = by_id["agt-0001"], by_id["agt-0002"], by_id["agt-0003"]
if harbor["kind"] != "bot" or harbor["memberIds"] is not None:
    raise SystemExit("harbor should be a bot with null memberIds")
if harbor["shape"] != "circle" or harbor["color"] != "green":
    raise SystemExit("harbor mark")
if harbor["title"] != "Notes" or harbor["avatar"] != "avatars/agt-0001.png":
    raise SystemExit("harbor avatar or title")
if group["kind"] != "group" or group["memberIds"] != ["agt-0001", "agt-0003"]:
    raise SystemExit(f"group members {group['memberIds']}")
if group["shape"] != "squircle" or group["color"] != "blue" or group["avatar"] is not None:
    raise SystemExit("group mark")
if pebble["kind"] != "bot" or pebble["memberIds"] is not None:
    raise SystemExit("pebble kind")
if pebble["shape"] is not None or pebble["color"] is not None or pebble["avatar"] is not None:
    raise SystemExit("pebble should keep null shape, color, and avatar")

def strings_under(value, out):
    if isinstance(value, str):
        out.append(value)
    elif isinstance(value, dict):
        for item in value.values():
            strings_under(item, out)
    elif isinstance(value, list):
        for item in value:
            strings_under(item, out)

sensitive = []
for path in (root / "tests/fixtures/agents").glob("*/profile.json"):
    profile = json.loads(path.read_text())
    for key in ("description", "serverId", "harness", "voiceId", "secrets", "skills", "memory"):
        if key in profile:
            strings_under(profile[key], sensitive)
for blob in sensitive:
    if blob and blob in text:
        raise SystemExit("fixture private value was published")
if mod.LEAK.search(text):
    raise SystemExit("default feed matches a secret pattern")
if "customField" in text or "sample-unknown" in text:
    raise SystemExit("unknown profile key was published")
if "description" in text:
    raise SystemExit("description leaked into the default feed")
if "customField" not in err or "warning:" not in err:
    raise SystemExit("expected a warning for the unknown profile key")
if "Traceback" in err:
    raise SystemExit(err)

from PIL import Image
with Image.open(feed / "avatars/agt-0001.png") as im:
    if im.size != (128, 128):
        raise SystemExit(f"thumbnail size {im.size}")
pngs = sorted((feed / "avatars").glob("*.png"))
if [p.name for p in pngs] != ["agt-0001.png"]:
    raise SystemExit(f"avatars {[p.name for p in pngs]}")
print("default feed ok")
PY

python3 scripts/build-feed.py --agents-dir tests/fixtures/agents --out "$TMP/feed" --check
python3 scripts/build-feed.py --agents-dir tests/fixtures/agents --out "$TMP/feed" --check
python3 scripts/build-feed.py --agents-dir tests/fixtures/agents --out "$TMP/feed-again" >/dev/null
diff -r "$TMP/feed" "$TMP/feed-again"

mkdir "$TMP/empty"
if python3 scripts/build-feed.py --agents-dir tests/fixtures/agents --out "$TMP/empty" --check >/dev/null 2>&1; then
  echo "--check should fail when the feed is missing" >&2
  exit 1
fi
if [ -e "$TMP/empty/index.json" ] || [ -d "$TMP/empty/avatars" ]; then
  echo "--check wrote files" >&2
  exit 1
fi

printf '\n' >> "$TMP/feed/index.json"
if python3 scripts/build-feed.py --agents-dir tests/fixtures/agents --out "$TMP/feed" --check >/dev/null 2>&1; then
  echo "--check should fail after index.json changes" >&2
  exit 1
fi

python3 scripts/build-feed.py --agents-dir tests/fixtures/agents --out "$TMP/feed" >/dev/null
printf 'x' > "$TMP/feed/avatars/stale.png"
if python3 scripts/build-feed.py --agents-dir tests/fixtures/agents --out "$TMP/feed" --check >/dev/null 2>&1; then
  echo "--check should fail when an avatar is stale" >&2
  exit 1
fi
python3 scripts/build-feed.py --agents-dir tests/fixtures/agents --out "$TMP/feed" >/dev/null
if [ -e "$TMP/feed/avatars/stale.png" ]; then
  echo "stale avatar was not deleted" >&2
  exit 1
fi
python3 scripts/build-feed.py --agents-dir tests/fixtures/agents --out "$TMP/feed" --check >/dev/null

schema=$(sed -n 's/.*"schemaVersion"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$TMP/feed/index.json" | head -n 1)
if [ "$schema" != "1" ]; then
  echo "widget schema check would reject the built feed (got ${schema})" >&2
  exit 1
fi
printf '%s\n' '{ "schemaVersion": 2, "bots": [] }' > "$TMP/bad.json"
bad=$(sed -n 's/.*"schemaVersion"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$TMP/bad.json" | head -n 1)
if [ "$bad" = "1" ]; then
  echo "widget schema check would accept version 2" >&2
  exit 1
fi

python3 scripts/build-feed.py \
  --agents-dir tests/fixtures/agents \
  --out "$TMP/described" \
  --include-descriptions \
  >"$TMP/desc.out" 2>"$TMP/desc.err"

python3 - "$ROOT" "$TMP/described" <<'PY'
import importlib.util
import json
import sys
from pathlib import Path

root, feed = map(Path, sys.argv[1:])
spec = importlib.util.spec_from_file_location("build_feed", root / "scripts/build-feed.py")
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
text = (feed / "index.json").read_text()
data = json.loads(text)
by_id = {b["id"]: b for b in data["bots"]}
harbor = by_id["agt-0001"]
if harbor["description"] != "Draft notes. token REDACTED end.":
    raise SystemExit("scrubbed description mismatch")
if by_id["agt-0002"]["description"] != "A sample group for the fixture.":
    raise SystemExit("group description was not kept when opted in")
if by_id["agt-0003"]["description"] != "":
    raise SystemExit("empty description")
raw = json.loads((root / "tests/fixtures/agents/agt-0001/profile.json").read_text())
if raw["description"] in text or raw["memory"] in text or raw["serverId"] in text:
    raise SystemExit("opt-in feed published a raw profile field")
if raw["secrets"]["api"] in text or "private-skill" in text or "fake-harness" in text:
    raise SystemExit("opt-in feed published a forbidden value")
if mod.LEAK.search(text):
    raise SystemExit("opt-in feed still matches a secret pattern")
for key in ("serverId", "harness", "voiceId", "secrets", "skills", "memory"):
    if f'"{key}"' in text:
        raise SystemExit(f"forbidden key {key} in opt-in feed")
cases = json.loads((root / "tests/fixtures/scrub-cases.json").read_text())
for case in cases:
    cleaned = mod.scrub(case)
    if cleaned == case or "REDACTED" not in cleaned or mod.LEAK.search(cleaned):
        raise SystemExit("scrub failed on a fixture case")
print("descriptions and scrub ok")
PY

expect_rc() {
  want=$1
  shift
  set +e
  "$@" >"$TMP/o" 2>"$TMP/e"
  rc=$?
  set -e
  if [ "$rc" -ne "$want" ]; then
    echo "exit $rc, want $want: $*" >&2
    cat "$TMP/e" >&2
    exit 1
  fi
}

mkdir -p "$TMP/bin" "$TMP/emptybin"
: > "$TMP/gh.log"
export GH_LOG="$TMP/gh.log"

cat > "$TMP/bin/gh-deny" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$GH_LOG"
exit 99
EOF
chmod +x "$TMP/bin/gh-deny"
ln -sf gh-deny "$TMP/bin/gh"

reset_log() {
  : > "$GH_LOG"
}

run_publish() {
  PATH="$TMP/bin:$PATH" GROKBOT_FEED_DIR="$TMP/not-a-feed" "$@"
}

reset_log
expect_rc 2 run_publish "$ROOT/scripts/publish-feed.sh"
reset_log
expect_rc 2 run_publish "$ROOT/scripts/publish-feed.sh" --repo 'not a repo'
reset_log
expect_rc 2 run_publish "$ROOT/scripts/publish-feed.sh" --repo 'https://github.com/a/b'
reset_log
expect_rc 2 run_publish "$ROOT/scripts/publish-feed.sh" --repo 'a/b/c'
reset_log
expect_rc 2 run_publish "$ROOT/scripts/publish-feed.sh" --repo 'a/b.git'
reset_log
expect_rc 2 run_publish "$ROOT/scripts/publish-feed.sh" --repo '../evil'
reset_log
expect_rc 2 run_publish "$ROOT/scripts/publish-feed.sh" --repo 'owner/name;touch'
if [ -s "$GH_LOG" ]; then
  echo "invalid --repo called gh" >&2
  cat "$GH_LOG" >&2
  exit 1
fi

cat > "$TMP/bin/gh-noauth" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$GH_LOG"
exit 1
EOF
chmod +x "$TMP/bin/gh-noauth"
ln -sf gh-noauth "$TMP/bin/gh"
reset_log
expect_rc 4 run_publish "$ROOT/scripts/publish-feed.sh" --repo example/grokbot-widget-feed
if [ "$(wc -l < "$GH_LOG" | tr -d ' ')" != "1" ]; then
  echo "auth failure should stop before any repo call" >&2
  cat "$GH_LOG" >&2
  exit 1
fi
grep -q "not logged in" "$TMP/e"
grep -q "Do not paste a token" "$TMP/e"

cat > "$TMP/bin/gh-public" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$GH_LOG"
if [ "$1" = "auth" ]; then
  exit 0
fi
if [ "$1" = "repo" ] && [ "$2" = "view" ]; then
  printf '%s\n' '{"visibility":"PUBLIC","isPrivate":false,"isEmpty":false}'
  exit 0
fi
exit 99
EOF
chmod +x "$TMP/bin/gh-public"
ln -sf gh-public "$TMP/bin/gh"
reset_log
expect_rc 1 run_publish "$ROOT/scripts/publish-feed.sh" --repo example/grokbot-widget-feed --include-descriptions
grep -q "PUBLIC" "$TMP/e"
grep -q "not private" "$TMP/e"
if grep -E -q 'repo create|repo clone|deploy-key|push' "$GH_LOG"; then
  echo "public repo was not refused before a write" >&2
  cat "$GH_LOG" >&2
  exit 1
fi
if [ -e "$TMP/not-a-feed" ]; then
  echo "public refusal still created a checkout" >&2
  exit 1
fi

reset_log
expect_rc 1 env PATH="$TMP/emptybin" "$ROOT/scripts/publish-feed.sh" --repo example/grokbot-widget-feed
grep -q "not installed" "$TMP/e"

# Private key is rejected before gh, from a file and from stdin.
reset_log
ln -sf gh-deny "$TMP/bin/gh"
expect_rc 1 env PATH="$TMP/bin:$PATH" "$ROOT/scripts/add-phone-key.sh" \
  --repo example/grokbot-widget-feed "$ROOT/tests/fixtures/fake-private.key"
grep -q "private key" "$TMP/e"
if grep -q "AAAAFAKE" "$TMP/e"; then
  echo "private key material was printed" >&2
  exit 1
fi
if [ -s "$GH_LOG" ]; then
  echo "private key rejection called gh" >&2
  cat "$GH_LOG" >&2
  exit 1
fi
reset_log
expect_rc 1 env PATH="$TMP/bin:$PATH" "$ROOT/scripts/add-phone-key.sh" \
  --repo example/grokbot-widget-feed < "$ROOT/tests/fixtures/fake-private.key"
grep -q "private key" "$TMP/e"
if [ -s "$GH_LOG" ]; then
  echo "stdin private key called gh" >&2
  exit 1
fi

printf '%s\n' 'this is not a key' > "$TMP/not-a-key"
reset_log
expect_rc 1 env PATH="$TMP/bin:$PATH" "$ROOT/scripts/add-phone-key.sh" \
  --repo example/grokbot-widget-feed "$TMP/not-a-key"
grep -q "public SSH key" "$TMP/e"
if [ -s "$GH_LOG" ]; then
  echo "invalid key called gh" >&2
  exit 1
fi

# A real public key is not mistaken for a private key. gh is not logged in, so we stop there.
if ! command -v ssh-keygen >/dev/null 2>&1; then
  echo "ssh-keygen is required for the public-key test" >&2
  exit 1
fi
ssh-keygen -t ed25519 -f "$TMP/phone" -N "" -C "widget-test" >/dev/null
rm -f "$TMP/phone"
reset_log
ln -sf gh-noauth "$TMP/bin/gh"
expect_rc 4 env PATH="$TMP/bin:$PATH" "$ROOT/scripts/add-phone-key.sh" \
  --repo example/grokbot-widget-feed "$TMP/phone.pub"
grep -q "not logged in" "$TMP/e"
if grep -q "private key" "$TMP/e"; then
  echo "a public key was rejected as private" >&2
  exit 1
fi
if ! grep -q '^auth status$' "$GH_LOG"; then
  echo "public key did not reach the auth check" >&2
  cat "$GH_LOG" >&2
  exit 1
fi

# Happy path against a local bare repo. No GitHub calls, no network.
# The phone-side shallow fetch cannot fast-forward; publish must still push.
bare=$TMP/bare
seed=$TMP/seed
git init -q -b main --bare "$bare"
git init -q -b main "$seed"
git -C "$seed" config user.email widget-test@localhost
git -C "$seed" config user.name "widget test"
printf '%s\n' '{"schemaVersion":1,"generatedAt":null,"bots":[]}' > "$seed/index.json"
git -C "$seed" add index.json
git -C "$seed" commit -q -m seed
git -C "$seed" remote add origin "$bare"
git -C "$seed" push -q origin main

export LOCAL_BARE=$bare
cat > "$TMP/bin/gh-local" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$GH_LOG"
if [ "$1" = "auth" ]; then
  exit 0
fi
if [ "$1" = "repo" ] && [ "$2" = "view" ]; then
  if printf '%s' "$*" | grep -q defaultBranchRef; then
    printf '%s\n' main
    exit 0
  fi
  printf '%s\n' '{"visibility":"PRIVATE","isPrivate":true,"isEmpty":false}'
  exit 0
fi
if [ "$1" = "repo" ] && [ "$2" = "clone" ]; then
  dest=$4
  git clone -q --depth 1 "$LOCAL_BARE" "$dest"
  git -C "$dest" remote set-url origin "https://github.com/example/grokbot-widget-feed.git"
  # Match the full URL. A prefix rewrite would append ".git" onto the bare path.
  git -C "$dest" config "url.${LOCAL_BARE}.insteadOf" "https://github.com/example/grokbot-widget-feed.git"
  exit 0
fi
printf '%s\n' "unexpected gh: $*" >> "$GH_LOG"
exit 99
EOF
chmod +x "$TMP/bin/gh-local"
ln -sf gh-local "$TMP/bin/gh"
reset_log
expect_rc 0 env PATH="$TMP/bin:$PATH" GROKBOT_FEED_DIR="$TMP/checkout" \
  "$ROOT/scripts/publish-feed.sh" \
  --repo example/grokbot-widget-feed \
  --agents-dir "$ROOT/tests/fixtures/agents"
grep -q "feed pushed" "$TMP/o"
grep -q "Harbor" "$TMP/checkout/index.json"
if grep -q '"description"' "$TMP/checkout/index.json"; then
  echo "published feed included descriptions" >&2
  exit 1
fi
before=$(git --git-dir="$bare" rev-list --count main)
reset_log
expect_rc 0 env PATH="$TMP/bin:$PATH" GROKBOT_FEED_DIR="$TMP/checkout" \
  "$ROOT/scripts/publish-feed.sh" \
  --repo example/grokbot-widget-feed \
  --agents-dir "$ROOT/tests/fixtures/agents"
grep -q "feed unchanged" "$TMP/o"
after=$(git --git-dir="$bare" rev-list --count main)
if [ "$before" != "$after" ]; then
  echo "unchanged feed was pushed again ($before -> $after)" >&2
  exit 1
fi
if git config --global user.name >/dev/null 2>&1; then
  echo "publish script wrote a global git identity" >&2
  exit 1
fi
if grep -E -q 'repo create|deploy-key|--public|allow-write' "$GH_LOG"; then
  echo "happy path used a write or public gh command" >&2
  cat "$GH_LOG" >&2
  exit 1
fi

if [ "$FEED_BEFORE" -eq 0 ] && [ -e /workspace/grokbot-widget-feed ]; then
  echo "a test created /workspace/grokbot-widget-feed" >&2
  exit 1
fi

echo "all tests passed"
