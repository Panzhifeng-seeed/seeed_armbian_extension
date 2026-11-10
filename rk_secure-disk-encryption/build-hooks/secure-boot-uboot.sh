# Secure boot U-Boot build hook helpers
function resolve_platform_rkbin_dir() {
    # Resolve platform-specific rkbin content directory.
    # Expected layout examples:
    # 1) rkbin/rk3576_rkbin/{RKTRUST,tools,...}
    # 2) rkbin/rk3588_rkbin/{RKTRUST,tools,...}
    # 3) legacy rkbin/{RKTRUST,tools,...}
    local rkbin_root platform rkbin_dir candidate
    rkbin_root="$(rk_sdk_rkbin_root)"
    platform="$(rk_detect_platform)"

    [[ "${platform}" != "unknown" ]] && rkbin_dir="${rkbin_root}/${platform}_rkbin"

    if [[ -n "${rkbin_dir}" && -d "${rkbin_dir}" ]]; then
        echo "${rkbin_dir}"
        return 0
    fi

    # If platform cannot be detected and both platform rkbin directories exist,
    # returning one arbitrarily is unsafe.
    if [[ "${platform}" == "unknown" && -d "${rkbin_root}/rk3576_rkbin" && -d "${rkbin_root}/rk3588_rkbin" ]]; then
        echo ""
        return 1
    fi

    if [[ -d "${rkbin_root}/RKTRUST" || -d "${rkbin_root}/tools" ]]; then
        echo "${rkbin_root}"
        return 0
    fi

    candidate="$(find "${rkbin_root}" -maxdepth 1 -mindepth 1 -type d -name "*_rkbin" | sort | head -n1)"
    if [[ -n "${candidate}" ]]; then
        echo "${candidate}"
        return 0
    fi

    echo "${rkbin_root}"
}

function resolve_platform_its_template() {
    # Match FIT load addresses to U-Boot's per-SoC ENV_MEM_LAYOUT_SETTINGS.
    rk_secure_kernel_fit_template_path || true
}

function resolve_platform_bl32_blob() {
    local platform="$1"

    case "${platform}" in
        rk3576) echo "rk35/rk3576_bl32_v1.08.bin" ;;
        rk3588) echo "rk35/rk3588_bl32_v1.20.bin" ;;
        *) echo "" ;;
    esac
}

function resolve_platform_bl32_blob_v5() {
    # vendor-next consumes the official rockchip-linux/rkbin master (bin/ layout,
    # newest-only blobs, fetched by the family conf into RKBIN_DIR); the
    # armbian-mirror blobs above no longer exist there. Versions follow the
    # official RKTRUST ini pairing with the bl31 blobs pinned by the family conf
    # (rk3576: bl31 v1.25 <-> bl32 v1.12; rk3588: bl31 v1.56 <-> bl32 v1.23).
    local platform="$1"

    case "${platform}" in
        rk3576) echo "bin/rk35/rk3576_bl32_v1.12.bin" ;;
        rk3588) echo "bin/rk35/rk3588_bl32_v1.23.bin" ;;
        *) echo "" ;;
    esac
}

function rk_secure_boot_stage_bl32_binman() {
    # Binman packs the TEE through the @tee-SEQ split-elf template, which only
    # accepts ELF images or OP-TEE v1 binaries. The Rockchip bl32 blobs are raw
    # AArch64 images with no header, so prepend a synthetic OP-TEE v1 header:
    # binman derives load/entry (0x48400000) from it and drops the header when
    # emitting the tee-1 node, so SPL copies exactly the raw blob to the load
    # address — the same memory image the vendor fit generator flow produces.
    # TEE_OFFSET matches the vendor fit_args.sh default (0x08400000) on top of
    # the 0x40000000 DRAM base.
    local blob_path="$1"
    local tee_bin="$2"
    local load_addr=$((0x40000000 + 0x08400000))
    local blob_size

    blob_size="$(stat -c %s "${blob_path}")" ||
        exit_with_error "BL32 blob unreadable" "${blob_path}"

    # NOTE: the python script must be guarded with `if ! cmd <<'PY' ... PY
    # then ... fi`. A `cmd <<'PY' || fallback` form is parsed differently: the
    # heredoc body starts on the line AFTER the marker (swallowing the `||`
    # continuation line as its first script line) and the `||` binds to the
    # command after the terminator — the fallback never runs on failure.
    if ! python3 - "${blob_path}" "${tee_bin}" "${load_addr}" "${blob_size}" <<'PY'
import struct
import sys

blob_path, tee_bin, load_addr, blob_size = (
    sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4]))
with open(blob_path, "rb") as blob:
    payload = blob.read()
if len(payload) != blob_size:
    raise SystemExit(f"BL32 blob size changed during staging: {len(payload)} != {blob_size}")
# Magic "OPTE\x01" + 3 pad bytes, then init_size, start_hi, start_lo, reserved,
# paged_size -- the layout binman's Entry_tee_os.read_elf_segments() parses.
header = b"OPTE\x01" + bytes(3) + struct.pack("<5I", blob_size, 0, load_addr, 0, 0)
with open(tee_bin, "wb") as out:
    out.write(header + payload)
PY
    then
        exit_with_error "Failed to wrap BL32 as an OP-TEE v1 binary" "${tee_bin}"
    fi
    display_alert "secure-uboot" "Staged BL32 for binman (OP-TEE v1 wrapped, load=0x$(printf '%x' "${load_addr}")): ${blob_path} -> tee.bin" "info"
}

function rk_secure_boot_prepare_tee_bin() {
    local uboot_workdir="$1"
    local platform bl32_blob bl32_path

    platform="$(rk_detect_platform)"

    if [[ "${BRANCH:-}" == "vendor-next" ]]; then
        bl32_blob="$(resolve_platform_bl32_blob_v5 "${platform}")"
    else
        bl32_blob="$(resolve_platform_bl32_blob "${platform}")"
    fi
    if [[ -z "${bl32_blob}" ]]; then
        exit_with_error "No BL32 blob mapping found" "BOOT_SOC=${BOOT_SOC:-} BOARD=${BOARD:-}"
    fi

    if [[ "${BRANCH:-}" == "vendor-next" ]]; then
        bl32_path="${RKBIN_DIR}/${bl32_blob}"
        if [[ ! -f "${bl32_path}" ]]; then
            exit_with_error "BL32 blob missing" "${bl32_path}"
        fi
        rk_secure_boot_stage_bl32_binman "${bl32_path}" "${uboot_workdir}/tee.bin"
    else
        bl32_path="${SRC}/cache/sources/rkbin-tools/${bl32_blob}"
        if [[ ! -f "${bl32_path}" ]]; then
            exit_with_error "BL32 blob missing" "${bl32_path}"
        fi

        install -m 0644 "${bl32_path}" "${uboot_workdir}/tee.bin" ||
            exit_with_error "Failed to stage BL32 as tee.bin" "${uboot_workdir}/tee.bin"
        display_alert "secure-uboot" "Staged BL32 for U-Boot FIT: ${bl32_blob} -> tee.bin" "info"
    fi
}

function resolve_kernel_dtb_path() {
    # Resolve kernel DTB path for resource/FIT packaging.
    # Priority:
    # 1) RK_SECURE_KERNEL_DTB absolute path
    # 2) RK_SECURE_KERNEL_DTB filename under kernel rockchip dtb dir
    # 3) board + platform based candidate list (BOARD_NAME + BOOT_SOC)
    local kernel_src="$1"
    local dtb_dir platform board candidate override

    dtb_dir="${kernel_src}/arch/arm64/boot/dts/rockchip"
    override="${RK_SECURE_KERNEL_DTB:-}"

    if [[ -n "${override}" ]]; then
        if [[ -f "${override}" ]]; then
            echo "${override}"
            return 0
        fi
        if [[ -f "${dtb_dir}/${override}" ]]; then
            echo "${dtb_dir}/${override}"
            return 0
        fi
        display_alert "secure-uboot" "RK_SECURE_KERNEL_DTB not found: ${override}" "warn"
    fi

    platform="$(rk_detect_platform)"
    board="$(rk_detect_vendor_board)"

    if [[ "${platform}" != "unknown" && "${board}" != "unknown" ]]; then
        for candidate in \
            "${platform}-${board}.dtb" \
            "${platform}-recomputer-devkit.dtb"; do
            [[ -f "${dtb_dir}/${candidate}" ]] && { echo "${dtb_dir}/${candidate}"; return 0; }
        done
    fi

    echo ""
}
function rk_secure_boot_stage_uboot_fit_generator() {
    local uboot_workdir="$1"
    local generator_src generator_dst

    generator_src="$(rk_secure_uboot_fit_generator_path)" ||
        exit_with_error "Secure U-Boot FIT generator missing" "$(rk_resolve_extension_dir "u-boot/fit-generator")/u-boot/fit-generator/make_fit_atf_optee.sh"
    generator_dst="${uboot_workdir}/arch/arm/mach-rockchip/make_fit_atf_optee.sh"

    install -m 0755 "${generator_src}" "${generator_dst}" ||
        exit_with_error "Failed to stage U-Boot FIT generator" "${generator_dst}"
}

function rk_secure_boot_apply_config_fragment() {
    local fragment="$1"

    rk_apply_kconfig_fragment scripts/config "${fragment}" ||
        exit_with_error "Failed to apply secure U-Boot config fragment" "${fragment}"
    display_alert "secure-uboot" "Applied U-Boot config fragment: ${fragment}" "info"
}
function enable_optee_bootchain_bl32_fit_node() {
    # Non-secure OP-TEE bootchain still needs BL32 packed into vendor u-boot.itb.
    # Keep this as a narrow local change instead of reusing the full secure-boot overlay.
    # vendor-next (rockchip-linux/u-boot v5) builds u-boot.itb through binman and
    # never runs the SPL_FIT_GENERATOR: the tee-1 node comes from TEE= plus the
    # OP-TEE-v1-wrapped blob staged by rk_secure_boot_stage_bl32_binman, so the
    # generator edit below would be a no-op on that tree.
    if [[ "${BRANCH:-}" == "vendor-next" ]]; then
        display_alert "secure-uboot" "OP-TEE bootchain: binman flow, tee packed via TEE= (fit generator untouched)" "info"
        return 0
    fi

    local fit_generator="arch/arm/mach-rockchip/make_fit_atf.sh"

    if [[ ! -f "${fit_generator}" ]]; then
        display_alert "secure-uboot" "OP-TEE bootchain: FIT generator not found, skipping BL32 enable" "warn"
        return 0
    fi

    if grep -q '^[[:space:]]*gen_bl32_node[[:space:]]*$' "${fit_generator}"; then
        display_alert "secure-uboot" "OP-TEE bootchain: BL32 FIT node already enabled" "debug"
        return 0
    fi

    if grep -q '^[[:space:]]*#gen_bl32_node[[:space:]]*$' "${fit_generator}"; then
        sed -i 's/^[[:space:]]*#gen_bl32_node[[:space:]]*$/gen_bl32_node/' "${fit_generator}" ||
            exit_with_error "Failed to enable BL32 FIT node for OP-TEE bootchain" "${fit_generator}"
        display_alert "secure-uboot" "OP-TEE bootchain: enabled BL32 FIT node in ${fit_generator}" "info"
        return 0
    fi

    display_alert "secure-uboot" "OP-TEE bootchain: no commented gen_bl32_node marker found, leaving ${fit_generator} unchanged" "warn"
}

function rk_secure_boot_verify_fit_images() {
    local fit_image="$1"
    local fit_info

    [[ -f "${fit_image}" ]] || exit_with_error "FIT image missing after U-Boot build" "${fit_image}"

    if ! command -v dumpimage >/dev/null 2>&1; then
        display_alert "secure-uboot" "dumpimage not found, skip FIT image content verification" "warn"
        return 0
    fi

    fit_info="$(dumpimage -l "${fit_image}" 2>/dev/null || true)"
    [[ -n "${fit_info}" ]] || exit_with_error "Failed to parse FIT image" "${fit_image}"

    # For auto-decryption mode, BL32(OP-TEE) and the third ATF loadable are mandatory.
    if rk_autodecrypt_enabled; then
        grep -Eq 'Image [0-9]+ \(atf-3\)' <<< "${fit_info}" ||
            exit_with_error "FIT image validation failed: missing atf-3 loadable" "${fit_image}"
        if [[ "${BRANCH:-}" == "vendor-next" ]]; then
            # Binman generates the TEE node(s) from the @tee-SEQ template as
            # tee-1/tee-2/...; the vendor fit generator names the node optee.
            grep -Eq 'Image [0-9]+ \(tee-1\)' <<< "${fit_info}" ||
                exit_with_error "FIT image validation failed: missing tee-1 loadable" "${fit_image}"
        else
            grep -Eq 'Image [0-9]+ \(optee\)' <<< "${fit_info}" ||
                exit_with_error "FIT image validation failed: missing optee loadable" "${fit_image}"
        fi
    fi

    display_alert "secure-uboot" "FIT image validation passed (${fit_image})" "info"
}

function rk_secure_boot_check_produced_fit_image() {
    if ! rk_optee_bootchain_enabled; then
        return 0
    fi

    [[ "${base_binfile}" == "u-boot.itb" ]] || return 0
    rk_secure_boot_verify_fit_images "${binfile}"
}

function rk_secure_boot_rebuild_idbloader() {
    # The normal Rockchip post-process runs before this signing hook.  Rebuild
    # its loader afterwards so the boot media contains the SPL DTB into which
    # mkimage injected the FIT public key, rather than the pre-signing SPL.
    local spl_bin_path

    case "${BOOT_SCENARIO:-}" in
        spl-blobs)
            spl_bin_path="${RKBIN_DIR}/${DDR_BLOB}"
            [[ -f "${spl_bin_path}" ]] || exit_with_error "DDR blob missing while rebuilding signed idbloader" "${spl_bin_path}"

            if declare -F board_uboot_spl_blobs_postprocess >/dev/null; then
                board_uboot_spl_blobs_postprocess "${BOOT_SOC}" "${spl_bin_path}" "./spl/u-boot-spl.bin"
            else
                rk_run_host_command tools/mkimage -n "${BOOT_SOC_MKIMAGE}" -T rksd \
                    -d "${spl_bin_path}:spl/u-boot-spl.bin" idbloader.img ||
                    exit_with_error "Failed to rebuild idbloader with signed SPL" "${BOOT_SOC}"
            fi
            ;;
        vendor-spl-blobs)
            # A vendor SPL cannot contain the FIT public key generated for this
            # build.  Continuing here would package an image that looks signed
            # but whose first mutable stage cannot validate U-Boot.
            exit_with_error "Full secure boot is incompatible with vendor-spl-blobs" "Use BOOT_SCENARIO=spl-blobs so the signed SPL is deployed"
            ;;
        *)
            exit_with_error "Unsupported secure U-Boot loader scenario" "BOOT_SCENARIO=${BOOT_SCENARIO:-<unset>}"
            ;;
    esac

    [[ -f idbloader.img ]] || exit_with_error "Signed idbloader was not produced" "${PWD}/idbloader.img"
}

function rk_secure_boot_sign_loader_artifacts() {
    local rk_sign_tool="$1" platform="$2" keys_dir="$3"

    "${rk_sign_tool}" cc --chip "${platform#rk}" ||
        exit_with_error "Failed to select Rockchip secure-boot chip" "${platform}"
    "${rk_sign_tool}" lk --key "${keys_dir}/dev.key" --pubkey "${keys_dir}/dev.pubkey" ||
        exit_with_error "Failed to load Rockchip secure-boot signing key" "${keys_dir}"
    "${rk_sign_tool}" sb --idb idbloader.img ||
        exit_with_error "Failed to sign idbloader" "${PWD}/idbloader.img"
    "${rk_sign_tool}" vb --idb idbloader.img ||
        exit_with_error "Signed idbloader verification failed" "${PWD}/idbloader.img"

    # Maskrom recovery uses this separately packaged loader, so it must carry
    # the same signed SPL when the board hook generated one.
    if [[ -f spl_loader_maskrom.bin ]]; then
        "${rk_sign_tool}" sl --loader spl_loader_maskrom.bin ||
            exit_with_error "Failed to sign Maskrom SPL loader" "${PWD}/spl_loader_maskrom.bin"
        "${rk_sign_tool}" vl --loader spl_loader_maskrom.bin ||
            exit_with_error "Signed Maskrom SPL loader verification failed" "${PWD}/spl_loader_maskrom.bin"
    fi
}

function rk_secure_boot_rebuild_spi_loader() {
    [[ "${BOOT_SUPPORT_SPI:-no}" == "yes" ]] || return 0

    if [[ "${BOOT_SPI_RKSPI_LOADER:-no}" == "yes" ]]; then
        rk_run_host_command dd if=/dev/zero of=rkspi_loader.img bs=1M count=0 seek=16 ||
            exit_with_error "Failed to initialise signed SPI loader image" "rkspi_loader.img"
        rk_run_host_command /sbin/parted -s rkspi_loader.img mklabel gpt || exit_with_error "Failed to create signed SPI loader GPT" "rkspi_loader.img"
        rk_run_host_command /sbin/parted -s rkspi_loader.img unit s mkpart idbloader 64 7167 || exit_with_error "Failed to create SPI idbloader partition" "rkspi_loader.img"
        rk_run_host_command /sbin/parted -s rkspi_loader.img unit s mkpart vnvm 7168 7679 || exit_with_error "Failed to create SPI vnvm partition" "rkspi_loader.img"
        rk_run_host_command /sbin/parted -s rkspi_loader.img unit s mkpart reserved_space 7680 8063 || exit_with_error "Failed to create SPI reserved-space partition" "rkspi_loader.img"
        rk_run_host_command /sbin/parted -s rkspi_loader.img unit s mkpart reserved1 8064 8127 || exit_with_error "Failed to create SPI reserved1 partition" "rkspi_loader.img"
        rk_run_host_command /sbin/parted -s rkspi_loader.img unit s mkpart uboot_env 8128 8191 || exit_with_error "Failed to create SPI U-Boot env partition" "rkspi_loader.img"
        rk_run_host_command /sbin/parted -s rkspi_loader.img unit s mkpart reserved2 8192 16383 || exit_with_error "Failed to create SPI reserved2 partition" "rkspi_loader.img"
        rk_run_host_command /sbin/parted -s rkspi_loader.img unit s mkpart uboot 16384 32734 || exit_with_error "Failed to create SPI U-Boot partition" "rkspi_loader.img"
        rk_run_host_command dd if=idbloader.img of=rkspi_loader.img seek=64 conv=notrunc || exit_with_error "Failed to place signed idbloader in SPI image" "rkspi_loader.img"
        rk_run_host_command dd if=u-boot.itb of=rkspi_loader.img seek=16384 conv=notrunc || exit_with_error "Failed to place signed U-Boot FIT in SPI image" "rkspi_loader.img"
    else
        [[ -f tpl/u-boot-tpl.bin ]] || exit_with_error "TPL missing while rebuilding signed SPI loader" "tpl/u-boot-tpl.bin"
        rk_run_host_command tools/mkimage -n "${BOOT_SOC_MKIMAGE}" -T rkspi \
            -d tpl/u-boot-tpl.bin:spl/u-boot-spl.bin rkspi_tpl_spl.img ||
            exit_with_error "Failed to build signed SPI TPL/SPL image" "rkspi_tpl_spl.img"
        rk_run_host_command dd if=/dev/zero of=rkspi_loader.img count=8128 status=none || exit_with_error "Failed to initialise signed SPI loader image" "rkspi_loader.img"
        rk_run_host_command dd if=rkspi_tpl_spl.img of=rkspi_loader.img conv=notrunc status=none || exit_with_error "Failed to place signed TPL/SPL in SPI image" "rkspi_loader.img"
        rk_run_host_command dd if=u-boot.itb of=rkspi_loader.img seek=768 conv=notrunc status=none || exit_with_error "Failed to place signed U-Boot FIT in SPI image" "rkspi_loader.img"
    fi
}

function rk_secure_boot_minimize_spl_fit_key() {
    # Do not reduce the key material. RK3588 SPL FIT verification needs the
    # complete RSA public key; clearing rsa,r-squared or rsa,c leaves the DTB
    # node present but makes SPL report "No RSA key found" at boot.
    local spl_dtb="spl/u-boot-spl.dtb"
    local key_node="/signature/key-dev"
    local property value

    fdtget -l "${spl_dtb}" /signature 2>/dev/null | grep -qx 'key-dev' ||
        exit_with_error "SPL FIT public key node missing" "${spl_dtb}"
    for property in rsa,modulus rsa,r-squared rsa,c rsa,np rsa,n0-inverse rsa,exponent; do
        value="$(fdtget -t bx "${spl_dtb}" "${key_node}" "${property}" 2>/dev/null)"
        [[ -n "${value}" && "${value}" != '0' ]] ||
            exit_with_error "SPL FIT public key property missing" "${spl_dtb}:${property}"
    done
}

function rk_secure_boot_repack_signed_spl() {
    local spl_bin="spl/u-boot-spl.bin"
    local spl_nodtb="spl/u-boot-spl-nodtb.bin"
    local spl_pad="spl/u-boot-spl-pad.bin"
    local spl_dtb="spl/u-boot-spl.dtb"

    cat "${spl_nodtb}" > "${spl_bin}" || exit_with_error "Failed to start signed SPL repack" "${spl_bin}"
    if ! grep -qx 'CONFIG_SPL_SEPARATE_BSS=y' .config; then
        [[ -f "${spl_pad}" ]] || exit_with_error "SPL pad missing while repacking signed SPL" "${spl_pad}"
        cat "${spl_pad}" >> "${spl_bin}" || exit_with_error "Failed to append SPL pad" "${spl_bin}"
    fi
    cat "${spl_dtb}" >> "${spl_bin}" || exit_with_error "Failed to append signed SPL DTB" "${spl_bin}"
}

function rk_secure_boot_generate_uboot_its_binman() {
    # Rebuild an ITS for the binman-assembled u-boot.itb. binman owns the FIT
    # assembly on the v5 tree (there is no u-boot.its to sign like on the
    # 2017.09 tree), but it leaves a fully formed mkimage description behind:
    # simple-bin.fit.fit records every image's load/entry/type/os and its
    # data-offset/data-size, and u-boot.itb stores the payloads externally,
    # base = FIT_ALIGN(fdt_totalsize) (the SPL's own ext_data_offset rule,
    # IMAGE_ALIGN_SIZE=512). This script extracts the payloads from that itb,
    # cross-checks the two copies that also exist as files (fdt-1 must equal
    # the in-tree u-boot.dtb — pass A injects the boot-FIT key into it; tee-1
    # must equal tee.bin without its OP-TEE v1 header) and emits an ITS with
    # a hash node per image plus the configuration signature node that mkimage
    # signs and -K injects.
    local desc_dtb="$1" fit_itb="$2" uboot_dtb="$3" tee_bin="$4" out_dir="$5" its_path="$6" rsa_bits="$7"

    if ! python3 - "${desc_dtb}" "${fit_itb}" "${uboot_dtb}" "${tee_bin}" "${out_dir}" "${its_path}" "${rsa_bits}" <<'PY'
import struct
import sys

FDT_BEGIN_NODE, FDT_END_NODE, FDT_PROP, FDT_NOP, FDT_END = 1, 2, 3, 4, 9


class Node:
    def __init__(self, name):
        self.name = name
        self.props = {}
        self.subnodes = []


def parse_fdt(data, label):
    magic, totalsize, off_struct, off_strings = struct.unpack_from(">IIII", data, 0)
    if magic != 0xD00DFEED:
        raise SystemExit(f"{label}: not an FDT blob")
    pos, stack, root = off_struct, [], None
    while True:
        token = struct.unpack_from(">I", data, pos)[0]
        pos += 4
        if token == FDT_BEGIN_NODE:
            end = data.index(b"\0", pos)
            node = Node(data[pos:end].decode())
            pos = (end + 1 + 3) & ~3
            if stack:
                stack[-1].subnodes.append(node)
            elif root is None:
                root = node
            stack.append(node)
        elif token == FDT_END_NODE:
            stack.pop()
        elif token == FDT_PROP:
            length, nameoff = struct.unpack_from(">II", data, pos)
            pos += 8
            value = data[pos:pos + length]
            pos = (pos + length + 3) & ~3
            nstart = off_strings + nameoff
            name = data[nstart:data.index(b"\0", nstart)].decode()
            stack[-1].props[name] = value
        elif token == FDT_NOP:
            continue
        elif token == FDT_END:
            break
        else:
            raise SystemExit(f"{label}: unexpected FDT token 0x{token:x}")
    return root, totalsize


def cell(node, name):
    return struct.unpack(">I", node.props[name])[0]


def text(node, name):
    return node.props[name].rstrip(b"\0").decode()


def strlist(node, name):
    return [p.decode() for p in node.props[name].rstrip(b"\0").split(b"\0") if p]


desc_path, itb_path, uboot_dtb_path, tee_path, out_dir, its_path, rsa_bits = (
    sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5], sys.argv[6], int(sys.argv[7]))

desc, _ = parse_fdt(open(desc_path, "rb").read(), desc_path)
itb_bytes, itb_base = None, 0
images_node = confs_node = None
for sub in desc.subnodes:
    if sub.name == "images":
        images_node = sub
    elif sub.name == "configurations":
        confs_node = sub
if images_node is None or confs_node is None:
    raise SystemExit(f"{desc_path}: missing images/configurations nodes")

config = None
for sub in confs_node.subnodes:
    if sub.name == text(confs_node, "default"):
        config = sub
if config is None:
    raise SystemExit(f"{desc_path}: default configuration not found")

# The reference signatures: mkimage with -E only keeps data-offset/data-size
# in the description, so the payloads are recovered from the built itb, whose
# header ends exactly at FIT_ALIGN(totalsize) — the base SPL uses too.
itb_data = open(itb_path, "rb").read()
_, itb_header = parse_fdt(itb_data, itb_path)
itb_base = (itb_header + 511) & ~511

tee_raw = open(tee_path, "rb").read()
if tee_raw[:5] != b"OPTE\x01":
    raise SystemExit(f"{tee_path}: missing OP-TEE v1 wrapper header")

payloads = {}
for image in images_node.subnodes:
    doff, dsize = cell(image, "data-offset"), cell(image, "data-size")
    blob = itb_data[itb_base + doff:itb_base + doff + dsize]
    if len(blob) != dsize:
        raise SystemExit(f"{itb_path}: {image.name} payload truncated "
                         f"({len(blob)} != {dsize})")
    if image.name.startswith("fdt"):
        if blob != open(uboot_dtb_path, "rb").read():
            raise SystemExit(f"{itb_path}: {image.name} payload does not match "
                             f"{uboot_dtb_path}; rebuild before signing")
    else:
        if image.name.startswith("tee") and blob != tee_raw[28:]:
            raise SystemExit(f"{itb_path}: {image.name} payload does not match "
                             f"the raw blob inside {tee_path}")
        with open(f"{out_dir}/{image.name}.bin", "wb") as out:
            out.write(blob)
    payloads[image.name] = image

# sign-images names the configuration's image-reference properties; the
# on-device verifier rebuilds its hash list from every reference present, so
# the signature must cover all of them.
sign_images = [p for p in ("fdt", "firmware", "loadables") if p in config.props]

lines = ["/dts-v1/;", "", "/ {", "\tdescription = \"Secure signed U-Boot FIT (binman inputs)\";",
         "\t#address-cells = <0x1>;", "", "\timages {"]
for image in images_node.subnodes:
    data_file = uboot_dtb_path if image.name.startswith("fdt") else f"{out_dir}/{image.name}.bin"
    lines.append(f"\t\t{image.name} {{")
    lines.append(f"\t\t\tdescription = \"{text(image, 'description')}\";")
    lines.append(f"\t\t\tdata = /incbin/(\"{data_file}\");")
    lines.append(f"\t\t\ttype = \"{text(image, 'type')}\";")
    # flat_dt entries carry no os/arch/load/entry; emit only what the
    # binman description records so the signed FIT keeps the exact layout.
    for prop in ("os", "arch", "compression", "load", "entry"):
        if prop not in image.props:
            continue
        value = (f"0x{cell(image, prop):x}" if prop in ("load", "entry")
                 else text(image, prop))
        lines.append(f"\t\t\t{prop} = \"{value}\";" if prop in ("os", "arch", "compression")
                     else f"\t\t\t{prop} = <{value}>;")
    lines += ["\t\t\thash-1 {", "\t\t\t\talgo = \"sha256\";", "\t\t\t};",
              "\t\t};", ""]
lines += ["\t};", "", "\tconfigurations {", f"\t\tdefault = \"{config.name}\";",
          f"\t\t{config.name} {{",
          f"\t\t\tdescription = \"{text(config, 'description')}\";"]
for prop in ("fdt", "firmware", "loadables"):
    if prop in config.props:
        values = strlist(config, prop)
        shown = values if prop == "loadables" else values[:1]
        rendered = ", ".join(f"\"{v}\"" for v in shown)
        lines.append(f"\t\t\t{prop} = {rendered};")
lines += ["\t\t\tsignature-1 {",
          f"\t\t\t\talgo = \"sha256,rsa{rsa_bits}\";",
          "\t\t\t\tpadding = \"pss\";",
          "\t\t\t\tkey-name-hint = \"dev\";",
          "\t\t\t\tsign-images = " + ", ".join(f"\"{p}\"" for p in sign_images) + ";",
          "\t\t\t\trequired = \"conf\";",
          "\t\t\t};",
          "\t\t};", "\t};", "};"]
with open(its_path, "w") as out:
    out.write("\n".join(lines) + "\n")
print(f"generated {its_path}: {len(payloads)} images, sign-images={' '.join(sign_images)}")
PY
    then
        exit_with_error "Failed to generate the signed-FIT ITS from binman artifacts" "${its_path}"
    fi
    display_alert "secure-uboot" "Generated signed-FIT ITS from binman description: ${its_path}" "info"
}

function rk_secure_boot_sign_uboot_fit_binman() {
    # vendor-next (rockchip-linux/u-boot v5): binman owns the FIT assembly, so
    # the 2017.09-style "sign the generated u-boot.its" path has no input.
    # Rebuild the ITS from binman's artifacts instead, then keep the proven
    # tail: two mkimage passes (the first injects the boot-FIT public key into
    # the control dtb so the DTB embedded as fdt-1 is the trusted one the
    # running U-Boot verifies boot.itb with; the second signs the FIT and
    # injects its key into the SPL dtb), the tree-built fit_check_sign gate,
    # SPL repack, idbloader rebuild and loader-artifact signing.
    #
    # The signer is the TREE-BUILT mkimage, not the Rockchip prebuilts: the
    # v5 verify code (boot/image-fit-sig.c, identical in the SPL, U-Boot and
    # the host fit_check_sign) rebuilds the hashed node list from the config
    # and ignores hashed-nodes, which the 2017.09-era prebuilt mkimage's
    # signing does not match — prebuilt-signed FITs fail this very gate. The
    # v5 padding_pss_verify() recovers the salt length from the signature, so
    # the 2017.09 chain's maximum-salt mkimage constraint does not apply here.
    local platform keys_dir rk_sign_tool fit_work rsa_bits
    platform="$(rk_detect_platform)"
    keys_dir="${UBOOT_FIT_KEYS_DIR:-${PWD}/keys}"
    rk_sign_tool="$(command -v rk_sign_tool 2>/dev/null || true)"
    if [[ -z "${rk_sign_tool}" && -n "${RKBIN_DIR:-}" && -x "${RKBIN_DIR}/tools/rk_sign_tool" ]]; then
        rk_sign_tool="${RKBIN_DIR}/tools/rk_sign_tool"
    fi
    [[ -n "${rk_sign_tool}" ]] || rk_sign_tool="$(resolve_platform_rkbin_dir)/tools/rk_sign_tool"

    [[ "${platform}" != "unknown" ]] || exit_with_error "Cannot sign U-Boot FIT for unknown Rockchip platform" "BOOT_SOC=${BOOT_SOC:-}"
    [[ -f .config && -f simple-bin.fit.fit && -f u-boot.itb && -f u-boot.dtb && -f tee.bin ]] ||
        exit_with_error "U-Boot binman artifacts missing for signing" "${PWD}"
    [[ -f spl/u-boot-spl.dtb && -f spl/u-boot-spl-nodtb.bin ]] ||
        exit_with_error "U-Boot SPL artifacts missing for signing" "${PWD}/spl"
    [[ -x tools/mkimage && -x tools/fit_check_sign ]] || exit_with_error "Rockchip FIT signing tools missing" "${PWD}"
    command -v fdtget >/dev/null 2>&1 || exit_with_error "fdtget is required for secure U-Boot FIT signing" "host dependency missing"
    [[ -x "${rk_sign_tool}" ]] || exit_with_error "rk_sign_tool missing for secure U-Boot build" "${rk_sign_tool}"
    [[ -f "${keys_dir}/dev.key" && -f "${keys_dir}/dev.pubkey" && -f "${keys_dir}/dev.crt" ]] ||
        exit_with_error "FIT signing key material missing" "${keys_dir}"
    grep -qx 'CONFIG_FIT_SIGNATURE=y' .config || exit_with_error "CONFIG_FIT_SIGNATURE must be enabled for full secure boot" ".config"
    grep -qx 'CONFIG_SPL_FIT_SIGNATURE=y' .config || exit_with_error "CONFIG_SPL_FIT_SIGNATURE must be enabled for full secure boot" ".config"
    grep -qx 'CONFIG_FIT_ENABLE_RSASSA_PSS_SUPPORT=y' .config || exit_with_error "CONFIG_FIT_ENABLE_RSASSA_PSS_SUPPORT must be enabled for full secure boot" ".config"

    rsa_bits=2048
    case "$(openssl rsa -in "${keys_dir}/private_key.pem" -noout -text 2>/dev/null | grep -oE '[0-9]+ bit' | head -n1)" in
        4096*) rsa_bits=4096 ;;
    esac

    fit_work="fit/sign-work"
    rm -rf "${fit_work}"
    mkdir -p "${fit_work}" || exit_with_error "Failed to create signed-FIT work directory" "${PWD}/${fit_work}"
    rk_secure_boot_generate_uboot_its_binman simple-bin.fit.fit u-boot.itb \
        "${PWD}/u-boot.dtb" "${PWD}/tee.bin" "${PWD}/${fit_work}" \
        "${PWD}/${fit_work}/uboot-signed.its" "${rsa_bits}"

    # The USBPLUG postprocess rebuilds host tools with its temporary config,
    # leaving mkimage without FIT-signature support. Restore the host tools
    # from the final secure U-Boot configuration before signing the FIT.
    if tools/mkimage -h 2>&1 | grep -q 'Signing / verified boot not supported'; then
        make -B tools-only || exit_with_error "Failed to rebuild FIT-signing U-Boot host tools" "${PWD}/tools"
    fi

    rm -f fit/uboot.itb
    if ! fdtget -l u-boot.dtb /signature >/dev/null 2>&1; then
        tools/mkimage -f "${fit_work}/uboot-signed.its" -k "${keys_dir}" -K u-boot.dtb \
            -E -p 0x1000 -r "${fit_work}/uboot-passA.itb" ||
            exit_with_error "Failed to inject the boot FIT public key into U-Boot DTB" "u-boot.dtb"
        rm -f "${fit_work}/uboot-passA.itb"
    fi
    tools/mkimage -f "${fit_work}/uboot-signed.its" -k "${keys_dir}" -K spl/u-boot-spl.dtb \
        -E -p 0x1000 -r fit/uboot.itb ||
        exit_with_error "Failed to sign the binman-built U-Boot FIT" "${platform}"

    fdtget -l u-boot.dtb /signature 2>/dev/null | grep -qx 'key-dev' ||
        exit_with_error "FIT public key was not embedded in U-Boot control DTB" "u-boot.dtb"
    fdtget -l spl/u-boot-spl.dtb /signature 2>/dev/null | grep -qx 'key-dev' ||
        exit_with_error "FIT public key was not embedded in SPL DTB" "spl/u-boot-spl.dtb"
    fdtget -p fit/uboot.itb /configurations/config-1/signature-1 2>/dev/null | grep -qx 'value' ||
        exit_with_error "U-Boot FIT configuration was not signed" "fit/uboot.itb"

    install -m 0644 fit/uboot.itb u-boot.itb || exit_with_error "Failed to install signed U-Boot FIT" "u-boot.itb"
    tools/fit_check_sign -f u-boot.itb -k spl/u-boot-spl.dtb -s ||
        exit_with_error "Signed U-Boot FIT verification failed" "u-boot.itb"

    rk_secure_boot_minimize_spl_fit_key
    rk_secure_boot_repack_signed_spl
    rk_secure_boot_rebuild_idbloader
    rk_secure_boot_sign_loader_artifacts "${rk_sign_tool}" "${platform}" "${keys_dir}"
    rk_secure_boot_rebuild_spi_loader
    display_alert "secure-uboot" "Signed U-Boot FIT, embedded SPL key, and loader artifacts (binman form)" "info"
}

function rk_secure_boot_sign_uboot_fit() {
    # Sign the Armbian-built ITS directly. Do not call Rockchip scripts/fit.sh:
    # with CONFIG_FIT_SIGNATURE it invokes make.sh --raw-compile and silently
    # rebuilds the already-built Armbian U-Boot with the vendor toolchain.
    # This hook instead injects the public key into the existing SPL DTB,
    # repacks the existing SPL, and host-verifies the resulting FIT.
    rk_full_secure_boot_enabled || return 0

    if [[ "${BRANCH:-}" == "vendor-next" ]]; then
        rk_secure_boot_sign_uboot_fit_binman
        return 0
    fi

    local platform keys_dir rk_sign_tool signed_fit fit_padding
    platform="$(rk_detect_platform)"
    keys_dir="${UBOOT_FIT_KEYS_DIR:-${PWD}/keys}"
    rk_sign_tool="$(command -v rk_sign_tool 2>/dev/null || true)"
    [[ -n "${rk_sign_tool}" ]] || rk_sign_tool="$(resolve_platform_rkbin_dir)/tools/rk_sign_tool"

    [[ "${platform}" != "unknown" ]] || exit_with_error "Cannot sign U-Boot FIT for unknown Rockchip platform" "BOOT_SOC=${BOOT_SOC:-}"
    [[ -x tools/mkimage && -x tools/fit_check_sign ]] || exit_with_error "Rockchip FIT signing tools missing" "${PWD}"
    command -v fdtget >/dev/null 2>&1 || exit_with_error "fdtget is required for secure U-Boot FIT signing" "host dependency missing"
    [[ -x "${rk_sign_tool}" ]] || exit_with_error "rk_sign_tool missing for secure U-Boot build" "${rk_sign_tool}"
    [[ -f .config && -f u-boot.its && -f spl/u-boot-spl.dtb && -f spl/u-boot-spl-nodtb.bin ]] ||
        exit_with_error "U-Boot signing inputs missing" "${PWD}"
    [[ -f "${keys_dir}/dev.key" && -f "${keys_dir}/dev.pubkey" && -f "${keys_dir}/dev.crt" ]] ||
        exit_with_error "FIT signing key material missing" "${keys_dir}"
    grep -qx 'CONFIG_FIT_SIGNATURE=y' .config || exit_with_error "CONFIG_FIT_SIGNATURE must be enabled for full secure boot" ".config"
    grep -qx 'CONFIG_SPL_FIT_SIGNATURE=y' .config || exit_with_error "CONFIG_SPL_FIT_SIGNATURE must be enabled for full secure boot" ".config"
    grep -Eq 'rsa(2048|4096)' u-boot.its || exit_with_error "U-Boot ITS has no supported RSA signature node" "u-boot.its"

    # With CONFIG_FIT_ENABLE_RSASSA_PSS_SUPPORT the generated U-Boot ITS is
    # signed with padding = "pss", and the SPL/U-Boot verifiers in this tree
    # only accept maximum-salt PSS signatures.  A tree-built mkimage linked
    # against OpenSSL >= 3.5 signs with digest-length salt, which SPL rejects
    # on the device.  Sign with the Rockchip prebuilt mkimage instead: it is
    # statically linked, so its maximum-salt behaviour is frozen into the
    # binary regardless of the build container's OpenSSL.  The tree-built
    # fit_check_sign below uses the same verify code as SPL, so any salt
    # drift in the signing tool fails the build instead of the boot.
    rk_secure_boot_resolve_mkimage

    # The USBPLUG postprocess rebuilds host tools with its temporary config,
    # leaving mkimage without FIT-signature support. Restore the host tools
    # from the final secure U-Boot configuration before signing the FIT.
    if tools/mkimage -h 2>&1 | grep -q 'Signing / verified boot not supported'; then
        make -B tools-only || exit_with_error "Failed to rebuild FIT-signing U-Boot host tools" "${PWD}/tools"
    fi

    fit_padding=0x1000
    grep -qx 'CONFIG_FIT_ENABLE_RSA4096_SUPPORT=y' .config && fit_padding=0x1200
    mkdir -p fit || exit_with_error "Failed to create FIT output directory" "${PWD}/fit"
    rm -f fit/uboot.itb data2sign.bin

    # boot.itb is signed later with -K u-boot.dtb.  Inject that key before
    # generating the final U-Boot FIT so the DTB embedded in u-boot.itb is the
    # same trusted DTB used by the running U-Boot instance.
    if ! fdtget -l u-boot.dtb /signature >/dev/null 2>&1; then
        "${RK_SECURE_BOOT_MKIMAGE}" -f u-boot.its -k "${keys_dir}" -K u-boot.dtb \
            -E -p "${fit_padding}" -r fit/uboot.itb ||
            exit_with_error "Failed to inject the boot FIT public key into U-Boot DTB" "u-boot.dtb"
    fi
    "${RK_SECURE_BOOT_MKIMAGE}" -f u-boot.its -k "${keys_dir}" -K spl/u-boot-spl.dtb \
        -E -p "${fit_padding}" -r fit/uboot.itb ||
        exit_with_error "Failed to sign Armbian-built U-Boot FIT" "${platform}"

    fdtget -l spl/u-boot-spl.dtb /signature 2>/dev/null | grep -qx 'key-dev' ||
        exit_with_error "FIT public key was not embedded in SPL DTB" "spl/u-boot-spl.dtb"

    fdtget -p fit/uboot.itb /configurations/conf/signature 2>/dev/null | grep -qx 'value' ||
        exit_with_error "U-Boot FIT configuration was not signed" "fit/uboot.itb"

    signed_fit="fit/uboot.itb"
    [[ -f "${signed_fit}" ]] || exit_with_error "Signed U-Boot FIT missing" "${signed_fit}"
    install -m 0644 "${signed_fit}" u-boot.itb || exit_with_error "Failed to install signed U-Boot FIT" "u-boot.itb"
    tools/fit_check_sign -f u-boot.itb -k spl/u-boot-spl.dtb -s ||
        exit_with_error "Signed U-Boot FIT verification failed" "u-boot.itb"

    rk_secure_boot_minimize_spl_fit_key
    rk_secure_boot_repack_signed_spl
    rk_secure_boot_rebuild_idbloader
    rk_secure_boot_sign_loader_artifacts "${rk_sign_tool}" "${platform}" "${keys_dir}"
    rk_secure_boot_rebuild_spi_loader
    display_alert "secure-uboot" "Signed U-Boot FIT, embedded SPL key, and loader artifacts" "info"
}

function rk_secure_boot_prepare_uboot_tree() {
    # Goal: Generate keys required for FIT signing before U-Boot configuration, plus an optional system encryption key.
    if ! rk_optee_bootchain_enabled; then
        return 0
    fi

    if [[ "${RK_OPTEE_BOOT_ENABLE}" == "yes" && "${RK_SECURE_UBOOT_ENABLE}" != "yes" ]]; then
        enable_optee_bootchain_bl32_fit_node
    fi

    if [[ "${DISABLE_FIT_KEY_GEN}" == "yes" ]]; then
        if rk_full_secure_boot_enabled; then
            exit_with_error "DISABLE_FIT_KEY_GEN cannot be used with full secure boot" "RK_SECURE_UBOOT_ENABLE=yes requires a FIT signing key"
        fi
        return 0
    fi

    local uboot_workdir rkbin_root rkbin_dir rk_sign_tool keys_dir persistent_keys_dir
    uboot_workdir="$(pwd)"  # Current directory is the U-Boot source tree
    keys_dir="${uboot_workdir}/keys"

    # Prefer UBOOT_DIR if user explicitly set it
    if [[ -n "${UBOOT_DIR}" ]]; then
        uboot_workdir="${UBOOT_DIR}"
        keys_dir="${UBOOT_DIR}/keys"
    fi

    # A caller may provide a persistent signing-key directory. This is useful
    # when an SPI-only build and a separately built OS FIT must retain one
    # signing identity. With no directory supplied, preserve the upstream
    # behavior: reuse worktree keys when present or generate a new key pair.
    persistent_keys_dir="${UBOOT_FIT_KEYS_BACKUP_DIR:-}"

    rk_secure_boot_stage_uboot_fit_generator "${uboot_workdir}"

    rkbin_root="$(rk_sdk_rkbin_root)"
    rkbin_dir="$(resolve_platform_rkbin_dir)"
    display_alert "secure-uboot" "rkbin root: ${rkbin_root}" "debug"
    display_alert "secure-uboot" "platform rkbin: ${rkbin_dir:-<not found>}" "debug"
    rk_secure_boot_prepare_tee_bin "${uboot_workdir}"

    # Find rk_sign_tool executable (prefer PATH)
    rk_sign_tool="$(command -v rk_sign_tool 2>/dev/null || true)"
    if [[ -z "${rk_sign_tool}" && -n "${rkbin_dir}" && -x "${rkbin_dir}/tools/rk_sign_tool" ]]; then
        rk_sign_tool="${rkbin_dir}/tools/rk_sign_tool"
    fi
    if [[ -z "${rk_sign_tool}" && -n "${rkbin_root}" && -x "${rkbin_root}/tools/rk_sign_tool" ]]; then
        rk_sign_tool="${rkbin_root}/tools/rk_sign_tool"
    fi

    if [[ -z "${rk_sign_tool}" ]]; then
        if rk_full_secure_boot_enabled; then
            exit_with_error "rk_sign_tool not found for full secure boot" "Cannot generate or sign FIT key material"
        fi
        display_alert "secure-uboot" "rk_sign_tool not found, skipping FIT key generation" "warn"
        return 0
    fi

    mkdir -p "${keys_dir}" || { display_alert "secure-uboot" "Cannot create directory ${keys_dir}" "err"; return 1; }

    if [[ -n "${persistent_keys_dir}" ]]; then
        [[ -f "${persistent_keys_dir}/private_key.pem" ]] ||
            exit_with_error "FIT signing private key missing" "${persistent_keys_dir}/private_key.pem"
        display_alert "secure-uboot" "Restoring caller-supplied FIT signing keys" "${persistent_keys_dir}" "info"
        (
            cd "${keys_dir}" || exit 1
            install -m 0600 "${persistent_keys_dir}/private_key.pem" private_key.pem || exit 1
            if [[ -f "${persistent_keys_dir}/public_key.pem" ]]; then
                install -m 0644 "${persistent_keys_dir}/public_key.pem" public_key.pem || exit 1
            else
                openssl pkey -in private_key.pem -pubout -out public_key.pem || exit 1
                chmod 0644 public_key.pem
            fi
            if [[ -f "${persistent_keys_dir}/dev.crt" ]]; then
                install -m 0644 "${persistent_keys_dir}/dev.crt" dev.crt || exit 1
            else
                openssl req -batch -new -x509 -key private_key.pem -out dev.crt -subj "/CN=Armbian FIT Key/" || exit 1
                chmod 0644 dev.crt
            fi
            ln -sf private_key.pem dev.key
            ln -sf public_key.pem dev.pubkey
        )
        display_alert "secure-uboot" "Caller-supplied FIT keys restored: ${keys_dir}" "info"
    elif [[ -f "${keys_dir}/dev.key" && -f "${keys_dir}/dev.crt" ]]; then
        display_alert "secure-uboot" "Existing keys detected, skipping generation (${keys_dir})" "info"
    else
        display_alert "secure-uboot" "Generating initial key pair using rk_sign_tool" "info"
        (
            cd "${keys_dir}" || exit 1
            "${rk_sign_tool}" kk --bits 2048 --out ./ || exit_with_error "rk_sign_tool key generation failed" "${rk_sign_tool}"
            ln -rsf private_key.pem dev.key
            ln -rsf public_key.pem dev.pubkey
            openssl req -batch -new -x509 -key dev.key -out dev.crt -subj "/CN=Armbian FIT Key/" || exit_with_error "Failed to generate self-signed certificate" "dev.crt"
            openssl rand -hex 32 > system_enc_key || exit_with_error "Failed to generate system_enc_key" "system_enc_key"
        )
        display_alert "secure-uboot" "FIT keys generated: ${keys_dir}" "info"
    fi

    # Export path for later stages/packaging
    export UBOOT_FIT_KEYS_DIR="${keys_dir}"
}
