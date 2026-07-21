#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# Copyright (C) 2026 MediaTek Inc. All rights reserved.
# Author: Sam Shih <sam.shih@mediatek.com>
# Rules for Kernel debug features
#   loglevel=<n> Console log level - override the default console log level (1-15)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
# Base default loglevel. Change this only by editing this file.
DEFAULT_LOGLEVEL=6

# Current default loglevel for this build. May be overridden by debug APIs.
current_default_loglevel="${DEFAULT_LOGLEVEL}"

set_kernel_loglevel() {
	local __ll="$1"

	kernel_config_disable CONFIG_CONSOLE_LOGLEVEL_DEFAULT
	kernel_config_enable CONFIG_CONSOLE_LOGLEVEL_DEFAULT "${__ll}"
}

set_current_default_loglevel() {
	local __ll="$1"

	case "${__ll}" in
		[1-9]|1[0-5])
			current_default_loglevel="${__ll}"
			;;
		*)
			echo "WARNING: default loglevel='${__ll}' outside 1-15, keep ${current_default_loglevel}"
			;;
	esac
}

apply_loglevel() {
	local __ll

	if test x"${loglevel_set}" = x"yes"; then
		case "${loglevel}" in
			[1-9]|1[0-5])
				__ll="${loglevel}"
				;;
			*)
				echo "WARNING: loglevel='${loglevel}' outside 1-15, use ${current_default_loglevel} instead"
				__ll="${current_default_loglevel}"
				;;
		esac
	else
		__ll="${current_default_loglevel}"
	fi

	set_kernel_loglevel "${__ll}"
}

# ---------------------------------------------------------------------------
# Parameter wiring
# ---------------------------------------------------------------------------
list_add_after $(hooks autobuild_prepare) platform_change_kernel_config apply_loglevel

help_add_line "  loglevel=<n> - Set default console log level (1-15; >=8 shows all). Overrides build defaults."

