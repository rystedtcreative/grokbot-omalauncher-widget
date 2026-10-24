# Releasing

The setup bot clones tag `v0.1.0`. It does not follow a branch. Before it runs any script it checks three things, and stops with nothing run if any one fails:

1. `git -C /workspace/grokbot-omalauncher-widget rev-parse HEAD` equals the commit in the skill.
2. The first field of `sha256sum checksums.txt` equals the sha256 of `checksums.txt` in the skill.
3. `sha256sum -c checksums.txt` prints `OK` for every line.

`setup-bot/SKILL.md` in this repository keeps the placeholders `__EXPECTED_COMMIT__` and `__EXPECTED_CHECKSUMS_SHA256__`. `scripts/release-skill.sh` fills those from a tag and writes `dist/SKILL.md` for the bot template. `dist/` is gitignored. Do not commit it.

## Steps

1. Change the widget or the scripts. Leave both placeholders in `setup-bot/SKILL.md`.
2. Run `scripts/update-checksums.sh`.
3. Commit. The work tree must be clean, including untracked files. `scripts/release-skill.sh` refuses a dirty tree.
4. Tag that commit, for example `git tag v0.1.0`.
5. Run `scripts/release-skill.sh v0.1.0`.
6. Paste `dist/SKILL.md` into the setup bot template.

The script reads `setup-bot/SKILL.md` and `checksums.txt` from the tagged commit. It refuses a missing tag, and it refuses if either placeholder is missing from that skill. The commit it writes is `TAG^{commit}`, and the checksum is the sha256 of `checksums.txt` at that commit.

## Host keys

`widget/known_hosts` is GitHub's published SSH host keys (ed25519, ecdsa, rsa), and the same lines are embedded in `widget/grokbot.owl`. The phone only receives the `.owl` file. When GitHub rotates a key, fetch `ssh_keys` from `https://api.github.com/meta`, check the fingerprints against [GitHub's SSH key fingerprints](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/githubs-ssh-key-fingerprints), update both files, then follow the steps above.
