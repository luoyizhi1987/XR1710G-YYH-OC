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
# feeds update may have overwritten it via git-pull.
# Use sed to directly modify the Makefile as a reliable fallback.
V2RAY_MAKEFILE="feeds/packages/net/v2ray-geodata/Makefile"
if [ -f "$V2RAY_MAKEFILE" ]; then
  echo "=== Patching $V2RAY_MAKEFILE with sed ==="
  sed -i 's/^GEOIP_VER:=.*/GEOIP_VER:=202607171233/' "$V2RAY_MAKEFILE"
  sed -i 's/^GEOSITE_VER:=.*/GEOSITE_VER:=20260721085449/' "$V2RAY_MAKEFILE"
  # Update geoip hash (old: e9002979..., new: b71d1999...)
  sed -i 's/^  HASH:=e9002979e0df72bce1c8751ff70725386594c551db684b7a232935b8b2bb8aa2/  HASH:=b71d1999439dde2de2d2b6844a2befa50c50211ff739785c005ca7c230a17d6a/' "$V2RAY_MAKEFILE"
  # Update geosite hash (old: 330e9383..., new: 4474555a...)
  sed -i 's/^  HASH:=330e9383df4b232747d900c70ff1718d396e0fff4914930285c24657e7f013a1/  HASH:=4474555a11e03d86f7677a043ce717ac096e9f998a7d66e90fc7a1065ee0ab8a/' "$V2RAY_MAKEFILE"
fi

# ---- Verify patch 007 was applied ----
echo "=== Verifying v2ray-geodata Makefile ==="
grep "GEOIP_VER\|GEOSITE_VER\|HASH" feeds/packages/net/v2ray-geodata/Makefile | head -10

# ---- Configure ----
cp /workspace/config/xr1710g-oc.conf .config
make defconfig

echo "=== Key config selections ==="
grep -E '^CONFIG_TARGET|^CONFIG_PACKAGE_kmod-ipsec|^CONFIG_ALL|^CONFIG_CCACHE|^CONFIG_PACKAGE_luci-theme-argon|^# CONFIG_PACKAGE_nftables-nojson|^# CONFIG_PACKAGE_golang' .config || true

echo "=== Prepare OpenWrt source DONE ==="
