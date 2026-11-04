# Stage the Seeed rescue-default-env U-Boot patch (recovery OTA v0.8 design
# section 3.4) into the userpatches overlay for every distro-form U-Boot tree
# (the vendor-next v5 bootstd tree is skipped -- gate in the function below).
#
# The patch's default bootcmd is self-routing: ota_rescue_boot boots the
# /recovery/ assets only when they exist and falls through to
# distro_bootcmd otherwise, so the same compiled U-Boot is correct for
# recovery-OTA, plain and A/B images. Staging unconditionally keeps:
#   - one stable U-Boot artifact hash across flavors sharing a checkout
#     (patches_hash covers this location; a gated patch used to bump the
#     artifact version and thrash the cache whenever flavors alternated);
#   - no stale-patch risk window (the previous stage/sweep pair had to run
#     on every single build or a recovery build's patch leaked into the
#     next plain build's U-Boot).
#
# Staging targets USERPATCHES_PATH (not SRC/patch) so the framework tree
# stays untouched. The patch versions together with the rest of the v0.8
# pieces under this repository's release tags.

function post_family_config__seeed_ota_stage_uboot_rescue_default_env() {
	local extension_common_root patch_src
	local boot_patch_dir target_dir target_patch

	extension_common_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
	patch_src="${extension_common_root}/patches/seeed-ota-rescue-default-env.patch"

	[[ -f "${patch_src}" ]] ||
		exit_with_error "seeed-ota" "rescue-default-env patch missing: ${patch_src}"

	# BOOTPATCHDIR is a space-separated list; the base family dir comes first.
	boot_patch_dir="${BOOTPATCHDIR%% *}"
	target_dir="${USERPATCHES_PATH}/u-boot/${boot_patch_dir}"
	target_patch="${target_dir}/seeed-ota-rescue-default-env.patch"

	# The patch anchors on the distro-form SoC headers -- the
	# config_distro_bootcmd.h include and the BOOTENV tail of
	# EXTRA_ENV_SETTINGS -- which only the 2017.09/radxa tree carries. The
	# vendor-next v5 tree (legacy/u-boot-rockchip-v5) went bootstd: that
	# include has no rockchip includer there and the default bootcmd is the
	# vendor boot_fit/bootflow chain, so the patch can neither apply (every
	# vendor-next build failed at the patching step) nor make sense -- its
	# fail-safe bootcmd falls through to distro_bootcmd, which does not
	# exist in that form. Skip (and heal a copy staged by pre-gating builds)
	# until a bootstd-shaped rescue default is designed.
	if [[ "${boot_patch_dir}" == "legacy/u-boot-rockchip-v5" ]]; then
		rm -f "${target_patch}"
		display_alert "seeed-ota" "rescue-default-env: u-boot-rockchip-v5 is bootstd-form, patch not staged" "info"
		return 0
	fi

	mkdir -p "${target_dir}"
	cp -f "${patch_src}" "${target_patch}"
	display_alert "seeed-ota" "staged rescue-default-env U-Boot patch -> ${target_dir}" "info"
}
