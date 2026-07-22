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

echo "=== Step 2: feeds update ==="

# ---- Update feeds with --force to get latest code ----
# This ensures feed packages are up-to-date even if upstream hasn't updated.
./scripts/feeds update -a -f

echo "=== Step 3: applying patches ==="

# ---- Apply overlay patches (inline) ----
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

echo "=== Step 4: argon theme ==="

# ---- Update argon feed and install as local package ----
./scripts/feeds update argon || true

# The argon feed's Makefile has issues with scan.mk.
# Copy argon theme source directly into the package tree as a local package.
if [ -d feeds/argon ]; then
  mkdir -p package/luci/luci-theme-argon
  cp -a feeds/argon/* package/luci/luci-theme-argon/
  sed -i 's/^# call BuildPackage - OpenWrt buildroot signature/$(eval $(call BuildPackage,luci-theme-argon))/' package/luci/luci-theme-argon/Makefile
  sed -i 's/^LUCI_DEPENDS:=.*/LUCI_DEPENDS:=+wget +jsonfilter/' package/luci/luci-theme-argon/Makefile
  echo "=== Argon theme installed as local package ==="
fi

echo "=== Step 5: feeds install ==="

# ---- Install all feeds ----
./scripts/feeds install -a

echo "=== Step 6: v2ray-geodata fix ==="

# ---- Fix v2ray-geodata Makefile (patch 007 via sed) ----
V2RAY_MAKEFILE="feeds/packages/net/v2ray-geodata/Makefile"
if [ -f "$V2RAY_MAKEFILE" ]; then
  sed -i 's/^GEOIP_VER:=.*/GEOIP_VER:=202607171233/' "$V2RAY_MAKEFILE"
  sed -i 's/^GEOSITE_VER:=.*/GEOSITE_VER:=20260721085449/' "$V2RAY_MAKEFILE"
  sed -i 's/^  HASH:=e9002979e0df72bce1c8751ff70725386594c551db684b7a232935b8b2bb8aa2/  HASH:=b71d1999439dde2de2d2b6844a2befa50c50211ff739785c005ca7c230a17d6a/' "$V2RAY_MAKEFILE"
  sed -i 's/^  HASH:=330e9383df4b232747d900c70ff1718d396e0fff4914930285c24657e7f013a1/  HASH:=4474555a11e03d86f7677a043ce717ac096e9f998a7d66e90fc7a1065ee0ab8a/' "$V2RAY_MAKEFILE"
fi

echo "=== Step 7: configure ==="

# ---- Configure ----
cp /workspace/config/xr1710g-oc.conf .config
make defconfig

# ---- Force enable i18n packages that defconfig may have dropped ----
# These are needed for full Chinese language support.
# After sed, do NOT run make defconfig again — it would reset them.
for pkg in luci-i18n-base-zh-cn luci-i18n-firewall-zh-cn luci-i18n-package-manager-zh-cn luci-i18n-argon-zh-cn; do
  sed -i "s/^# CONFIG_PACKAGE_${pkg} is not set/CONFIG_PACKAGE_${pkg}=y/" .config
  grep -q "CONFIG_PACKAGE_${pkg}" .config || echo "CONFIG_PACKAGE_${pkg}=y" >> .config
done

# ---- Force kernel rebuild to ensure OC patch takes effect ----
# The OC patch modifies DTS files. If build_dir/linux-* has cached
# compiled kernel objects from a previous run, make won't rebuild.
# Delete the kernel build cache to force a full kernel recompile.
echo "=== Step 8: forcing kernel rebuild for OC patch ==="
rm -rf build_dir/linux-*
rm -rf build_dir/target-linux-* 2>/dev/null || true
# Also clean kernel stamps in tmp/
rm -f tmp/.target-linux-compile 2>/dev/null || true
rm -f tmp/.packageinfo-linux 2>/dev/null || true

echo "=== Key config selections ==="
grep -E '^CONFIG_TARGET|^CONFIG_PACKAGE_luci-theme-argon|^CONFIG_PACKAGE_luci-i18n|CONFIG_CPU_FREQ|CONFIG_CCACHE' .config || true

echo "=== Verify i18n packages ==="
grep -E 'luci-i18n.*zh-cn' .config || true

echo "=== Prepare OpenWrt source DONE ==="
