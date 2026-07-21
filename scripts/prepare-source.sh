#!/bin/bash
# prepare-source.sh
# Run INSIDE the Docker container to prepare OpenWrt source.
# Usage: docker exec -u 0 DK bash /workspace/scripts/prepare-source.sh

set -euxo pipefail

cd /bld/openwrt
echo "=== Step 1: pwd=$(pwd) hostname=$(hostname) ==="

# ---- Incremental source update ----
if [ -d .git ]; then
  echo "=== Incremental source update ==="
  git remote set-url origin "$UPSTREAM_REPO" 2>/dev/null || git remote add origin "$UPSTREAM_REPO"
  git fetch --depth=1 origin "$UPSTREAM_BRANCH"
  git reset --hard "origin/$UPSTREAM_BRANCH"
  git clean -fd
else
  echo "=== Fresh clone ==="
  git clone --depth=1 --branch="$UPSTREAM_BRANCH" "$UPSTREAM_REPO" .
fi
git log -1 --format="Upstream HEAD: %H %s (%ci)"

# ---- Set up symlinks for volumes ----
if [ -L staging_dir ]; then
  echo "Removing old staging_dir symlink"
  rm -f staging_dir
fi
rm -rf bin dl 2>/dev/null || true
ln -sf /bld/openwrt_bin bin
ln -sf /dlcache dl

echo "=== Step 2: before feeds update, pwd=$(pwd) ==="

# ---- Update feeds (initial) ----
./scripts/feeds update -a

echo "=== Step 3: after feeds update, pwd=$(pwd) ==="

# ---- Apply overlay patches (inline) ----
echo "=== Applying overlay patches ==="
for p in /workspace/patches/*.patch; do
  name=$(basename "$p")
  echo "--- applying $name"
  if patch -p1 --forward --no-backup-if-mismatch < "$p" 2>&1; then
    echo "    OK (patch)"
  elif git apply --3way --whitespace=nowarn "$p" 2>&1; then
    echo "    OK (git apply --3way)"
  else
    if patch -p1 --reverse --forward --no-backup-if-mismatch < "$p" >/dev/null 2>&1; then
      echo "    SKIP (already applied)"
      patch -p1 --forward --no-backup-if-mismatch < "$p" >/dev/null 2>&1 || true
    else
      echo "    FAIL"
      head -20 "$p" || true
    fi
  fi
done

echo "=== Step 4: after patches, pwd=$(pwd) ==="

# ---- Update only the newly-added argon feed ----
# Do NOT run 'feeds update -a' again — it would git-pull the packages
# feed and overwrite patch 007's Makefile edit.
./scripts/feeds update argon || true

echo "=== Step 5: after argon update, pwd=$(pwd) ==="

# ---- Install all feeds ----
./scripts/feeds install -a

echo "=== Step 6: after feeds install, pwd=$(pwd) ==="

# ---- Re-apply patch 007 (v2ray-geodata version bump) ----
# feeds update may have overwritten it via git-pull
patch -p1 --forward --no-backup-if-mismatch < /workspace/patches/007-update-v2ray-geodata-versions.patch || true

# ---- Configure ----
cp /workspace/config/xr1710g-oc.conf .config
make defconfig

echo "=== Key config selections ==="
grep -E '^CONFIG_TARGET|^CONFIG_PACKAGE_kmod-ipsec|^CONFIG_ALL|^CONFIG_CCACHE|^CONFIG_PACKAGE_luci-theme-argon|^# CONFIG_PACKAGE_nftables-nojson|^# CONFIG_PACKAGE_golang' .config || true

echo "=== Prepare OpenWrt source DONE ==="
