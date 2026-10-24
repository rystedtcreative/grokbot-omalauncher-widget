# Security

This kit publishes a list of your Grok Bots so a phone widget can show it. The list is names, titles, colors, shapes, avatar thumbnails, group membership, and links that open a bot on the same phone. It is still private data.

## Trust boundaries

| Place | What it holds | What it can do |
| --- | --- | --- |
| Your Grok Bot computer | Full agent profiles, and a GitHub login that can push | Builds the feed. This machine is already trusted with your bots. |
| Your private GitHub repo | The feed files only | Stores them for the phone. The publish script refuses a public repo. |
| Your phone | A read-only deploy key, a clone of the feed, notification text already on the phone | Reads the feed and opens `grokbot://` links. It cannot push. |
| This kit's author | Nothing in the pipeline | Does not host the feed, the keys, or a relay. |

The widget clones only the feed repository, shallow and sparse (`index.json` and `avatars/`). Git runs with `BatchMode` and `GIT_TERMINAL_PROMPT=0`, so it cannot ask for a password. An unknown `schemaVersion`, a missing `index.json`, or a failed command shows an error and no bot rows.

## What the scripts refuse

- A feed repo that exists and is not private. They will not create a public repo and they will not push until a second visibility check passes.
- A deploy key with write access. `add-phone-key.sh` never passes `--allow-write`. It adds `--read-only` when this `gh` supports that flag, and it checks the new key is read-only.
- A private SSH key. The script rejects PEM and OpenSSH private keys before it calls `gh`, and it does not print the pasted text.
- Descriptions, unless you pass `--include-descriptions`. Opt-in text is scrubbed (token-shaped values become `REDACTED`). Scrubbing is not a promise that every secret is gone. Leave descriptions off.
- Profile fields the feed does not need. `serverId`, `harness`, `voiceId`, `secrets`, `skills`, and `memory` are never written. Unknown profile keys are warned about and dropped, not copied.

`checksums.txt` is the sha256 of the widget and the scripts. Install from a pinned git tag, then run `sha256sum -c checksums.txt` before you run those scripts. A mismatch means the tree is not the release you pinned.

GitHub CLI output is not printed. Do not paste a personal access token into the chat or into these scripts. Log in with `gh auth login` on the computer.

## Residual risk

Someone who can read the private repo, or who has the phone, can see the feed: bot names, titles, avatars, and group member ids. They cannot push unless they also have the computer's GitHub login. Remove the deploy key to cut the phone off (`gh repo deploy-key list`, then `gh repo deploy-key delete`).

A stolen computer can push a new feed, because that is the machine that builds it. Treat the computer like the bots it already stores.

The widget accepts GitHub's host key on first connect (`StrictHostKeyChecking=accept-new`), same as a first SSH connection to GitHub. After that, the host key is pinned in the phone's known_hosts.

Notification matching uses the bot id and name against notification titles from the Grok Bot app. The widget does not send those notifications anywhere.

## Reporting

Report it privately with GitHub's **Report a vulnerability** button on this repository's Security tab. Do not open a public issue for a vulnerability, and do not include a live feed, a token, or a private key in the report.
