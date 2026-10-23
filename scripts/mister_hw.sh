#!/bin/bash
# Drive a MiSTer running the C65 core from a PC (key-based ssh to root@MiSTer.local):
#
#   mister_hw.sh type "text"      type on the C65 (~ = RETURN, ` = Esc, {dollar} = $)
#   mister_hw.sh osd KEY ...      press OSD keys (F12 DOWN UP ENTER ...)
#   mister_hw.sh shot FILE.png    take a screenshot and copy it to FILE.png
#   mister_hw.sh cmd "command"    run a shell command on the MiSTer
#
# Screenshots can take tens of seconds to be written when the MiSTer is busy,
# so "shot" waits for a file newer than the previous newest one.
D="$(cd "$(dirname "$0")" && pwd)"; H=${MISTER:-root@MiSTer.local}; O="-o BatchMode=yes -o ConnectTimeout=10"
case "$1" in
type) T=$(mktemp); printf '%s' "$2" > "$T"; scp -q $O "$T" $H:/tmp/t.txt; rm -f "$T"
      ssh $O $H 'python3 - "$(cat /tmp/t.txt)"' < "$D/mister_type.py" ;;
osd)  shift; ssh $O $H python3 - "$@" < "$D/mister_osd.py" ;;
shot) f=$(ssh $O $H 'd=/media/fat/screenshots/C65; mkdir -p $d; old=$(ls -t $d | head -1); echo screenshot > /dev/MiSTer_cmd; for i in $(seq 180); do sleep 0.5; new=$(ls -t $d | head -1); if [ "$new" != "$old" ]; then sleep 0.5; echo $new; exit; fi; done; echo TIMEOUT' | tr -d '\r')
      if [ "$f" = TIMEOUT ]; then echo "screenshot timeout" >&2; exit 1; fi
      scp -q $O "$H:/media/fat/screenshots/C65/$f" "$2"; echo "$2" ;;
cmd)  ssh $O $H "$2" ;;
*)    sed -n '2,10p' "$0"; exit 2 ;;
esac
