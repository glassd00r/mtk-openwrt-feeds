#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# Copyright (C) 2025 MediaTek Inc.
#
# Usage:
# - enable: ./mt76_sns_dump.sh &
# - disable: killall mt76_sns_dump.sh

do_cmd() {
    local cmd="$1"

    echo "[cmd] $cmd"
    eval $cmd
    echo ""
}

# ---- get_uboot_env_emmc ---------------------------------------------------
# Corresponds to `uci show ubootenv`: extract dev offset envsize secsize
# numsec and join them into a config string in order.
get_uboot_env_emmc() {
	e_dev=''; e_offset=''; e_envsize=''; e_secsize=''; e_numsec=''
	while IFS= read -r line; do
		case "$line" in
			ubootenv.*=*)
				key=${line%%=*}
				key=${key##*.}
				val=${line#*=}
				val=${val#\'}; val=${val%\'}
				case "$key" in
					dev)     e_dev=$val ;;
					offset)  e_offset=$val ;;
					envsize) e_envsize=$val ;;
					secsize) e_secsize=$val ;;
					numsec)  e_numsec=$val ;;
				esac
				;;
		esac
	done <<-EOF
	$(uci show ubootenv 2>/dev/null)
	EOF

	config=''
	for v in "$e_dev" "$e_offset" "$e_envsize" "$e_secsize" "$e_numsec"; do
		[ -n "$v" ] || continue
		if [ -n "$config" ]; then
			config="$config $v"
		else
			config="$v"
		fi
	done

	[ -n "$config" ] || return 1
	printf '%s' "$config"
}

# ---- get_uboot_env_ubi ----------------------------------------------------
# $1: ubi part_num, $2: flash_sector_size
# Scan /sys/class/ubi/ubi<N>/ubi<N>_* for volumes whose name contains ubootenv
get_uboot_env_ubi() {
	part_num=$1
	flash_sector_size=$2
	config=''

	for p in $(ls "/sys/class/ubi/ubi${part_num}" 2>/dev/null | grep "ubi${part_num}_"); do
		name=$(cat "/sys/class/ubi/ubi${part_num}/${p}/name" 2>/dev/null)
		case "$name" in
			*ubootenv*)
				# Handle redundant ubootenv (ubootenv, ubootenv2) multi-line case
				if [ -n "$config" ]; then
					config="$config
/dev/${p} 0x0000 0x20000 ${flash_sector_size}"
				else
					config="/dev/${p} 0x0000 0x20000 ${flash_sector_size}"
				fi
				;;
		esac
	done

	[ -n "$config" ] || return 1
	printf '%s' "$config"
}

# ---- get_uboot_env --------------------------------------------------------
get_uboot_env() {
	if [ -e /dev/mmcblk0 ]; then
		get_uboot_env_emmc
		return $?
	fi

	uboot_line=$(grep '"u-boot-env"' /proc/mtd 2>/dev/null)
	ubi_line=$(grep '"ubi"' /proc/mtd 2>/dev/null)

	if [ -z "$uboot_line" ]; then
		# Full UBI
		[ -n "$ubi_line" ] || return 1
		# e.g. mtd5: 07f80000 00020000 "ubi"
		part_num=$(echo "$ubi_line" | sed -n 's/^mtd\([0-9]*\):.*/\1/p')
		size2=$(echo "$ubi_line" | awk '{print $3}')
		[ -n "$part_num" ] && [ -n "$size2" ] || return 1
		get_uboot_env_ubi "$part_num" "0x$size2"
		return $?
	else
		# NMBM
		# e.g. mtd0: 00080000 00020000 "u-boot-env"
		partition=$(echo "$uboot_line" | awk -F: '{print $1}')
		size2=$(echo "$uboot_line" | awk '{print $3}')
		[ -n "$partition" ] && [ -n "$size2" ] || return 1
		printf '/dev/%s 0x0000 0x20000 0x%s' "$partition" "$size2"
		return 0
	fi
}

# ---- gen_fw_env_config ----------------------------------------------------
gen_fw_env_config() {
	config=$(get_uboot_env)
	[ -n "$config" ] || return 1
	echo "$config" > /etc/fw_env.config
	return 0
}

# ---- get_bootfile ---------------------------------------------------------
get_bootfile() {
	config_generated=0

	if [ ! -e /etc/fw_env.config ]; then
		gen_fw_env_config || return 1
		config_generated=1
	fi

	bootfile=$(fw_printenv bootfile 2>/dev/null)
	case "$bootfile" in
		*bootfile=*) ;;
		*)
			# Might have bad CRC, generate our own fw_env.config
			if [ "$config_generated" = "1" ]; then
				return 1
			fi
			gen_fw_env_config || return 1
			bootfile=$(fw_printenv bootfile 2>/dev/null)
			case "$bootfile" in
				*bootfile=*) ;;
				*) return 1 ;;
			esac
			;;
	esac

	# Print the output returned by `fw_printenv bootfile`
	echo "$bootfile"
	return 0
}

dump_board_info() {
    echo "command timeout: $command_timeout"
    # get bootfile name
    do_cmd "get_bootfile"

    do_cmd "uname -a"
    do_cmd "lspci"
    do_cmd "cat /sys/kernel/debug/ieee80211/phy0/mt76/fw_version"
    do_cmd "cat /sys/kernel/debug/ieee80211/phy0/mt76/eeprom_mode"
    do_cmd "cat /etc/config/wireless"
    do_cmd "cat /etc/config/network"
    do_cmd "iw dev"
    do_cmd "/sbin/mtk_factory_rw.sh -r wan"
}

dump_link_sta_info() {
    local phy="/sys/kernel/debug/ieee80211/phy0"

    ls $phy | grep netdev | awk -F ':' '{print $2}'| while read iface; do
        local base="${phy}/netdev:${iface}"
        [ -d "$base" ] || { echo "[skip] ${base} not found"; continue; }

        local sta_dir="${base}/stations"
        [ -d "$sta_dir" ] || { echo "[skip] ${sta_dir} not found"; continue; }

        for s in "${sta_dir}"/*; do
            [ -d "$s" ] || continue
            local mac
            mac="$(basename "$s")"

            for f in "$s"/link-*/link_sta_info "$s"/link_sta_info; do
                [ -f "$f" ] || continue
                parent="$(basename "$(dirname "$f")")"
                case "$parent" in
                    link-*)
                        echo "=== iface:${iface} mac:${mac} ${parent} ==="
                        ;;
                    *)
                        echo "=== iface:${iface} mac:${mac} (single-link) ==="
                        ;;
                esac
                do_cmd "cat '$f'"
                echo ""
            done
        done
    done
}

dump_mt76_links_info() {
    local phy="/sys/kernel/debug/ieee80211/phy0"

    [ -d "$phy" ] || { echo "[error] $phy not found"; return; }

    for f in "$phy"/*/mt76_links_info; do
        [ -f "$f" ] || continue
        local rel="${f#$phy/}"
        echo "$rel"
        do_cmd "cat '$f'"
        echo ""
    done
}

dump_connection_info() {
    iw dev | awk '
    $1 == "Interface" {iface=$2}
    $1 == "type" {print iface, $2}
    ' | while read iface type; do
    if [ "$type" = "AP" ]; then
        count=$(iw dev "$iface" station dump | grep Station | wc -l)
        echo -e "\033[1m$iface (AP): $count clients\033[0m"
        hostapd_cli -i "$iface" get_disconn_counter
    elif [ "$type" = "STA" ]; then
        echo -e "\033[1m$iface (STA):\033[0m"
        iw dev "$iface" link
    else
        echo "$iface ($type): Skip"
    fi
    done
}

dump_per_vif_sta_info() {
    for i in /sys/kernel/debug/ieee80211/phy0/*/stations/; do
        iface=${i#*netdev:}
        iface=${iface%%/*}
        echo
        echo -e "\033[1m$iface:\033[0m"
        ls -1 $i
        echo $iface total station count: `ls $i | wc -l`
    done
}

dump_fw_timestamp() {
    echo 0x820eb37c > /sys/kernel/debug/ieee80211/phy0/mt76/regidx
    val=$(($(cat /sys/kernel/debug/ieee80211/phy0/mt76/regval)))
    echo "${val%??????}.${val#${val%??????}} (1~2s tolerance)"
}

dump_token_info() {
    do_cmd "cat /sys/kernel/debug/ieee80211/phy0/mt76/token"
}

dump_ple_info() {
    echo $command_timeout > /sys/kernel/debug/ieee80211/phy0/mt76/ple_query_cr
    do_cmd "cat /sys/kernel/debug/ieee80211/phy0/mt76/ple_info"
}

dump_pse_info() {
    do_cmd "cat /sys/kernel/debug/ieee80211/phy0/mt76/pse_info"
}

dump_mib_info() {
    do_cmd "cat /sys/kernel/debug/ieee80211/phy0/mt76/*/mibinfo"
}

dump_drop_stats() {
    do_cmd "cat /sys/kernel/debug/ieee80211/phy0/mt76/tx_drop_stats"
    do_cmd "cat /sys/kernel/debug/ieee80211/phy0/mt76/rx_drop_stats"
}

dump_tr_info() {
    do_cmd "cat /sys/kernel/debug/ieee80211/phy0/mt76/tr_info"
}

dump_twt_info() {
    do_cmd "cat /sys/kernel/debug/ieee80211/phy0/mt76/twt_stats"
}

dump_ser_status() {
    local phy="/sys/kernel/debug/ieee80211/phy0"

    if [ "$command_timeout" = "0" ]
    then
        do_cmd "echo 0 > $phy/mt76/band0/sys_recovery" # FW
        sleep 1
        dmesg | tail -n 200 | grep 'ieee80211 phy0: WM'
    fi
    do_cmd "cat $phy/mt76/band0/sys_recovery" # Driver
}

dump_sta_info() {
    echo $command_timeout > /sys/kernel/debug/ieee80211/phy0/mt76/wtbl_query_cr
    do_cmd "cat /sys/kernel/debug/ieee80211/phy0/mt76/sta_info"
}

dump_wm_info() {
    do_cmd "cat /sys/kernel/debug/ieee80211/phy0/mt76/fw_wm_info"
}

dump_wed_rxinfo() {
    do_cmd "cat /sys/kernel/debug/wed0/rxinfo"
    do_cmd "cat /sys/kernel/debug/wed1/rxinfo" #Eagle
}

dump_wed_txinfo() {
    do_cmd "cat /sys/kernel/debug/wed0/txinfo"
    do_cmd "cat /sys/kernel/debug/wed1/txinfo" #Eagle
}

dump_wed_cfg() {
    do_cmd "cat /sys/kernel/debug/wed0/cfg"
    do_cmd "cat /sys/kernel/debug/wed1/cfg" #Eagle
}

per_10_min_work() {
    do_cmd "dump_fw_timestamp"
    [ "$command_timeout" = "0" ] && do_cmd "dump_connection_info"
    do_cmd "dump_per_vif_sta_info"
    dump_sta_info

    local i=0
    local max=3
    while [ $i -lt $max ]
    do
        dump_token_info
        dump_ple_info
        dump_pse_info
        dump_mib_info
        dump_tr_info
        dump_wed_rxinfo
        dump_wed_txinfo

        true $(( i++ ))
        sleep 1
    done
}

per_30_min_work() {
    dump_drop_stats
    dump_twt_info
    dump_ser_status
    dump_link_sta_info
}

per_60_min_work() {
    dump_mt76_links_info

    local i=0
    local max=2
    while [ $i -lt $max ]
    do
        dump_wm_info
        dump_wed_cfg

        true $(( i++ ))
        sleep 1
    done
}

counter=0
command_timeout=0
[ $(dmesg | grep -c -e 'Message .* (seq.*) timeout' \
                    -e 'Failed to send scs mcu cmd' \
                    -e 'Failed to update noise floor') -gt 3 ] && command_timeout=1
dump_board_info

while true; do
    echo "===== $(date '+%Y-%m-%d %H:%M:%S') ====="
    command_timeout=0
    [ $(dmesg | grep -c -e 'Message .* (seq.*) timeout' \
                        -e 'Failed to send scs mcu cmd' \
                        -e 'Failed to update noise floor') -gt 3 ] && command_timeout=1
    # works for every 10-minute
    per_10_min_work

    # works for every 30-minute
    if [ $(( $counter % 3 )) -eq "0" ]; then
        per_30_min_work
    fi

    # works for every 60-minute
    if [ $(( $counter % 6 )) -eq "0" ]; then
        per_60_min_work
    fi

    echo ""
    sleep 600

    counter=$(( (counter + 1) ))
done
