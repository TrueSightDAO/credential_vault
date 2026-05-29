#!/usr/bin/env bash
#
# restore.sh — decrypt a credential vault snapshot back to $HOME and
# $TRUESIGHT_WORKSPACE.
#
# V1.1 — workspace-root configurability:
#   Reads vault_meta.json from the archive. Workspace-relative paths
#   (staged under w/ in the archive) are restored into the current
#   user's $TRUESIGHT_WORKSPACE (default: $HOME/Applications) — NOT
#   into the workspace the backup was created from. Home-relative paths
#   (staged under h/) are restored into $HOME.
#
#   Legacy archives (V1, no vault_meta.json) are detected automatically
#   and extracted directly to $HOME with the old semantics so older
#   snapshots remain restorable.
#
# Usage:
#   restore.sh                        # restore latest snapshot
#   restore.sh <path-to-snapshot>     # restore specific snapshot
#   restore.sh --list                 # list available snapshots
#   restore.sh --dry-run [snapshot]   # show what WOULD be written + targets
#   restore.sh --force [snapshot]     # overwrite existing files
#
# Requires the passphrase in ~/.credential_vault_passphrase (created by
# you on the new Mac, contents pasted from your password manager).
#
# Refuses to overwrite existing files unless --force is passed. Default
# behavior on conflict: skip and warn.
#
# See README.md for the disaster-recovery runbook.

set -euo pipefail

PASSPHRASE_FILE="${HOME}/.credential_vault_passphrase"
VAULT_DIR="${HOME}/Library/Mobile Documents/com~apple~CloudDocs/credential_vault"
WORKSPACE="${TRUESIGHT_WORKSPACE:-$HOME/Applications}"

DRY_RUN=0
FORCE=0
SNAPSHOT=""
LIST_ONLY=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --force)   FORCE=1 ;;
    --list)    LIST_ONLY=1 ;;
    -h|--help)
      sed -n '3,32p' "$0"
      exit 0 ;;
    -*)
      echo "Unknown flag: $1" >&2; exit 1 ;;
    *)
      SNAPSHOT="$1" ;;
  esac
  shift
done

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }

if (( LIST_ONLY )); then
  if [[ ! -d "$VAULT_DIR" ]]; then
    log "Vault dir not present: $VAULT_DIR"
    exit 1
  fi
  log "Snapshots in $VAULT_DIR (newest first):"
  ls -lt "$VAULT_DIR"/credentials-*.age 2>/dev/null | head -40
  exit 0
fi

# ─── Resolve which snapshot to restore ─────────────────────────────────
# Three resolution strategies, in order of preference:
#   1. credentials-latest.txt — plain-text pointer (V1.1+ backup.sh writes this).
#   2. credentials-latest.age — legacy symlink (V1 backup.sh wrote this).
#   3. Newest matching credentials-*.age by mtime.
if [[ -z "$SNAPSHOT" ]]; then
  if [[ -f "$VAULT_DIR/credentials-latest.txt" ]]; then
    SNAPSHOT="$VAULT_DIR/$(cat "$VAULT_DIR/credentials-latest.txt")"
  elif [[ -L "$VAULT_DIR/credentials-latest.age" ]]; then
    SNAPSHOT="$VAULT_DIR/$(readlink "$VAULT_DIR/credentials-latest.age")"
  else
    SNAPSHOT=$(ls -t "$VAULT_DIR"/credentials-*.age 2>/dev/null | grep -v latest | head -1 || true)
  fi
fi

if [[ -z "$SNAPSHOT" || ! -f "$SNAPSHOT" ]]; then
  log "ERROR: no snapshot found. Tried: ${SNAPSHOT:-(none)}"
  log "       Run --list to see what's available."
  exit 1
fi

if [[ ! -s "$PASSPHRASE_FILE" ]]; then
  log "ERROR: passphrase file not found or empty at $PASSPHRASE_FILE"
  log "       On a fresh Mac: paste passphrase from your password manager and:"
  log "         printf 'YOUR_PASSPHRASE' > $PASSPHRASE_FILE && chmod 600 $PASSPHRASE_FILE"
  exit 2
fi

log "Restoring from: $(basename "$SNAPSHOT")"
log "  size: $(stat -f %z "$SNAPSHOT") bytes"
log "  mtime: $(stat -f %Sm "$SNAPSHOT")"
log "  target HOME      = $HOME"
log "  target WORKSPACE = $WORKSPACE"

# ─── Extract to staging area so we can inspect metadata first ──────────
EXTRACT=$(mktemp -d 2>/dev/null || mktemp -d -t vault-restore)
extract_cleanup() { rm -rf "$EXTRACT"; }
trap extract_cleanup EXIT

if ! openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 \
       -pass file:"$PASSPHRASE_FILE" -in "$SNAPSHOT" \
     | tar -xzf - -C "$EXTRACT"; then
  log "ERROR: decrypt pipeline failed. Most common cause: wrong passphrase."
  exit 3
fi

# ─── Detect archive format ─────────────────────────────────────────────
if [[ -f "$EXTRACT/vault_meta.json" ]]; then
  ARCHIVE_VERSION="v1.1"
  BACKUP_WS=$(sed -n 's/.*"workspace_root_at_backup": *"\([^"]*\)".*/\1/p' "$EXTRACT/vault_meta.json")
  BACKUP_HOME=$(sed -n 's/.*"home_root_at_backup": *"\([^"]*\)".*/\1/p' "$EXTRACT/vault_meta.json")
  log "  archive format: V1.1 (workspace-aware)"
  log "  backed up FROM: HOME=$BACKUP_HOME  WORKSPACE=$BACKUP_WS"
  if [[ "$BACKUP_WS" != "$WORKSPACE" ]]; then
    log "  RE-ROOTING workspace paths into $WORKSPACE on restore"
  fi
else
  ARCHIVE_VERSION="v1-legacy"
  log "  archive format: V1 legacy (no vault_meta.json — paths assumed home-relative)"
fi

# ─── Plan + apply ──────────────────────────────────────────────────────
plan_and_restore_tree() {
  local SRC="$1"      # e.g. $EXTRACT/h or $EXTRACT/w
  local TARGET="$2"   # e.g. $HOME or $WORKSPACE
  local LABEL="$3"    # human label

  [[ -d "$SRC" ]] || return 0

  # Walk SRC and decide per-file action.
  while IFS= read -r -d '' f; do
    rel="${f#$SRC/}"
    dst="$TARGET/$rel"
    if (( DRY_RUN )); then
      printf '  [%s] %s → %s\n' "$LABEL" "$rel" "$dst"
      continue
    fi
    if [[ -e "$dst" && $FORCE -eq 0 ]]; then
      printf '  [%s] SKIP (exists): %s\n' "$LABEL" "$dst"
      continue
    fi
    mkdir -p "$(dirname "$dst")"
    cp -a "$f" "$dst"
    printf '  [%s] %s\n' "$LABEL" "$dst"
  done < <(find "$SRC" -type f -print0)
}

if (( DRY_RUN )); then
  log "DRY RUN: planned writes (nothing actually written):"
else
  if (( FORCE )); then
    log "FORCE mode: existing files will be OVERWRITTEN"
  else
    log "Default mode: existing files will be SKIPPED (use --force to overwrite)"
  fi
fi

if [[ "$ARCHIVE_VERSION" == "v1.1" ]]; then
  plan_and_restore_tree "$EXTRACT/h" "$HOME"      "HOME"
  plan_and_restore_tree "$EXTRACT/w" "$WORKSPACE" "WORKSPACE"
else
  # Legacy: tar contents are HOME-relative; extract directly to $HOME.
  # Use cp -a to honor SKIP/FORCE semantics.
  plan_and_restore_tree "$EXTRACT" "$HOME" "HOME(legacy)"
fi

log "Done."
