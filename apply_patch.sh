#!/usr/bin/env bash
# Paykari Bazar — Production Hardening Patch Installer
# Usage: bash apply_patch.sh  (from your paykaribazar repo root)
#
# This installer is SAFE: it backs up every file it overwrites to
# .patch-backup-<timestamp>/ before copying the new version in.
# New files are added without touching existing ones (unless they collide).

set -euo pipefail

PATCH_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(pwd)"
TS="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="$REPO_ROOT/.patch-backup-$TS"

if [ ! -d "$REPO_ROOT/.git" ]; then
  echo "❌ Run this script from the root of your paykaribazar git repo."
  exit 1
fi

if [ ! -d "$PATCH_DIR/functions" ] || [ ! -f "$PATCH_DIR/PATCH_MANIFEST.md" ]; then
  echo "❌ Patch folder not found next to this script. Expected: $PATCH_DIR"
  exit 1
fi

echo "📦 Paykari Bazar Production Patch — installer"
echo "   Repo root : $REPO_ROOT"
echo "   Patch dir : $PATCH_DIR"
echo "   Backup    : $BACKUP_DIR"
echo ""
mkdir -p "$BACKUP_DIR"

# Walk every file in the patch (excluding this script + the manifest + the zip).
SKIP_NAMES=("apply_patch.sh" "PATCH_MANIFEST.md" "paykaribazar-production-patch.zip")
count_new=0
count_overwritten=0

while IFS= read -r -d '' f; do
  rel="${f#$PATCH_DIR/}"
  dest="$REPO_ROOT/$rel"
  name="$(basename "$f")"
  case " ${SKIP_NAMES[*]} " in
    *" $name "*) continue ;;
  esac

  if [ -e "$dest" ]; then
    mkdir -p "$BACKUP_DIR/$(dirname "$rel")"
    cp -p "$dest" "$BACKUP_DIR/$rel"
    cp -p "$f" "$dest"
    count_overwritten=$((count_overwritten + 1))
    echo "🔄 overwrote  $rel"
  else
    mkdir -p "$(dirname "$dest")"
    cp -p "$f" "$dest"
    count_new=$((count_new + 1))
    echo "✨ added      $rel"
  fi
done < <(find "$PATCH_DIR" -type f -not -name "apply_patch.sh" -not -name "PATCH_MANIFEST.md" -not -name "paykaribazar-production-patch.zip" -print0)

echo ""
echo "✅ Done. $count_new new file(s), $count_overwritten overwritten (backed up)."
echo ""
echo "Next steps:"
echo "  1. Review git diff and resolve any local edits."
echo "  2. cd functions && npm ci && npm run build"
echo "  3. flutter pub get"
echo "  4. flutter analyze --fatal-infos --fatal-warnings"
echo "  5. firebase emulators:exec --only firestore,functions 'dart test test/firestore_rules/'"
echo "  6. Configure secrets — see functions/.env.example and docs/SECURITY.md"
echo "  7. firebase deploy --only firestore:rules,storage:rules,functions"
echo "  8. Register webhooks with bKash / Nagad / SSLCommerz (see docs/PAYMENTS.md)"
echo "  9. Run through functions-deploy-checklist.md"
echo ""
echo "Backup of pre-patch state: $BACKUP_DIR"
echo "See PATCH_MANIFEST.md for the full issue→file map."
