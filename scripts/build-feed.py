#!/usr/bin/env python3
"""Build a minimal Grok Bot widget feed from local agent profiles.

Reads <agents-dir>/*/profile.json and writes, under --out:
  index.json          schemaVersion 1 feed (no descriptions unless opted in)
  avatars/<id>.png    128x128 PNG thumbnails, when Pillow and avatar.png exist

Descriptions stay off unless --include-descriptions is set. Even then, only a
scrubbed description string is added. serverId, harness, voiceId, secrets,
skills, and memory are never written.

Usage:
  python3 scripts/build-feed.py --out DIR
  python3 scripts/build-feed.py --out DIR --check
"""
import argparse
import io
import json
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

try:
    from PIL import Image, ImageOps
    HAVE_PILLOW = True
except ImportError:  # pragma: no cover
    HAVE_PILLOW = False

DEFAULT_AGENTS_DIR = Path("/home/box/agent-data/agents")
# Keys we may read. Anything else is ignored and warned about, not copied.
KNOWN_KEYS = {
    "name", "title", "description", "avatarShape", "avatarColor",
    "serverId", "harness", "namedBy", "voiceId", "secrets", "skills",
    "memory", "id", "kind", "members", "memberIds",
}
# Never appear as keys in the feed, even if a profile has them.
FORBIDDEN_OUTPUT_KEYS = {
    "serverId", "harness", "voiceId", "secrets", "skills", "memory",
}
THUMB = 128
SHELL_NAMES = {"", "new bot"}
INDEX_CAP = 1_000_000

# Secret scrub: replace live-looking values with REDACTED, keep env-var names.
SCRUB_PATTERNS = [
    (re.compile(r"\bsk-(?:[A-Za-z0-9_-]*-)?[A-Za-z0-9_-]{16,}"), "REDACTED"),
    (re.compile(r"\bgh[pousr]_[A-Za-z0-9]{20,}"), "REDACTED"),
    (re.compile(r"\bgithub_pat_[A-Za-z0-9_]{20,}"), "REDACTED"),
    (re.compile(r"\bxox[abposr]-[A-Za-z0-9-]{10,}"), "REDACTED"),
    (re.compile(r"\bAKIA[0-9A-Z]{16}\b"), "REDACTED"),
    (re.compile(r"\bAIza[0-9A-Za-z_-]{35}\b"), "REDACTED"),
    (re.compile(r"(?i)\b(Bearer)\s+[A-Za-z0-9._~+/=-]{16,}"), r"\1 REDACTED"),
    (re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----.*?-----END [A-Z ]*PRIVATE KEY-----", re.S),
     "REDACTED"),
    # NAME_WITH_KEY/SECRET/TOKEN/PASSWORD = <long value>  -> keep the name
    (re.compile(r"(?i)\b([A-Z0-9_]*(?:KEY|SECRET|TOKEN|PASSWORD|PASSWD|PWD)[A-Z0-9_]*\s*[=:]\s*)"
                r"([\"']?)[A-Za-z0-9._~+/=-]{16,}\2"), r"\1\2REDACTED\2"),
]
LEAK = re.compile(
    r"sk-(?:[A-Za-z0-9_-]*-)?[A-Za-z0-9_-]{16,}"
    r"|gh[pousr]_[A-Za-z0-9]{20,}"
    r"|github_pat_[A-Za-z0-9_]{20,}"
    r"|xox[abposr]-[A-Za-z0-9-]{10,}"
    r"|\bAKIA[0-9A-Z]{16}\b"
    r"|\bAIza[0-9A-Za-z_-]{35}\b"
    r"|-----BEGIN [A-Z ]*PRIVATE KEY-----"
)

_pillow_warned = False


def die(msg):
    print(f"error: {msg}", file=sys.stderr)
    sys.exit(2)


def scrub(text):
    for pat, repl in SCRUB_PATTERNS:
        text = pat.sub(repl, text)
    return text


def iso(ts):
    return datetime.fromtimestamp(int(ts), timezone.utc).isoformat(timespec="seconds")


def nullable(v):
    if v is None:
        return None
    if not isinstance(v, str):
        v = str(v)
    v = v.strip()
    return v if v else None


def as_text(v):
    if v is None:
        return ""
    if not isinstance(v, str):
        v = str(v)
    return v.strip()


def thumbnail(src):
    global _pillow_warned
    if not HAVE_PILLOW:
        if not _pillow_warned:
            print("warning: Pillow is not installed; skipping avatars "
                  "(pip install Pillow)", file=sys.stderr)
            _pillow_warned = True
        return None
    try:
        resample = Image.Resampling.LANCZOS if hasattr(Image, "Resampling") else Image.LANCZOS
        with Image.open(src) as im:
            im = ImageOps.exif_transpose(im).convert("RGBA")
            im = ImageOps.fit(im, (THUMB, THUMB), resample)
            buf = io.BytesIO()
            im.save(buf, format="PNG", optimize=True)
            return buf.getvalue()
    except Exception as e:  # noqa: BLE001 — one bad image should not drop the feed
        print(f"warning: {src}: could not make a thumbnail ({e})", file=sys.stderr)
        return None


def load_profile(path):
    try:
        data = json.loads(path.read_text())
    except json.JSONDecodeError as e:
        die(f"{path}: invalid JSON ({e})")
    if not isinstance(data, dict):
        die(f"{path}: profile.json must be an object")
    extra = sorted(set(data) - KNOWN_KEYS)
    if extra:
        print(f"warning: {path}: unknown key(s) {extra} (ignored, not published)",
              file=sys.stderr)
    return data


def load_members(path):
    try:
        data = json.loads(path.read_text())
    except json.JSONDecodeError as e:
        die(f"{path}: invalid JSON ({e})")
    if not isinstance(data, dict):
        die(f"{path}: group.json must be an object")
    extra = sorted(set(data) - {"memberIds"})
    if extra:
        print(f"warning: {path}: unknown key(s) {extra} (ignored, not published)",
              file=sys.stderr)
    members = data.get("memberIds") or []
    if not isinstance(members, list) or not all(isinstance(m, str) for m in members):
        die(f"{path}: memberIds must be a list of strings")
    return list(members)


def collect(agents_dir):
    bots = []
    for prof in sorted(agents_dir.glob("*/profile.json")):
        folder = prof.parent
        bot_id = folder.name
        data = load_profile(prof)
        name = (data.get("name") or "").strip()
        desc = data.get("description") or ""
        if not isinstance(desc, str):
            desc = str(desc)
        desc = desc.strip()
        if name.lower() in SHELL_NAMES and not desc:
            print(f"skip: empty shell {bot_id}", file=sys.stderr)
            continue
        if not name:
            die(f"{prof}: missing name")
        group_file = folder / "group.json"
        member_ids = load_members(group_file) if group_file.exists() else None
        avatar_src = folder / "avatar.png"
        bots.append({
            "id": bot_id,
            "kind": "group" if member_ids is not None else "bot",
            "name": name,
            "title": as_text(data.get("title")),
            "description": scrub(desc),
            "shape": nullable(data.get("avatarShape")),
            "color": nullable(data.get("avatarColor")),
            "memberIds": member_ids,
            "avatarSrc": avatar_src if avatar_src.is_file() else None,
            "updatedAt": iso(prof.stat().st_mtime),
        })
    bots.sort(key=lambda b: (b["name"].casefold(), b["id"]))
    return bots


def render(bots, include_descriptions):
    """Return {relative path: bytes} for index.json and avatar thumbnails."""
    out = {}
    entries = []
    for b in bots:
        avatar = None
        if b["avatarSrc"]:
            thumb = thumbnail(b["avatarSrc"])
            if thumb is not None:
                avatar = f"avatars/{b['id']}.png"
                out[avatar] = thumb
        entry = {
            "id": b["id"],
            "kind": b["kind"],
            "name": b["name"],
            "title": b["title"],
            "shape": b["shape"],
            "color": b["color"],
            "memberIds": b["memberIds"],
            "avatar": avatar,
            "link": f"grokbot://app/v1/agent?id={b['id']}",
            "updatedAt": b["updatedAt"],
        }
        if include_descriptions:
            entry["description"] = b["description"]
        entries.append(entry)
    generated_at = max((e["updatedAt"] for e in entries), default=None)
    index = {"schemaVersion": 1, "generatedAt": generated_at, "bots": entries}
    assert_safe(index, include_descriptions)
    blob = (json.dumps(index, indent=2, sort_keys=True, ensure_ascii=False) + "\n").encode()
    if LEAK.search(blob.decode()):
        die("refusing to write index.json; output still looks like a secret")
    if len(blob) >= INDEX_CAP:
        die("index.json is over the 1 MB widget cap")
    out["index.json"] = blob
    return out


def assert_safe(index, include_descriptions):
    for bot in index["bots"]:
        for key in bot:
            if key in FORBIDDEN_OUTPUT_KEYS:
                die(f"refusing to publish forbidden key {key}")
            if key == "description" and not include_descriptions:
                die("refusing to publish descriptions without --include-descriptions")


def stale_files(out_dir, files):
    stale = []
    avatars = out_dir / "avatars"
    if avatars.is_dir():
        for path in sorted(avatars.glob("*.png")):
            rel = path.relative_to(out_dir).as_posix()
            if rel not in files:
                stale.append(rel)
    return stale


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--check", action="store_true",
                    help="exit 1 if outputs would change; write nothing")
    ap.add_argument("--agents-dir", type=Path, default=DEFAULT_AGENTS_DIR)
    ap.add_argument("--out", type=Path, required=True,
                    help="directory for index.json and avatars/")
    ap.add_argument("--include-descriptions", action="store_true",
                    help="add scrubbed descriptions (off by default; "
                         "descriptions can hold private instructions)")
    args = ap.parse_args()
    if not args.agents_dir.is_dir():
        die(f"agents dir not found: {args.agents_dir}")

    files = render(collect(args.agents_dir), args.include_descriptions)
    out_dir = args.out
    changed = []
    for rel, data in files.items():
        path = out_dir / rel
        if not path.exists() or path.read_bytes() != data:
            changed.append(rel)
    stale = stale_files(out_dir, files) if out_dir.exists() else []

    if args.check:
        for rel in sorted(changed):
            print(f"would write: {rel}")
        for rel in stale:
            print(f"would delete: {rel}")
        if changed or stale:
            print("feed is out of date; run scripts/build-feed.py", file=sys.stderr)
            return 1
        print("feed up to date")
        return 0

    for rel in sorted(changed):
        path = out_dir / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(files[rel])
        print(f"wrote: {rel}")
    for rel in stale:
        (out_dir / rel).unlink()
        print(f"deleted: {rel}")
    n = json.loads(files["index.json"].decode())["bots"]
    print(f"{len(n)} entries; index.json {len(files['index.json'])} bytes; "
          f"{len(changed)} written, {len(stale)} deleted")
    return 0


if __name__ == "__main__":
    sys.exit(main())
