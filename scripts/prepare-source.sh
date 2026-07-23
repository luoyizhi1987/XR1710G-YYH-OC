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

echo "=== Step 5.5: install luci-app-daed ==="

# Clone the luci-app-daed overlay into package/dae/. The OpenWrt build
# system auto-discovers package/<dir>/<name>/Makefile pairs, so this
# adds two sub-packages:
#   - package/dae/daed/Makefile         -> Package/daed
#   - package/dae/luci-app-daed/Makefile -> Package/luci-app-daed
# Both are enabled via CONFIG_PACKAGE_{daed,luci-app-daed}=y in
# config/xr1710g-oc.conf. See daed/Makefile for the upstream build
# requirements (Node.js v24 + pnpm, Go, Clang, llvm) — all downloaded
# at Build/Prepare time from inside the daed package itself.
if [ ! -d package/dae ]; then
    git clone --depth=1 https://github.com/QiuSimons/luci-app-daed package/dae
    # Verify both sub-package Makefiles landed
    test -f package/dae/daed/Makefile || { echo "FATAL: daed/Makefile missing after clone"; exit 1; }
    test -f package/dae/luci-app-daed/Makefile || { echo "FATAL: luci-app-daed/Makefile missing after clone"; exit 1; }
    echo "=== luci-app-daed cloned into package/dae/ ==="
else
    # Incremental build: refresh the clone (depth=1 keeps it small).
    ( cd package/dae && git fetch --depth=1 origin && git reset --hard origin/HEAD )
    echo "=== luci-app-daed refreshed in package/dae/ ==="
fi

# --- Strip the vmlinux-btf conditional dependency from daed/Makefile ---
# OpenWrt 23.05+ uses apk (.apk packages, not .ipk). The daed package's
# Makefile declares:
#   DEPENDS:=... +DAED_USE_VMLINUX_BTF:vmlinux-btf
# That conditional dep ends up in the .apk manifest, so installing the
# daed .apk with `apk add` would refuse (or pull in vmlinux-btf) even
# though we explicitly chose DAED_USE_KERNEL_BTF in .config and the
# kernel has built-in BTF support (CONFIG_KERNEL_DEBUG_INFO_BTF=y).
# We never need vmlinux-btf on this build, so unconditionally remove
# that line — the .apk becomes self-contained and installs cleanly
# with plain `apk add .../*.apk` (no --force-deps required).
echo "=== Stripping vmlinux-btf dep from daed/Makefile (apk mode, kernel BTF used) ==="
if grep -q '^+DAED_USE_VMLINUX_BTF:vmlinux-btf' package/dae/daed/Makefile; then
    sed -i '/^+DAED_USE_VMLINUX_BTF:vmlinux-btf/d' package/dae/daed/Makefile
    echo "    OK — removed conditional vmlinux-btf dep"
else
    echo "    SKIP — line not present (already stripped or upstream changed)"
fi
grep -nE 'vmlinux-btf' package/dae/daed/Makefile || echo "    (no vmlinux-btf references left in daed/Makefile)"

echo "=== Step 6: configure ==="

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
echo "=== Step 7: forcing kernel rebuild for OC patch ==="
rm -rf build_dir/linux-*
rm -rf build_dir/target-linux-* 2>/dev/null || true
# Also clean kernel stamps in tmp/
rm -f tmp/.target-linux-compile 2>/dev/null || true
rm -f tmp/.packageinfo-linux 2>/dev/null || true

echo "=== Key config selections ==="
grep -E '^CONFIG_TARGET|^CONFIG_PACKAGE_luci-theme-argon|^CONFIG_PACKAGE_luci-i18n|CONFIG_CPU_FREQ|CONFIG_CCACHE|CONFIG_(PACKAGE_)?DAED' .config || true

echo "=== Verify i18n packages ==="
grep -E 'luci-i18n.*zh-cn' .config || true

echo "=== Verify daed packages ==="
grep -E '^CONFIG_(PACKAGE_)?(daed|luci-app-daed|kmod-sched-core|kmod-sched-bpf|kmod-veth)' .config || true

echo "=== Prepare OpenWrt source DONE ==="
