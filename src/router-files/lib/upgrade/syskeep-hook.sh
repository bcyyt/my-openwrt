#!/bin/sh
# Keep extra GPT partitions (e.g. /mnt/data) when flashing x86 combined images.
# Sourced after platform.sh; replaces check/upgrade when layout differs.

RAMFS_COPY_BIN="${RAMFS_COPY_BIN} blkdiscard"

syskeep_write_parts() {
	local image="$1"
	local diskdev="$2"
	local part start size partdev disk_sects

	while read part start size; do
		part=$(echo "$part" | awk '{print int($1)}')
		start=$(echo "$start" | awk '{print int($1)}')
		size=$(echo "$size" | awk '{print int($1)}')
		[ "$part" -ge 1 ] || continue
		[ "$part" -le 2 ] || {
			v "syskeep: skip image partition $part"
			continue
		}
		if export_partdevice partdev "$part"; then
			disk_sects=$(cat "/sys/class/block/${partdev}/size" 2>/dev/null || echo 0)
			if [ "$size" -gt "$disk_sects" ]; then
				v "syskeep: image p$part ($size) larger than /dev/$partdev ($disk_sects)"
				return 1
			fi
			v "syskeep: writing image p$part -> /dev/$partdev ($size sectors)"
			get_image_dd "$image" of="/dev/$partdev" ibs=512 obs=1M skip="$start" count="$size" conv=fsync
			if [ "$part" = "2" ] && [ "$disk_sects" -gt "$size" ]; then
				v "syskeep: wiping leftover overlay on /dev/$partdev"
				if command -v blkdiscard >/dev/null 2>&1; then
					blkdiscard -o $((size * 512)) -l $(((disk_sects - size) * 512)) "/dev/$partdev" 2>/dev/null || \
						dd if=/dev/zero of="/dev/$partdev" bs=512 seek="$size" count=$((disk_sects - size)) conv=fsync
				else
					dd if=/dev/zero of="/dev/$partdev" bs=512 seek="$size" count=$((disk_sects - size)) conv=fsync
				fi
			fi
		else
			v "syskeep: disk partition $part missing, abort"
			return 1
		fi
	done < /tmp/partmap.image
	return 0
}

platform_check_image() {
	local diskdev diff
	[ "$#" -gt 1 ] && return 1

	if is_onie_install; then
		[ "$(get_magic_word "$1")" = "2321" ] || {
			v "Invalid image: expected ONIE installer (shell script)"
			return 1
		}
		head -c 4096 "$1" | grep -q '^PAYLOAD_OFFSET=' || {
			v "Invalid image: no PAYLOAD_OFFSET header"
			return 1
		}
		return 0
	fi

	case "$(get_magic_word "$1")" in
		eb48|eb63) ;;
		*)
			v "Invalid image type"
			return 1
		;;
	esac

	export_bootdevice && export_partdevice diskdev 0 || {
		v "Unable to determine upgrade device"
		return 1
	}

	get_partitions "/dev/$diskdev" bootdisk
	v "Extract boot sector from the image"
	get_image_dd "$1" of=/tmp/image.bs count=63 bs=512b
	get_partitions /tmp/image.bs image
	diff="$(grep -F -x -v -f /tmp/partmap.bootdisk /tmp/partmap.image)"
	rm -f /tmp/image.bs /tmp/partmap.bootdisk /tmp/partmap.image

	if [ -n "$diff" ]; then
		v "syskeep: partition layout differs; will write boot+rootfs only and keep extra partitions"
	fi
	return 0
}

platform_do_upgrade() {
	local diskdev partdev diff

	if is_onie_install; then
		v "syskeep: ONIE upgrade is not supported"
		return 1
	fi

	export_bootdevice && export_partdevice diskdev 0 || {
		v "Unable to determine upgrade device"
		return 1
	}

	sync

	get_partitions "/dev/$diskdev" bootdisk
	v "Extract boot sector from the image"
	get_image_dd "$1" of=/tmp/image.bs count=63 bs=512b
	get_partitions /tmp/image.bs image
	diff="$(grep -F -x -v -f /tmp/partmap.bootdisk /tmp/partmap.image)"

	if [ -n "$diff" ]; then
		v "syskeep: keeping partition table on /dev/$diskdev"
		syskeep_write_parts "$1" "$diskdev" || return 1
	else
		while read part start size; do
			if export_partdevice partdev $part; then
				v "Writing image to /dev/$partdev..."
				get_image_dd "$1" of="/dev/$partdev" ibs=512 obs=1M skip="$start" count="$size" conv=fsync
			else
				v "Unable to find partition $part device, skipped."
			fi
		done < /tmp/partmap.image
	fi

	v "Writing new UUID to /dev/$diskdev..."
	get_image_dd "$1" of="/dev/$diskdev" bs=1 skip=440 count=4 seek=440 conv=fsync

	platform_do_bootloader_upgrade "$diskdev"
	local parttype=ext4
	part_magic_efi "/dev/$diskdev" || return 0

	if export_partdevice partdev 1; then
		part_magic_fat "/dev/$partdev" && parttype=vfat
		mount -t $parttype -o rw,noatime "/dev/$partdev" /mnt
		set -- $(dd if="/dev/$diskdev" bs=1 skip=1168 count=16 2>/dev/null | hexdump -v -e '8/1 "%02x "" "2/1 "%02x""-"6/1 "%02x"')
		sed -i "s/\(PARTUUID=\)[a-f0-9-]\+/\1$4$3$2$1-$6$5-$8$7-$9/ig" /mnt/boot/grub/grub.cfg
		umount /mnt
	fi
}
