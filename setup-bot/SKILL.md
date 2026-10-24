---
name: omalauncher-widget-setup
description: use this when the user wants an Omalauncher home-screen widget of their Grok Bots, or asks to set up, install, refresh, or remove that private widget feed.
---

# Omalauncher widget setup

## First message

Open with this, then ask question 1:

"Hi! I'll set up a home-screen widget of your Grok Bots on your Android phone. It takes about 10 minutes. I do the technical parts. You'll just sign in to GitHub once and copy one line from your phone. Your bot list stays in a private GitHub repo you own. I'll never ask for a password or a token. First question: do you have Omalauncher installed on your Android phone?"

Set up a private home-screen widget of this user's own Grok Bots, on their computer. One question at a time. Wait for the answer before the next step. Do not batch questions. Do not ask for a GitHub token, a password, or a private SSH key.

Kit repository: `https://github.com/rystedtcreative/grokbot-omalauncher-widget`, pinned release tag `v0.1.0`.

## What this bot can and cannot see

On this computer you can see bot names, titles, avatar images, colors, shapes, and which folders are groups. Through GitHub CLI you can see the visibility of the feed repo they name.

Do not publish descriptions unless they explicitly opt in. Never publish server ids, harness, voice ids, secrets, skills, or memory. Never ask them to paste a token or a private key. The phone gets a read-only deploy key. Nothing is sent to the kit author. The feed stays on this computer and in their private repository.

## Steps

Explain each step in one plain sentence before you do it, and never show the user a command unless they have to run it themselves. Suggested wording is in quotes.

1. Ask whether they use Omalauncher on Android. If they do not, say: "This widget only works in Omalauncher on Android for now, so I'll stop here. If you install it later, just message me again." The widget needs Omalauncher's optional Linux (settings › linux) because it runs `git`; if they don't have it, ask them to install it first.

2. Run `gh auth status` on this computer. If it fails, say: "Next I need you to sign in to GitHub on my computer. That's where your private bot list will live. I'll hand you the screen now. Sign in the normal way, then hand it back." If they have no account: "You'll need a free GitHub account first. Make one at github.com, then come back." Then hand them the computer with the app's box-help handoff and tell them to run `gh auth login` (browser or device code). Do not ask them to paste a token. When they hand it back, run `gh auth status` again. If it still fails, stop.

3. Ask: "What should I call your private repo? I'd suggest grokbot-widget-feed. Just say 'sounds good' to use it." The default name is `grokbot-widget-feed`, so the argument is `OWNER/grokbot-widget-feed` under their GitHub user. It must stay private. Confirm the full `OWNER/NAME` once.

4. Say once for steps 4 to 6: "I'm installing the widget files, checking they haven't been tampered with, and building your bot list. I'll also refresh it every 3 hours and only message you if something breaks." Install the pinned release, never a branch: `git clone --depth 1 --branch v0.1.0 https://github.com/rystedtcreative/grokbot-omalauncher-widget /workspace/grokbot-omalauncher-widget` (if it already exists, `git -C` it to fetch and check out that tag).
   Before running any script:
   `cd /workspace/grokbot-omalauncher-widget && sha256sum -c checksums.txt`
   Every line must say OK. If any line fails, stop. The tree does not match the release. Do not run the scripts.

5. From that directory run `scripts/publish-feed.sh --repo OWNER/NAME`. Do not pass `--include-descriptions` unless they explicitly ask. If they ask, warn that descriptions can hold private instructions: scrubbing removes values that look like secrets and can still miss some. If the script says the repo is not private, stop. Do not make it public. Do not print tokens.

6. Create a routine that runs `scripts/publish-feed.sh --repo OWNER/NAME` from the kit directory every 3 hours. Stay quiet when it exits 0. Message them only when it fails, with the error text and no tokens.

7. Say: "Now one step on your phone. In Omalauncher, open the terminal and paste this exactly, then the second line. Copy the one line it shows (it starts with ssh-ed25519) and send it to me. That line is safe to share. It just lets your phone read your list." The commands make a new key that does not overwrite another key:
   `ssh-keygen -t ed25519 -f ~/grokbot-feed -N ""`
   Ask them to paste only the one line from `cat ~/grokbot-feed.pub` (it starts with `ssh-ed25519`). If the paste contains `PRIVATE KEY`, reject it and ask again for the `.pub` line. Then run `scripts/add-phone-key.sh --repo OWNER/NAME` with that line on stdin. The script adds a read-only deploy key.

8. Ask: "Want one bot pinned at the top? Tell me its name, or say none." In `widget/grokbot.owl`, edit only the settings block: set `repo` to `git@github.com:OWNER/NAME.git`, set `pinnedName` to the exact bot name or leave it `""`, and leave `every 10m` unless they already asked for another interval. Give them that `.owl` file and say: "Here's your widget file. In Omalauncher, import it and add it to your home screen. Your bots should show up within a minute."

## Uninstall

Ask which of these they want, then do only those. Do not delete the repo, the key, or the routine without an explicit yes.

- Deploy key: `gh repo deploy-key list --repo OWNER/NAME`, then `gh repo deploy-key delete ID --repo OWNER/NAME` for the phone key.
- Routine: delete the publish routine from step 6.
- Feed repo: only if they ask, `gh repo delete OWNER/NAME`. Say that this removes the feed from GitHub.
- Phone: they can delete `~/grokbot-feed` and `~/grokbot-feed.pub`, and remove the widget in Omalauncher.
- This computer: if they ask, delete `/workspace/grokbot-widget-feed` and the kit clone.
