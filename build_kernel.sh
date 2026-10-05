#!/bin/bash

# Exit on any error
set -e

# ==========================================
# Argument Parsing
# ==========================================
if [ -z "$1" ]; then
    echo "[!] Error: No device specified."
    echo "Usage: $0 <device_name> [ksu] [miui|aosp]"
    exit 1
fi

DEVICE_NAME="$1"
DEFCONFIG="${DEVICE_NAME}_defconfig"
DEFCONFIG_PATH="arch/arm64/configs/${DEFCONFIG}"

if [ ! -f "$DEFCONFIG_PATH" ]; then
    echo "[!] Error: Defconfig not found at $DEFCONFIG_PATH"
    exit 1
fi

ENABLE_KSU=0
TARGET_OS="both"

shift
for arg in "$@"; do
    case "$arg" in
        ksu) ENABLE_KSU=1 ;;
        miui) TARGET_OS="miui" ;;
        aosp) TARGET_OS="aosp" ;;
    esac
done

# ==========================================
# Configuration & Environment
# ==========================================
KERNEL_DIR="$(pwd)"
TOOLCHAIN_BIN="$HOME/zyc-clang/bin"

export PATH="${TOOLCHAIN_BIN}:${PATH}"
export ARCH="arm64"
export SUBARCH="arm64"

export CCACHE_DIR="$HOME/.cache/ccache_mikernel"
export CCACHE_EXEC=$(command -v ccache)
if [ -z "$CCACHE_EXEC" ]; then
    echo "[!] ccache not found!"; exit 1
fi
export USE_CCACHE=1
export CROSS_COMPILE="aarch64-linux-gnu-"
export CROSS_COMPILE_ARM32="arm-linux-gnueabi-"

echo "[*] Checking Clang version..."
clang --version || { echo "[!] Clang not found"; exit 1; }
mkdir -p "$CCACHE_DIR"

# ==========================================
# SukiSU Ultra Setup  (changed from ReSukiSU)
# ==========================================
if [ "$ENABLE_KSU" -eq 1 ]; then
    echo "==========================================="
    echo " [*] Initializing SukiSU Ultra Setup"
    echo "==========================================="
    echo "[*] Downloading and running SukiSU Ultra remote setup script..."
    curl -LSs "https://raw.githubusercontent.com/SukiSU-Ultra/SukiSU-Ultra/main/kernel/setup.sh" | bash
    # 4.19 相容修正：MODULE_IMPORT_NS 不存在
    sed -i 's|^MODULE_IMPORT_NS(VFS_internal.*|// &|' "$KERNEL_DIR/KernelSU/kernel/core/init.c"
    # 4.19 相容修正：file_operations 無 iopoll / remap_file_range 成員
    python3 - "$KERNEL_DIR/KernelSU/kernel/infra/file_wrapper.c" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p).read()
# iopoll：把 #else 改為 #elif >=5.10，4.19 兩分支都不編
s = s.replace(
"#else\nstatic int ksu_wrapper_iopoll(struct kiocb *kiocb, bool spin)",
"#elif LINUX_VERSION_CODE >= KERNEL_VERSION(5, 10, 0)\nstatic int ksu_wrapper_iopoll(struct kiocb *kiocb, bool spin)")
# iopoll ops 賦值守衛
s = s.replace(
"    p->ops.iopoll = fp->f_op->iopoll ? ksu_wrapper_iopoll : NULL;",
"#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 10, 0)\n    p->ops.iopoll = fp->f_op->iopoll ? ksu_wrapper_iopoll : NULL;\n#endif")
# remap_file_range：包裝函式守衛
s = s.replace(
"static loff_t ksu_wrapper_remap_file_range",
"#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 16, 0)\nstatic loff_t ksu_wrapper_remap_file_range")
s = s.replace(
"    return orig->f_op->remap_file_range(orig, pos_in, file_out, pos_out, len, remap_flags);\n    }\n}",
"    return orig->f_op->remap_file_range(orig, pos_in, file_out, pos_out, len, remap_flags);\n    }\n}\n#endif")
# remap ops 賦值守衛
s = s.replace(
"    p->ops.remap_file_range = fp->f_op->remap_file_range ? ksu_wrapper_remap_file_range : NULL;",
"#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 16, 0)\n    p->ops.remap_file_range = fp->f_op->remap_file_range ? ksu_wrapper_remap_file_range : NULL;\n#endif")
open(p,"w").write(s)
print("patched file_wrapper.c for 4.19")
PYEOF
    # 4.19 相容：seccomp_cache.c 使用 5.10+ 才有的 SECCOMP_ARCH_NATIVE_NR
    python3 - "$KERNEL_DIR/KernelSU/kernel/infra/seccomp_cache.c" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p).read()
guard = "#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 10, 0)\n"
if not s.startswith(guard):
    # 在最後一個 #include 之後插入守衛結尾
    marker = '#include "infra/seccomp_cache.h"\n'
    s = s.replace(marker, marker + "\n#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 10, 0)\n", 1)
    s = s.rstrip() + "\n#else\nvoid ksu_seccomp_clear_cache(struct seccomp_filter *filter, int nr) { (void)filter; (void)nr; }\nvoid ksu_seccomp_allow_cache(struct seccomp_filter *filter, int nr) { (void)filter; (void)nr; }\n#endif\n"
open(p,"w").write(s)
print("patched seccomp_cache.c for 4.19")
PYEOF
    # 4.19 相容：uapi/linux/mount.h 為 5.10+ 表頭
    sed -i 's|#include <uapi/linux/mount.h>|#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 10, 0)\n#include <uapi/linux/mount.h>\n#endif|' "$KERNEL_DIR/KernelSU/kernel/infra/su_mount_ns.c"
    # 4.19 相容：fsnotify_ops 在 4.19 用 handle_event 而非 handle_inode_event，整個 observer 在低版本包成 stub
    python3 - "$KERNEL_DIR/KernelSU/kernel/manager/pkg_observer.c" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p).read()
marker = '#include "manager/throne_tracker.h"\n'
if marker in s and "#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 4, 0)" not in s:
    s = s.replace(marker, marker + "\n#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 4, 0)\n", 1)
    s = s.rstrip() + "\n#else\nint ksu_observer_init(void) { return 0; }\nvoid ksu_observer_exit(void) {}\n#endif\n"
open(p,"w").write(s)
print("patched pkg_observer.c for 4.19")
PYEOF
    # 4.19 相容：TWA_RESUME 為 5.14+，task_work_add 第三參數用 0；補 put_task_struct 表頭
    sed -i 's|#include <linux/hashtable.h>|#include <linux/hashtable.h>\n#include <linux/sched/task.h>|' "$KERNEL_DIR/KernelSU/kernel/policy/allowlist.c"
    sed -i 's|if (task_work_add(tsk, cb, TWA_RESUME)) {|#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 14, 0)\n    if (task_work_add(tsk, cb, TWA_RESUME)) {\n#else\n    if (task_work_add(tsk, cb, 0)) {\n#endif|' "$KERNEL_DIR/KernelSU/kernel/policy/allowlist.c"
    # 4.19 相容：struct seccomp 無 filter_count 成員
    sed -i 's|    atomic_set(&current->seccomp.filter_count, 0);|#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 10, 0)\n    atomic_set(\&current->seccomp.filter_count, 0);\n#endif|' "$KERNEL_DIR/KernelSU/kernel/policy/app_profile.c"
    # 4.19 相容：selinux/rules.c 使用 5.x 的 selinux_state.policy/policy_mutex，4.19 API 不同，整包成 stub
    python3 - "$KERNEL_DIR/KernelSU/kernel/selinux/rules.c" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p).read()
marker = '#include "xfrm.h"\n'
if marker in s and "#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 10, 0)" not in s:
    s = s.replace(marker, marker + "\n#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 10, 0)\n", 1)
    s = s.rstrip() + "\n#else\nstruct selinux_policy *backup_sepolicy;\nvoid apply_kernelsu_rules(void) {}\nint handle_sepolicy(void __user *user_data, u64 data_len) { (void)user_data; (void)data_len; return 0; }\n#endif\n"
open(p,"w").write(s)
print("patched rules.c for 4.19")
PYEOF
    # 4.19 相容：sepolicy.c 使用 5.x SELinux policydb 內部結構，整包成 stub
    python3 - "$KERNEL_DIR/KernelSU/kernel/selinux/sepolicy.c" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p).read()
marker = '#include "ss/symtab.h"\n'
if marker in s and "#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 10, 0)" not in s:
    s = s.replace(marker, marker + "\n#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 10, 0)\n", 1)
    stub = """
#else
struct selinux_policy *ksu_dup_sepolicy(struct selinux_policy *old_pol) { (void)old_pol; return NULL; }
void ksu_destroy_sepolicy(struct selinux_policy *orig) { (void)orig; }
bool ksu_type(struct policydb *db, const char *name, const char *attr) { (void)db;(void)name;(void)attr; return false; }
bool ksu_attribute(struct policydb *db, const char *name) { (void)db;(void)name; return false; }
bool ksu_permissive(struct policydb *db, const char *type) { (void)db;(void)type; return false; }
bool ksu_enforce(struct policydb *db, const char *type) { (void)db;(void)type; return false; }
bool ksu_typeattribute(struct policydb *db, const char *type, const char *attr) { (void)db;(void)type;(void)attr; return false; }
bool ksu_exists(struct policydb *db, const char *type) { (void)db;(void)type; return false; }
bool ksu_allow(struct policydb *db, const char *src, const char *tgt, const char *cls, const char *perm) { (void)db;(void)src;(void)tgt;(void)cls;(void)perm; return false; }
bool ksu_deny(struct policydb *db, const char *src, const char *tgt, const char *cls, const char *perm) { (void)db;(void)src;(void)tgt;(void)cls;(void)perm; return false; }
bool ksu_auditallow(struct policydb *db, const char *src, const char *tgt, const char *cls, const char *perm) { (void)db;(void)src;(void)tgt;(void)cls;(void)perm; return false; }
bool ksu_dontaudit(struct policydb *db, const char *src, const char *tgt, const char *cls, const char *perm) { (void)db;(void)src;(void)tgt;(void)cls;(void)perm; return false; }
bool ksu_allowxperm(struct policydb *db, const char *src, const char *tgt, const char *cls, const char *range) { (void)db;(void)src;(void)tgt;(void)cls;(void)range; return false; }
bool ksu_auditallowxperm(struct policydb *db, const char *src, const char *tgt, const char *cls, const char *range) { (void)db;(void)src;(void)tgt;(void)cls;(void)range; return false; }
bool ksu_dontauditxperm(struct policydb *db, const char *src, const char *tgt, const char *cls, const char *range) { (void)db;(void)src;(void)tgt;(void)cls;(void)range; return false; }
bool ksu_type_transition(struct policydb *db, const char *src, const char *tgt, const char *cls, const char *def, const char *obj) { (void)db;(void)src;(void)tgt;(void)cls;(void)def;(void)obj; return false; }
bool ksu_type_change(struct policydb *db, const char *src, const char *tgt, const char *cls, const char *def) { (void)db;(void)src;(void)tgt;(void)cls;(void)def; return false; }
bool ksu_type_member(struct policydb *db, const char *src, const char *tgt, const char *cls, const char *def) { (void)db;(void)src;(void)tgt;(void)cls;(void)def; return false; }
bool ksu_genfscon(struct policydb *db, const char *fs_name, const char *path, const char *ctx) { (void)db;(void)fs_name;(void)path;(void)ctx; return false; }
#endif
"""
    s = s.rstrip() + stub
open(p,"w").write(s)
print("patched sepolicy.c for 4.19")
PYEOF
    # 4.19 相容：linux/minmax.h 為 5.10+ 表頭
    sed -i 's|#include <linux/minmax.h>|/* minmax.h not on 4.19 */|' "$KERNEL_DIR/KernelSU/kernel/sulog/event.c"
    # 4.19 相容：dispatch.c 用 tasklist_lock/task_pgrp/task_session/init_task，補表頭
    sed -i '1i #include <linux/sched/signal.h>\n#include <linux/init_task.h>' "$KERNEL_DIR/KernelSU/kernel/supercall/dispatch.c"
    # 4.19 相容：supercall.c 也用 TWA_RESUME
    python3 - "$KERNEL_DIR/KernelSU/kernel/supercall/supercall.c" <<'PYEOF'
import sys,re
p=sys.argv[1]
s=open(p).read()
s=re.sub(r'if \(task_work_add\((.*?), TWA_RESUME\)\) \{\n',
         r'#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 14, 0)\n    if (task_work_add(\1, TWA_RESUME)) {\n#else\n    if (task_work_add(\1, 0)) {\n#endif\n', s)
open(p,"w").write(s)
print("patched supercall.c")
PYEOF
    echo "[+] SukiSU Ultra setup finished."
fi

# ==========================================
# Baseband-guard Setup
# ==========================================
echo "==========================================="
echo " [*] Initializing Baseband-guard Setup"
echo "==========================================="
wget -O- https://github.com/vc-teahouse/Baseband-guard/raw/main/setup.sh | bash
sed -i '/^config LSM$/,/^help$/{ /^[[:space:]]*default/ { /baseband_guard/! s/selinux/selinux,baseband_guard/ } }' security/Kconfig
echo "[+] Baseband-guard setup finished."
echo "==========================================="

# ==========================================
# AnyKernel3 Setup
# ==========================================
echo "==========================================="
echo " [*] Initializing AnyKernel3 Workspace"
echo "==========================================="
rm -rf anykernel
git clone https://github.com/AstideLabs/AnyKernel3 -b kona --single-branch --depth=1 anykernel
sed -i "s/^device\.name1=.*/device.name1=${DEVICE_NAME}/" anykernel/anykernel.sh
echo "[+] AnyKernel3 ready."
echo "==========================================="

# ==========================================
# Modular Build Function
# ==========================================
build_target() {
    local OS_TYPE=$1
    echo "==========================================="
    echo " Building ${DEVICE_NAME} (${OS_TYPE})"
    echo "==========================================="

    local OUT_DIR="${KERNEL_DIR}/out_${OS_TYPE}"

    local MAKE_OPTS=(
        -j"$(nproc)"
        O="${OUT_DIR}"
        ARCH="${ARCH}"
        SUBARCH="${SUBARCH}"
        LLVM=1
        LLVM_IAS=1
        CC="ccache clang"
        HOSTCC="ccache clang"
        CROSS_COMPILE="${CROSS_COMPILE}"
        CROSS_COMPILE_ARM32="${CROSS_COMPILE_ARM32}"
        KCFLAGS="-Wno-error"
    )

    echo "[*] Cleaning ${OUT_DIR}..."
    rm -rf "${OUT_DIR}"
    mkdir -p "${OUT_DIR}"

    local DTS_SOURCE="arch/arm64/boot/dts/vendor/qcom"
    local DTS_BACKUP=".dts.bak.${OS_TYPE}"

    if [ "$OS_TYPE" == "miui" ]; then
        echo "[*] Applying MIUI DTS patches..."
        cp -a "${DTS_SOURCE}" "${DTS_BACKUP}"
        sed -i 's/<154>/<1537>/g' ${DTS_SOURCE}/dsi-panel-j1s* || true
        sed -i 's/<154>/<1537>/g' ${DTS_SOURCE}/dsi-panel-j2* || true
        sed -i 's/<155>/<1544>/g' ${DTS_SOURCE}/dsi-panel-j3s-37-02-0a-dsc-video.dtsi || true
        sed -i 's/<155>/<1545>/g' ${DTS_SOURCE}/dsi-panel-j11-38-08-0a-fhd-cmd.dtsi || true
        sed -i 's/<155>/<1546>/g' ${DTS_SOURCE}/dsi-panel-k11a-38-08-0a-dsc-cmd.dtsi || true
        sed -i 's/<155>/<1546>/g' ${DTS_SOURCE}/dsi-panel-l11r-38-08-0a-dsc-cmd.dtsi || true
        sed -i 's/<70>/<695>/g' ${DTS_SOURCE}/dsi-panel-j11-38-08-0a-fhd-cmd.dtsi || true
        sed -i 's/<70>/<695>/g' ${DTS_SOURCE}/dsi-panel-j3s-37-02-0a-dsc-video.dtsi || true
        sed -i 's/<70>/<695>/g' ${DTS_SOURCE}/dsi-panel-k11a-38-08-0a-dsc-cmd.dtsi || true
        sed -i 's/<70>/<695>/g' ${DTS_SOURCE}/dsi-panel-l11r-38-08-0a-dsc-cmd.dtsi || true
        sed -i 's/<71>/<710>/g' ${DTS_SOURCE}/dsi-panel-j1s* || true
        sed -i 's/<71>/<710>/g' ${DTS_SOURCE}/dsi-panel-j2* || true
        sed -i 's/\/\/ mi,mdss-dsi-pan-enable-smart-fps/mi,mdss-dsi-pan-enable-smart-fps/g' ${DTS_SOURCE}/dsi-panel* || true
        sed -i 's/\/\/ mi,mdss-dsi-smart-fps-max_framerate/mi,mdss-dsi-smart-fps-max_framerate/g' ${DTS_SOURCE}/dsi-panel* || true
        sed -i 's/\/\/ qcom,mdss-dsi-pan-enable-smart-fps/qcom,mdss-dsi-pan-enable-smart-fps/g' ${DTS_SOURCE}/dsi-panel* || true
        sed -i 's/qcom,mdss-dsi-qsync-min-refresh-rate/\/\/qcom,mdss-dsi-qsync-min-refresh-rate/g' ${DTS_SOURCE}/dsi-panel* || true
        sed -i 's/120 90 60/120 90 60 50 30/g' ${DTS_SOURCE}/dsi-panel-g7a-36-02-0c-dsc-video.dtsi || true
        sed -i 's/120 90 60/120 90 60 50 30/g' ${DTS_SOURCE}/dsi-panel-g7a-37-02-0a-dsc-video.dtsi || true
        sed -i 's/120 90 60/120 90 60 50 30/g' ${DTS_SOURCE}/dsi-panel-g7a-37-02-0b-dsc-video.dtsi || true
        sed -i 's/144 120 90 60/144 120 90 60 50 48 30/g' ${DTS_SOURCE}/dsi-panel-j3s-37-02-0a-dsc-video.dtsi || true
        sed -i 's/\/\/39 00 00 00 00 00 03 51 03 FF/39 00 00 00 00 00 03 51 03 FF/g' ${DTS_SOURCE}/dsi-panel-j9-38-0a-0a-fhd-video.dtsi || true
        sed -i 's/\/\/39 00 00 00 00 00 03 51 0D FF/39 00 00 00 00 00 03 51 0D FF/g' ${DTS_SOURCE}/dsi-panel-j2-p2-1-38-0c-0a-dsc-cmd.dtsi || true
        sed -i 's/\/\/39 00 00 00 00 00 05 51 0F 8F 00 00/39 00 00 00 00 00 05 51 0F 8F 00 00/g' ${DTS_SOURCE}/dsi-panel-j1s-42-02-0a-dsc-cmd.dtsi || true
        sed -i 's/\/\/39 00 00 00 00 00 05 51 0F 8F 00 00/39 00 00 00 00 00 05 51 0F 8F 00 00/g' ${DTS_SOURCE}/dsi-panel-j1s-42-02-0a-mp-dsc-cmd.dtsi || true
        sed -i 's/\/\/39 00 00 00 00 00 05 51 0F 8F 00 00/39 00 00 00 00 00 05 51 0F 8F 00 00/g' ${DTS_SOURCE}/dsi-panel-j2-mp-42-02-0b-dsc-cmd.dtsi || true
        sed -i 's/\/\/39 00 00 00 00 00 05 51 0F 8F 00 00/39 00 00 00 00 00 05 51 0F 8F 00 00/g' ${DTS_SOURCE}/dsi-panel-j2-p2-1-42-02-0b-dsc-cmd.dtsi || true
        sed -i 's/\/\/39 00 00 00 00 00 05 51 0F 8F 00 00/39 00 00 00 00 00 05 51 0F 8F 00 00/g' ${DTS_SOURCE}/dsi-panel-j2s-mp-42-02-0a-dsc-cmd.dtsi || true
        sed -i 's/\/\/39 01 00 00 00 00 03 51 00 00/39 01 00 00 00 00 03 51 00 00/g' ${DTS_SOURCE}/dsi-panel-j2-38-0c-0a-dsc-cmd.dtsi || true
        sed -i 's/\/\/39 01 00 00 00 00 03 51 03 FF/39 01 00 00 00 00 03 51 03 FF/g' ${DTS_SOURCE}/dsi-panel-j11-38-08-0a-fhd-cmd.dtsi || true
        sed -i 's/\/\/39 01 00 00 00 00 03 51 03 FF/39 01 00 00 00 00 03 51 03 FF/g' ${DTS_SOURCE}/dsi-panel-j9-38-0a-0a-fhd-video.dtsi || true
        sed -i 's/\/\/39 01 00 00 00 00 03 51 07 FF/39 01 00 00 00 00 03 51 07 FF/g' ${DTS_SOURCE}/dsi-panel-j1u-42-02-0b-dsc-cmd.dtsi || true
        sed -i 's/\/\/39 01 00 00 00 00 03 51 07 FF/39 01 00 00 00 00 03 51 07 FF/g' ${DTS_SOURCE}/dsi-panel-j2-42-02-0b-dsc-cmd.dtsi || true
        sed -i 's/\/\/39 01 00 00 00 00 03 51 07 FF/39 01 00 00 00 00 03 51 07 FF/g' ${DTS_SOURCE}/dsi-panel-j2-p1-42-02-0b-dsc-cmd.dtsi || true
        sed -i 's/\/\/39 01 00 00 00 00 03 51 0F FF/39 01 00 00 00 00 03 51 0F FF/g' ${DTS_SOURCE}/dsi-panel-j1u-42-02-0b-dsc-cmd.dtsi || true
        sed -i 's/\/\/39 01 00 00 00 00 03 51 0F FF/39 01 00 00 00 00 03 51 0F FF/g' ${DTS_SOURCE}/dsi-panel-j2-42-02-0b-dsc-cmd.dtsi || true
        sed -i 's/\/\/39 01 00 00 00 00 03 51 0F FF/39 01 00 00 00 00 03 51 0F FF/g' ${DTS_SOURCE}/dsi-panel-j2-p1-42-02-0b-dsc-cmd.dtsi || true
        sed -i 's/\/\/39 01 00 00 00 00 05 51 07 FF 00 00/39 01 00 00 00 00 05 51 07 FF 00 00/g' ${DTS_SOURCE}/dsi-panel-j1s-42-02-0a-dsc-cmd.dtsi || true
        sed -i 's/\/\/39 01 00 00 00 00 05 51 07 FF 00 00/39 01 00 00 00 00 05 51 07 FF 00 00/g' ${DTS_SOURCE}/dsi-panel-j1s-42-02-0a-mp-dsc-cmd.dtsi || true
        sed -i 's/\/\/39 01 00 00 00 00 05 51 07 FF 00 00/39 01 00 00 00 00 05 51 07 FF 00 00/g' ${DTS_SOURCE}/dsi-panel-j2-mp-42-02-0b-dsc-cmd.dtsi || true
        sed -i 's/\/\/39 01 00 00 00 00 05 51 07 FF 00 00/39 01 00 00 00 00 05 51 07 FF 00 00/g' ${DTS_SOURCE}/dsi-panel-j2-p2-1-42-02-0b-dsc-cmd.dtsi || true
        sed -i 's/\/\/39 01 00 00 00 00 05 51 07 FF 00 00/39 01 00 00 00 00 05 51 07 FF 00 00/g' ${DTS_SOURCE}/dsi-panel-j2s-mp-42-02-0a-dsc-cmd.dtsi || true
        sed -i 's/\/\/39 01 00 00 01 00 03 51 03 FF/39 01 00 00 01 00 03 51 03 FF/g' ${DTS_SOURCE}/dsi-panel-j11-38-08-0a-fhd-cmd.dtsi || true
        sed -i 's/\/\/39 01 00 00 11 00 03 51 03 FF/39 01 00 00 11 00 03 51 03 FF/g' ${DTS_SOURCE}/dsi-panel-j2-p2-1-38-0c-0a-dsc-cmd.dtsi || true
    fi

    echo "[*] Making defconfig: ${DEFCONFIG}..."
    make "${MAKE_OPTS[@]}" "${DEFCONFIG}"

    # Configuration tweaks
    echo "[*] Injecting Baseband-guard configuration..."
    scripts/config --file "${OUT_DIR}/.config" -e BBG

    if [ "$ENABLE_KSU" -eq 1 ]; then
        echo "[*] Injecting SukiSU Ultra configs (KSU + SUSFS + KALLSYMS + KPM)..."
        scripts/config --file "${OUT_DIR}/.config" \
            -e KSU \
            -e KPROBES \
            -e THREAD_INFO_IN_TASK \
            -e KSU_SUSFS \
            -e KALLSYMS \
            -e KALLSYMS_ALL
        scripts/config --file "${OUT_DIR}/.config" -d WERROR
    fi

    if [ "$OS_TYPE" == "miui" ]; then
        echo "[*] Injecting MIUI configs..."
        scripts/config --file "${OUT_DIR}/.config" \
            --set-str STATIC_USERMODEHELPER_PATH /system/bin/micd \
            -e PERF_CRITICAL_RT_TASK \
            -e SF_BINDER \
            -e OVERLAY_FS \
            -e MIGT \
            -e MIGT_ENERGY_MODEL \
            -e MIHW \
            -e PACKAGE_RUNTIME_INFO \
            -e BINDER_OPT \
            -e KPERFEVENTS \
            -e PERF_HUMANTASK \
            -d LTO_CLANG \
            -e LTO_NONE \
            -d SHADOW_CALL_STACK \
            -e XIAOMI_MIUI \
            -d MI_MEMORY_SYSFS \
            -e TASK_DELAY_ACCT \
            -e MIUI_ZRAM_MEMORY_TRACKING \
            -e PERF_HELPER \
            -e BOOTUP_RECLAIM \
            -e MI_RECLAIM \
            -e RTMM \
            -e MILLET_CGROUP \
            -e MILLET_SIG \
            -e MILLET_BINDER \
            -e MILLET_PKG \
            -e MILLET_BINDER_GKI \
            -e MILLET_CORE \
            -e MILLET_HS \
            -e BINDER_PRIO \
            -d REKERNEL \
            -d REKERNEL_NETWORK
    fi

    if [ "$OS_TYPE" == "aosp" ]; then
        echo "[*] Injecting AOSP configs..."
        scripts/config --file "${OUT_DIR}/.config" \
            -e REKERNEL \
            -e REKERNEL_NETWORK
    fi

    echo "[*] Updating config (make olddefconfig)..."
    make "${MAKE_OPTS[@]}" olddefconfig

    echo "[*] Building kernel..."
    make "${MAKE_OPTS[@]}"

    if [ "$OS_TYPE" == "miui" ]; then
        echo "[*] Restoring DTS backups..."
        rm -rf "${DTS_SOURCE}"
        mv "${DTS_BACKUP}" "${DTS_SOURCE}"
    fi

    echo "==========================================="
    if [ -f "${OUT_DIR}/arch/arm64/boot/Image" ]; then
        echo "[+] ${OS_TYPE} Build Successful!"
        echo "[+] Image: ${OUT_DIR}/arch/arm64/boot/Image"

        rm -rf anykernel/kernels/*
        mkdir -p "anykernel/kernels/${OS_TYPE}/"
        cp "${OUT_DIR}/arch/arm64/boot/Image" "anykernel/kernels/${OS_TYPE}/"
        cp "${OUT_DIR}/arch/arm64/boot/dtb" "anykernel/kernels/${OS_TYPE}/"
        if [ -f "${OUT_DIR}/arch/arm64/boot/dtbo.img" ]; then
            cp "${OUT_DIR}/arch/arm64/boot/dtbo.img" "anykernel/kernels/${OS_TYPE}/"
        fi

        local KSU_ZIP_STR="NoKernelSU"
        if [ "$ENABLE_KSU" -eq 1 ]; then
            KSU_ZIP_STR="SukiSU-Ultra-SuSFS"
        fi
        local GIT_COMMIT_ID=$(git rev-parse --short=8 HEAD 2>/dev/null || echo "unknown")
        local OS_UPPER=$(echo "$OS_TYPE" | tr '[:lower:]' '[:upper:]')
        local ZIP_FILENAME="APTKernel_${OS_UPPER}_${DEVICE_NAME}_${KSU_ZIP_STR}_$(date +'%Y%m%d_%H%M%S')_anykernel3_${GIT_COMMIT_ID}.zip"

        echo "[*] Zipping $ZIP_FILENAME ..."
        pushd anykernel > /dev/null
        zip -r9 "$ZIP_FILENAME" ./* -x .git .gitignore out/ ./*.zip > /dev/null
        mv "$ZIP_FILENAME" ../
        popd > /dev/null
        echo "[+] Packed into: $ZIP_FILENAME"
    else
        echo "[-] ${OS_TYPE} Build Failed."; exit 1
    fi
}

if [ "$TARGET_OS" == "aosp" ] || [ "$TARGET_OS" == "both" ]; then
    build_target "aosp"
fi
if [ "$TARGET_OS" == "miui" ] || [ "$TARGET_OS" == "both" ]; then
    build_target "miui"
fi

echo "[*] ccache stats:"
ccache -s
echo "[+] Done!"
