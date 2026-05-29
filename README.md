# credential_vault

> **Disaster recovery for your laptop credentials.** If your MacBook dies, is
> stolen, or you get a new one, this repo gets you back to a working state
> with one passphrase from your password manager.

This is the first repo a **new governor architect** should clone after
joining the TrueSight DAO workspace, and the first repo you should set up on
a fresh Mac. It is *separate* from the regular operational repos on purpose:
its only job is to survive your laptop dying.

**Visibility:** PRIVATE. The manifest reveals which services the workspace
keeps credentials for; the runbook reveals the storage layout. Both are
low-grade information disclosures that don't belong in a public repo.

---

## What it covers

| Scope | Status |
|---|---|
| `~/Applications/*/.env` files (API keys, RSA private keys) | ✅ |
| `~/Applications/*/{config,credentials}/*.json` Google service-account + OAuth tokens | ✅ |
| `~/.clasprc-*.json` per-account clasp tokens (Google Apps Script CLI) | ✅ |
| `~/.config/gh/` GitHub CLI auth | ✅ |
| `~/.ssh/id_rsa` + `config` + `known_hosts` | ✅ |
| `~/.aws/{credentials,config}` AWS CLI auth | ✅ |
| Source code | ❌ — re-clone from GitHub |
| Memory dir (`~/.claude/projects/*/memory/`) | ❌ — flagged as a known V1 gap, see Open Follow-ups |
| Per-credential rotation / per-service scoping | ❌ — Tier-2 problem; not addressed |
| EC2 fleet provisioning (host-side secrets) | ❌ — different problem; see `OPEN_FOLLOWUPS.md` "AWS Secrets Manager" in `agentic_ai_context` |

---

## How it works

```
                          ┌─────────────────────────────────────┐
   Edit a .env or         │   launchd                           │
   config/*.json    ─────►│   me.truesight.credential-backup    │──┐
                          │   WatchPaths + 3am heartbeat        │  │
                          └─────────────────────────────────────┘  │
                                                                   ▼
                          ┌─────────────────────────────────────┐
                          │   scripts/backup.sh                 │
                          │   ─ reads MANIFEST.txt              │
                          │   ─ tars manifest paths             │
                          │   ─ openssl enc -aes-256-cbc        │
                          │     -pbkdf2 -iter 600000            │
                          │   ─ passphrase: ~/.credential_      │
                          │     vault_passphrase (0600)         │
                          └────────────────┬────────────────────┘
                                           │
                                           ▼
                ~/Library/Mobile Documents/com~apple~CloudDocs/
                          credential_vault/
                              credentials-20260529-154124.age
                              credentials-latest.age → newest
                          (retention: 30 snapshots)
```

**Why openssl, not age?** `age` has no `--passphrase-from-file` flag — it
always prompts. That breaks unattended launchd. LibreSSL 3.3.6 ships with
macOS and supports `-pbkdf2 -iter` natively, so restore on a fresh Mac
needs zero `brew install`. Same security boundary, fewer moving parts.

---

## First-time setup (new Mac, new governor architect)

### 1. Clone this repo

```bash
mkdir -p ~/Applications && cd ~/Applications
gh repo clone TrueSightDAO/credential_vault
```

(You need GitHub access to `TrueSightDAO`; if you don't have it, ask your
sponsoring contributor — `[[reference-dapp-api-docs]]`'s sponsor field is
a good starting reference.)

### 2. Adapt MANIFEST.txt to your machine

The shipped manifest reflects the workspace's current credential layout.
If you're a new governor architect:

- Comment out paths for services you don't yet use (e.g. if you don't run
  the `video_editor/` workflow yet, comment those lines).
- Add any laptop-local credentials specific to your role.

This is the **only** file you typically need to touch.

### 3. Pick + store a strong passphrase

≥ 20 characters, random. Examples:

```bash
openssl rand -base64 32          # 44-char random string
# or use a diceware passphrase from EFF wordlist
```

Save it in your password manager under an entry named
`truesight credential vault`. (LastPass, 1Password, Bitwarden — pick one and
stick with it. The threat-model section below explains why the password
manager choice matters less than passphrase strength.)

### 4. Plant the passphrase file

```bash
printf 'YOUR_PASSPHRASE_HERE' > ~/.credential_vault_passphrase
chmod 600 ~/.credential_vault_passphrase
```

**Important:** use `printf`, not `echo` — `echo` would append a trailing
newline that `openssl` treats as part of the passphrase.

### 5. First backup

```bash
~/Applications/credential_vault/scripts/backup.sh
```

Expect output like:

```
[2026-05-29 15:41:24] Encrypting 26 path(s) → credentials-20260529-154124.age
[2026-05-29 15:41:25] Wrote credentials-20260529-154124.age (245792 bytes)
[2026-05-29 15:41:25] Done.
```

The snapshot lands in
`~/Library/Mobile Documents/com~apple~CloudDocs/credential_vault/`.

### 6. Install the launchd agent

Render the plist template with your `$HOME` and load it:

```bash
sed "s|__HOME__|$HOME|g" \
  ~/Applications/credential_vault/launchd/me.truesight.credential-backup.plist.template \
  > ~/Library/LaunchAgents/me.truesight.credential-backup.plist

launchctl load -w ~/Library/LaunchAgents/me.truesight.credential-backup.plist
```

Confirm it loaded:

```bash
launchctl list | grep me.truesight.credential-backup
```

Touch a credential file (e.g. re-save a `.env`) — a new snapshot should
appear in iCloud Drive within ~60 seconds.

### 7. (Recommended) Verify roundtrip into a scratch HOME

Before trusting the backup, prove that a restore works:

```bash
mkdir -p /tmp/vault_smoke
cp ~/.credential_vault_passphrase /tmp/vault_smoke/
mkdir -p /tmp/vault_smoke/Library/Mobile\ Documents/com~apple~CloudDocs
ln -sfn "$HOME/Library/Mobile Documents/com~apple~CloudDocs/credential_vault" \
        "/tmp/vault_smoke/Library/Mobile Documents/com~apple~CloudDocs/credential_vault"
HOME=/tmp/vault_smoke ~/Applications/credential_vault/scripts/restore.sh --dry-run
```

You should see a listing of every file you backed up. Delete `/tmp/vault_smoke`
when done.

---

## Disaster-recovery runbook (fresh / wiped MacBook)

1. Install Xcode Command Line Tools:
   ```bash
   xcode-select --install
   ```
2. Sign into iCloud so `~/Library/Mobile Documents/com~apple~CloudDocs/`
   becomes visible.
3. Open your password manager on phone or another device; copy the
   `truesight credential vault` passphrase.
4. Clone this repo:
   ```bash
   mkdir -p ~/Applications && cd ~/Applications
   gh repo clone TrueSightDAO/credential_vault
   # If gh isn't installed yet: download .pkg from cli.github.com, then `gh auth login`
   ```
5. Plant the passphrase file (same as setup step 4 above).
6. Restore:
   ```bash
   ~/Applications/credential_vault/scripts/restore.sh
   ```
   Defaults to the latest snapshot. Existing files are **skipped** unless
   you pass `--force`. Files land in their original `$HOME`-relative
   locations.
7. Re-clone the rest of your workspace repos as needed; their `.env` and
   `config/*.json` SA keys are already in place from step 6.
8. Reinstall the launchd agent (same as setup step 6).

**Expected end-to-end time on a fresh Mac:** 15 minutes excluding repo
re-cloning.

---

## Day-to-day operation

You don't touch anything. Every time you save a credential file, a new
encrypted snapshot lands in iCloud Drive within ~60 seconds (script-level
debounce + launchd `ThrottleInterval` smooth bursts).

Sanity check (run from any device):

```bash
ls -lt ~/Library/Mobile\ Documents/com~apple~CloudDocs/credential_vault/ | head -5
```

Newest snapshot should be under 24 hours old (because of the 3am nightly
heartbeat). If it isn't, something has stopped the launchd agent:

```bash
launchctl list | grep me.truesight.credential-backup
cat /tmp/credential_vault_backup.err
```

---

## Maintenance

**Adding a new credential.** Edit `MANIFEST.txt`, run `scripts/backup.sh`
once by hand to verify the new path was picked up. If the new path lives
under a directory not already in the plist's `<WatchPaths>`, update
`launchd/me.truesight.credential-backup.plist.template`, re-render to
`~/Library/LaunchAgents/`, and reload:

```bash
launchctl unload ~/Library/LaunchAgents/me.truesight.credential-backup.plist
launchctl load -w ~/Library/LaunchAgents/me.truesight.credential-backup.plist
```

**Rotating the passphrase.** Pick a new passphrase, write it to your
password manager, update `~/.credential_vault_passphrase`. Run `scripts/backup.sh`
to produce a freshly-encrypted snapshot under the new passphrase. **Old
snapshots remain decryptable only with the old passphrase** — if you want
them unreadable, delete them from iCloud Drive (retention will get the rest
naturally over time).

**Manifest hygiene.** When you uninstall a service or rotate a repo away,
remove the old paths so missing-path warnings stay meaningful.

---

## Threat model

| Threat | V1 stance |
|---|---|
| MacBook lost / stolen / dead | ✅ Covered — encrypted snapshot in iCloud Drive, passphrase in password manager. |
| MacBook compromised + attacker has both filesystem + password manager | ❌ Out of scope. Same exposure as plaintext on disk today. |
| iCloud account breach + password manager breach (simultaneous) | ❌ Out of scope. Defense via strong passphrase + 2FA on both. |
| Per-credential rotation / least-privilege per-service | ❌ Tier-2 problem. |
| New EC2 host needs creds at provision time | ❌ Different problem — see `agentic_ai_context/OPEN_FOLLOWUPS.md` § "AWS Secrets Manager". |

**Honest summary.** V1 buys "MacBook died, here's how I get back" for ~3
hours of one-time setup. It does **not** change your exposure surface on a
working laptop — credentials are still plaintext on disk while you use
them. Making them not-plaintext on a working laptop is a vastly more
invasive project that doesn't reduce real risk.

**On password manager choice.** Any of LastPass / 1Password / Bitwarden
works. The choice matters less than passphrase strength. LastPass had a
2022 vault-exfil incident — encrypted vaults left the building; users with
weak passphrases were compromised, users with strong ones weren't. Pick a
strong passphrase regardless of which password manager you trust.

---

## Open follow-ups

- **Memory dir not vaulted.** `~/.claude/projects/*/memory/` is excluded by
  default. If you want them in, add the dir to `MANIFEST.txt` and the
  parent dir to the plist `<WatchPaths>`. ~50 KB cost.
- **Verify-on-restore checksum.** Adding a SHA-256 of the cleartext tar
  inside the manifest header would close a "did the roundtrip actually
  preserve everything?" gap. Worth doing after the first real restore in
  anger.
- **Tier-2: per-credential vaulting / sharing.** When the workspace grows
  past one operator, single-passphrase becomes a sharing problem. SOPS +
  age + shared age recipients, or Bitwarden Organization with per-cred
  items, are the obvious next moves.
- **Tier-3: host-side vault.** EC2 fleet provisioning is tracked
  separately — see `agentic_ai_context/OPEN_FOLLOWUPS.md` § "AWS Secrets
  Manager".

---

## Cross-references

- `agentic_ai_context/GOOGLE_API_CREDENTIALS.md` — what each credential is
  for (service-account scopes, OAuth audiences).
- `agentic_ai_context/OPEN_FOLLOWUPS.md` — the EC2-side vault problem,
  separate concern.
- `dao_client/.env` — RSA private key for [CONTRIBUTION EVENT] submissions
  to Edgar. This is the single highest-leverage credential here — losing
  it without a backup means losing your DAO contribution authority until
  a new key is registered.
