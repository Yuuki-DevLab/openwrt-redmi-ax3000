# Merge Rootfs Partitions

This guide describes the risky single-rootfs layout for Redmi AX3000 / Xiaomi CR880x class devices. It replaces the stock A/B `rootfs` + `rootfs_1` layout with one `rootfs` partition for OpenWrt and, optionally, one separate `data` partition for persistent files.

This is not an image-only change. The partition table comes from the bootloader / Qualcomm partition data, not from this repository's DTS files. You need a merged MIBIB / custom U-Boot flow that is known to match your exact board revision.

## Expected Result

Stock layout uses two firmware slots:

```text
rootfs    30-36 MiB
rootfs_1  30-36 MiB
overlay/data/vendor remainder
```

OpenWrt is flashed into only one slot, so `kernel`, `rootfs`, and `rootfs_data` share that slot. On many devices this leaves about 16-18 MiB usable overlay.

The preferred layout for this tree is not one huge `rootfs`. Keep `rootfs` at the stock 30 MiB slot size and put the rest into a separate `data` partition:

```text
rootfs  30 MiB
data    remaining NAND area after rootfs, about 87.5 MiB on 128 MiB NAND
```

On the known Redmi AX3000 / CR880x 128 MiB NAND layout, the safe firmware/data region starts at `0x0a80000` and ends at `0x8000000`. Use this split:

```text
rootfs  offset 0x0a80000, size 0x1e00000, end 0x2880000
data    offset 0x2880000, size 0x5780000, end 0x8000000
```

Exact offsets and sizes must be eraseblock-aligned and must come from the MIBIB partition table, not DTS.

This keeps OpenWrt firmware inside `rootfs`, while the writable overlay can be moved to a separate `data` UBI/UBIFS partition. Packages installed by `opkg` then use `data` because `/overlay` lives there. It also leaves more recovery room than a maximal rootfs partition because sysupgrade only rewrites `rootfs`.

After this repository's upgrade script changes:

- If `/proc/mtd` contains `rootfs_1`, sysupgrade keeps the stock dualboot path.
- If `/proc/mtd` has only `rootfs` for firmware, sysupgrade writes the UBI image directly to `rootfs`.
- Xiaomi A/B success flag handling is skipped when `rootfs_1` is absent.
- A separate `data` partition is attached before `mount_root` and can be used as extroot `/overlay`.
- The `data` partition is preserved by sysupgrade.

## Risks

- Wrong MIBIB or U-Boot can brick the device before Linux boots.
- UART access may be disabled by some custom U-Boot builds.
- Stock Xiaomi recovery / rollback semantics stop applying after merge.
- Touching `0:ART` can permanently break WiFi calibration.
- Bad `bdata` backup/restore can break board-specific vendor data.
- Recovery may require UART, TFTP, and possibly a SPI-NAND programmer.

Do not proceed without verified backups and a recovery path.

## Files You Need

You must provide these yourself from a trusted source for your exact device family and board revision:

- `MIBIB.bin`: custom partition table with one `rootfs` and one separate `data` partition.
- `APPSBL.bin`: custom U-Boot / bootloader image for `0:APPSBL`.
- `APPSBL_1.bin` or `APPSBL1.bin`: custom U-Boot / bootloader image for `0:APPSBL_1`.
- `openwrt-ipq50xx-arm-redmi_ax3000-squashfs-nand-factory.ubi`: OpenWrt UBI image built from this tree.

Known community guides use names like `MIBIB.bin`, `APPSBL.bin`, and `APPSBL1.bin`. Verify the target partition name before flashing; `APPSBL1.bin` is usually the file for partition `0:APPSBL_1`.

Do not use a maximal merged MIBIB if you want a separate data partition. The MIBIB must describe both partitions, for example:

```text
rootfs  starts where stock rootfs started, size 0x1e00000 / 30 MiB
data    starts at 0x2880000, uses remaining safe NAND area to 0x8000000
```

Do not move or resize bootloader, ART, calibration, or board-data partitions.

## Preflight Checks

Boot an existing working system and record the hardware identity:

```sh
cat /proc/cmdline
cat /proc/mtd
cat /tmp/sysinfo/board_name
ubinfo -a
fw_printenv
```

Expected supported board names for this guide:

```text
redmi,ax3000
xiaomi,cr881x
```

Stop if `/proc/mtd` does not show Xiaomi-style partitions such as `0:MIBIB`, `0:APPSBL`, `0:APPSBL_1`, `0:ART`, `rootfs`, and `rootfs_1`.

## Backup From Linux

Copy backups off-device before flashing anything. Replace paths and host as needed.

Create local dumps:

```sh
mkdir -p /tmp/mtd-backup

for p in 0:MIBIB 0:APPSBL 0:APPSBL_1 0:ART bdata rootfs rootfs_1; do
	mtd="$(grep "\"$p\"" /proc/mtd | cut -d: -f1)"
	[ -n "$mtd" ] || { echo "missing $p"; exit 1; }
	name="$(printf '%s' "$p" | tr ':' '_')"
	dd if="/dev/$mtd" of="/tmp/mtd-backup/${name}.bin" bs=128k
done

(cd /tmp/mtd-backup && sha256sum *.bin > SHA256SUMS)
```

Copy them to your computer:

```sh
scp -O -r root@192.168.1.1:/tmp/mtd-backup ./cr880x-mtd-backup
```

Verify the backup exists on your computer before continuing:

```sh
(cd ./cr880x-mtd-backup && sha256sum -c SHA256SUMS)
```

If `scp` is not available on the router, use `nc`, a USB drive, or TFTP. Do not store the only copy in `/tmp`; it is RAM-backed and disappears after reboot.

## Backup From U-Boot

U-Boot backup is useful when Linux is not trusted or before changing bootloader partitions. Exact commands vary by U-Boot build. Use `help`, `smem`, `mtdparts`, or `printenv` to confirm partition names and sizes.

Example network setup:

```text
setenv ipaddr 192.168.1.2
setenv serverip 192.168.1.1
```

If your U-Boot supports partition reads by name, back up critical partitions to a TFTP server:

```text
nand read 0x44000000 0:MIBIB
tftpput 0x44000000 $filesize MIBIB-backup.bin

nand read 0x44000000 0:APPSBL
tftpput 0x44000000 $filesize APPSBL-backup.bin

nand read 0x44000000 0:APPSBL_1
tftpput 0x44000000 $filesize APPSBL_1-backup.bin

nand read 0x44000000 0:ART
tftpput 0x44000000 $filesize ART-backup.bin
```

Some U-Boot builds require explicit offset and size instead of partition names. Get the exact table with `smem` or `mtdparts`, then read only those ranges. Never write to `0:ART` during this merge.

## Flash Merged Partition Table And U-Boot

Preferred path is U-Boot TFTP, because bootloader partitions are being changed.

Set network addresses:

```text
setenv ipaddr 192.168.1.2
setenv serverip 192.168.1.1
```

Flash the merged partition table:

```text
tftpboot MIBIB.bin
flash 0:MIBIB
```

Power-cycle or reset back into U-Boot after flashing MIBIB. Then flash U-Boot images:

```text
tftpboot APPSBL.bin
flash 0:APPSBL

tftpboot APPSBL_1.bin
flash 0:APPSBL_1
```

If your file is named `APPSBL1.bin`, use that filename but still flash it to partition `0:APPSBL_1`:

```text
tftpboot APPSBL1.bin
flash 0:APPSBL_1
```

Reset back into U-Boot and inspect the partition table:

```text
reset
smem
```

Expected merged layout has one `rootfs`, one `data`, and no `rootfs_1`. Stop if the table still has both `rootfs` and `rootfs_1`, if `data` is missing, or if critical partitions moved unexpectedly.

## Flash OpenWrt After Merge

With a merged layout, flash OpenWrt to `rootfs`:

```text
tftpboot openwrt-ipq50xx-arm-redmi_ax3000-squashfs-nand-factory.ubi
flash rootfs
reset
```

If using a web recovery U-Boot, upload the same `nand-factory.ubi` image through the web UI. The web UI must be from the custom U-Boot that understands the merged layout.

## Alternative Linux Flashing

Only use this if you are already booted into Linux after the merged partition table is active and `/proc/mtd` shows one `rootfs`, one `data`, and no `rootfs_1`.

```sh
cat /proc/mtd
mtdnum="$(grep '"rootfs"' /proc/mtd | cut -d: -f1 | tr -dc '0-9')"
ubiformat "/dev/mtd${mtdnum}" -f /tmp/openwrt-ipq50xx-arm-redmi_ax3000-squashfs-nand-factory.ubi -y
sync
reboot -f
```

Do not run this on the stock layout unless you intentionally want to overwrite only the current `rootfs` slot.

## Use Data As Package Space

This tree includes `block-mount` by default and auto-attaches the `data` MTD partition before `mount_root` when `rootfs_1` is absent. That allows `data` to be used as extroot `/overlay`, so normal package installs use it.

After booting the merged layout, verify the partition first:

```sh
cat /proc/mtd
```

Only continue if `rootfs_1` is absent and `data` is present. Formatting `data` erases only that partition.

Create one UBIFS volume on `data`:

```sh
mtdnum="$(grep '"data"' /proc/mtd | cut -d: -f1 | tr -dc '0-9')"
[ -n "$mtdnum" ] || { echo "missing data partition"; exit 1; }

ubidetach -m "$mtdnum" 2>/dev/null || true
ubiformat "/dev/mtd${mtdnum}" -y
ubiattach -m "$mtdnum"

ubidev=""
for d in /sys/class/ubi/ubi[0-9]*; do
	[ -r "$d/mtd_num" ] || continue
	[ "$(cat "$d/mtd_num")" = "$mtdnum" ] || continue
	ubidev="${d##*/}"
	break
done
[ -n "$ubidev" ] || { echo "failed to attach data partition"; exit 1; }
ubimkvol "/dev/${ubidev}" -N data -m
mkdir -p /mnt/data
mount -t ubifs "${ubidev}:data" /mnt/data
```

Configure `data` as extroot `/overlay`:

```sh
uci add fstab mount
uci set fstab.@mount[-1].target='/overlay'
uci set fstab.@mount[-1].device="/dev/${ubidev}_0"
uci set fstab.@mount[-1].fstype='ubifs'
uci set fstab.@mount[-1].enabled='1'
uci commit fstab
```

Copy the current overlay into it after writing the extroot config:

```sh
tar -C /overlay -cf - . | tar -C /mnt/data -xf -
```

Reboot, then confirm `/overlay` is mounted from `data`:

```sh
reboot
```

After reboot:

```sh
mount | grep ' /overlay '
df -h /overlay
```

From this point, normal `opkg install ...` writes package files into the `data` partition through `/overlay`.

## First Boot Verification

After OpenWrt boots, verify layout and space:

```sh
cat /proc/cmdline
cat /proc/mtd
ubinfo -a
df -h
logread | grep -Ei 'ubi|ubifs|ath11k|nss|remoteproc'
```

Expected signs:

- `/proc/mtd` has `rootfs` but no `rootfs_1`.
- `/proc/mtd` has a separate `data` partition if using the rootfs-plus-data layout.
- Kernel command line uses `ubi.mtd=rootfs`.
- `df -h /overlay` shows space from the separate `data` partition after extroot is configured.
- WiFi loads calibration from `0:ART`.
- NSS and ath11k initialize without remoteproc crashes.

Run a reboot test:

```sh
reboot
```

Then verify `df -h`, WiFi, WAN, LAN, and `logread` again.

## Sysupgrade Behavior

This repository now supports both layouts at runtime:

- Stock dualboot: `rootfs_1` exists, so sysupgrade uses `mi_dualboot_do_upgrade` and writes the inactive slot.
- Merged single-rootfs: `rootfs_1` is absent, so sysupgrade sets `CI_UBIPART=rootfs` and uses `nand_do_upgrade`.
- Separate data extroot: sysupgrade does not touch `data` unless you manually format it or flash over it. Keep a backup anyway, because extroot contains installed packages and config changes.

Use the factory UBI image for this target unless image rules are changed later:

```sh
sysupgrade -n /tmp/openwrt-ipq50xx-arm-redmi_ax3000-squashfs-nand-factory.ubi
```

Keeping configuration should also work through OpenWrt NAND upgrade flow:

```sh
sysupgrade /tmp/openwrt-ipq50xx-arm-redmi_ax3000-squashfs-nand-factory.ubi
```

Test `sysupgrade -n` first on a recoverable device before trusting config preservation.

## Recovery Notes

If boot fails but U-Boot still works:

```text
setenv ipaddr 192.168.1.2
setenv serverip 192.168.1.1
tftpboot openwrt-ipq50xx-arm-redmi_ax3000-squashfs-nand-factory.ubi
flash rootfs
reset
```

If the merged layout itself is wrong, restore the original bootloader partitions from backups:

```text
tftpboot MIBIB-backup.bin
flash 0:MIBIB

tftpboot APPSBL-backup.bin
flash 0:APPSBL

tftpboot APPSBL_1-backup.bin
flash 0:APPSBL_1
```

After restoring stock MIBIB/U-Boot, flash stock-compatible OpenWrt to `rootfs` or `rootfs_1` using the original dualboot instructions.

If U-Boot no longer starts, serial alone may not be enough. You may need external SPI-NAND programming and verified raw partition backups.

## Do Not Change These For Merge

- Do not edit DTS to fake a larger partition. This target gets NAND partitions from bootloader / Qualcomm partition data.
- Do not shrink Q6/WCSS reserved memory for storage. RAM reservation is unrelated to NAND space.
- Do not erase `0:ART`; WiFi calibration lives there.
- Do not update feeds, QSDK sources, or firmware refs as part of partition merge.
