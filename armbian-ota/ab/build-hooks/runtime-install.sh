# A/B OTA rootfs installation hooks

readonly OTA_COMMON_INITRAMFS_AB="${OTA_SUPPORT_DIR}/common/initramfs"

function ota_install_ab_runtime_to_rootfs() {
    local root_dir="$1"

    ota_install_common_runtime_to_rootfs "${root_dir}" || return 1
    ota_sync_rootfs "A/B OTA runtime" "${OTA_AB_ROOTFS}" "${root_dir}"
    ota_ab_write_complete_initial_env "${root_dir}"
}

function ota_enable_ab_runtime_services() {
    local root_dir="$1"
    local title="A/B partition OTA"

    display_alert "${title}" "Enabling A/B OTA services" "info"
    chroot "${root_dir}" systemctl enable armbian-ota-init-uboot.service \
        || display_alert "${title}" "Failed to enable armbian-ota-init-uboot.service" "warn"
    chroot "${root_dir}" systemctl enable armbian-ota-firstboot.service \
        || display_alert "${title}" "Failed to enable armbian-ota-firstboot.service" "warn"
    chroot "${root_dir}" systemctl enable armbian-ota-firstboot-hook.service \
        || display_alert "${title}" "Failed to enable armbian-ota-firstboot-hook.service" "warn"
}

# Install the Seeed OTA common initramfs pieces (userdata resolver plus the
# anchored /boot mounter) into an A/B image. Mirrors ota_install_common_initramfs
# in the recovery hook but is kept independent so the A/B path can evolve
# without coupling.
function ota_install_ab_common_initramfs() {
    local root_dir="$1"
    local title="A/B OTA common initramfs"
    local -a common_initramfs_file_list=(
        "hooks/98-seeed-bind-userdata:etc/initramfs-tools/hooks/98-seeed-bind-userdata:0755"
        "scripts/init-bottom/00-seeed-bind-userdata:etc/initramfs-tools/scripts/init-bottom/00-seeed-bind-userdata:0755"
        "scripts/init-bottom/zz-seeed-mount-boot:etc/initramfs-tools/scripts/init-bottom/zz-seeed-mount-boot:0755"
    )
    local entry source_path destination_path mode

    display_alert "${title}" "Installing userdata resolver" "info"
    for entry in "${common_initramfs_file_list[@]}"; do
        IFS=: read -r source_path destination_path mode <<< "${entry}"
        [[ -f "${OTA_COMMON_INITRAMFS_AB}/${source_path}" ]] || {
            display_alert "${title}" "Missing source file: ${OTA_COMMON_INITRAMFS_AB}/${source_path}" "err"
            return 1
        }
        install -D -m "${mode}" \
            "${OTA_COMMON_INITRAMFS_AB}/${source_path}" \
            "${root_dir}/${destination_path}" || return 1
    done
}

function pre_update_initramfs__895_install_ab_ota_runtime() {
    ota_install_ab_runtime_to_rootfs "${MOUNT}" || return 1
    ota_install_ab_common_initramfs "${MOUNT}" || return 1
    ota_enable_ab_runtime_services "${MOUNT}"
}

# Remove the /boot fstab entry: /boot is mounted by the initramfs
# (zz-seeed-mount-boot, anchored to the disk U-Boot booted from) instead,
# mirroring the recovery image. A fstab source is unworkable in multi-disk
# clone setups -- A/B images dd-cloned onto eMMC and NVMe expose duplicate
# boot partition UUIDs/LABELs, udev's duplicate-UUID symlinks point the
# mount at whichever disk enumerated first, and a hand-made /dev symlink
# never satisfies systemd's udev-backed device unit (observed as a ~90s
# stall in "Expecting device dev-armbian-boot.device" on recovery images).
# Without this, /boot lands on the wrong disk while kernel and rootfs come
# from the bootdev one (observed: /boot from eMMC mmcblk0p1, root overlay
# from NVMe). Raw-FIT (secure boot) layouts never get a /boot entry, so the
# grep does not match there.
function pre_update_initramfs__896_ab_boot_anchor_fstab() {
    local fstab="${MOUNT}/etc/fstab"

    [[ -f "${fstab}" ]] || return 0
    if grep -qE '^[^[:space:]]+[[:space:]]+/boot([[:space:]]|$)' "${fstab}"; then
        sed -i -E '\@^[^[:space:]]+[[:space:]]+/boot([[:space:]]|$)@d' "${fstab}" ||
            exit_with_error "A/B OTA" "failed to remove fstab /boot entry"
        display_alert "A/B OTA" "removed fstab /boot entry (initramfs mounts /boot anchored)" "info"
    fi
}
