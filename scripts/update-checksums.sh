#!/bin/sh
# Rewrite checksums.txt with sha256 of the widget and the scripts.
set -eu
cd "$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
tmp=$(mktemp)
sha256sum \
  scripts/add-phone-key.sh \
  scripts/build-feed.py \
  scripts/publish-feed.sh \
  scripts/update-checksums.sh \
  widget/grokbot.owl \
  > "$tmp"
mv "$tmp" checksums.txt
