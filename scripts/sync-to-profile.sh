#!/usr/bin/env bash
# sync-to-profile.sh — copy the canonical ansible tree into the runtime
# profile directory that bin/deploy actually executes, then ASSERT
# byte-equality.
#
# WHY THIS EXISTS (2026-10-25):
#
#   /home/amd/infra1-ansible                          <- canonical, a GIT repo
#   ~/.hermes/profiles/infra1/ansible                 <- runtime copy, NOT git
#
#   `bin/deploy` executes the RUNTIME COPY. Nothing syncs the two. So an
#   edit made in the canonical repo but not copied here is a SILENT
#   NO-OP: the deploy runs the OLD playbook and reports success.
#   (This already happened once — a `lgs-redeploy` action was written in
#   the repo and only worked because it had been hand-copied.)
#
# This script makes the copy explicit AND verifies it, so a partial copy
# fails loudly instead of deploying stale recipes.
#
# Usage:
#   scripts/sync-to-profile.sh [DEST]
#   DEST defaults to ~/.hermes/profiles/infra1/ansible
#
# Exit codes:
#   0  synced + byte-identical
#   1  copy failed or a file is not byte-identical

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="${1:-$HOME/.hermes/profiles/infra1/ansible}"

echo "[sync] $REPO"
echo "[sync]   -> $DEST"

if [[ ! -d "$REPO/group_vars" || ! -d "$REPO/playbooks" ]]; then
  echo "[sync] ✗ $REPO does not look like the ansible repo (missing group_vars/ or playbooks/)" >&2
  exit 1
fi

mkdir -p "$DEST/group_vars" "$DEST/playbooks"

# ── 1. top-level files ────────────────────────────────────────────────────
for f in inventory.yml ansible.cfg; do
  if [[ -f "$REPO/$f" ]]; then
    cp "$REPO/$f" "$DEST/$f"
    echo "[sync]   cp $f"
  fi
done

# ── 2. group_vars ─────────────────────────────────────────────────────────
for f in "$REPO"/group_vars/*.yml; do
  [[ -e "$f" ]] || continue
  cp "$f" "$DEST/group_vars/"
  echo "[sync]   cp group_vars/$(basename "$f")"
done

# ── 3. playbooks ──────────────────────────────────────────────────────────
for f in "$REPO"/playbooks/*.yml; do
  [[ -e "$f" ]] || continue
  cp "$f" "$DEST/playbooks/"
  echo "[sync]   cp playbooks/$(basename "$f")"
done

# playbooks/files/ holds jinja templates used by some playbooks
if [[ -d "$REPO/playbooks/files" ]]; then
  mkdir -p "$DEST/playbooks/files"
  cp -r "$REPO"/playbooks/files/. "$DEST/playbooks/files/" 2>/dev/null || true
  echo "[sync]   cp playbooks/files/"
fi

# ── 4. ASSERT byte-equality on everything we copied ───────────────────────
fail=0
checked=0
while IFS= read -r -d '' f; do
  rel="${f#"$REPO"/}"
  if [[ ! -f "$DEST/$rel" ]]; then
    echo "[sync] ✗ MISSING in dest: $rel" >&2
    fail=1
    continue
  fi
  if ! cmp -s "$f" "$DEST/$rel"; then
    echo "[sync] ✗ MISMATCH: $rel" >&2
    fail=1
  fi
  checked=$((checked + 1))
done < <(find "$REPO/group_vars" "$REPO/playbooks" -name '*.yml' -print0)

for f in inventory.yml ansible.cfg; do
  [[ -f "$REPO/$f" ]] || continue
  cmp -s "$REPO/$f" "$DEST/$f" || { echo "[sync] ✗ MISMATCH: $f" >&2; fail=1; }
  checked=$((checked + 1))
done

if [[ $fail -ne 0 ]]; then
  echo "[sync] ✗ sync incomplete — the runtime copy would deploy STALE recipes" >&2
  exit 1
fi

echo "[sync] ✓ all $checked files byte-identical"
