#!/bin/bash
# apply-patches.sh
# Apply the XR1710G-YYH-OC overlay patches on top of a freshly pulled
# YYH2913/openwrt xr1710g-6.18-integration checkout.
#
# Usage:  apply-patches.sh <openwrt_source_root>
#
# The script is idempotent: if a patch has already been applied (git am
# reports "already applied" or patch reports "Reversed (or previously applied)
# patch detected"), it is skipped instead of failing. This lets the workflow
# be re-run on the same checkout without manual cleanup.

set -euo pipefail

SRC="${1:-}"
if [ -z "$SRC" ] || [ ! -d "$SRC" ]; then
    echo "Usage: $0 <openwrt_source_root>"
    exit 1
fi

PATCH_DIR="$(cd "$(dirname "$0")/.." && pwd)/patches"
echo "=== XR1710G-YYH-OC: applying overlay patches ==="
echo "  source:     $SRC"
echo "  patch dir:  $PATCH_DIR"
echo

cd "$SRC"

applied=0
skipped=0
failed=0

for p in $(ls -1 "$PATCH_DIR"/*.patch 2>/dev/null | sort); do
    name=$(basename "$p")
    echo "--- applying $name"
    # Try `patch -p1 --forward` first; --forward makes it skip already-applied
    # patches instead of prompting. We also guard with a fallback to `git apply
    # --3way` so that minor context drift can be resolved automatically.
    if patch -p1 --forward --no-backup-if-mismatch --reject-file=/dev/null < "$p" 2>/dev/null; then
        echo "    OK (patch)"
        applied=$((applied+1))
    elif git apply --3way --whitespace=nowarn "$p" 2>/dev/null; then
        echo "    OK (git apply --3way)"
        applied=$((applied+1))
    else
        # Final check: maybe the patch is already applied (patch --forward
        # returns non-zero in that case too). Probe by trying to reverse it.
        if patch -p1 --reverse --forward --no-backup-if-mismatch --reject-file=/dev/null < "$p" 2>/dev/null; then
            echo "    SKIP (already applied)"
            skipped=$((skipped+1))
            # Re-apply forward to restore the patched state, since the reverse
            # above actually un-did the change.
            patch -p1 --forward --no-backup-if-mismatch --reject-file=/dev/null < "$p" 2>/dev/null || true
        else
            echo "    FAIL"
            failed=$((failed+1))
            # Print the patch header so the workflow log shows what failed.
            head -20 "$p" || true
        fi
    fi
done

echo
echo "=== summary: applied=$applied skipped=$skipped failed=$failed ==="
if [ "$failed" -gt 0 ]; then
    exit 1
fi
exit 0
