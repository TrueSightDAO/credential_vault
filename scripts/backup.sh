#!/usr/bin/env bash
#
# backup.sh — encrypt the credential manifest into iCloud Drive.
#
# V1.1 — workspace-root configurability:
#   ${WORKSPACE} in MANIFEST.txt resolves to $TRUESIGHT_WORKSPACE
#   (default: $HOME/Applications). Backup stages workspace-relative paths
#   under `w/` and home-relative paths under `h/` inside the tar, with a
#   vault_meta.json sidecar that records both roots so restore can
#   re-root workspace paths into the restoring user's $TRUESIGHT_WORKSPACE.
#
# Reads ~/Applications/credential_vault/MANIFEST.txt, tars the listed paths
# with the h/ + w/ + meta layout, and pipes through `openssl enc
# -aes-256-cbc -pbkdf2 -iter 600000` using the passphrase in
# ~/.credential_vault_passphrase.
#
# Output:
#   ~/Library/Mobile Documents/com~apple~CloudDocs/credential_vault/
#       credentials-YYYYMMDD-HHMMSS.age
#       credentials-latest.txt           (plain text pointer, not symlink —
#                                         symlink update needs `unlink` which
#                                         launchd lacks under iCloud Drive)
#
# Retention: keeps the 30 most recent snapshots. Prune `rm`s are wrapped so
# launchd-without-FDA failures log a warning instead of failing the run.
#
# Designed safe under launchd WatchPaths: includes a 60-second debounce.
#
# Exit codes:
#   0  — backup succeeded, or skipped due to debounce
#   1  — manifest missing / zero existing paths
#   2  — passphrase file missing
#   3  — encrypt pipeline failed
#
# See README.md for the threat model + restore runbook.

set -euo pipefail

# Auto-detect MANIFEST relative to this script so credential_vault can be
# cloned anywhere (not just ~/Applications/credential_vault).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST="$SCRIPT_DIR/../MANIFEST.txt"
PASSPHRASE_FILE="${HOME}/.credential_vault_passphrase"
VAULT_DIR="${HOME}/Library/Mobile Documents/com~apple~CloudDocs/credential_vault"
WORKSPACE="${TRUESIGHT_WORKSPACE:-$HOME/Applications}"
RETENTION=30
DEBOUNCE_SEC=60

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }

# ─── Pre-flight ────────────────────────────────────────────────────────
[[ -f "$MANIFEST" ]] || { log "ERROR: manifest not found at $MANIFEST"; exit 1; }
[[ -s "$PASSPHRASE_FILE" ]] || {
  log "ERROR: passphrase file not found or empty at $PASSPHRASE_FILE"
  log "       Create it with: printf 'YOUR_PASSPHRASE' > $PASSPHRASE_FILE && chmod 600 $PASSPHRASE_FILE"
  exit 2
}

# Refuse to run if passphrase file is world-readable (defense in depth)
PERMS=$(stat -f '%Sp' "$PASSPHRASE_FILE")
if [[ "$PERMS" != "-rw-------" ]]; then
  log "WARNING: tightening passphrase file perms to 600 (was $PERMS)"
  chmod 600 "$PASSPHRASE_FILE"
fi

[[ -d "$WORKSPACE" ]] || log "WARN: TRUESIGHT_WORKSPACE=$WORKSPACE does not exist (workspace-relative manifest entries will be skipped)"

mkdir -p "$VAULT_DIR"

# ─── Debounce: skip if a backup ran within DEBOUNCE_SEC ────────────────
LATEST=$(ls -t "$VAULT_DIR"/credentials-*.age 2>/dev/null | head -1 || true)
if [[ -n "${LATEST:-}" ]]; then
  NOW=$(date +%s)
  MTIME=$(stat -f %m "$LATEST")
  AGE_SEC=$((NOW - MTIME))
  if (( AGE_SEC < DEBOUNCE_SEC )); then
    log "Recent backup ${AGE_SEC}s ago at $(basename "$LATEST") — skipping"
    exit 0
  fi
fi

# ─── Resolve manifest paths into HOME_PATHS[] and WS_PATHS[] ────────────
declare -a HOME_PATHS=()   # paths relative to $HOME
declare -a WS_PATHS=()     # paths relative to $WORKSPACE
declare -a MISSING=()

while IFS= read -r line || [[ -n "$line" ]]; do
  # strip CR + trim
  line="${line%$'\r'}"
  line="${line#"${line%%[![:space:]]*}"}"
  line="${line%"${line##*[![:space:]]}"}"
  [[ -z "$line" || "$line" =~ ^# ]] && continue

  if [[ "$line" == '${WORKSPACE}'/* ]]; then
    # Workspace-relative
    rel="${line#'${WORKSPACE}'/}"
    full="$WORKSPACE/$rel"
    if [[ -e "$full" ]]; then
      WS_PATHS+=("$rel")
    else
      MISSING+=("$line  (resolved: $full)")
    fi
  elif [[ "$line" == '~/'* ]]; then
    # Home-relative
    rel="${line#'~/'}"
    full="$HOME/$rel"
    if [[ -e "$full" ]]; then
      HOME_PATHS+=("$rel")
    else
      MISSING+=("$line  (resolved: $full)")
    fi
  else
    log "WARN: manifest entry not anchored to \${WORKSPACE} or ~/ — skipping: $line"
  fi
done < "$MANIFEST"

TOTAL=$((${#HOME_PATHS[@]} + ${#WS_PATHS[@]}))
if (( TOTAL == 0 )); then
  log "ERROR: manifest produced zero existing paths — refusing to write empty vault"
  exit 1
fi

if (( ${#MISSING[@]} > 0 )); then
  log "Note: ${#MISSING[@]} manifest path(s) not present on this host:"
  for m in "${MISSING[@]}"; do log "  - $m"; done
fi

# ─── Stage symlinks under STAGE/h/ and STAGE/w/ + write vault_meta.json ─
STAGE=$(mktemp -d 2>/dev/null || mktemp -d -t vault)
stage_cleanup() { rm -rf "$STAGE"; }
trap stage_cleanup EXIT

mkdir -p "$STAGE/h" "$STAGE/w"

for p in "${HOME_PATHS[@]}"; do
  # Strip trailing slash — `ln target/` is interpreted as "inside dir" and fails
  # when the parent doesn't exist. We want to symlink the entry itself.
  p="${p%/}"
  mkdir -p "$STAGE/h/$(dirname "$p")"
  ln -s "$HOME/$p" "$STAGE/h/$p"
done
for p in "${WS_PATHS[@]}"; do
  p="${p%/}"
  mkdir -p "$STAGE/w/$(dirname "$p")"
  ln -s "$WORKSPACE/$p" "$STAGE/w/$p"
done

cat > "$STAGE/vault_meta.json" <<EOF
{
  "schema_version": 1,
  "created_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "created_by_host": "$(hostname)",
  "workspace_root_at_backup": "$WORKSPACE",
  "home_root_at_backup": "$HOME",
  "home_path_count": ${#HOME_PATHS[@]},
  "workspace_path_count": ${#WS_PATHS[@]}
}
EOF

# ─── Build encrypted snapshot ──────────────────────────────────────────
# NOTE on launchd + iCloud Drive: macOS Sonoma sandboxes launchd-spawned
# processes from `rename` and `unlink` ops inside iCloud Drive unless
# `/bin/bash` has Full Disk Access. CREATE works. We write directly to
# OUT (no .tmp + mv) and use a plain-text "latest" pointer (no symlink
# update). Retention `rm`s are wrapped to log a warning instead of failing.
TS=$(date +%Y%m%d-%H%M%S)
OUT="$VAULT_DIR/credentials-${TS}.age"

log "Encrypting ${#HOME_PATHS[@]} home + ${#WS_PATHS[@]} workspace path(s) → $(basename "$OUT")"

# tar -h dereferences symlinks so file CONTENTS land in the archive at the
# h/ + w/ prefixed paths. openssl pipes the tar stream through PBKDF2+AES.
if ! ( cd "$STAGE" && tar -czhf - h w vault_meta.json ) | \
       openssl enc -aes-256-cbc -pbkdf2 -iter 600000 -salt \
                   -pass file:"$PASSPHRASE_FILE" -out "$OUT"; then
  log "ERROR: encrypt pipeline failed"
  rm -f "$OUT" 2>/dev/null || true
  exit 3
fi

# Update the "latest" plain-text pointer (CREATE only — no unlink needed).
echo "$(basename "$OUT")" > "$VAULT_DIR/credentials-latest.txt"

SIZE=$(stat -f %z "$OUT")
log "Wrote $(basename "$OUT") (${SIZE} bytes)"

# ─── Prune old snapshots beyond RETENTION ──────────────────────────────
SNAPSHOTS=()
while IFS= read -r snap; do
  SNAPSHOTS+=("$snap")
done < <(ls -t "$VAULT_DIR"/credentials-*.age 2>/dev/null || true)
if (( ${#SNAPSHOTS[@]} > RETENTION )); then
  i=$RETENTION
  while (( i < ${#SNAPSHOTS[@]} )); do
    if rm -f "${SNAPSHOTS[i]}" 2>/dev/null; then
      log "Pruned $(basename "${SNAPSHOTS[i]}")"
    else
      log "WARN: could not prune $(basename "${SNAPSHOTS[i]}") (likely launchd-without-FDA; run backup.sh from terminal occasionally to prune)"
    fi
    i=$((i+1))
  done
fi

log "Done."
