#!/bin/sh
# Fake sysfs, configfs, mounts and init. No host storage command is reachable.
# shellcheck disable=SC2218,SC2034,SC2154
set -eu
HERE=$(cd "$(dirname "$0")/.." && pwd)
T=$1
RECOVERY_DRIVE_TEST=1
RECOVERY_DRIVE_SYS=$T/sys RECOVERY_DRIVE_DEV=$T/dev RECOVERY_DRIVE_GADGET=$T/gadget
RECOVERY_DRIVE_MOUNTS=$T/mountinfo RECOVERY_DRIVE_CMDLINE=$T/cmdline
RECOVERY_DRIVE_STATE=$T/state
RECOVERY_DRIVE_OTG=$T/otg_mode
export RECOVERY_DRIVE_TEST RECOVERY_DRIVE_SYS RECOVERY_DRIVE_DEV RECOVERY_DRIVE_GADGET
export RECOVERY_DRIVE_MOUNTS RECOVERY_DRIVE_CMDLINE RECOVERY_DRIVE_STATE RECOVERY_DRIVE_OTG
# shellcheck disable=SC1091
. "$HERE/tools/recovery_usb_drive.sh"

count=0
check() { count=$((count + 1)); "$@" || { echo "FAIL ($count): $*" >&2; exit 1; }; }
reject() { count=$((count + 1)); if "$@"; then echo "FAIL ($count): accepted $*" >&2; exit 1; fi; }
block_node() { [ -f "$DEV/$1" ]; }
source_node() { [ "$1" = "$T/ntfs-source" ]; }
source_numbers() { printf 'b3:27\n'; }
mktemp() { command mktemp -d "$T/session.XXXXXX"; }
sync() { echo sync >>"$T/log"; }
sleep() { printf 'sleep %s\n' "$1" >>"$T/log"; }
blockdev() { printf 'rescan %s\n' "$2" >>"$T/log"; }
getprop() { cat "$T/props/$1" 2>/dev/null || true; }
setprop() {
	printf 'prop %s %s\n' "$1" "$2" >>"$T/log"
	printf '%s\n' "$2" >"$T/props/$1"
	case $1:$2 in
	sys.usb.config.recovery_drive:1)
		[ "$fail_gate" = 0 ] || return 0
		printf 'stopped\n' >"$T/props/init.svc.adbd"
		printf 'none\n' >"$G/UDC"
		rm -f "$G/configs/b.1/f1"
		printf '1\n' >"$T/props/sys.usb.config.recovery_drive.ready"
		printf 'ack\n' >>"$T/log"
		;;
	sys.usb.configfs:1) printf 'none\n' >"$T/props/sys.usb.state" ;;
	sys.usb.config:*)
		[ "$2" != adb ] || [ "$fail_adb" = 0 ] || return 0
		printf '%s\n' "$2" >"$T/props/sys.usb.state"
		;;
	esac
}
mkdir() {
	command mkdir "$@" || return 1
	if [ "$#" = 1 ] && [ "$1" = "$F" ]; then command mkdir "$F/lun.0"; fi
}
rmdir() {
	printf 'rmdir %s\n' "$1" >>"$T/log"
	[ "$fail_close" = 0 ] || return 1
	if [ "$1" = "$F" ]; then command rm -rf "$F/lun.0"; fi
	command rm -f "$1/file" "$1/ro" "$1/removable"
	command rmdir "$1"
}
put() {
	printf 'write %s %s\n' "$1" "$2" >>"$T/log"
	case $1:$2 in
	*/UDC:none)
		[ "$fail_unbind" = 0 ] || return 1
		if [ "$unbind_race" = 1 ]; then : >"$1"; return 1; fi
		[ "$(cat "$1")" != none ] && [ -n "$(cat "$1")" ] || return 1
		printf 'none\n' >"$1" ;;
	*/UDC:ff300000.usb)
		bind_attempts=$((bind_attempts + 1))
		[ "$bind_attempts" -gt "$fail_binds" ] || return 1
		[ "$bad_readback" = 0 ] || return 0
		printf '%s\n' "$2" >"$1" ;;
	*/otg_mode:peripheral)
		[ "$fail_role" = 0 ] || return 1
		printf '%s\n' "$2" >"$1" ;;
	*/otg_mode:host)
		[ "$fail_restore_role" = 0 ] || return 1
		printf '%s\n' "$2" >"$1" ;;
	*/andr36oid_unlock:unlock*)
		[ "$fail_unlock" = 0 ] || return 1
		printf 'unlocked\n' >"$1" ;;
	*/andr36oid_unlock:lock)
		[ "$fail_lock" = 0 ] || return 1
		printf 'locked\n' >"$1" ;;
	*/lun.*/file:*)
		[ -z "$2" ] || [ "$fail_file" = 0 ] || return 1
		printf '%s\n' "$2" >"$1"
		if [ -n "$2" ] && [ "$late_mount" = 1 ]; then
			printf '9 1 179:39 / /late rw - ext4 /dev/root rw\n' >>"$MOUNTS"
		fi
		if [ -n "$2" ] && [ "$replace_card" = 1 ]; then
			printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n' >"$SYS/$disk/device/cid"
		fi
		;;
	*) printf '%s\n' "$2" >"$1" ;;
	esac
}
umount() {
	printf 'umount %s\n' "$1" >>"$T/log"
	[ "$fail_unmount" = 0 ] || return 1
	[ "$keep_mounted" = 0 ] || return 0
	encoded=$(printf '%s' "$1" | sed 's/ /\\040/g')
	POINT=$encoded awk '$5!=ENVIRON["POINT"]' "$MOUNTS" >"$T/newmounts"
	mv "$T/newmounts" "$MOUNTS"
}
reset_fixture() {
	fail_gate=0 fail_adb=0
	command rm -rf "$T"
	command mkdir -p "$SYS" "$DEV" "$G/configs/b.1/strings/0x409" "$G/functions/ffs.adb" "$T/props" "$T/work"
	work=$T/work
	: >"$T/log"; : >"$MOUNTS"
	for spec in '0 ff370000.dwmmc 0 SD' '1 ff380000.dwmmc 32 SD' '2 ff390000.dwmmc 64 MMC'; do
		# shellcheck disable=SC2086
		set -- $spec
		command mkdir -p "$T/platform/$2/mmc_host/block/mmcblk$1/device" "$T/platform/$2/mmc_host/block/mmcblk$1/holders"
		ln -s "$T/platform/$2/mmc_host/block/mmcblk$1" "$SYS/mmcblk$1"
		printf '0123456789abcdef0123456789abcde%s\n' "$1" >"$SYS/mmcblk$1/device/cid"
		printf '%s\n' "$4" >"$SYS/mmcblk$1/device/type"
		printf '33554432\n' >"$SYS/mmcblk$1/size"
		printf '0\n' >"$SYS/mmcblk$1/ro"
		printf '179:%s\n' "$3" >"$SYS/mmcblk$1/dev"
		: >"$DEV/mmcblk$1"
		for part in 2 6 7; do
			command mkdir -p "$SYS/mmcblk$1/mmcblk${1}p$part/holders"
			ln -s "$SYS/mmcblk$1/mmcblk${1}p$part" "$SYS/mmcblk${1}p$part"
			printf '%s\n' "$part" >"$SYS/mmcblk${1}p$part/partition"
			printf '179:%s\n' "$(($3 + part))" >"$SYS/mmcblk${1}p$part/dev"
		done
	done
	for boot in 0 1; do
		command mkdir -p "$SYS/mmcblk2boot$boot/holders"
		printf '1\n' >"$SYS/mmcblk2boot$boot/force_ro"
		printf '179:%s\n' "$((96 + boot * 32))" >"$SYS/mmcblk2boot$boot/dev"
		: >"$DEV/mmcblk2boot$boot"
	done
	printf 'locked\n' >"$SYS/mmcblk2/andr36oid_unlock"
	printf 'host\n' >"$OTG"
	printf 'androidboot.boot_devices=ff370000.dwmmc dw_mmc_rockchip.builtin_emmc=1\n' >"$CMDLINE"
	printf '0xD001\n' >"$G/idProduct"
	printf 'adb\n' >"$G/configs/b.1/strings/0x409/configuration"
	printf 'ff300000.usb\n' >"$G/UDC"
	ln -s "$G/functions/ffs.adb" "$G/configs/b.1/f1"
	setprop sys.usb.configfs 1
	setprop sys.usb.config adb
	setprop sys.usb.controller ff300000.usb
	setprop init.svc.adbd running
	owned=0 guard=0 returned=0
	fail_unlock=0 fail_file=0 fail_close=0 fail_unmount=0 keep_mounted=0
	fail_gate=0 fail_adb=0 late_mount=0 replace_card=0
	fail_binds=0 bind_attempts=0 fail_unbind=0 unbind_race=0 bad_readback=0
	fail_role=0 fail_restore_role=0 fail_lock=0
}
select_disk() { target=$1; target_cid=$(cat "$SYS/$1/device/cid"); }
start() { prepare_drive "$target" "$target_cid" "${1:-0}" && start_drive; }
protocol() { sed '/^log|/d'; }
locked() {
	[ "$(cat "$SYS/mmcblk2/andr36oid_unlock")" = locked ] &&
	[ "$(cat "$SYS/mmcblk2boot0/force_ro")" = 1 ] &&
	[ "$(cat "$SYS/mmcblk2boot1/force_ro")" = 1 ]
}

reset_fixture
check test "$(discover | wc -l)" = 3
check identify mmcblk0
check test "$slot:$boot:$forced" = 1:1:none
check identify mmcblk1
check test "$slot:$boot:$forced" = 2:0:none
check identify mmcblk2
check test "$slot:$forced" = 3:none
reject identify mmcblk0p7
reject identify ../../etc/passwd
rm "$SYS/mmcblk2/andr36oid_unlock"
check test "$(discover | wc -l)" = 2
reset_fixture
rm "$DEV/mmcblk1"
check test "$(discover | wc -l)" = 2
reset_fixture
printf '0\n' >"$SYS/mmcblk1/size"
reject identify mmcblk1
printf 'bad\n' >"$SYS/mmcblk1/size"
reject identify mmcblk1
reset_fixture
printf 'bad\n' >"$SYS/mmcblk1/device/cid"
reject identify mmcblk1
reset_fixture
rm "$DEV/mmcblk2boot1"
reject identify mmcblk2
reset_fixture
# Block numbering does not determine the physical slot.
mv "$SYS/mmcblk0" "$SYS/mmcblk8"
mv "$DEV/mmcblk0" "$DEV/mmcblk8"
check identify mmcblk8
check test "$slot:$boot" = 1:1
reset_fixture
select_disk mmcblk0
check start
check test "$(cat "$F/lun.0/file")" = "$DEV/mmcblk0"
check test "$(cat "$F/lun.0/ro")" = 0
check test "$(cat "$F/lun.0/removable")" = 1
check cleanup
check test ! -d "$F"
check test "$(getprop sys.usb.configfs)" = 1
check test "$(getprop sys.usb.config)" = adb
check test "$(cat "$G/idProduct")" = 0xD001
check test "$(cat "$G/configs/b.1/strings/0x409/configuration")" = adb
reset_fixture
select_disk mmcblk1
printf '1 0 179:39 / /storage/card rw - ext4 /dev/block/volmgr/public:179_39 rw\n2 1 179:39 /games /storage/card/games ro - ext4 /dev/root ro\n3 0 179:38 / /cache rw - ext4 /dev/root rw\n4 0 179:6 / /data rw - ext4 /dev/root rw\n' >"$MOUNTS"
check start 1
check test "$(sed -n '/^umount /p' "$T/log" | head -1)" = 'umount /storage/card/games'
check test "$(wc -l <"$MOUNTS")" = 1
check test "$(cat "$F/lun.0/ro")" = 1
check cleanup
reset_fixture
select_disk mmcblk1
printf '1 0 179:39 / /storage/card rw - ext4 /dev/root rw\n' >"$MOUNTS"
fail_unmount=1
reject start
check test "$error:$detail" = busy:/storage/card
check test ! -d "$F"
check cleanup
fail_unmount=0 keep_mounted=1
reject start
check test "$error" = busy
reset_fixture
select_disk mmcblk1
command mkdir -p "$SYS/dm-0/holders"
printf '253:0\n' >"$SYS/dm-0/dev"
ln -s "$SYS/dm-0" "$SYS/mmcblk1p6/holders/dm-0"
printf '1 0 253:0 / /data rw - ext4 /dev/mapper/data rw\n' >"$MOUNTS"
reject start
check test "$(wc -l <"$MOUNTS")" = 0
check test "$error:$detail" = busy:dm-0
reset_fixture
select_disk mmcblk1
printf '%s\n' '1 0 179:39 / /storage/My\040Card rw - ext4 /dev/root rw' >"$MOUNTS"
check start
check test "$(sed -n '/^umount /p' "$T/log")" = 'umount /storage/My Card'
check cleanup
reset_fixture
select_disk mmcblk1
rm "$MOUNTS"
reject start
check test "$error" = busy
reset_fixture
select_disk mmcblk1
fail_gate=1
reject start
check test "$failed_step" = gate_init
reject cleanup
check test -d "$STATE"
check test "$(cat "$OTG")" = host
fail_gate=0
check recover
reset_fixture
select_disk mmcblk1
late_mount=1
reject start
check test "$error" = busy
check cleanup
reset_fixture
select_disk mmcblk1
replace_card=1
reject start
check test "$error" = changed
check cleanup
reset_fixture
select_disk mmcblk2
check start
for lun in 0 1 2; do check test "$(cat "$F/lun.$lun/ro")" = 0; done
check test "$(cat "$F/lun.1/file")" = "$DEV/mmcblk2boot0"
check test "$(cat "$F/lun.2/file")" = "$DEV/mmcblk2boot1"
check test "$(cat "$SYS/mmcblk2/andr36oid_unlock")" = unlocked
check test "$(cat "$SYS/mmcblk2boot0/force_ro")" = 0
check test "$(cat "$SYS/mmcblk2boot1/force_ro")" = 0
check cleanup
check locked
check test "$(awk '/^sync$/ {s=NR} /andr36oid_unlock lock$/ {l=NR} /^rescan / {r=NR} END {print (s<l && l<r)}' "$T/log")" = 1
reset_fixture
select_disk mmcblk2
check start 1
for lun in 0 1 2; do check test "$(cat "$F/lun.$lun/ro")" = 1; done
check locked
check cleanup
reset_fixture
select_disk mmcblk2
printf 'androidboot.boot_devices=ff390000.dwmmc dw_mmc_rockchip.builtin_emmc=system\n' >"$CMDLINE"
check start
check test "$forced:$ro" = system:1
check test "$(sed -n '/andr36oid_unlock unlock /p' "$T/log" | wc -l)" = 0
check locked
check cleanup
reset_fixture
select_disk mmcblk2
: >"$CMDLINE"
check start
check test "$forced:$ro" = unknown:1
check test "$(sed -n '/andr36oid_unlock unlock /p' "$T/log" | wc -l)" = 0
check cleanup
reset_fixture
select_disk mmcblk2
fail_unlock=1
check start
check test "$forced:$ro" = unlock:1
for lun in 0 1 2; do check test "$(cat "$F/lun.$lun/ro")" = 1; done
check cleanup
check locked
reset_fixture
select_disk mmcblk2
fail_file=1
reject start
check cleanup
check locked
check test ! -d "$F"
reset_fixture
select_disk mmcblk2
check start
fail_close=1
reject cleanup
check locked
check test "$(getprop sys.usb.configfs)" = 2
check test -d "$F"
fail_close=0
check cleanup
reset_fixture
select_disk mmcblk1
setprop sys.usb.config none
setprop init.svc.adbd stopped
check start
check cleanup
check test "$(getprop sys.usb.config)" = none
reset_fixture
select_disk mmcblk1
check start
fail_adb=1
reject cleanup
check test ! -d "$F"
before=$(wc -l <"$T/log")
fail_adb=0
setprop sys.usb.state adb
check cleanup
check test "$(wc -l <"$T/log")" = "$((before + 1))"
reset_fixture
select_disk mmcblk2
check start
# Simulate a helper killed without running its traps.
unset saved_config saved_adb saved_product saved_label disk
owned=0 guard=0 returned=0
check recover
check locked
check test ! -d "$STATE"
check test ! -d "$F"
reset_fixture
select_disk mmcblk1
printf '1 0 0:42 / /storage/ntfs rw - fuseblk %s/ntfs-source rw\n' "$T" >"$MOUNTS"
check start
check test "$(wc -l <"$MOUNTS")" = 0
check test "$(sed -n '/^umount /p' "$T/log")" = 'umount /storage/ntfs'
check cleanup
reset_fixture
select_disk mmcblk1
printf 'unreadable mount record\n' >"$MOUNTS"
reject start
check test "$error" = busy
reset_fixture
select_disk mmcblk1
printf '1\n' >"$SYS/mmcblk1/ro"
check start
check test "$ro:$forced" = 1:locked
check cleanup
reset_fixture
select_disk mmcblk2
printf '1 0 179:96 / /boot-area ro - vfat /dev/root ro\n' >"$MOUNTS"
fail_unmount=1
reject start
check test "$error:$detail" = busy:/boot-area
reset_fixture
select_disk mmcblk2
output=$(printf 'start\nstop\n' | (main session "$target" "$target_cid" 0) | protocol)
check test "$(printf '%s\n' "$output" | head -1)" = gated
check test "$(printf '%s\n' "$output" | sed -n '2p')" = 'ready|0|none'
check test "$(printf '%s\n' "$output" | tail -1)" = stopped
check locked
check test ! -d "$F"
check test ! -d "$STATE"
reset_fixture
select_disk mmcblk2
output=$(printf 'start\n' | (main session "$target" "$target_cid" 0) | protocol)
check test "$output" = "$(printf 'gated\nready|0|none')"
check locked
check test ! -d "$F"
check test ! -d "$STATE"
reset_fixture
select_disk mmcblk1
printf '1 0 179:39 / /storage/card rw - ext4 /dev/root rw\n' >"$MOUNTS"
check start
# shellcheck disable=SC2016
check awk -v g="$G" -v role="$OTG" -v dev="$DEV" '
    $0=="ack" {a=NR}
    $1=="umount" {u=NR}
    $0=="write " g "/functions/mass_storage.recovery/lun.0/file " dev "/mmcblk1" {l=NR}
    $0=="sleep 0.2" {d=NR}
    $0=="write " role " peripheral" {p=NR}
    $0=="sleep 0.5" {s=NR}
    $0=="write " g "/UDC ff300000.usb" {b=NR}
    END {exit !(0<a && a<u && u<l && l<d && d<p && p<s && s<b)}' "$T/log"
check cleanup
check test "$(cat "$OTG")" = host
# shellcheck disable=SC2016
check awk -v g="$G" -v role="$OTG" '
    $0=="write " g "/UDC none" {u=NR}
    $0=="write " g "/functions/mass_storage.recovery/lun.0/file " {c=NR}
    $0=="sync" {s=NR}
    $0=="write " role " host" {r=NR}
    $0=="prop sys.usb.configfs 1" {p=NR}
    END {exit !(u<c && c<s && s<r && r<p)}' "$T/log"
reset_fixture
select_disk mmcblk1
fail_binds=3
check start
check test "$bind_attempts" = 4
check cleanup
reset_fixture
select_disk mmcblk1
fail_binds=10
check start
check test "$bind_attempts" = 11
check test "$(sed -n '\|/UDC none$|p' "$T/log" | wc -l)" = 1
check cleanup
reset_fixture
select_disk mmcblk2
fail_binds=20
reject start
check test "$bind_attempts:$failed_step" = 20:bind_udc
check test "$(getprop sys.usb.configfs)" = 2
check cleanup
check locked
check test "$(cat "$OTG")" = host
check test "$(getprop sys.usb.config)" = adb
check test ! -d "$STATE"
reset_fixture
select_disk mmcblk1
bad_readback=1
reject start
check test "$bind_attempts:$failed_step" = 20:bind_udc
check cleanup
reset_fixture
select_disk mmcblk1
fail_role=1
reject start
check test "$bind_attempts:$failed_step" = 0:device_role
check test "$(cat "$OTG")" = host
check cleanup
reset_fixture
select_disk mmcblk1
check start
fail_restore_role=1
reject cleanup
check test "$failed_step" = restore_role
check test "$(getprop sys.usb.configfs)" = 2
fail_restore_role=0
check recover
check test "$(cat "$OTG")" = host
reset_fixture
select_disk mmcblk1
printf 'peripheral\n' >"$OTG"
check start
check cleanup
check test "$(cat "$OTG")" = peripheral
reset_fixture
select_disk mmcblk1
rm "$OTG"
check start
check cleanup
check test ! -e "$OTG"
reset_fixture
printf 'none\n' >"$G/UDC"
check unbind
check unbind retry
check test "$(cat "$G/UDC")" = none
: >"$G/UDC"
check unbind
check unbind retry
printf 'ff300000.usb\n' >"$G/UDC"
unbind_race=1
check unbind
check test ! -s "$G/UDC"
reset_fixture
select_disk mmcblk2
check start
fail_unbind=1
reject cleanup
check test "$failed_step" = unbind
check locked
check test -d "$F"
check test -d "$STATE"
check test "$(getprop sys.usb.configfs)" = 2
fail_unbind=0
check cleanup
reset_fixture
select_disk mmcblk2
check start
fail_lock=1
reject cleanup
check test "$failed_step" = lock_emmc
check test "$(cat "$SYS/mmcblk2boot0/force_ro")" = 1
check test "$(cat "$SYS/mmcblk2boot1/force_ro")" = 1
check test "$(getprop sys.usb.configfs)" = 2
fail_lock=0
check cleanup
reset_fixture
select_disk mmcblk1
# Enable ADB can leave the requested configuration at none.
setprop sys.usb.config none
setprop init.svc.adbd running
check start
check cleanup
check test "$(getprop sys.usb.config)" = adb
reset_fixture
select_disk mmcblk2
# Stop before Start closes a gated session without opening a LUN or changing roles.
output=$(printf 'stop\n' | (main session "$target" "$target_cid" 0) | protocol)
check test "$output" = "$(printf 'gated\nstopped')"
check test "$(cat "$OTG")" = host
check locked
check test ! -d "$STATE"
reset_fixture
select_disk mmcblk2
fail_binds=20
output=$(printf 'start\nstop\n' | (main session "$target" "$target_cid" 0) | protocol)
check test "$output" = "$(printf 'gated\nerror|setup||bind_udc\nstopped')"
check locked
check test ! -d "$STATE"
reset_fixture
select_disk mmcblk2
fail_close=1
# A cleanup failure exits after one attempt, retains its journal and reports the step.
if (printf 'start\nstop\n' | (main session "$target" "$target_cid" 0)) >"$T/output"; then
    echo 'FAIL: cleanup error returned success' >&2; exit 1
fi
check test "$(protocol <"$T/output" | tail -1)" = 'error|cleanup||close_drive'
check test "$(sed -n '/^sync$/p' "$T/log" | wc -l)" = 1
check locked
check test -d "$STATE"
fail_close=0
check recover
reset_fixture
select_disk mmcblk2
fail_close=1
if (printf 'start\n' | (main session "$target" "$target_cid" 0)) >"$T/output"; then
    echo 'FAIL: EOF cleanup error returned success' >&2; exit 1
fi
check test "$(sed -n '/^sync$/p' "$T/log" | wc -l)" = 1
check locked
fail_close=0
check recover
echo "$count recovery USB drive checks passed ($0)"
