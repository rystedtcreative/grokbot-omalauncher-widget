#!/bin/sh
# Print the one line the user pastes into Omalauncher's terminal on the phone.
# Usage: phone-install-line.sh --repo OWNER/NAME [--pin "Bot Name"] [--ref v0.1.0]
# The line downloads widget/grokbot.owl at REF, checks it against the sha256 of
# this checkout's copy, fills in the feed repo and pinned bot, and writes it to
# ~/.config/omalauncher/widgets/grokbot.owl, where Omalauncher loads it.
# --base-url is for tests only. It replaces the raw GitHub URL up to the ref.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)

REPO=
PIN=
REF=v0.1.0
BASE=

usage() {
  echo "usage: phone-install-line.sh --repo OWNER/NAME [--pin \"Bot Name\"] [--ref TAG]" >&2
  exit 2
}
die() {
  echo "error: $1" >&2
  exit 2
}
# Whole-string match. Rejects anything with a newline.
matches() {
  case "$1" in
    *'
'*) return 1 ;;
  esac
  printf '%s\n' "$1" | grep -E -q -x -e "$2"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --repo|--pin|--ref|--base-url)
      [ $# -ge 2 ] || usage
      case "$1" in
        --repo) REPO=$2 ;;
        --pin) PIN=$2 ;;
        --ref) REF=$2 ;;
        --base-url) BASE=$2 ;;
      esac
      shift 2
      ;;
    *) usage ;;
  esac
done

[ -n "$REPO" ] || usage
owner=${REPO%%/*}
name=${REPO#*/}
# GitHub owners: letters, digits, single hyphens, 1-39 chars. Names: letters, digits, . _ -
matches "$REPO" '[^/]+/[^/]+' || die "--repo must look like OWNER/NAME"
matches "$owner" '[A-Za-z0-9]([A-Za-z0-9]|-[A-Za-z0-9]){0,38}' || die "--repo owner is not a GitHub user name"
matches "$name" '[A-Za-z0-9_-][A-Za-z0-9._-]{0,99}' || die "--repo name has characters GitHub does not allow"
case "$name" in *.git) die "--repo name must not end in .git" ;; esac

if [ -n "$PIN" ]; then
  [ "${#PIN}" -le 64 ] || die "--pin is longer than 64 characters"
  case "$PIN" in
    *[\"\'\\\|\$\`\&]*) die "--pin must not contain quotes, backslashes, | \$ \` or &" ;;
    *'
'*) die "--pin must be one line" ;;
  esac
  if printf '%s' "$PIN" | LC_ALL=C grep -q '[[:cntrl:]]'; then
    die "--pin must not contain control characters"
  fi
  matches "$PIN" '[^ ].*[^ ]|[^ ]' || die "--pin must not start or end with a space"
fi

matches "$REF" '[A-Za-z0-9][A-Za-z0-9._-]{0,63}' || die "--ref must be a tag or branch name"
if [ -z "$BASE" ]; then
  BASE="https://raw.githubusercontent.com/rystedtcreative/grokbot-omalauncher-widget/$REF"
else
  matches "$BASE" 'https?://[A-Za-z0-9._:/-]+' || die "--base-url must be a plain http(s) URL"
fi

sum=$(sha256sum "$ROOT/widget/grokbot.owl" | awk '{ print $1 }')
grep -q -F 'git@github.com:YOUR_USER/grokbot-widget-feed.git' "$ROOT/widget/grokbot.owl" || die "widget has no repo placeholder"
grep -q -F 'let pinnedName = ""' "$ROOT/widget/grokbot.owl" || die "widget has no pinnedName line"

pin_sed=
if [ -n "$PIN" ]; then
  pin_sed=" -e 's|let pinnedName = \"\"|let pinnedName = \"$PIN\"|'"
fi

printf '%s\n' "d=\"\$HOME/.config/omalauncher/widgets\" t=\$(mktemp) && curl -fsSL '$BASE/widget/grokbot.owl' -o \"\$t\" && { echo '$sum  '\"\$t\" | sha256sum -c --status || { echo 'Stopped: the widget file failed its tamper check. Nothing was installed.'; false; }; } && mkdir -p \"\$d\" && sed -e 's|YOUR_USER/grokbot-widget-feed|$REPO|'$pin_sed \"\$t\" > \"\$d/.grokbot.part\" && mv \"\$d/.grokbot.part\" \"\$d/grokbot.owl\" && echo 'Grok Bot widget installed. Look on page 2.' || echo 'Install failed. Nothing was changed.'; rm -f \"\$t\" \"\$d/.grokbot.part\""
