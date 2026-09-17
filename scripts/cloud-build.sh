#!/bin/bash
# cloud-build.sh — OnePlus 11R (SM8475) custom 5.10.236 kernel build for CI
# Mirrors the proven on-device container flow (msm-kernel tree, O=out-msm,
# CFI/SCS/Full-LTO, MT7601U=m + BT + NAT), minus Termux-only host hacks
# (Ubuntu has proper bionic-free headers, real python, llvm-objdump).
#
# Layout: repo root contains configs/, manifests/, scripts/, build/,
#         drivers-out/, firmware/, magisk-module/. Sources are cloned.
# Usage:  bash scripts/cloud-build.sh   (env: JOBS, WORKSPACE)
set -euo pipefail

ROOT="${WORKSPACE:-$PWD}"
SRC="$ROOT/src"
OUT="$ROOT/out-msm"
KDIR="$SRC/msm-kernel"
JOBS="${JOBS:-$(nproc)}"
LOG="$ROOT/build.log"

COMMON_SHA="5b5ead1ba41e4a0727a6b6a460deba5718c52cb6"
MSM_SHA="c6939a66e44bb65859206053dd5f92ea69e059f7"
MODS_SHA="46ba2a7ace39ba653f3f9cc92fdc5af16a771d7e"

echo "[*] OP11R cloud build | jobs=$JOBS | root=$ROOT"
date -u | tee "$LOG"

# Heartbeat: LTO link prints nothing for 10+ min; prove we're alive + watch RAM.
heartbeat() { while sleep 120; do echo "[hb] $(date -u) mem=$(free -m | awk '/^Mem:/{print $3"/"$2"MB"}') disk_free=$(df -h "$ROOT" | awk 'END{print $4}')"; done; }
heartbeat & HB=$!
trap 'kill $HB 2>/dev/null || true' EXIT

# --- toolchain env (matches proven container flow) ---
export ARCH=arm64 SUBARCH=arm64 LLVM=1 LLVM_IAS=1
export CROSS_COMPILE=aarch64-linux-gnu-
export CLANG_TRIPLE=aarch64-linux-gnu-
export CC="ccache clang"
export LD=ld.lld
export KCFLAGS="-w -Wno-error"
# REQUIRED with LLVM/LD=ld.lld: host kconfig/conf links via lld, which has no
# legacy bcmp — same workaround as the proven on-device container flow.
export HOSTCFLAGS="-Dbcmp=memcmp -D__KBUILD_HOSTBUILD__ -include $ROOT/build/host-compat.h"
export PYTHON=python3
export CCACHE_BASEDIR="$ROOT"
export CCACHE_DIR="${CCACHE_DIR:-$HOME/.ccache}"

clone_sha() { # $1=repo url $2=sha $3=dest
  if [ -d "$3/.git" ]; then echo "[=] exists $3"; return; fi
  git init -q "$3" && git -C "$3" remote add origin "$1"
  git -C "$3" fetch -q --depth 1 origin "$2"
  git -C "$3" checkout -q FETCH_HEAD
  echo "[+] cloned $3 @ $(git -C "$3" rev-parse --short HEAD)"
}

echo "[*] Cloning pinned sources..."
mkdir -p "$SRC"
clone_sha https://github.com/OnePlusOSS/android_kernel_common_oneplus_sm8475.git "$COMMON_SHA" "$SRC/common"
clone_sha https://github.com/OnePlusOSS/android_kernel_oneplus_sm8475.git "$MSM_SHA" "$SRC/msm-kernel"
clone_sha https://github.com/OnePlusOSS/android_kernel_modules_and_devicetree_oneplus_sm8475.git "$MODS_SHA" "$SRC/mods"
# Container parity: KDIR=$ROOT/src/msm-kernel, so ../../../vendor from
# KDIR/kernel resolves to $ROOT/vendor (NOT $ROOT/src/vendor).
ln -sfn "$SRC/mods/vendor" "$ROOT/vendor"

# --- kernel-code fixes (documented, stock-intent; working tree carries them too) ---
echo "[*] Applying kernel-code patches..."
git -C "$KDIR" apply --check "$ROOT/patches/msm-kernel-fixes.patch" \
  || { echo "[!] patch check failed"; exit 1; }
git -C "$KDIR" apply "$ROOT/patches/msm-kernel-fixes.patch"
echo "[+] patches applied"

# --- OnePlus vendor overlay links (proven on-device layout) ---
# msm-kernel Kconfig/Makefiles reference kernel/oplus_cpu, drivers/soc/oplus/*,
# etc., which live in mods/vendor/oplus. Recreate the exact overlay symlinks.
echo "[*] Creating vendor overlay symlinks..."
while IFS='|' read -r link target; do
  [ -z "$link" ] && continue
  mkdir -p "$KDIR/$(dirname "$link")"
  ln -sfn "$target" "$KDIR/$link"
done <<'LINKS'
drivers/android/oplus_binder|../../../../vendor/oplus/kernel/ipc
drivers/base/kernelFwUpdate|../../../../vendor/oplus/kernel/touchpanel/kernelFwUpdate
drivers/dma-buf/heaps/oplus_boostpool|../../../../../vendor/oplus/kernel/oplus_performance_5.10/misc/mm_boost_pool/
drivers/input/oplus_fp_driver|../../../../vendor/oplus/secure/biometrics/fingerprints/bsp/drivers_kernel/component3.0/qcom
drivers/input/oplus_secure_drivers|../../../../vendor/oplus/secure/common/bsp/drivers
drivers/input/touchscreen/oplus_touchscreen_v2|../../../../../vendor/oplus/kernel/touchpanel/oplus_touchscreen_v2
drivers/input/touchscreen/synaptics_hbp|../../../../../vendor/oplus/kernel/touchpanel/synaptics_hbp/
drivers/input/uff_fp_drivers|../../../../vendor/oplus/secure/biometrics/fingerprints/bsp/uff/driver
drivers/misc/oplus_procs_load|../../../../vendor/oplus/kernel/power/procs_load/
drivers/power/oplus|../../../../vendor/oplus/kernel/charger
drivers/soc/oplus/boot|../../../../../vendor/oplus/kernel/boot
drivers/soc/oplus/device_info|../../../../../vendor/oplus/kernel/device_info/device_info
drivers/soc/oplus/dfr|../../../../../vendor/oplus/kernel/dfr
drivers/soc/oplus/dft|../../../../../vendor/oplus/kernel/dft
drivers/soc/oplus/hans|../../../../../vendor/oplus/kernel/hans
drivers/soc/oplus/mdmfeature|../../../../../vendor/oplus/hardware/radio/kernel/mdmfeature
drivers/soc/oplus/mdmrst|../../../../../vendor/oplus/hardware/radio/mdmrst/common
drivers/soc/oplus/multimedia|../../../../../vendor/oplus/kernel/multimedia/feedback
drivers/soc/oplus/oplus_consumer_ir|../../../../../vendor/oplus/sensor/kernel/oplus_consumer_ir
drivers/soc/oplus/power|../../../../../vendor/oplus/kernel/power
drivers/soc/oplus/sensor|../../../../../vendor/oplus/sensor/kernel/qcom/sensor/
drivers/soc/oplus/storage|../../../../../vendor/oplus/kernel/storage/storage_feature_in_module
include/linux/cpufreq_effiency.h|../../kernel/oplus_cpu/cpufreq_effiency/cpufreq_effiency.h
include/linux/cpufreq_health.h|../../kernel/oplus_cpu/cpufreq_health/cpufreq_health.h
include/soc/oplus/boot|../../../../../vendor/oplus/kernel/boot/include
include/soc/oplus/dfr|../../../../../vendor/oplus/kernel/dfr/include
include/soc/oplus/dft|../../../../../vendor/oplus/kernel/dft/include
include/soc/oplus/oplus_mm_kevent_fb.h|../../../../../vendor/oplus/kernel/multimedia/feedback/oplus_mm_kevent_fb.h
include/soc/oplus/touchpanel_event_notify.h|../../../../../vendor/oplus/kernel/touchpanel/oplus_touchscreen_v2/touchpanel_notify/touchpanel_event_notify.h
kernel/locking/oplus_locking|../../../../vendor/oplus/kernel/synchronize
kernel/oplus_cpu|../../../vendor/oplus/kernel/cpu
kernel/sched/walt/oem_sched|../../oplus_cpu/misc/sched_assist
kernel/sched/walt/tuning|../../../../../vendor/oplus/kernel/oplus_performance_5.10/misc/sched_input_boost/
mm/oplus_mm|../../../vendor/oplus/kernel/mm
net/oplus_modules|../../../vendor/oplus/kernel/network
LINKS
missing=0
while IFS='|' read -r link target; do
  [ -z "$link" ] && continue
  if [ ! -e "$KDIR/$link" ]; then echo "[!] overlay target missing: $link -> $target"; missing=1; fi
done <<'LINKS'
kernel/oplus_cpu|../../../vendor/oplus/kernel/cpu
kernel/oplus_cpu/sched/Kconfig|../../../vendor/oplus/kernel/cpu/sched/Kconfig
LINKS
test "$missing" -eq 0 || exit 1
echo "[+] overlay links OK"

# --- config: stock base + additive fragment (has MT7601U/BT/NAT) ---
echo "[*] Applying config..."
mkdir -p "$OUT"
cp "$ROOT/configs/device-5.10.236.config" "$OUT/.config"
cat "$ROOT/configs/additive-rtl-bt-otg.fragment" >> "$OUT/.config"
cd "$KDIR"
./scripts/config --file "$OUT/.config" --enable CONFIG_WLAN_VENDOR_MEDIATEK
./scripts/config --file "$OUT/.config" --module CONFIG_MT7601U
./scripts/config --file "$OUT/.config" --disable CONFIG_OPLUS_FEATURE_SENSOR_CFG
./scripts/config --file "$OUT/.config" --set-str CONFIG_UNUSED_KSYMS_WHITELIST "$ROOT/build/abi_symbollist.raw"
make O="$OUT" olddefconfig 2>&1 | tee -a "$LOG" | tail -n 20
test "${PIPESTATUS[0]}" -eq 0 || { echo "[!] olddefconfig failed (see $LOG)"; exit 1; }

echo "[*] Verifying config..."
for k in CONFIG_DM_VERITY CONFIG_SECURITY_SELINUX CONFIG_BT CONFIG_USB_DWC3 \
         CONFIG_MMC CONFIG_THERMAL CONFIG_MODULES CONFIG_FW_LOADER; do
  grep -q "^$k=y" "$OUT/.config" || { echo "[!] FAIL must-keep $k"; exit 1; }
done
for k in CONFIG_MT7601U CONFIG_WLAN_VENDOR_MEDIATEK CONFIG_CFG80211 CONFIG_MAC80211 \
         CONFIG_BT_HCIBTUSB CONFIG_LTO_CLANG_FULL CONFIG_CFI_CLANG CONFIG_SHADOW_CALL_STACK; do
  grep -qE "^$k=(y|m)" "$OUT/.config" || { echo "[!] FAIL addition $k"; exit 1; }
  echo "  [OK] $(grep -E "^$k=" "$OUT/.config")"
done

# --- built-in firmware: EXTRA_FIRMWARE_DIR=/lib/firmware means kbuild takes
# blobs from the HOST /lib/firmware (same as proven container flow) ---
echo "[*] Installing built-in firmware to host /lib/firmware..."
sudo mkdir -p /lib/firmware/rtl_bt
sudo cp "$ROOT/firmware/rtl_bt/"* /lib/firmware/rtl_bt/
ls -la /lib/firmware/rtl_bt/

# --- kernel + in-tree modules ---
echo "[*] Building Image.gz + modules..."
make O="$OUT" -j"$JOBS" Image.gz modules 2>&1 | tee -a "$LOG"
test -f "$OUT/arch/arm64/boot/Image.gz" || { echo "[!] Image.gz missing"; exit 1; }
echo "[+] Image.gz: $(du -h "$OUT/arch/arm64/boot/Image.gz" | cut -f1)"

# --- out-of-tree 88x2bu (DWA-185 0bda:b812) ---
echo "[*] Building out-of-tree 88x2bu..."
cd "$ROOT/drivers-out/rtl88x2bu-cilynx"
make KSRC="$OUT" ARCH=arm64 R_ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- \
  LLVM=1 LLVM_IAS=1 KCFLAGS="-w -Wno-error" EXTRA_CFLAGS="-w" \
  CONFIG_WIFI_MONITOR=y -j"$JOBS" 2>&1 | tee -a "$LOG" | tail -n 10
test "${PIPESTATUS[0]}" -eq 0 || { echo "[!] 88x2bu build failed (see $LOG)"; exit 1; }
find . -name "88x2bu.ko" | head -n 3

# --- verify gates ---
echo "[*] Verify gates..."
MTKO=$(find "$OUT" -name "mt7601u.ko" | head -n 1)
test -n "$MTKO" || { echo "[!] mt7601u.ko missing"; exit 1; }
modinfo "$MTKO" | grep -q "5.10.236-android12-9-o-g74d132f4467a" || { echo "[!] vermagic mismatch"; modinfo "$MTKO" | grep vermagic; exit 1; }
grep -q "__cfi_check" "$OUT/Module.symvers" || echo "[WARN] no __cfi_check in symvers"
X2BU=$(find "$ROOT/drivers-out" -name "88x2bu.ko" | head -n 1)
test -n "$X2BU" || { echo "[!] 88x2bu.ko missing"; exit 1; }
modinfo "$X2BU" | grep -qi "B812" || echo "[WARN] b812 alias not seen in modinfo"
strings "$OUT/arch/arm64/boot/Image" | grep -m1 "5.10.236-android12-9" || echo "[WARN] UTS tabel differs"
echo "[+] all gates passed"

# --- stage artifacts + Magisk zip ---
echo "[*] Staging artifacts..."
ART="$ROOT/artifacts"
rm -rf "$ART" && mkdir -p "$ART/modules" "$ART/firmware"
cp "$OUT/arch/arm64/boot/Image" "$OUT/arch/arm64/boot/Image.gz" "$ART/" 2>/dev/null || true
cp "$MTKO" "$X2BU" "$ART/modules/"
for m in btusb.ko bnep.ko btintel.ko; do find "$OUT" -name "$m" -exec cp {} "$ART/modules/" \; 2>/dev/null || true; done
cp "$OUT/Module.symvers" "$OUT/.config" "$ART/"
cp "$ROOT/firmware/mt7601u.bin" "$ART/firmware/"
cp -r "$ROOT/firmware/rtl_bt" "$ART/firmware/"
ls -la "$ART" "$ART/modules"
cat "$MTKO" > /dev/null && echo "[+] artifacts staged at $ART"
