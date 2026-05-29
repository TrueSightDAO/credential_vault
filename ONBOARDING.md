# ONBOARDING.md — LLM-guided credential setup for a new governor architect

> **For the LLM reading this:** This is a sequenced script. Walk the new
> governor through it step by step. After each step, **confirm with her**
> that it succeeded before moving to the next. Maintain a per-governor
> progress file at `~/.credential_vault_onboarding_progress.md` (see §
> "LLM: progress tracking" below) so she can resume across sessions by
> simply asking *"what do I do next?"*. When she hits a permission gap,
> use the template in § "Permission escalation" to draft a request she can
> send to her sponsoring governor.
>
> **For the human governor reading this:** Don't try to follow this top-to-bottom
> alone. Open a session with Claude (or any compatible LLM that has access
> to `agentic_ai_context`) and say: *"Walk me through credential setup using
> `credential_vault/ONBOARDING.md`."* The LLM will pace it, fetch the right
> material, confirm each step, track your progress locally, and produce
> permission-request messages for you to send to your sponsor when access
> is blocked. Resume anytime with: *"What do I do next?"*

---

## Audience

A new governor architect — someone joining TrueSight DAO who will be
operating signed events, managing partner data, or running treasury
workflows from a personal laptop. This is the first technical onboarding
step after she has been added as a contributor.

**Prerequisites already done (verify before starting):**

1. She has a TrueSight DAO RSA signing key registered via
   [`dapp.truesight.me/create_signature.html`](https://dapp.truesight.me/create_signature.html)
   and a verified email tied to it.
2. Her signing key (`publicKey` / `privateKey`) is in her browser
   localStorage on `dapp.truesight.me`. Step 1 below extracts it to disk.
3. She has a sponsoring contributor who can grant her GitHub access to
   `TrueSightDAO` org and (where applicable) GCP / AWS access.

---

## Step 0 — Install the baseline toolchain

Ask her to confirm each is installed. On macOS:

```bash
# Apple's command-line tools (provides bash, tar, openssl, git)
xcode-select --install

# Homebrew + the standard toolchain
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
brew install gh node python@3.11 jq

# Google Apps Script CLI (only if she'll deploy GAS — ask first)
npm install -g @google/clasp
```

✋ **Confirm:** `which gh git python3 node openssl tar` all return paths.

---

## Step 1 — Clone the workspace skeleton

```bash
mkdir -p ~/Applications && cd ~/Applications
gh auth login                                     # GitHub HTTPS, browser flow
gh repo clone TrueSightDAO/credential_vault        # ← this repo (clone first)
gh repo clone TrueSightDAO/agentic_ai_context      # context + onboarding docs
gh repo clone TrueSightDAO/dao_client               # signed-event CLI
```

✋ **Confirm:** `ls ~/Applications/credential_vault` shows `README.md`,
`MANIFEST.txt`, `scripts/`.

---

## Step 2 — Set up her DAO signing key (`dao_client/.env`)

This is the highest-leverage credential — it authorizes every
`[CONTRIBUTION EVENT]` and signed event she submits.

1. Ask her to open
   [`dapp.truesight.me/create_signature.html`](https://dapp.truesight.me/create_signature.html)
   in the browser where her signing key was registered.
2. In Chrome devtools / Application / Local Storage / `https://dapp.truesight.me`,
   copy:
   - `publicKey` (the long base64 string)
   - `privateKey` (longer base64 string — handle as secret)
3. Have her create `~/Applications/dao_client/.env` with:
   ```
   EMAIL=her_email@example.com
   PUBLIC_KEY=<paste publicKey>
   PRIVATE_KEY=<paste privateKey>
   ```
4. `chmod 600 ~/Applications/dao_client/.env`
5. Verify by running a dry-run contribution submission per
   `[[reference-dao-client-cli]]`.

✋ **Confirm:** A dry-run signed event prints `signature_verification: success`.

---

## Step 3 — gh CLI auth (Step 1 above already did this, but verify)

```bash
gh auth status
```

✋ **Confirm:** Output shows `Logged in to github.com as <her-username>`
with `keyring: macOS keychain` or token storage active.

---

## Step 4 — clasp per-account OAuth (only if she'll deploy Google Apps Script)

Ask: *"Will you be deploying or modifying any of our Google Apps Script
projects (Edgar GAS scripts, treasury cache, donations mint, etc.)?"*

If **no** → skip to Step 5.

If **yes** → walk her through `agentic_ai_context/GOOGLE_API_CREDENTIALS.md`
§ "clasp OAuth per-account credentials":

1. `clasp login` while signed into her DAO-role Google account →
   writes `~/.clasprc.json`.
2. `cp ~/.clasprc.json ~/.clasprc-<role>.json` (where `<role>` is `gary`,
   `admin`, etc. — see the doc).
3. Repeat per-account if she manages multiple Google identities.

✋ **Confirm:** `cat ~/.clasprc.json | jq .token.id_token` decodes via
`jwt.io` to her expected Google identity.

---

## Step 5 — Google service-account keys (only if she'll run server-side jobs)

Ask: *"Will you be running any of the Python / Ruby workers locally
(autopilot, sentiment_importer, market_research)?"*

If **no** → skip to Step 6.

If **yes** → her sponsor needs to:

1. Add her Google Workspace account as a viewer/editor on the relevant
   Sheets/Drive resources (see `agentic_ai_context/GOOGLE_API_CREDENTIALS.md`
   for the full matrix).
2. Share the required `*_gdrive_key.json` SA JSONs out-of-band (1Password
   shared vault is the recommended channel).
3. She places them under the canonical paths listed in `MANIFEST.txt`
   (e.g. `~/Applications/sentiment_importer/config/edgar_dapp_listener_key.json`).

✋ **Confirm:** A read-only smoke test against the Main Ledger using one
of the SA keys succeeds.

---

## Step 6 — SSH key

```bash
ssh-keygen -t ed25519 -C "her_email@example.com" -f ~/.ssh/id_rsa
```

(Sticking with the `id_rsa` filename because that's what `MANIFEST.txt`
expects; the algorithm is ed25519, not RSA — the filename is just a label.)

Add the public key to her GitHub account and any DAO-operated EC2 hosts
she needs access to.

✋ **Confirm:** `ssh -T git@github.com` returns "Hi <username>!".

---

## Step 7 — AWS CLI auth (only if she'll touch the EC2 fleet)

Ask: *"Will you be SSH'ing into or deploying to TrueSight DAO EC2 hosts?"*

If **no** → skip to Step 8.

If **yes** → her sponsor provisions an IAM user (per-person, never shared),
shares the access key + secret out-of-band, and she runs:

```bash
aws configure
```

✋ **Confirm:** `aws sts get-caller-identity` returns her ARN.

---

## Step 8 — Other `.env` files (per active project)

Ask: *"Which of these projects will you be working in locally?"* For each
**yes**, her sponsor shares the canonical `.env` template and she fills in
her values:

| Project | What's in the `.env` |
|---|---|
| `truesight_autopilot` | Bugsnag key, GitHub PAT scoped to repos, OpenAI / Anthropic keys |
| `agroverse_shop` | Stripe, Shopify, sender-email creds |
| `governor_chatbot_service` | Telegram bot token, GAS endpoints |
| `video_editor` | YouTube OAuth, Google Drive folder IDs |
| `market_research` | Search Console OAuth, Gmail OAuth |
| `truesight_me` | Wix CMS (legacy, may be empty), analytics keys |
| `garyteh_blog/google-apps-script` | GAS webhook URL |

She only needs the `.env` files for projects she'll touch — others can be
populated later as her scope expands.

✋ **Confirm:** Each `.env` she filled has `chmod 600`.

---

## Step 9 — Customize her `MANIFEST.txt`

```bash
cd ~/Applications/credential_vault
cp MANIFEST.txt MANIFEST.txt.canonical          # keep the upstream version
$EDITOR MANIFEST.txt
```

Comment out paths for services she didn't set up. Add any laptop-local
paths specific to her role.

✋ **Confirm:** `grep -v '^#' MANIFEST.txt | grep -v '^$' | wc -l`
matches the number of credentials she actually has on disk.

---

## Step 10 — Set up the vault (capture everything from Steps 2-9)

This is the closing step — once it runs, everything she just created is
backed up and continues to back up automatically on every edit.

### 10a — Generate + store a strong passphrase

```bash
openssl rand -base64 32
```

Have her copy that output into her password manager (LastPass / 1Password
/ Bitwarden) under an entry named `truesight credential vault`. Verify
she's saved it in the password manager **before** continuing — if she
loses it after Step 10c, every snapshot from this point forward is
unrecoverable.

### 10b — Plant the passphrase file

```bash
printf 'PASTE_PASSPHRASE_HERE' > ~/.credential_vault_passphrase
chmod 600 ~/.credential_vault_passphrase
```

⚠ **Use `printf`, not `echo`** — `echo` would append a newline that
`openssl` treats as part of the passphrase.

### 10c — First backup

```bash
~/Applications/credential_vault/scripts/backup.sh
```

Expected output:

```
[YYYY-MM-DD HH:MM:SS] Encrypting N path(s) → credentials-<ts>.age
[YYYY-MM-DD HH:MM:SS] Wrote credentials-<ts>.age (... bytes)
[YYYY-MM-DD HH:MM:SS] Done.
```

✋ **Confirm:** `ls ~/Library/Mobile\ Documents/com~apple~CloudDocs/credential_vault/`
shows the snapshot + a `credentials-latest.age` symlink.

### 10d — Verify roundtrip into a scratch HOME

Before trusting her backup, prove a restore works:

```bash
mkdir -p /tmp/vault_smoke
cp ~/.credential_vault_passphrase /tmp/vault_smoke/
mkdir -p /tmp/vault_smoke/Library/Mobile\ Documents/com~apple~CloudDocs
ln -sfn "$HOME/Library/Mobile Documents/com~apple~CloudDocs/credential_vault" \
        "/tmp/vault_smoke/Library/Mobile Documents/com~apple~CloudDocs/credential_vault"
HOME=/tmp/vault_smoke ~/Applications/credential_vault/scripts/restore.sh --dry-run
rm -rf /tmp/vault_smoke
```

She should see her files listed. If she does, the roundtrip works.

### 10e — Install the launchd agent (so future edits auto-snapshot)

```bash
sed "s|__HOME__|$HOME|g" \
  ~/Applications/credential_vault/launchd/me.truesight.credential-backup.plist.template \
  > ~/Library/LaunchAgents/me.truesight.credential-backup.plist

launchctl load -w ~/Library/LaunchAgents/me.truesight.credential-backup.plist
launchctl list | grep me.truesight.credential-backup
```

✋ **Confirm:** the agent shows up in `launchctl list` output. Then edit
any credential file (e.g. add a comment to her `.env` and save it). Within
60 seconds a new snapshot should appear in iCloud.

---

## Done

She is now operational. Her credentials persist to iCloud as encrypted
snapshots, retention 30, automatically on every edit + nightly 03:00.

**The single mental model she needs:** *"If my laptop dies, I open the
README, clone this repo, paste my passphrase from my password manager,
and run `scripts/restore.sh`."*

---

---

## LLM: progress tracking pattern

On first contact with a new governor, **create** (don't overwrite) a local
progress file in her home dir. This file is per-laptop, **uncommitted**,
and outlives any single LLM session — so the next time she returns and
asks *"what do I do next?"*, the LLM re-reads it and resumes.

### Where it lives

```
~/.credential_vault_onboarding_progress.md
```

Not in any repo. Not in `MANIFEST.txt` (it's transient state, not a
credential). 0600 perms.

### Template

When you create it, seed with this exact structure (one line per step;
keep the `[ ]` / `[x]` / `[blocked]` markers machine-readable so you can
parse it on the next session):

```markdown
# credential_vault onboarding — progress

Governor: <her name>
Sponsor: <sponsoring contributor name + email>
Started: YYYY-MM-DD
Runbook version: <git rev of credential_vault/ONBOARDING.md at start>

## Status

- [ ] Step 0  — Baseline toolchain (xcode-select, brew, gh, node, python, clasp)
- [ ] Step 1  — Cloned credential_vault + agentic_ai_context + dao_client
- [ ] Step 2  — dao_client/.env populated with her DAO RSA key
- [ ] Step 3  — gh auth verified
- [ ] Step 4  — clasp per-account tokens (SKIP if not deploying GAS)
- [ ] Step 5  — Google service-account keys (SKIP if not running workers)
- [ ] Step 6  — SSH key generated + uploaded to GitHub
- [ ] Step 7  — AWS CLI auth (SKIP if not touching EC2)
- [ ] Step 8  — Project-specific .env files
- [ ] Step 9  — MANIFEST.txt customized to her active scope
- [ ] Step 10 — Vault set up (passphrase, first backup, restore verified, launchd loaded)

## Notes

(Free-form. LLM appends one-liners per step as it works.)

## Blocked

(LLM appends entries here when a step can't proceed without external help.
Format:
  - Step N: blocked on <what> — drafted permission request → <where she sent it>
)
```

### Update protocol

- When she completes a step → flip `[ ]` to `[x]`.
- When a step doesn't apply (she's not running GAS, etc.) → flip to `[x] (skipped — not in scope)`.
- When she's blocked → flip to `[blocked]` AND add an entry under § "Blocked"
  AND draft the permission request per § "Permission escalation" below.
- Append a `## Notes` line for anything that diverged from the runbook
  (e.g., "Used 1Password instead of LastPass — no functional difference").
- On resume (`"what do I do next?"`) — parse the file, find the first
  non-`[x]` non-`[blocked]` step, and resume from there. If everything is
  `[x]` or `[blocked]`, summarize blockers and ask her how she wants to
  proceed.

### Privacy guarantee

This file may end up reflecting her sponsor name, her email, her role.
Treat it as sensitive (0600) but not as a credential. It is **not**
backed up by the vault — losing it is recoverable (the LLM can rebuild
state by asking her a few questions; her actual credentials are safe in
the vault).

---

## Permission escalation

If she hits a step that requires access she doesn't yet have — a Google
Workspace permission, an IAM grant, a shared SA key, a GitHub team add —
generate a copy-pasteable request she can send to her sponsoring governor.

### Detection

Trigger this flow when any of:
- Step 4: `clasp login` succeeds but she can't `clasp open <scriptId>` on a
  project she's expected to manage → needs viewer/editor on that GAS project.
- Step 5: Her sponsor hasn't shared the SA key JSONs yet, or her Google
  account isn't on the relevant Sheets / Drive ACL.
- Step 7: She doesn't have an AWS IAM user provisioned yet.
- Step 8: She doesn't have the project-specific `.env` template values.
- Any clone / push fails with `403` / `permission denied` → needs GitHub
  org / team / repo access.

### Template

Render this template into her clipboard or just print it in chat for her
to copy. Fill in the bracketed fields from the progress file + context:

```
Hi [SPONSOR_NAME],

I'm onboarding as a TrueSight DAO governor architect (started
[START_DATE], currently at Step [N] of `credential_vault/ONBOARDING.md`).
To proceed I need:

  ▸ [SPECIFIC_RESOURCE — e.g. "viewer access to the Edgar GAS project
    1zKgMwd6..." or "the edgar_dapp_listener_key.json SA key shared via
    1Password" or "IAM user provisioned in the TrueSightDAO AWS account
    with read-only on EC2"]

Context: I'm at Step [N] [verb-phrase from the runbook, e.g.
"setting up clasp per-account OAuth"]. The runbook describes the
expected access pattern at
https://github.com/TrueSightDAO/credential_vault/blob/main/ONBOARDING.md#step-[N]

Could you grant this and let me know when it's live? Once unblocked I'll
mark this step complete and continue.

Thanks,
[HER_NAME]
```

### After sending

Update the progress file:

```markdown
## Blocked

- Step [N]: blocked on [SHORT_DESCRIPTION]
  Request sent to [SPONSOR] on YYYY-MM-DD via [Telegram / email / Slack].
  Expected unblock: [SPONSOR'S ETA, or "TBD"]
```

When she returns and asks *"what do I do next?"*:
- If the blocker is resolved → flip `[blocked]` to `[ ]` and resume.
- If not → see whether any later steps are *unblocked* and runnable in
  parallel (Steps 6 and 9 often are). If yes, suggest those. If no,
  surface the open blockers and ask if she wants to nudge the sponsor.

---

## LLM — closing checklist

Before you mark this onboarding complete:

- [ ] Step 2: she confirmed a dry-run signed event verified successfully.
- [ ] Step 10c: at least one real snapshot exists in iCloud.
- [ ] Step 10d: she ran the dry-run restore and saw her files listed.
- [ ] Step 10e: `launchctl list` shows the agent.
- [ ] Her password manager has an entry for `truesight credential vault`
      with a strong, unique passphrase.
- [ ] She has been told: *"If you lose access to your password manager,
      every snapshot becomes unrecoverable. Treat that passphrase like
      it's the master key — because it is."*

If any of these is unchecked, do not mark onboarding complete; ask her to
finish that step before closing the session.
