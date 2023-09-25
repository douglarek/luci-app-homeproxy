#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# Copyright (C) 2022-2023 ImmortalWrt.org

NAME="homeproxy"

RESOURCES_DIR="/etc/$NAME/resources"
mkdir -p "$RESOURCES_DIR"

RUN_DIR="/var/run/$NAME"
LOG_PATH="$RUN_DIR/$NAME.log"
mkdir -p "$RUN_DIR"

log() {
	echo -e "$(date "+%Y-%m-%d %H:%M:%S") $*" >> "$LOG_PATH"
}

set_lock() {
	local act="$1"
	local type="$2"

	local lock="$RUN_DIR/update_resources-$type.lock"
	if [ "$act" = "set" ]; then
		if [ -e "$lock" ]; then
			log "[$(to_upper "$type")] A task is already running."
			exit 2
		else
			touch "$lock"
		fi
	elif [ "$act" = "remove" ]; then
		rm -f "$lock"
	fi
}

to_upper() {
	echo -e "$1" | tr "[a-z]" "[A-Z]"
}

check_clash_dashboard_update() {
	local cdtype="$1"
	local cdrepo="$2"
	local wget="wget --timeout=10 -q"

	set_lock "set" "$cdtype"

	local cddata_ver="$($wget -O- "https://api.github.com/repos/$cdrepo/releases/latest" | jsonfilter -e "@.tag_name")"
	if [ -z "$cddata_ver" ]; then
		log "[$(to_upper "$cdtype")] Failed to get the latest version, please retry later."

		set_lock "remove" "$cdtype"
		return 1
	fi

	local local_cddata_ver="$(cat "$RESOURCES_DIR/$cdtype.ver" 2>"/dev/null" || echo "NOT FOUND")"
	if [ "$local_cddata_ver" = "$cddata_ver" ]; then
		log "[$(to_upper "$cdtype")] Current version: $cddata_ver."
		log "[$(to_upper "$cdtype")] You're already at the latest version."

		set_lock "remove" "$cdtype"
		return 3
	else
		log "[$(to_upper "$cdtype")] Local version: $local_cddata_ver, latest version: $cddata_ver."
	fi

	$wget "https://github.com/$cdrepo/releases/download/$cddata_ver/compressed-dist.tgz" -O "$RESOURCES_DIR/compressed-dist.tgz" && \
		rm -rf "$RESOURCES_DIR/ui" && mkdir -p "$RESOURCES_DIR/ui" && \
		tar -zxf "$RESOURCES_DIR/compressed-dist.tgz" -C "$RESOURCES_DIR/ui" && \
		rm -rf "$RESOURCES_DIR/compressed-dist.tgz"

	echo -e "$cddata_ver" > "$RESOURCES_DIR/$cdtype.ver"
	log "[$(to_upper "$cdtype")] Successfully updated."

	set_lock "remove" "$cdtype"
	return 0
}

check_geodata_update() {
	local geotype="$1"
	local georepo="$2"
	local wget="wget --timeout=10 -q"

	set_lock "set" "$geotype"

	local geodata_ver="$($wget -O- "https://api.github.com/repos/$georepo/releases/latest" | jsonfilter -e "@.tag_name")"
	if [ -z "$geodata_ver" ]; then
		log "[$(to_upper "$geotype")] Failed to get the latest version, please retry later."

		set_lock "remove" "$geotype"
		return 1
	fi

	local local_geodata_ver="$(cat "$RESOURCES_DIR/$geotype.ver" 2>"/dev/null" || echo "NOT FOUND")"
	if [ "$local_geodata_ver" = "$geodata_ver" ]; then
		log "[$(to_upper "$geotype")] Current version: $geodata_ver."
		log "[$(to_upper "$geotype")] You're already at the latest version."

		set_lock "remove" "$geotype"
		return 3
	else
		log "[$(to_upper "$geotype")] Local version: $local_geodata_ver, latest version: $geodata_ver."
	fi

	local geodata_hash
	$wget "https://github.com/$georepo/releases/download/$geodata_ver/$geotype.db" -O "$RUN_DIR/$geotype.db"
	geodata_hash="$($wget -O- "https://github.com/$georepo/releases/download/$geodata_ver/$geotype.db.sha256sum" | awk '{print $1}')"
	if ! echo -e "$geodata_hash $RUN_DIR/$geotype.db" | sha256sum -s -c -; then
		rm -f "$RUN_DIR/$geotype.db"
		log "[$(to_upper "$geotype")] Update failed."

		set_lock "remove" "$geotype"
		return 1
	fi

	mv -f "$RUN_DIR/$geotype.db" "$RESOURCES_DIR/$geotype.db"
	echo -e "$geodata_ver" > "$RESOURCES_DIR/$geotype.ver"
	log "[$(to_upper "$geotype")] Successfully updated."

	set_lock "remove" "$geotype"
	return 0
}

check_list_update() {
	local listtype="$1"
	local listrepo="$2"
	local listref="$3"
	local listname="$4"
	local wget="wget --timeout=10 -q"

	set_lock "set" "$listtype"

	local list_info="$($wget -O- "https://api.github.com/repos/$listrepo/commits?sha=$listref&path=$listname")"
	local list_sha="$(echo -e "$list_info" | jsonfilter -e "@[0].sha")"
	local list_ver="$(echo -e "$list_info" | jsonfilter -e "@[0].commit.message" | grep -Eo "[0-9-]+" | tr -d '-')"
	if [ -z "$list_sha" ] || [ -z "$list_ver" ]; then
		log "[$(to_upper "$listtype")] Failed to get the latest version, please retry later."

		set_lock "remove" "$listtype"
		return 1
	fi

	local local_list_ver="$(cat "$RESOURCES_DIR/$listtype.ver" 2>"/dev/null" || echo "NOT FOUND")"
	if [ "$local_list_ver" = "$list_ver" ]; then
		log "[$(to_upper "$listtype")] Current version: $list_ver."
		log "[$(to_upper "$listtype")] You're already at the latest version."

		set_lock "remove" "$listtype"
		return 3
	else
		log "[$(to_upper "$listtype")] Local version: $local_list_ver, latest version: $list_ver."
	fi

	$wget "https://fastly.jsdelivr.net/gh/$listrepo@$list_sha/$listname" -O "$RUN_DIR/$listname"
	if [ ! -s "$RUN_DIR/$listname" ]; then
		rm -f "$RUN_DIR/$listname"
		log "[$(to_upper "$listtype")] Update failed."

		set_lock "remove" "$listtype"
		return 1
	fi

	mv -f "$RUN_DIR/$listname" "$RESOURCES_DIR/$listtype.${listname##*.}"
	echo -e "$list_ver" > "$RESOURCES_DIR/$listtype.ver"
	log "[$(to_upper "$listtype")] Successfully updated."

	set_lock "remove" "$listtype"
	return 0
}

case "$1" in
"clash_dashboard")
	check_clash_dashboard_update "$1" "MetaCubeX/metacubexd"
	;;
"geoip")
	check_geodata_update "$1" "douglarek/sing-geoip"
	;;
"geosite")
	check_geodata_update "$1" "douglarek/sing-geosite"
	;;
"china_ip4")
	check_list_update "$1" "douglarek/IPCIDR-CHINA" "master" "ipv4.txt"
	;;
"china_ip6")
	check_list_update "$1" "douglarek/IPCIDR-CHINA" "master" "ipv6.txt"
	;;
"gfw_list")
	check_list_update "$1" "Loyalsoldier/v2ray-rules-dat" "release" "gfw.txt"
	;;
"china_list")
	check_list_update "$1" "Loyalsoldier/v2ray-rules-dat" "release" "direct-list.txt"
	;;
*)
	echo -e "Usage: $0 <clash_dashboard/ geoip / geosite / china_ip4 / china_ip6 / gfw_list / china_list>"
	exit 1
	;;
esac
