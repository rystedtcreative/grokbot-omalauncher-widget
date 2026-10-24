---
name: omalauncher-widget-setup
description: use this when the user wants an Omalauncher home-screen widget of their Grok Bots on Android, or asks to set up, install, refresh, or remove that private widget feed.
---

# Omalauncher widget setup

## First message

"Hi! I'll set up a home-screen widget of your Grok Bots in Omalauncher on your Android phone. It takes 10 to 20 minutes. We'll go one step at a time, and I'll wait for you after each one. Your bot list stays in a private GitHub repo you own. I'll never ask for a password or a token. First: is your phone Android 10 or newer, with a 64-bit (arm64) processor?"

## Rules

- ONE step per message. Say exactly what to tap or paste, put anything to paste alone in its own code block, and say what they should see. Then wait for them to confirm or paste what they see. Never skip ahead.
- If something fails, diagnose it with them (see Troubleshooting) before moving on.
- Never ask for a GitHub token, a password, or a private SSH key. Never print tokens.
- Do not show commands they don't run themselves.
- Not yet confirmed on a phone: the name of Omalauncher's Linux setting, the on-screen way to open its terminal, whether curl is preinstalled. Say so when it matters.

Kit: `https://github.com/rystedtcreative/grokbot-omalauncher-widget`, pinned tag `v0.1.0`. You see bot names, titles, avatars, colors, shapes and groups here, and the feed repo's visibility through `gh`. Never publish server ids, harness, voice ids, secrets, skills, memory, or descriptions (unless opted in). Nothing goes to the kit author.

## Prerequisites (one per message)

1. Android 10+, arm64. If not: "This widget only works in Omalauncher on Android 10+ with arm64, so I'll stop here."
2. Omalauncher installed from Google Play and set as home screen. If not, ask them to install it and message you back.
3. Omalauncher's Linux turned on (look in Omalauncher's settings for Linux; menu name not yet confirmed). The widget runs `git` there. The first download can take a while.
4. Grok Bot Android app installed and signed in.
5. A GitHub account. If none: "Make a free one at github.com, then come back."

## Steps

1. Run `gh auth status`. If it fails: "I'll hand you my computer screen. Sign in to GitHub the normal way, then hand it back. Don't paste a token." Hand over with the box-help handoff and have them run `gh auth login` (browser or device code). Re-check; if it still fails, stop.

2. "What should I call your private repo? I suggest grokbot-widget-feed. Say 'sounds good' to use it." Confirm `OWNER/NAME` once. It must stay private.

3. "Nothing for you to do: I'm installing the widget files, checking they haven't been tampered with, and building your bot list." Install the pinned tag, never a branch: `git clone --depth 1 --branch v0.1.0 https://github.com/rystedtcreative/grokbot-omalauncher-widget /workspace/grokbot-omalauncher-widget` (if present, fetch and check out that tag).
   Run nothing unless these match. If either still reads `__EXPECTED_...__`, stop: this copy isn't a finished release. Never skip the check.
   EXPECTED_COMMIT=__EXPECTED_COMMIT__
   EXPECTED_CHECKSUMS_SHA256=__EXPECTED_CHECKSUMS_SHA256__
   `git -C /workspace/grokbot-omalauncher-widget rev-parse HEAD` equals EXPECTED_COMMIT. There, `sha256sum checksums.txt` equals EXPECTED_CHECKSUMS_SHA256 (first field). Then `sha256sum -c checksums.txt`; every line must say OK.
   Then run `scripts/publish-feed.sh --repo OWNER/NAME`. No `--include-descriptions` unless they ask; if they do, warn that descriptions can hold private instructions and scrubbing can miss a secret. If it says the repo isn't private, stop. Never make it public.
   Create a routine running that publish command from the kit directory every 3 hours. Quiet on exit 0; on failure, message the error text (no tokens).

4. "Open Omalauncher's terminal (Super+T with a keyboard, or a terminal tile). Paste this and press Enter:"
   ```
   ssh-keygen -t ed25519 -f ~/grokbot-feed -N ""
   ```
   "You'll see a few lines ending in a box of symbols. Tell me when you do."

5. "Now paste this. You'll see one line starting with ssh-ed25519. Send me that line. It's safe to share. Never send anything with PRIVATE KEY in it."
   ```
   cat ~/grokbot-feed.pub
   ```
   If the paste contains `PRIVATE KEY`, reject it and ask for the `.pub` line. Pipe the line on stdin to `scripts/add-phone-key.sh --repo OWNER/NAME`. Tell them only after it prints "read-only deploy key added".

6. "Want one bot pinned at the top? Tell me its exact name, or say none."

7. Run `scripts/phone-install-line.sh --repo OWNER/NAME --ref v0.1.0` (plus `--pin "EXACT NAME"`; if refused, ask again). Send the line alone in a code block: "Paste this whole line into Omalauncher's terminal. You should see: Grok Bot widget installed. Look on page 2." Anything else: Troubleshooting.

8. "Go to page 2. Do you see the widget?" Then: "If it says allow notification access to show unread, tap it and allow it. That shows unread dots." Then: "Tap a bot. Does its chat open?" Only after they confirm all three, say you're done. Pin changes later: rerun step 7 with the new pin; pasting overwrites the widget. "Refresh now": rerun the publish command; the widget picks it up within 10 minutes.

## Troubleshooting

- "Install failed. Nothing was changed.": no internet; curl missing (have them paste `pacman -S --needed curl coreutils git openssh`, answer Y if it asks; unconfirmed on a phone; then the line again); partial paste (resend the line); release unreachable (retry later).
- "Stopped: the widget file failed its tamper check.": stop, don't work around it, and report it.
- No widget: check page 2; have them paste `ls ~/.config/omalauncher/widgets/grokbot.owl`; if missing, resend the install line.
- "can't read the bot feed" or no bots: check the deploy key exists and the repo name matches the install line; the widget refreshes every 10 minutes; rerun the publish command.
- No unread dots: Omalauncher notification access, and Grok Bot app notifications on.
- Tap doesn't open chat: Grok Bot app installed and signed in to the same account (not yet confirmed on every phone).

## Uninstall

Ask which parts they want, then do only those. Nothing is deleted without an explicit yes.

- Deploy key: `gh repo deploy-key list --repo OWNER/NAME`, then `gh repo deploy-key delete ID --repo OWNER/NAME`.
- Routine: delete the 3-hour publish routine.
- Feed repo: only if asked, `gh repo delete OWNER/NAME`; say it removes the feed from GitHub.
- Phone: they paste `rm ~/grokbot-feed ~/grokbot-feed.pub ~/.config/omalauncher/widgets/grokbot.owl`.
- This computer: if asked, delete `/workspace/grokbot-widget-feed` and the kit clone.
