# OP11R kernel cloud build — OnePlus 11R (SM8475), 5.10.236

Custom kernel: in-tree **MT7601U** (`148f:7601` USB stick) + out-of-tree
**RTL8822BU** (DWA-185 `0bda:b812`) + **RTL8761BU** BT, CFI/SCS/Full-LTO kept
stock-exact so vendor_dlkm (`qca6490` WiFi, audio, camera) keeps loading.

## Layout
- `configs/` — stock `device-5.10.236.config` + additive fragment (MT7601U/BT/NAT)
- `build/abi_symbollist.raw` — TRIM_UNUSED_KSYMS whitelist incl. `ieee80211_*`
- `drivers-out/rtl88x2bu-{cilynx,rincat}` — out-of-tree 88x2bu (cilynx proven)
- `firmware/` — `mt7601u.bin`, `rtl_bt/rtl8761b_*`
- `magisk-module/` — Magisk template (kos + firmware injected by CI)
- `scripts/cloud-build.sh` — the build (mirrors proven on-device container flow)
- `.github/workflows/build-kernel.yml` — manual CI (`workflow_dispatch`)

Sources are **not** vendored: CI clones pinned SHAs
(`common 5b5ead1`, `msm c6939a6`, `mods 46ba2a7`).

## Run
Actions → `OP11R kernel cloud build` → Run workflow → download
`op11r-Image`, `op11r-modules-magisk` artifacts.

## Test gate (mandatory, no flash before this)
Bugjaeger `fastboot boot` the test image (RAM-only) on slot `_a`
(`_b` stays fallback): `uname -r`, `lsusb 148f:7601`, `iw dev wlan1`,
`dmesg mt7601u`, internal `wlan0` still up.

## Notes
- `drivers-out/rtl8812au` (unused 103M aircrack variant) intentionally omitted.
- Local iteration lives next to this repo (`op11r-stock-kernel/`, container
  `/root/op11r`, Magisk `magisk-rtw88-module.zip`).
