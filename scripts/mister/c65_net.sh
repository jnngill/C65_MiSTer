#!/bin/sh
# C65 network: connects the C65 core's MEGA65 Ethernet controller to the
# MiSTer's wired network port (eth0), so MEGA65 network programs work.
#
# The FPGA has no network port of its own: the core keeps its frames in DDR
# memory and the c65_net program, running in the background, passes them to
# and from eth0.  The C65 appears on your network as a machine of its own,
# with its own MAC address, so it gets its own address from your router's
# DHCP.  The MiSTer's own Linux cannot reach the C65 this way (but everything
# else on the network, and the internet, can).  Wi-Fi does not work for this.
#
# Install: copy this file and c65_net to /media/fat/Scripts and run this
# script once from the Scripts menu.  It copies both to /media/fat/linux,
# adds a line to /media/fat/linux/user-startup.sh so the program starts at
# every boot, and starts it.  Running it again restarts it;
# "c65_net.sh remove" takes it out again.
#
# Another interface: put NET_IF=eth1 (for example) into
# /media/fat/linux/c65_net.conf.

DIR=/media/fat/linux
SELF=$DIR/c65_net.sh
BIN=$DIR/c65_net
CONF=$DIR/c65_net.conf
STARTUP=$DIR/user-startup.sh
LINE='[ -x /media/fat/linux/c65_net.sh ] && /media/fat/linux/c65_net.sh daemon &'

stop_daemon() {
	killall c65_net 2>/dev/null
	for p in $(ps | grep "c65_net.sh daemon" | grep -v grep | awk '{print $1}'); do
		[ "$p" != "$$" ] && kill "$p" 2>/dev/null
	done
}

case "$1" in
daemon)
	NET_IF=eth0
	[ -f "$CONF" ] && . "$CONF"
	# restart it if it ever stops
	while :; do
		"$BIN" "$NET_IF" > /dev/null 2>&1
		sleep 5
	done
	;;
remove)
	stop_daemon
	[ -f "$STARTUP" ] && grep -v "c65_net.sh" "$STARTUP" > "$STARTUP.tmp" && mv "$STARTUP.tmp" "$STARTUP"
	rm -f "$SELF" "$BIN"
	echo "C65 network removed."
	exit 0
	;;
*)
	src=$(dirname "$(readlink -f "$0")")
	mkdir -p "$DIR"
	if [ ! -f "$src/c65_net" ] && [ ! -f "$BIN" ]; then
		echo "c65_net is missing: copy it next to this script."
		exit 1
	fi
	stop_daemon
	[ "$src" != "$DIR" ] && cp "$0" "$SELF" && [ -f "$src/c65_net" ] && cp "$src/c65_net" "$BIN"
	chmod +x "$SELF" "$BIN"
	[ -f "$STARTUP" ] || printf '#!/bin/sh\n' > "$STARTUP"
	grep -q "c65_net.sh" "$STARTUP" || echo "$LINE" >> "$STARTUP"
	"$SELF" daemon > /dev/null 2>&1 &
	echo "C65 network installed and running."
	echo "In the C65 core (MEGA65 Extensions on), MEGA65 network"
	echo "programs now reach your network through the MiSTer's"
	echo "network cable."
	exit 0
	;;
esac
