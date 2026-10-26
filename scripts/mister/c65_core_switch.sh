#!/bin/sh
# C65 core switch: lets the C65 core load the MiSTer C64 or C128 core
# (GO64 with the OSD's "GO64: Load C64 core", or RUN"GO128" / RUN"GO64" from
# go.d81, which POKE 55037,67 and then 55038 with 128 or 64).
#
# A core cannot ask the MiSTer for another core, so the C65 core writes the
# request into DDR memory at 0x3FFFF800 and this script, running in the
# background while the C65 core is loaded, picks it up and loads the core.
#
# Install: copy this file to /media/fat/Scripts and run it once from the
# Scripts menu.  It copies itself to /media/fat/linux, adds a line to
# /media/fat/linux/user-startup.sh so it starts at every boot, and starts.
# Running it again restarts it; "c65_core_switch.sh remove" takes it out again.
#
# Which core: the newest _Computer/C64_*.rbf / C128_*.rbf (by the date in the
# name).  To pick one, put for example
#     C64_CORE=/media/fat/_Computer/C64_20260823.rbf
#     C128_CORE=/media/fat/_Computer/C128_20260830.rbf
# into /media/fat/linux/c65_core_switch.conf.

SELF=/media/fat/linux/c65_core_switch.sh
CONF=/media/fat/linux/c65_core_switch.conf
STARTUP=/media/fat/linux/user-startup.sh
LINE='[ -x /media/fat/linux/c65_core_switch.sh ] && /media/fat/linux/c65_core_switch.sh daemon &'
MAGIC=0x47353643        # "C65G" at 0x3FFFF800, then "O", the target (64 / 128), a sequence number

stop_daemon() {
	for p in $(ps | grep "c65_core_switch.sh daemon" | grep -v grep | awk '{print $1}'); do
		[ "$p" != "$$" ] && kill "$p" 2>/dev/null
	done
}

case "$1" in
daemon)
	;;
remove)
	stop_daemon
	[ -f "$STARTUP" ] && grep -v "c65_core_switch.sh" "$STARTUP" > "$STARTUP.tmp" && mv "$STARTUP.tmp" "$STARTUP"
	rm -f "$SELF"
	echo "C65 core switch removed."
	exit 0
	;;
*)
	mkdir -p /media/fat/linux
	[ "$(readlink -f "$0")" != "$SELF" ] && cp "$0" "$SELF"
	chmod +x "$SELF"
	[ -f "$STARTUP" ] || printf '#!/bin/sh\n' > "$STARTUP"
	grep -q "c65_core_switch.sh" "$STARTUP" || echo "$LINE" >> "$STARTUP"
	stop_daemon
	"$SELF" daemon > /dev/null 2>&1 &
	echo "C65 core switch installed and running."
	echo "In the C65 core, GO64 loads the C64 core when the OSD's"
	echo "GO64 option is set to Load C64 core; RUN\"GO128\" from go.d81"
	echo "loads the C128 core."
	exit 0
	;;
esac

# newest core for a name prefix (C64 / C128), by the _YYYYMMDD in the file name
newest() {
	ls /media/fat/_Computer/"$1"_*.rbf 2>/dev/null |
		sed -n 's/^\(.*_\([0-9]\{8\}\)\.rbf\)$/\2 \1/p' | sort -r | head -n 1 | cut -d' ' -f2-
}

while :; do
	sleep 1
	[ "$(cat /tmp/CORENAME 2>/dev/null)" = "C65" ] || continue
	w=$(devmem 0x3FFFF800 32 2>/dev/null) || continue
	[ $((w)) -eq $((MAGIC)) ] || continue
	t=$(devmem 0x3FFFF804 32)
	devmem 0x3FFFF800 32 0
	devmem 0x3FFFF804 32 0
	C64_CORE=""; C128_CORE=""
	[ -f "$CONF" ] && . "$CONF"
	case $(( (t >> 8) & 255 )) in
		64)  core=${C64_CORE:-$(newest C64)} ;;
		128) core=${C128_CORE:-$(newest C128)} ;;
		*)   core="" ;;
	esac
	[ -n "$core" ] && [ -f "$core" ] && echo "load_core $core" > /dev/MiSTer_cmd
done
