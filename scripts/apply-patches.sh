#!/bin/bash
# apply-patches.sh
# Apply the XR1710G-YYH-OC overlay patches on top of a freshly pulled
# YYH2913/openwrt xr1710g-6.18-integration checkout.
#
# Usage:  apply-patches.sh <openwrt_source_root>

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
    # Try patch -p1 --forward first; show errors if it fails
    if patch -p1 --forward --no-backup-if-mismatch < "$p" 2>&1; then
        echo "    OK (patch)"
        applied=$((applied+1))
    elif git apply --3way --whitespace=nowarn "$p" 2>&1; then
        echo "    OK (git apply --3way)"
        applied=$((applied+1))
    else
        # Maybe already applied
        if patch -p1 --reverse --forward --no-backup-if-mismatch < "$p" >/dev/null 2>&1; then
            echo "    SKIP (already applied)"
            skipped=$((skipped+1))
            # Re-apply forward to restore the patched state
            patch -p1 --forward --no-backup-if-mismatch < "$p" >/dev/null 2>&1 || true
        else
            echo "    FAIL"
            failed=$((failed+1))
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
