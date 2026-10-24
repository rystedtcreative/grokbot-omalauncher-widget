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
  | grep -v -e 'rystedtcreative/grokbot-omalauncher-widget' -e 'README.md:.*Made by Joshua Rystedt at'; then
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
assert "__EXPECTED_COMMIT__" in text
assert "__EXPECTED_CHECKSUMS_SHA256__" in text
assert "git -C /workspace/grokbot-omalauncher-widget rev-parse HEAD" in text
assert "sha256sum checksums.txt" in text
assert "sha256sum -c checksums.txt" in text
size = len(text.encode())
assert size < 7168, f"SKILL.md is {size} bytes"
print(f"skill ok ({size} bytes)")
PY

for needle in \
  'git@github.com:YOUR_USER/grokbot-widget-feed.git' \
  'let pinnedName = ""' \
  'every 10m' \
  'BatchMode=yes' \
  'GIT_TERMINAL_PROMPT=0' \
  'schemaVersion' \
  'unknown feed schema' \
  'StrictHostKeyChecking=yes' \
  'UserKnownHostsFile=$kh' \
  '.cache/omalauncher/grokbot-widget/known_hosts' \
  'grokbot://app/v1/agent?id=${b.id}' \
  '^[A-Za-z0-9-]{1,64}$' \
  'reEsc'
do
  if ! grep -q -F "$needle" widget/grokbot.owl; then
    echo "widget is missing: $needle" >&2
    exit 1
  fi
done

if grep -n -F '.link' widget/grokbot.owl; then
  echo "widget reads .link" >&2
  exit 1
fi
if grep -q 'accept-new' widget/grokbot.owl; then
  echo "widget still accepts a new host key" >&2
  exit 1
fi
if grep -F '${lower(b.name)}' widget/grokbot.owl; then
  echo "bot name is interpolated into a regex unescaped" >&2
  exit 1
fi

python3 - <<'PY'
import subprocess
from pathlib import Path
owl = Path("widget/grokbot.owl").read_text()
lines = [ln for ln in Path("widget/known_hosts").read_text().splitlines() if ln.strip()]
kinds = ("ssh-ed25519", "ecdsa-sha2-nistp256", "ssh-rsa")
if len(lines) != 3 or any(not ln.startswith("github.com " + k + " ") for ln, k in zip(lines, kinds)):
    raise SystemExit(f"known_hosts should be github.com ed25519, ecdsa, rsa; got {len(lines)} lines")
for ln in lines:
    if ln not in owl:
        raise SystemExit("widget command is missing a known_hosts line")
fp = subprocess.check_output(["ssh-keygen", "-lf", "widget/known_hosts"], text=True)
expect = {
    "ED25519": "SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU",
    "ECDSA": "SHA256:p2QAMXNIC1TJYWeIOttrVc98/R1BUFWu3/LiyKgUfQM",
    "RSA": "SHA256:uNiVztksCsDhcc0u9e8BujQXVUpKZIDTMczCvj3tD2s",
}
found = {}
for line in fp.splitlines():
    parts = line.split()
    # 256 SHA256:... github.com (ED25519)
    found[parts[-1].strip("()")] = parts[1]
if found != expect:
    raise SystemExit(f"host key fingerprints {found}")
print("widget link, name escape, and host keys ok")
PY

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

def joined(*parts):
    return "".join(parts)

# Built here, not stored as secret-shaped literals.
runtime_cases = [
    joined("sk_live_", "a" * 24),
    joined("sk_test_", "b" * 24),
    joined("rk_live_", "c" * 24),
    joined("xai-", "d" * 20),
    joined("eyJ", "e" * 12, ".eyJ", "f" * 12, ".", "g" * 12),
    joined("https://", "user", ":", "pass", "@example.com/feed"),
    joined("https://hooks.slack.com/services/", "T" * 9, "/", "B" * 9, "/", "h" * 16),
    "password: " + joined("hunter2"),
    "password is " + joined("hunter2"),
    "pw=" + joined("hunter2"),
]
for case in runtime_cases:
    cleaned = mod.scrub("note " + case + " end")
    if case in cleaned or "REDACTED" not in cleaned or mod.LEAK.search(cleaned):
        raise SystemExit("scrub failed on a runtime case: " + cleaned)
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
# The key is generated here and deleted with the temp dir. No key file is committed.
if ! command -v ssh-keygen >/dev/null 2>&1; then
  echo "ssh-keygen is required for the key tests" >&2
  exit 1
fi
ssh-keygen -t ed25519 -f "$TMP/throwaway" -N "" -C "widget-test-private" >/dev/null
priv_line=$(awk 'NR==2 { print; exit }' "$TMP/throwaway")
reset_log
ln -sf gh-deny "$TMP/bin/gh"
expect_rc 1 env PATH="$TMP/bin:$PATH" "$ROOT/scripts/add-phone-key.sh" \
  --repo example/grokbot-widget-feed "$TMP/throwaway"
grep -q "private key" "$TMP/e"
if grep -q -F "$priv_line" "$TMP/e"; then
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
  --repo example/grokbot-widget-feed < "$TMP/throwaway"
grep -q "private key" "$TMP/e"
if grep -q -F "$priv_line" "$TMP/e"; then
  echo "stdin private key material was printed" >&2
  exit 1
fi
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

# After adding, the key must read back as read-only. gh documents readOnly, but
# real gh 2.103 returns read_only, so both shapes are accepted; false is refused.
cat > "$TMP/bin/gh-keys" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$GH_LOG"
case "$1 $2 $3" in
  "auth status"*) exit 0 ;;
  "repo view"*) printf '%s\n' '{"visibility":"PRIVATE","isPrivate":true}'; exit 0 ;;
  "repo deploy-key add")
    case "$*" in *--help*) echo "  -w, --allow-write"; exit 0 ;; esac
    exit 0 ;;
  "repo deploy-key list")
    k=$(cut -d' ' -f1,2 "$KEY_PUB")
    printf '[{"id":7,"key":"%s","title":"omalauncher-phone",%s}]\n' "$k" "$KEY_RO"
    exit 0 ;;
esac
exit 99
EOF
chmod +x "$TMP/bin/gh-keys"
ln -sf gh-keys "$TMP/bin/gh"
for ro in '"read_only":true' '"readOnly":true'; do
  reset_log
  expect_rc 0 env PATH="$TMP/bin:$PATH" KEY_PUB="$TMP/phone.pub" KEY_RO="$ro" \
    "$ROOT/scripts/add-phone-key.sh" --repo example/grokbot-widget-feed "$TMP/phone.pub"
  grep -q "read-only deploy key added" "$TMP/o"
  if grep -q -- '--allow-write' "$GH_LOG"; then
    echo "add-phone-key passed --allow-write" >&2
    exit 1
  fi
done
for ro in '"read_only":false' '"readOnly":false'; do
  reset_log
  expect_rc 1 env PATH="$TMP/bin:$PATH" KEY_PUB="$TMP/phone.pub" KEY_RO="$ro" \
    "$ROOT/scripts/add-phone-key.sh" --repo example/grokbot-widget-feed "$TMP/phone.pub"
  grep -q "is not read-only" "$TMP/e"
done
ln -sf gh-deny "$TMP/bin/gh"

# A pushInsteadOf that mentions github.com is refused before gh or any network git command.
REAL_GIT=$(command -v git)
export REAL_GIT
GIT_WRAP_LOG=$TMP/gitwrap.log
export GIT_WRAP_LOG
cat > "$TMP/bin/git-nonet" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "${GIT_WRAP_LOG:-/dev/null}"
prev=
sub=
for a in "$@"; do
  if [ "$prev" = "-C" ] || [ "$prev" = "-c" ]; then
    prev=$a
    continue
  fi
  case "$a" in
    -*) prev=$a; continue ;;
  esac
  sub=$a
  break
done
case "$sub" in
  fetch|push|ls-remote|clone|pull)
    printf '%s\n' "network git: $*" >> "${GIT_WRAP_LOG:-/dev/null}"
    exit 97
    ;;
esac
exec "$REAL_GIT" "$@"
EOF
chmod +x "$TMP/bin/git-nonet"
ln -sf git-nonet "$TMP/bin/git"
printf '%s\n' '[url "https://evil.example/git"]' '	pushInsteadOf = https://github.com/' > "$TMP/gitconfig"
reset_log
: > "$GIT_WRAP_LOG"
ln -sf gh-deny "$TMP/bin/gh"
expect_rc 1 env PATH="$TMP/bin:$PATH" GIT_CONFIG_GLOBAL="$TMP/gitconfig" \
  GROKBOT_FEED_DIR="$TMP/not-a-feed" \
  "$ROOT/scripts/publish-feed.sh" --repo example/grokbot-widget-feed
grep -q "pushInsteadOf" "$TMP/e"
grep -q "Not pushing" "$TMP/e"
if [ -s "$GH_LOG" ]; then
  echo "pushInsteadOf refusal called gh" >&2
  cat "$GH_LOG" >&2
  exit 1
fi
if grep -q "network git:" "$GIT_WRAP_LOG"; then
  echo "pushInsteadOf refusal reached a network git command" >&2
  cat "$GIT_WRAP_LOG" >&2
  exit 1
fi

# A broad rewrite that never names github.com is still refused.
for rule in 'insteadOf = https://' 'pushInsteadOf = https://' 'insteadOf = git@'; do
  printf '%s\n' '[url "https://evil.example/"]' "	$rule" > "$TMP/gitconfig-broad"
  reset_log
  : > "$GIT_WRAP_LOG"
  ln -sf gh-deny "$TMP/bin/gh"
  expect_rc 1 env PATH="$TMP/bin:$PATH" GIT_CONFIG_GLOBAL="$TMP/gitconfig-broad" \
    GROKBOT_FEED_DIR="$TMP/not-a-feed" \
    "$ROOT/scripts/publish-feed.sh" --repo example/grokbot-widget-feed
  grep -q "would rewrite" "$TMP/e"
  if grep -q "network git:" "$GIT_WRAP_LOG"; then
    echo "broad rewrite ($rule) reached a network git command" >&2
    exit 1
  fi
done

# A rewrite that never mentions github.com is not refused here.
printf '%s\n' '[url "https://example.com/mirror"]' '	insteadOf = https://gitlab.com/' > "$TMP/gitconfig-ok"
reset_log
: > "$GIT_WRAP_LOG"
ln -sf gh-noauth "$TMP/bin/gh"
expect_rc 4 env PATH="$TMP/bin:$PATH" GIT_CONFIG_GLOBAL="$TMP/gitconfig-ok" \
  GROKBOT_FEED_DIR="$TMP/not-a-feed" \
  "$ROOT/scripts/publish-feed.sh" --repo example/grokbot-widget-feed
grep -q "not logged in" "$TMP/e"
if grep -q "would rewrite" "$TMP/e"; then
  echo "a non-github insteadOf was refused" >&2
  exit 1
fi
if grep -q "network git:" "$GIT_WRAP_LOG"; then
  echo "non-github insteadOf reached a network git command" >&2
  cat "$GIT_WRAP_LOG" >&2
  exit 1
fi
rm -f "$TMP/bin/git"

if grep -E -n '[[:space:]]push[[:space:]]+(-u[[:space:]]+)?("?\$\{?origin\}?|origin)([[:space:]]|$)' scripts/publish-feed.sh; then
  echo "publish-feed.sh pushes via origin" >&2
  exit 1
fi
grep -q -F 'HEAD:refs/heads/${def:-main}' scripts/publish-feed.sh
grep -q 'https://github.com/${REPO}.git' scripts/publish-feed.sh

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
  exit 0
fi
printf '%s\n' "unexpected gh: $*" >> "$GH_LOG"
exit 99
EOF
chmod +x "$TMP/bin/gh-local"
ln -sf gh-local "$TMP/bin/gh"
# Redirect only the test's GitHub URL. Production has no such wrapper.
cat > "$TMP/bin/git-rewrite" <<'EOF'
#!/usr/bin/env python3
import os, sys
real = os.environ["REAL_GIT"]
bare = os.environ["LOCAL_BARE"]
log = os.environ.get("GIT_WRAP_LOG", "")
githubs = {
    "https://github.com/example/grokbot-widget-feed.git",
    "git@github.com:example/grokbot-widget-feed.git",
}
if log:
    with open(log, "a") as fh:
        fh.write(" ".join(sys.argv[1:]) + "\n")
args = sys.argv[1:]

def subcommand(argv):
    i = 0
    while i < len(argv):
        a = argv[i]
        if a in ("-C", "-c"):
            i += 2
            continue
        if a.startswith("-"):
            i += 1
            continue
        return a, i
    return "", 0

def exec_git(argv):
    os.execv(real, [real, *argv])

sub, idx = subcommand(args)
if sub == "ls-remote":
    exec_git([bare if a == "origin" else a for a in args])
if sub == "fetch" and "origin" in args:
    prefix = args[:idx]
    rest = args[idx + 1:]
    depth = []
    branch = None
    i = 0
    while i < len(rest):
        a = rest[i]
        if a == "--depth" and i + 1 < len(rest):
            depth = ["--depth", rest[i + 1]]
            i += 2
            continue
        if a == "origin":
            i += 1
            continue
        if a.startswith("-"):
            i += 1
            continue
        branch = a
        i += 1
    if branch is None:
        refspec = "+refs/heads/*:refs/remotes/origin/*"
    else:
        refspec = "+refs/heads/%s:refs/remotes/origin/%s" % (branch, branch)
    exec_git([*prefix, "fetch", *depth, bare, refspec])
if sub == "push":
    if "origin" in args:
        sys.stderr.write("test wrapper: push via origin\n")
        sys.exit(99)
    exec_git([bare if a in githubs else a for a in args])
exec_git(args)
EOF
chmod +x "$TMP/bin/git-rewrite"
ln -sf git-rewrite "$TMP/bin/git"
: > "$GIT_WRAP_LOG"
reset_log
expect_rc 0 env PATH="$TMP/bin:$PATH" GROKBOT_FEED_DIR="$TMP/checkout" \
  "$ROOT/scripts/publish-feed.sh" \
  --repo example/grokbot-widget-feed \
  --agents-dir "$ROOT/tests/fixtures/agents"
grep -q "feed pushed" "$TMP/o"
if ! grep -q -F "push https://github.com/example/grokbot-widget-feed.git HEAD:refs/heads/main" "$GIT_WRAP_LOG"; then
  echo "publish did not push the explicit main ref" >&2
  cat "$GIT_WRAP_LOG" >&2
  exit 1
fi
if grep -E '(^| )push( | .* )origin( |$)' "$GIT_WRAP_LOG"; then
  echo "publish pushed via origin" >&2
  cat "$GIT_WRAP_LOG" >&2
  exit 1
fi
grep -q "Harbor" "$TMP/checkout/index.json"
if grep -q '"description"' "$TMP/checkout/index.json"; then
  echo "published feed included descriptions" >&2
  exit 1
fi
before=$(git --git-dir="$bare" rev-list --count main)
reset_log
: > "$GIT_WRAP_LOG"
expect_rc 0 env PATH="$TMP/bin:$PATH" GROKBOT_FEED_DIR="$TMP/checkout" \
  "$ROOT/scripts/publish-feed.sh" \
  --repo example/grokbot-widget-feed \
  --agents-dir "$ROOT/tests/fixtures/agents"
grep -q "feed unchanged" "$TMP/o"
if grep -q -F "HEAD:refs/heads/" "$GIT_WRAP_LOG"; then
  echo "unchanged feed still tried to push" >&2
  cat "$GIT_WRAP_LOG" >&2
  exit 1
fi
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

# First push into an empty repo still names main explicitly.
emptybare=$TMP/emptybare
git init -q -b main --bare "$emptybare"
: > "$GIT_WRAP_LOG"
reset_log
expect_rc 0 env PATH="$TMP/bin:$PATH" LOCAL_BARE="$emptybare" GROKBOT_FEED_DIR="$TMP/emptyco" \
  "$ROOT/scripts/publish-feed.sh" \
  --repo example/grokbot-widget-feed \
  --agents-dir "$ROOT/tests/fixtures/agents"
grep -q "feed pushed" "$TMP/o"
if ! grep -q -F "push https://github.com/example/grokbot-widget-feed.git HEAD:refs/heads/main" "$GIT_WRAP_LOG"; then
  echo "empty repo was not pushed to main" >&2
  cat "$GIT_WRAP_LOG" >&2
  exit 1
fi
git --git-dir="$emptybare" rev-parse --verify refs/heads/main >/dev/null
grep -q "Harbor" "$TMP/emptyco/index.json"

# phone-install-line.sh refuses bad input, and its line installs only a verified widget.
for bad in 'nope' 'a/b/c' 'a/b;rm' "a/b'" '-a/b' 'a-/b' 'a/b.git' 'a b/c' 'a/$(id)'; do
  expect_rc 2 "$ROOT/scripts/phone-install-line.sh" --repo "$bad"
  if [ -s "$TMP/o" ]; then
    echo "phone-install-line.sh printed a line for repo $bad" >&2
    exit 1
  fi
done
for bad in 'a"b' "a'b" 'a\b' 'a|b' 'a$b' 'a`b' 'a&b' "$(printf 'a\tb')" "$(printf 'a\nb')" ' a' "$(printf '%065d' 0)"; do
  expect_rc 2 "$ROOT/scripts/phone-install-line.sh" --repo octo/feed --pin "$bad"
  if [ -s "$TMP/o" ]; then
    echo "phone-install-line.sh printed a line for a bad pin" >&2
    exit 1
  fi
done
expect_rc 2 "$ROOT/scripts/phone-install-line.sh" --repo octo/feed --ref "v1;rm"
expect_rc 2 "$ROOT/scripts/phone-install-line.sh" --repo octo/feed --base-url "http://x/';id"
expect_rc 0 "$ROOT/scripts/phone-install-line.sh" --repo octo/feed
if [ "$(wc -l < "$TMP/o")" -ne 1 ]; then
  echo "install line is not one line" >&2
  exit 1
fi
grep -q -F "curl -fsSL 'https://raw.githubusercontent.com/rystedtcreative/grokbot-omalauncher-widget/v0.1.0/widget/grokbot.owl'" "$TMP/o"
grep -q -F "$(sha256sum widget/grokbot.owl | cut -d ' ' -f 1)" "$TMP/o"
if grep -q 'pinnedName = "' "$TMP/o"; then
  echo "install line set a pin nobody asked for" >&2
  exit 1
fi
expect_rc 0 "$ROOT/scripts/phone-install-line.sh" --repo octo/feed --ref v9.9.9
grep -q -F '/grokbot-omalauncher-widget/v9.9.9/widget/grokbot.owl' "$TMP/o"

if command -v curl >/dev/null 2>&1; then
  srv=$TMP/srv
  mkdir -p "$srv/good/widget" "$srv/bad/widget"
  cp widget/grokbot.owl "$srv/good/widget/grokbot.owl"
  sed 's/StrictHostKeyChecking=yes/StrictHostKeyChecking=no/' widget/grokbot.owl > "$srv/bad/widget/grokbot.owl"
  python3 - "$srv" "$TMP/port" >"$TMP/http.log" 2>&1 <<'PY' &
import functools, http.server, sys
root, portfile = sys.argv[1], sys.argv[2]
handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=root)
srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
open(portfile, "w").write(str(srv.server_address[1]))
srv.serve_forever()
PY
  HTTP_PID=$!
  trap 'kill "$HTTP_PID" 2>/dev/null || true; rm -rf "$TMP"' EXIT
  i=0
  while [ ! -s "$TMP/port" ] && [ "$i" -lt 50 ]; do
    sleep 0.1
    i=$((i + 1))
  done
  base="http://127.0.0.1:$(cat "$TMP/port")"

  expect_rc 0 "$ROOT/scripts/phone-install-line.sh" --repo octo-cat/my.feed --pin "Harbor Bot" --base-url "$base/good"
  line=$(cat "$TMP/o")
  for shell in sh bash; do
    command -v "$shell" >/dev/null 2>&1 || continue
    home=$TMP/phone-$shell
    mkdir -p "$home"
    HOME=$home "$shell" -c "$line" >"$TMP/install.out" 2>&1
    grep -q "widget installed" "$TMP/install.out"
    python3 - "$home/.config/omalauncher/widgets" <<'PY'
import sys
from pathlib import Path
d = Path(sys.argv[1])
names = sorted(p.name for p in d.iterdir())
if names != ["grokbot.owl"]:
    raise SystemExit(f"widgets dir has {names}")
got = (d / "grokbot.owl").read_text()
want = Path("widget/grokbot.owl").read_text()
want = want.replace("YOUR_USER/grokbot-widget-feed", "octo-cat/my.feed")
want = want.replace('let pinnedName = ""', 'let pinnedName = "Harbor Bot"')
if got != want:
    raise SystemExit("installed widget differs from the template plus repo and pin")
if 'repo="git@github.com:octo-cat/my.feed.git"' not in got:
    raise SystemExit("installed widget has the wrong repo")
PY
  done

  # A tampered file is refused and leaves an existing widget alone.
  expect_rc 0 "$ROOT/scripts/phone-install-line.sh" --repo octo-cat/my.feed --base-url "$base/bad"
  bad_line=$(cat "$TMP/o")
  home=$TMP/phone-tampered
  mkdir -p "$home"
  HOME=$home sh -c "$bad_line" >"$TMP/install.out" 2>&1
  grep -q "tamper check" "$TMP/install.out"
  if [ -e "$home/.config" ]; then
    echo "tampered install wrote files" >&2
    exit 1
  fi
  home=$TMP/phone-sh
  cp "$home/.config/omalauncher/widgets/grokbot.owl" "$TMP/before.owl"
  HOME=$home sh -c "$bad_line" >"$TMP/install.out" 2>&1
  grep -q "tamper check" "$TMP/install.out"
  cmp "$TMP/before.owl" "$home/.config/omalauncher/widgets/grokbot.owl"
  if [ "$(ls -A "$home/.config/omalauncher/widgets")" != "grokbot.owl" ]; then
    echo "tampered install left files behind" >&2
    exit 1
  fi

  # A missing file (bad ref) installs nothing.
  expect_rc 0 "$ROOT/scripts/phone-install-line.sh" --repo octo-cat/my.feed --base-url "$base/missing"
  home=$TMP/phone-missing
  mkdir -p "$home"
  HOME=$home sh -c "$(cat "$TMP/o")" >"$TMP/install.out" 2>&1
  grep -q "Install failed" "$TMP/install.out"
  if [ -e "$home/.config" ]; then
    echo "failed download wrote files" >&2
    exit 1
  fi
  kill "$HTTP_PID" 2>/dev/null || true
  echo "phone install line ok"
else
  echo "curl missing: skipped the phone install line run" >&2
  exit 1
fi

# release-skill.sh fills placeholders from a tag and refuses a dirty tree or a skill without them.
rel=$TMP/relkit
mkdir -p "$rel"
tar -C "$ROOT" -cf - --exclude .git --exclude dist --exclude __pycache__ --exclude '*.pyc' . | tar -C "$rel" -xf -
git -C "$rel" init -q -b main
git -C "$rel" config user.email widget-test@localhost
git -C "$rel" config user.name "widget test"
git -C "$rel" add -A
git -C "$rel" commit -q -m base
git -C "$rel" tag v0.1.0-test
( cd "$rel" && scripts/release-skill.sh v0.1.0-test ) >"$TMP/rel.out"
python3 - "$rel" <<'PY'
import hashlib, subprocess, sys
from pathlib import Path
root = Path(sys.argv[1])
text = (root / "dist/SKILL.md").read_text()
if "__EXPECTED_COMMIT__" in text or "__EXPECTED_CHECKSUMS_SHA256__" in text:
    raise SystemExit("filled skill still has placeholders")
commit = subprocess.check_output(["git", "-C", str(root), "rev-parse", "v0.1.0-test^{commit}"], text=True).strip()
digest = hashlib.sha256((root / "checksums.txt").read_bytes()).hexdigest()
if commit not in text or digest not in text:
    raise SystemExit("filled skill is missing the tag commit or checksums digest")
if not text.startswith("---\n"):
    raise SystemExit("filled skill lost its frontmatter")
print("release skill ok")
PY
printf '\n' >> "$rel/README.md"
if ( cd "$rel" && scripts/release-skill.sh v0.1.0-test ) >"$TMP/rel.out" 2>"$TMP/rel.err"; then
  echo "release-skill.sh ran on a dirty tree" >&2
  exit 1
fi
grep -q "dirty tree" "$TMP/rel.err"
git -C "$rel" checkout -q -- .
python3 - "$rel/setup-bot/SKILL.md" <<'PY'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
text = path.read_text().replace("__EXPECTED_COMMIT__", "COMMIT").replace("__EXPECTED_CHECKSUMS_SHA256__", "SUM")
if "__EXPECTED_COMMIT__" in text or "__EXPECTED_CHECKSUMS_SHA256__" in text:
    raise SystemExit("failed to strip placeholders in the fixture")
path.write_text(text)
PY
git -C "$rel" add setup-bot/SKILL.md
git -C "$rel" commit -q -m "drop placeholders"
git -C "$rel" tag v-missing
if ( cd "$rel" && scripts/release-skill.sh v-missing ) >"$TMP/rel.out" 2>"$TMP/rel.err"; then
  echo "release-skill.sh accepted a skill with no placeholders" >&2
  exit 1
fi
grep -q "placeholder missing" "$TMP/rel.err"

if [ "$FEED_BEFORE" -eq 0 ] && [ -e /workspace/grokbot-widget-feed ]; then
  echo "a test created /workspace/grokbot-widget-feed" >&2
  exit 1
fi

echo "all tests passed"
