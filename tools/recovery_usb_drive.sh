#!/system/bin/sh
# shellcheck shell=ksh
# Recovery owns g1 for one session. stdin closing also returns the storage.

SYS=${RECOVERY_DRIVE_SYS:-/sys/class/block}
DEV=${RECOVERY_DRIVE_DEV:-/dev/block}
G=${RECOVERY_DRIVE_GADGET:-/config/usb_gadget/g1}
MOUNTS=${RECOVERY_DRIVE_MOUNTS:-/proc/self/mountinfo}
CMDLINE=${RECOVERY_DRIVE_CMDLINE:-/proc/cmdline}
STATE=${RECOVERY_DRIVE_STATE:-/tmp/recovery-usb-drive-state}
F=$G/functions/mass_storage.recovery

put() { printf '%s\n' "$2" >"$1"; }
block_node() { [ -b "$DEV/$1" ]; }
fail() { error=$1; detail=${2:-}; return 1; }

identify() {
	disk=$1
	case $disk in mmcblk[0-9]|mmcblk[0-9][0-9]) ;; *) return 1 ;; esac
	[ ! -e "$SYS/$disk/partition" ] && block_node "$disk" || return 1
	path=$(readlink -f "$SYS/$disk") || return 1
	slot=0
	case $path in
	*/ff370000.dwmmc/*) slot=1 ;;
	*/ff380000.dwmmc/*) slot=2 ;;
	*/ff390000.dwmmc/*) slot=3 ;;
	esac
	[ "$slot" != 0 ] || return 1
	cid=$(cat "$SYS/$disk/device/cid") || return 1
	[ "${#cid}" = 32 ] || return 1
	case $cid in *[!0-9a-fA-F]*) return 1 ;; esac
	sectors=$(cat "$SYS/$disk/size") || return 1
	case $sectors in ''|*[!0-9]*) return 1 ;; esac
	[ "$sectors" -gt 0 ] || return 1
	forced=none
	boot=0
	cmdline=" $(cat "$CMDLINE") "
	case $cmdline in
	*' androidboot.boot_devices=ff370000.dwmmc '*) source=1 ;;
	*' androidboot.boot_devices=ff380000.dwmmc '*) source=2 ;;
	*' androidboot.boot_devices=ff390000.dwmmc '*) source=3 ;;
	*) source=0 ;;
	esac
	[ "$source" != "$slot" ] && [ "$source" != 0 ] || boot=1
	if [ "$slot" = 3 ]; then
		[ -e "$SYS/$disk/andr36oid_unlock" ] || return 1
		[ "$(cat "$SYS/$disk/device/type")" = MMC ] || return 1
		for n in "${disk}boot0" "${disk}boot1"; do
			block_node "$n" && [ -e "$SYS/$n/force_ro" ] || return 1
		done
		case $cmdline in
		*' dw_mmc_rockchip.builtin_emmc=system '*) forced=system ;;
		*) [ "$source" = 1 ] || [ "$source" = 2 ] || forced=unknown ;;
		esac
	else
		[ "$(cat "$SYS/$disk/device/type")" = SD ] || return 1
		[ "$(cat "$SYS/$disk/ro")" = 0 ] || forced=locked
	fi
}

discover() {
	for entry in "$SYS"/mmcblk*; do
		identify "${entry##*/}" 2>/dev/null || continue
		printf '%s|%s|%s|%s|%s|%s\n' "$disk" "$slot" "$sectors" "$cid" "$forced" "$boot"
	done
}

plan() {
	if ! identify "$1" || [ "$cid" != "$2" ]; then fail changed; return 1; fi
	ro=$3
	case $ro in 0|1) ;; *) fail changed; return 1 ;; esac
	[ "$forced" = none ] || ro=1
	luns=$disk
	[ "$slot" != 3 ] || luns="$disk ${disk}boot0 ${disk}boot1"
}

nodes() {
	for n in $luns; do printf '%s\n' "$n"; done
	for n in "$SYS/$disk"p*; do
		[ ! -f "$n/partition" ] || printf '%s\n' "${n##*/}"
	done
}

# Include mapped devices and their partitions, even when /data uses an alias.
numbers() {
	pending=$(nodes)
	seen=' '
	while [ -n "$pending" ]; do
		next=
		for n in $pending; do
			case $seen in *" $n "*) continue ;; esac
			seen="$seen$n "
			num=$(cat "$SYS/$n/dev") || return 1
			case $num in *[!0-9:]*|''|:*|*:|*:*:*) return 1 ;; esac
			printf '%s\n' "$num"
			for holder in "$SYS/$n/holders"/*; do
				[ ! -e "$holder" ] || next="$next ${holder##*/}"
			done
		done
		pending=$next
	done
}

mounts() {
	nums=$(numbers) || { fail busy; return 1; }
	[ -r "$MOUNTS" ] || { fail busy; return 1; }
	: >"$work/mounts" || return 1
	while read -r mount_id parent num root point options rest; do
		if [ -z "$mount_id" ] || [ -z "$parent" ] || [ -z "$root" ] ||
		    [ -z "$point" ] || [ -z "$options" ]; then fail busy; return 1; fi
		remainder=" $rest"
		case $remainder in *' - '*) fields=${remainder#* - } ;; *) fail busy; return 1 ;; esac
		read -r fs source_path super_options <<EOF
$fields
EOF
		if [ -z "$fs" ] || [ -z "$source_path" ] || [ -z "$super_options" ]; then fail busy; return 1; fi
		matched=0
		for candidate in $nums; do [ "$candidate" != "$num" ] || matched=1; done
		# FUSE mounts have an anonymous mount device; check their backing source too.
		decoded=$(printf '%b' "$source_path")
		if [ "$matched" = 0 ] && source_node "$decoded"; then
			hex=$(source_numbers "$decoded") || { fail busy; return 1; }
			for candidate in $nums; do
				[ "$(printf '%x:%x' "${candidate%:*}" "${candidate#*:}")" != "$hex" ] || matched=1
			done
		fi
		[ "$matched" = 0 ] || printf '%s %s\n' "${#point}" "$point" >>"$work/mounts"
	done <"$MOUNTS"
	# Longest paths first, so nested mounts and bind mounts are removed first.
	sort -rn "$work/mounts" | cut -d ' ' -f 2-
}

source_node() { [ -b "$1" ]; }
source_numbers() { stat -L -c '%t:%T' "$1"; }

unmount_disk() {
	points=$(mounts) || { fail busy; return 1; }
	while IFS= read -r point; do
		[ -n "$point" ] || continue
		decoded=$(printf '%b' "$point")
		umount "$decoded" || { fail busy "$point"; return 1; }
	done <<EOF
$points
EOF
	points=$(mounts) || { fail busy; return 1; }
	[ -z "$points" ] || { fail busy "$points"; return 1; }
	# An inactive mapper or another raw block user must be released separately.
	for n in $(nodes); do
		for holder in "$SYS/$n/holders"/*; do
			[ ! -e "$holder" ] || { fail busy "${holder##*/}"; return 1; }
		done
	done
}

wait_prop() {
	i=0
	while [ "$(getprop "$1")" != "$2" ]; do
		i=$((i + 1)); [ "$i" -lt 100 ] || return 1
		sleep 0.1
	done
}

start_drive() {
	error=setup detail=
	plan "$1" "$2" "$3" || return 1
	unmount_disk || return 1
	[ "$(getprop sys.usb.configfs)" = 1 ] || return 1
	[ ! -d "$F" ] || return 1
	controller=$(getprop sys.usb.controller)
	[ -n "$controller" ] || return 1
	saved_config=$(getprop sys.usb.config)
	saved_adb=$(getprop init.svc.adbd)
	saved_product=$(cat "$G/idProduct") || return 1
	saved_label=$(cat "$G/configs/b.1/strings/0x409/configuration") || return 1
	# A new helper can finish cleanup if this one is killed without its traps.
	mkdir "$STATE" || return 1
	for key in config adb product label disk; do
		case $key in
		config) value=$saved_config ;; adb) value=$saved_adb ;;
		product) value=$saved_product ;; label) value=$saved_label ;; disk) value=$disk ;;
		esac
		if ! put "$STATE/$key" "$value"; then rm -rf "$STATE"; return 1; fi
	done
	owned=1
	setprop sys.usb.config.recovery_drive.ready 0 || return 1
	setprop sys.usb.configfs 2 || return 1
	setprop sys.usb.config.recovery_drive 1 || return 1
	wait_prop sys.usb.config.recovery_drive.ready 1 || return 1
	wait_prop init.svc.adbd stopped || return 1
	unbind || return 1
	# Init has drained earlier gadget actions before acknowledging ownership.
	put "$G/idProduct" 0x4ee0 || return 1
	put "$G/configs/b.1/strings/0x409/configuration" mass_storage || return 1
	mkdir "$F" || return 1
	if [ "$slot" = 3 ]; then
		guard=1
		if [ "$ro" = 0 ]; then
			if put "$SYS/$disk/andr36oid_unlock" "unlock $cid" &&
			    [ "$(cat "$SYS/$disk/andr36oid_unlock")" = unlocked ]; then
				put "$SYS/${disk}boot0/force_ro" 0 || return 1
				put "$SYS/${disk}boot1/force_ro" 0 || return 1
			else
				ro=1 forced=unlock
			fi
		fi
		if [ "$ro" = 1 ]; then
			lock_emmc || return 1
		fi
	fi
	i=0
	for n in $luns; do
		[ "$i" = 0 ] || mkdir "$F/lun.$i" || return 1
		put "$F/lun.$i/removable" 1 || return 1
		put "$F/lun.$i/ro" "$ro" || return 1
		put "$F/lun.$i/file" "$DEV/$n" || return 1
		i=$((i + 1))
	done
	# Refuse both a replacement card and a mount made during setup.
	[ "$(cat "$SYS/$disk/device/cid")" = "$cid" ] || { fail changed; return 1; }
	points=$(mounts) || { fail busy; return 1; }
	[ -z "$points" ] || { fail busy "$points"; return 1; }
	ln -s "$F" "$G/configs/b.1/f1" || return 1
	put "$G/UDC" "$controller"
}

lock_emmc() {
	put "$SYS/$disk/andr36oid_unlock" lock || return 1
	[ "$(cat "$SYS/$disk/andr36oid_unlock")" = locked ] || return 1
	for n in "${disk}boot0" "${disk}boot1"; do
		put "$SYS/$n/force_ro" 1 || return 1
	done
}

unbind() {
	bound=$(cat "$G/UDC") || return 1
	# This kernel returns ENODEV when an already unbound gadget is unbound again.
	case $bound in ''|none) return 0 ;; esac
	put "$G/UDC" none
}

close_drive() {
	[ "${owned:-0}" = 1 ] || return 0
	unbind || return 1
	rm -f "$G/configs/b.1/f1" || return 1
	for lun in "$F"/lun.*; do
		[ ! -d "$lun" ] || put "$lun/file" '' || return 1
	done
	for lun in "$F/lun.2" "$F/lun.1"; do
		[ ! -d "$lun" ] || rmdir "$lun" || return 1
	done
	[ ! -d "$F" ] || rmdir "$F" || return 1
}

cleanup() {
	if [ "${returned:-0}" = 1 ]; then
		wait_prop sys.usb.state "$saved_config" || return 1
		owned=0
		rm -rf "$STATE"
		return 0
	fi
	closed=1
	close_drive || closed=0
	if [ "${owned:-0}" = 1 ]; then sync; fi
	# Close the write window even if configfs detach failed.
	if [ "${guard:-0}" = 1 ]; then lock_emmc || return 1; fi
	[ "$closed" = 1 ] || return 1
	[ "${owned:-0}" = 1 ] || return 0
	put "$G/idProduct" "$saved_product" || return 1
	put "$G/configs/b.1/strings/0x409/configuration" "$saved_label" || return 1
	setprop sys.usb.config.recovery_drive 0 || return 1
	setprop sys.usb.config none || return 1
	setprop sys.usb.configfs 1 || return 1
	wait_prop sys.usb.state none || return 1
	# Enable ADB can start the daemon without changing sys.usb.config.
	if [ "$saved_adb" = running ]; then saved_config=adb; fi
	setprop sys.usb.config "$saved_config" || return 1
	returned=1
	# Re-read a partition table changed by the computer, while probes are paused.
	blockdev --rereadpt "$DEV/$disk" >&2 || true
	wait_prop sys.usb.state "$saved_config" || return 1
	owned=0
	rm -rf "$STATE"
}

recover() {
	if [ ! -d "$STATE" ]; then [ ! -d "$F" ]; return; fi
	saved_config=$(cat "$STATE/config") && saved_adb=$(cat "$STATE/adb") &&
	saved_product=$(cat "$STATE/product") && saved_label=$(cat "$STATE/label") &&
	disk=$(cat "$STATE/disk") || return 1
	case $disk in mmcblk[0-9]|mmcblk[0-9][0-9]) ;; *) return 1 ;; esac
	owned=1 guard=0 returned=0
	[ ! -e "$SYS/$disk/andr36oid_unlock" ] || guard=1
	# Drain any partially restored init actions before touching g1 again.
	setprop sys.usb.config.recovery_drive.ready 0 || return 1
	setprop sys.usb.configfs 2 || return 1
	setprop sys.usb.config.recovery_drive 1 || return 1
	wait_prop sys.usb.config.recovery_drive.ready 1 || return 1
	cleanup
}

finish() {
	trap '' HUP INT TERM PIPE
	while ! cleanup; do sleep 1; done
}

main() {
	umask 077
	work=$(mktemp -d /tmp/recovery-usb-drive.XXXXXX) || exit 1
	trap 'finish; rm -rf "$work"' EXIT
	trap 'exit 1' HUP INT TERM PIPE
	case ${1:-} in
	recover)
		if recover; then printf 'stopped\n'; else
			printf 'error|cleanup|\n'
			# Recovery keeps its volume lock and offers Retry for this command.
			trap - EXIT
			rm -rf "$work"
			exit 1
		fi
		;;
	list) discover ;;
	mounts)
		if ! plan "$2" "$3" 1 || ! mounts; then
			printf 'error|%s|%s\n' "$error" "$detail"; exit 1
		fi
		;;
	volumes)
		plan "$2" "$3" 1 && numbers >"$work/numbers" || exit 1
		sed 's/:/_/;s/^/public:/' "$work/numbers"
		;;
	session)
		if start_drive "$2" "$3" "$4"; then
			printf 'ready|%s|%s\n' "$ro" "$forced"
		else
			printf 'error|%s|%s\n' "$error" "$detail"
		fi
		while :; do
			# EOF means recovery exited. Its disks must still be returned safely.
			if ! IFS= read -r command; then finish; break; fi
			[ "$command" = stop ] || continue
			if cleanup; then printf 'stopped\n'; break; fi
			printf 'error|cleanup|\n'
		done
		;;
	*) exit 1 ;;
	esac
}

[ "${RECOVERY_DRIVE_TEST:-0}" = 1 ] || main "$@"
