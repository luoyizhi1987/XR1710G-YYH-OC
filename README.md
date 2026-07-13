# XR1710G-YYH-OC

OpenWrt build overlay for the **Econet / Airoha XR1710G** router, based on the
[`YYH2913/openwrt`](https://github.com/YYH2913/openwrt) `xr1710g-6.18-integration`
branch, with three customisations applied on top:

1. **30 dBm 5 GHz UNII-1 transmit power** (channels 36-48).
   The upstream tree already raises UNII-1 from the stock 23 dBm to 29 dBm via
   `package/firmware/wireless-regdb/patches/520-w1700k-us-power-limits.patch`.
   This overlay raises it one more dBm to **30 dBm** so the 5 GHz low channels
   report and allow a 1 W conducted limit. See
   [`patches/001-txpower-30dbm-5ghz-unii1.patch`](patches/001-txpower-30dbm-5ghz-unii1.patch).

2. **+200 MHz CPU overclock + performance governor**.
   Ported from [`OpenWRT-fanboy/OpenW1700k`](https://github.com/OpenWRT-fanboy/OpenW1700k)
   branch `ubi2-oc`. The DTS OPP table is shifted up by 200 MHz per step
   (500-1200 MHz -> 700-1400 MHz) and the default cpufreq governor is switched
   from `ondemand` to `performance`, so the router boots at 1.4 GHz.
   See [`patches/002-oc-overclock-200mhz-performance-governor.patch`](patches/002-oc-overclock-200mhz-performance-governor.patch).

3. **Theme and package adjustments**.
   * Drop `luci-theme-glass` and its i18n packs (disabled in `.config`).
   * Add `luci-theme-argon` + `luci-i18n-argon-zh-cn` as the default theme.
   * Add `luci-app-upnp` + `luci-i18n-upnp-zh-cn` + `miniupnpd-nftables`.
   * Add `v2ray-geoip` + `v2ray-geosite`.
   See [`patches/003-drop-glass-add-argon-theme.patch`](patches/003-drop-glass-add-argon-theme.patch)
   and [`patches/004-add-upnp-v2ray-geo-packages.patch`](patches/004-add-upnp-v2ray-geo-packages.patch).

The build also enables the following kernel options as requested:

```
CONFIG_DEVEL=y
CONFIG_KERNEL_DEBUG_INFO=y
CONFIG_KERNEL_DEBUG_INFO_REDUCED=n
CONFIG_KERNEL_DEBUG_INFO_BTF=y
CONFIG_KERNEL_CGROUPS=y
CONFIG_KERNEL_CGROUP_BPF=y
CONFIG_KERNEL_BPF_EVENTS=y
CONFIG_BPF_TOOLCHAIN_HOST=y
CONFIG_KERNEL_XDP_SOCKETS=y
CONFIG_PACKAGE_kmod-xdp-sockets-diag=y
```

## How it builds

The GitHub Actions workflow (`.github/workflows/build.yml`) is **manual trigger
only** (`workflow_dispatch`). Each run:

1. Clones the latest `YYH2913/openwrt` `xr1710g-6.18-integration` branch.
2. Applies the four overlay patches in numeric order via
   `scripts/apply-patches.sh` (idempotent: re-running on an already-patched
   tree is a no-op).
3. Seeds `.config` from [`config/xr1710g-oc.conf`](config/xr1710g-oc.conf).
4. Updates and installs all upstream feeds (no feed is removed).
5. Runs `make defconfig` to expand the config.
6. Downloads all sources (`make download`).
7. Builds the toolchain, then the full target.
8. Uploads the firmware images, manifest, and full `.config` as a GitHub
   Actions artifact.

## Repository layout

```
.
├── .github/workflows/build.yml   # manual-trigger full build workflow
├── config/
│   └── xr1710g-oc.conf           # .config seed (kernel options, packages, themes)
├── patches/
│   ├── 001-txpower-30dbm-5ghz-unii1.patch
│   ├── 002-oc-overclock-200mhz-performance-governor.patch
│   ├── 003-drop-glass-add-argon-theme.patch
│   └── 004-add-upnp-v2ray-geo-packages.patch
├── scripts/
│   └── apply-patches.sh          # idempotent patch applicator
└── README.md
```

## Triggering a build

Go to **Actions** -> **Build XR1710G YYH OC firmware** -> **Run workflow**.
Optionally tick "Wipe ccache and tmp/" for a fully clean build.

## Notes

* The 30 dBm UNII-1 setting is a local regulatory override. Make sure it is
  legal in your jurisdiction before flashing.
* The +200 MHz overclock assumes the BL31 firmware on the device already
  accepts the higher OPP levels through the SMCCC cpufreq interface. The
  upstream YYH2913 tree ships that firmware, so no extra blob is needed.
* The Glass theme is disabled in `.config` and is not in the device package
  list, so it will not appear in the image even if the luci feed defines it.
