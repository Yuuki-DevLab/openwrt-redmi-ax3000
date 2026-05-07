. /lib/functions.sh

RAMFS_COPY_BIN='fw_printenv fw_setenv'
RAMFS_COPY_DATA='/etc/fw_env.config /var/lock/fw_printenv.lock'

ipq50xx_has_mi_dualboot() {
	grep -q '"rootfs_1"' /proc/mtd
}

ipq50xx_check_single_rootfs_image() {
	local ret=0
	local file_type="$( identify "$1" )"

	if [ "${file_type}" != ubi ]; then
		v "Unsupport file type: ${file_type}"
		v "Please use ubi file"
		ret=1
	fi

	if ! grep -q '"rootfs"' /proc/mtd; then
		v "Unable to find rootfs MTD partition"
		ret=1
	fi

	return ${ret}
}

ipq50xx_do_single_rootfs_upgrade() {
	CI_UBIPART="rootfs"
	nand_do_upgrade "$1"
}

platform_check_image() {
	local board=$(board_name)
	case $board in
		redmi,ax3000|\
		xiaomi,cr881x)
			if ipq50xx_has_mi_dualboot; then
				mi_dualboot_check_image "$1"
			else
				ipq50xx_check_single_rootfs_image "$1"
			fi
			return $?
			;;
		*)
			v "Sysupgrade is not supported on your board($board) yet."
			return 1
			;;
	esac
}

platform_do_upgrade() {
	local board=$(board_name)
	case $board in
		redmi,ax3000|\
		xiaomi,cr881x)
			if ipq50xx_has_mi_dualboot; then
				mi_dualboot_do_upgrade "$1"
			else
				ipq50xx_do_single_rootfs_upgrade "$1"
			fi
			;;
		*)
			default_do_upgrade "$1"
			;;
	esac
}
