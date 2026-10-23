#!/system/bin/sh
# shellcheck shell=ksh
# Recovery owns g1 for one session. stdin closing also returns the storage.

SYS=${RECOVERY_DRIVE_SYS:-/sys/class/block}
DEV=${RECOVERY_DRIVE_DEV:-/dev/block}
G=${RECOVERY_DRIVE_GADGET:-/config/usb_gadget/g1}
MOUNTS=${RECOVERY_DRIVE_MOUNTS:-/proc/self/mountinfo}
CMDLINE=${RECOVERY_DRIVE_CMDLINE:-/proc/cmdline}
STATE=${RECOVERY_DRIVE_STATE:-/tmp/recovery-usb-drive-state}
OTG=${RECOVERY_DRIVE_OTG:-/sys/devices/platform/ff2c0000.syscon/ff2c0000.syscon:usb2-phy@100/otg_mode}
F=$G/functions/mass_storage.recovery

log_step() { printf 'log|%s\n' "$*"; }
put() {
	log_step "write: $1 <- $2"
	printf '%s\n' "$2" >"$1" || { log_step "write failed: $1"; return 1; }
}
block_node() { [ -b "$DEV/$1" ]; }
fail() { error=$1; detail=${2:-}; return 1; }
step() {
	log_step "$*"
	"$@" || {
		[ -n "${failed_step:-}" ] || failed_step=$1
		log_step "failed: $1 (${error:-setup}) ${detail:-}"
		return 1
	}
}
reply_error() {
	# Mount lists can contain several paths; keep each protocol reply on one line.
	detail=$(printf '%s' "$detail" | tr '\n|' '  ')
	printf 'error|%s|%s|%s\n' "$error" "$detail" "$failed_step"
}

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

gate_gadget() {
	[ "$(getprop sys.usb.configfs)" = 1 ] || return 1
	[ ! -d "$F" ] || return 1
	controller=$(getprop sys.usb.controller)
	[ -n "$controller" ] || return 1
	saved_config=$(getprop sys.usb.config)
	saved_adb=$(getprop init.svc.adbd)
	saved_product=$(cat "$G/idProduct") || return 1
	saved_label=$(cat "$G/configs/b.1/strings/0x409/configuration") || return 1
	saved_role=none
	if [ -e "$OTG" ]; then
		saved_role=$(cat "$OTG") || return 1
		case $saved_role in host|peripheral|otg) ;; *) return 1 ;; esac
	fi
	# A new helper can finish cleanup if this one is killed without its traps.
	mkdir "$STATE" || return 1
	for key in config adb product label disk role; do
		case $key in
		config) value=$saved_config ;; adb) value=$saved_adb ;;
		product) value=$saved_product ;; label) value=$saved_label ;; disk) value=$disk ;;
		role) value=$saved_role ;;
		esac
		if ! put "$STATE/$key" "$value"; then rm -rf "$STATE"; return 1; fi
	done
	owned=1
	step gate_init
}

gate_init() {
	setprop sys.usb.config.recovery_drive.ready 0 || return 1
	setprop sys.usb.configfs 2 || return 1
	setprop sys.usb.config.recovery_drive 1 || return 1
	wait_prop sys.usb.config.recovery_drive.ready 1 || return 1
	wait_prop init.svc.adbd stopped || return 1
	log_step 'gate_init: acknowledged, adbd stopped'
}

prepare_drive() {
	error=setup detail='' failed_step=''
	step plan "$1" "$2" "$3" || return 1
	step gate_gadget
}

configure_drive() {
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
	step check_drive || return 1
	ln -s "$F" "$G/configs/b.1/f1"
}

check_drive() {
	# Refuse both a replacement card and a mount made during setup or retries.
	[ "$(cat "$SYS/$disk/device/cid")" = "$cid" ] || { fail changed; return 1; }
	points=$(mounts) || { fail busy; return 1; }
	[ -z "$points" ] || { fail busy "$points"; return 1; }
}

device_role() {
	sleep 0.2
	if [ "$saved_role" != none ]; then
		put "$OTG" peripheral || return 1
		[ "$(cat "$OTG")" = peripheral ] || return 1
	fi
	log_step 'device_role: settling'
	sleep 0.5
}

bind_udc() {
	attempt=0
	while [ "$attempt" -lt 20 ]; do
		check_drive || return 1
		attempt=$((attempt + 1))
		log_step "bind_udc: attempt $attempt"
		if put "$G/UDC" "$controller" && [ "$(cat "$G/UDC")" = "$controller" ]; then
			log_step "bind_udc: bound $controller"
			return 0
		fi
		log_step "bind_udc: attempt $attempt failed"
		if [ "$attempt" = 10 ]; then step unbind retry || return 1; fi
		sleep 0.2
	done
	return 1
}

start_drive() {
	step unmount_disk || return 1
	step unbind || return 1
	step configure_drive || return 1
	step device_role || return 1
	step bind_udc || return 1
	log_step sharing
}

lock_emmc() {
	locked=1
	put "$SYS/$disk/andr36oid_unlock" lock || locked=0
	[ "$(cat "$SYS/$disk/andr36oid_unlock")" = locked ] || locked=0
	for n in "${disk}boot0" "${disk}boot1"; do
		put "$SYS/$n/force_ro" 1 || locked=0
	done
	[ "$locked" = 1 ]
}

unbind() {
	bound=$(cat "$G/UDC") || return 1
	# This kernel returns ENODEV when an already unbound gadget is unbound again.
	case $bound in ''|none) [ "${1:-}" = retry ] || return 0 ;; esac
	put "$G/UDC" none || log_step 'unbind: write failed, checking for already unbound gadget'
	bound=$(cat "$G/UDC") || return 1
	case $bound in ''|none) return 0 ;; *) return 1 ;; esac
}

close_drive() {
	[ "${owned:-0}" = 1 ] || return 0
	step wait_prop sys.usb.config.recovery_drive.ready 1 || return 1
	step wait_prop init.svc.adbd stopped || return 1
	step unbind || return 1
	rm -f "$G/configs/b.1/f1" || return 1
	for lun in "$F"/lun.*; do
		[ ! -d "$lun" ] || put "$lun/file" '' || return 1
	done
	for lun in "$F/lun.2" "$F/lun.1"; do
		[ ! -d "$lun" ] || rmdir "$lun" || return 1
	done
	[ ! -d "$F" ] || rmdir "$F" || return 1
}

restore_role() {
	[ "$saved_role" != none ] || return 0
	[ "$(cat "$OTG")" = "$saved_role" ] || put "$OTG" "$saved_role" || return 1
	[ "$(cat "$OTG")" = "$saved_role" ]
}

restore_usb() {
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
}

rescan() { blockdev --rereadpt "$DEV/$disk" >&2 || log_step "rescan: failed for $disk"; }

cleanup() {
	error=cleanup detail='' failed_step=''
	if [ "${returned:-0}" = 1 ]; then
		step wait_prop sys.usb.state "$saved_config" || return 1
		owned=0
		rm -rf "$STATE"
		return 0
	fi
	closed=1 cleanup_ok=1
	step close_drive || closed=0
	if [ "${owned:-0}" = 1 ]; then step sync || cleanup_ok=0; fi
	# Close the write window even if configfs detach failed.
	if [ "${guard:-0}" = 1 ]; then step lock_emmc || cleanup_ok=0; fi
	[ "$closed:$cleanup_ok" = 1:1 ] || return 1
	[ "${owned:-0}" = 1 ] || return 0
	step restore_role || return 1
	step restore_usb || return 1
	# Re-read a partition table changed by the computer, while probes are paused.
	step rescan
	step wait_prop sys.usb.state "$saved_config" || return 1
	owned=0
	rm -rf "$STATE"
	log_step stopped
}

recover() {
	error=cleanup detail='' failed_step=''
	if [ ! -d "$STATE" ]; then [ ! -d "$F" ]; return; fi
	saved_config=$(cat "$STATE/config") && saved_adb=$(cat "$STATE/adb") &&
	saved_product=$(cat "$STATE/product") && saved_label=$(cat "$STATE/label") &&
	disk=$(cat "$STATE/disk") && saved_role=$(cat "$STATE/role") || return 1
	case $disk in mmcblk[0-9]|mmcblk[0-9][0-9]) ;; *) return 1 ;; esac
	case $saved_role in none|host|peripheral|otg) ;; *) return 1 ;; esac
	owned=1 guard=0 returned=0
	[ ! -e "$SYS/$disk/andr36oid_unlock" ] || guard=1
	# Drain any partially restored init actions before touching g1 again.
	step gate_init || return 1
	cleanup
}

finish() {
	trap '' HUP INT TERM PIPE
	[ "${finished:-0}" != 1 ] || return 0
	finished=1
	cleanup
}

main() {
	umask 077
	work=$(mktemp -d /tmp/recovery-usb-drive.XXXXXX) || exit 1
	finished=0
	trap 'finish; rm -rf "$work"' EXIT
	trap 'exit 1' HUP INT TERM PIPE
	case ${1:-} in
	recover)
		if step recover; then finished=1; printf 'stopped\n'; else
			reply_error
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
		prepared=0
		if prepare_drive "$2" "$3" "$4"; then
			prepared=1
			printf 'gated\n'
		else
			reply_error
		fi
		while :; do
			# EOF means recovery exited. Its disks must still be returned safely.
			if ! IFS= read -r command; then finish || exit 1; break; fi
			if [ "$command" = start ] && [ "$prepared" = 1 ]; then
				prepared=0
				if start_drive; then printf 'ready|%s|%s\n' "$ro" "$forced"; else reply_error; fi
				continue
			fi
			[ "$command" = stop ] || continue
			if finish; then printf 'stopped\n'; break; fi
			reply_error
			exit 1
		done
		;;
	*) exit 1 ;;
	esac
}

[ "${RECOVERY_DRIVE_TEST:-0}" = 1 ] || main "$@"
