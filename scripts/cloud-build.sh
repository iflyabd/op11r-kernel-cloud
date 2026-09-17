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
ln -sfn "$SRC/mods/vendor" "$SRC/vendor"

# --- config: stock base + additive fragment (has MT7601U/BT/NAT) ---
echo "[*] Applying config..."
mkdir -p "$OUT"
cp "$ROOT/configs/device-5.10.236.config" "$OUT/.config"
cat "$ROOT/configs/additive-rtl-bt-otg.fragment" >> "$OUT/.config"
cd "$KDIR"
./scripts/config --file "$OUT/.config" --enable CONFIG_WLAN_VENDOR_MEDIATEK
./scripts/config --file "$OUT/.config" --module CONFIG_MT7601U
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

# --- kernel + in-tree modules ---
echo "[*] Building Image.gz + modules..."
make O="$OUT" -j"$JOBS" Image.gz modules 2>&1 | tee -a "$LOG"
test -f "$OUT/arch/arm64/boot/Image.gz" || { echo "[!] Image.gz missing"; exit 1; }
echo "[+] Image.gz: $(du -h "$OUT/arch/arm64/boot/Image.gz" | cut -f1)"

# --- out-of-tree 88x2bu (DWA-185 0bda:b812) ---
echo "[*] Building out-of-tree 88x2bu..."
cd "$ROOT/drivers-out/rtl88x2bu-cilynx"
make KSRC="$OUT" ARCH=arm64 R_ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- \
  LLVM=1 LLVM_IAS=1 KCFLAGS="-w -Wno-error" -j"$JOBS" 2>&1 | tee -a "$LOG" | tail -n 10
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
