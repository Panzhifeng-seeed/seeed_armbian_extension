# Common OTA rootfs installation helpers

function ota_sync_rootfs() {
    local title="$1"
    local source_rootfs="$2"
    local target_rootfs="$3"

    if [[ ! -d "${source_rootfs}" ]]; then
        display_alert "${title}" "rootfs source dir missing: ${source_rootfs}" "err"
        return 1
    fi

    display_alert "${title}" "Installing ${source_rootfs}" "info"
    rsync -aH --chown=0:0 "${source_rootfs}/" "${target_rootfs}/" || {
        display_alert "${title}" "Failed to install ${source_rootfs}" "err"
        return 1
    }
}

function ota_install_common_runtime_to_rootfs() {
    ota_sync_rootfs "OTA runtime" "${OTA_COMMON_ROOTFS}" "$1"
    printf 'IMAGE_VARIANT=%s\n' "${OTA_IMAGE_VARIANT}" > "$1/etc/armbian-ota-image"
    # Per-image v5-only routing-env token (see fwenv.sh): the vendor-next
    # routing env's fit branches are the only cmdline source on raw-FIT
    # (secure) images and plymouthd otherwise eats serial login input there.
    # The 6.1 vendor tree boots fine without it and shares this code once
    # fit/vendor-next merges to main, so only vendor-next builds stamp it --
    # a missing file is the 6.1-preserving default. Runs before
    # update-initramfs, so 99-copy-tools rides the file into the initramfs
    # and the rescue-side routing rebuild keeps the token too.
    if [[ "${BRANCH:-}" == "vendor-next" ]]; then
        printf '%s\n' 'OTA_ENV_PLYMOUTH_TOKEN="plymouth.ignore-serial-consoles "' \
            > "$1/usr/share/armbian-ota/uboot-tree.env"
    fi
}
