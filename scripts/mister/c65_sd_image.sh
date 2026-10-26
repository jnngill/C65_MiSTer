#!/bin/bash
# C65 SD card image: builds /media/fat/games/C65/mega65sd.img, a FAT32 disk
# image holding everything in the folder /media/fat/games/C65/SD (sub-folders
# too), for the core's "Mount SD Card / Data File (MEGA65)" OSD option.
# MEGA65 programs then find their files there through the hypervisor, and
# BASIC 65's MOUNT (or a program) can attach the .D81 images in it to drive 8.
# Copy this file to /media/fat/Scripts and run it from the MiSTer Scripts
# menu after changing the folder.
#
# The image is rebuilt from the folder each time, so anything written into
# it from the core (into an attached .D81) is replaced; the previous image is
# kept as mega65sd.img.bak.

C65=${C65_DIR:-/media/fat/games/C65}
SRC="$C65/SD"
OUT="$C65/mega65sd.img"
MNT=/tmp/c65_sd_mnt

if [ ! -d "$SRC" ]; then
	mkdir -p "$SRC"
	echo "Created $SRC"
	echo "Copy the files and folders for the MEGA65 SD card there"
	echo "and run this script again."
	exit 0
fi

# room for the files plus a quarter, at least 64 MB (FAT32 needs 33 MB)
used=$(du -sm "$SRC" | cut -f1)
size=$(( used + used / 4 + 16 ))
[ $size -lt 64 ] && size=64

[ -f "$OUT" ] && mv -f "$OUT" "$OUT.bak"
echo "Making a $size MB image..."
if ! dd if=/dev/zero of="$OUT" bs=1M count=$size 2>/dev/null; then
	echo "Not enough space for the image."
	rm -f "$OUT"
	exit 1
fi
# one sector per cluster below 256 MB keeps FAT32 valid on small cards
spc=""
[ $size -lt 256 ] && spc="-s 1"
mkfs.vfat -F 32 $spc -n MEGA65 "$OUT" >/dev/null || { echo "mkfs.vfat failed"; exit 1; }

mkdir -p "$MNT"
mount -o loop "$OUT" "$MNT" || { echo "Could not mount the image"; exit 1; }
cp -r "$SRC"/. "$MNT"/
ok=$?
sync
umount "$MNT"
rmdir "$MNT"
if [ $ok -ne 0 ]; then
	echo "Copying the files failed (image too small?)"
	exit 1
fi
echo "Done: $OUT"
echo "In the C65 core: F12, Mount SD Card / Data File (MEGA65), pick mega65sd.img."
