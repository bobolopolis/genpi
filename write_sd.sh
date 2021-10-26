#!/bin/sh

SD="$1"
TARBALL="$2"

if [ -z "$SD" ]; then
	printf "%s\n" "Specify the device to write"
	exit 1
fi

if [ -z "$TARBALL" ]; then
	printf "%s\n" "Specify the tarball to write"
	exit 1
fi

if [ $(id -u) -ne 0 ]; then
	printf "%s\n" "Run this as root"
	exit 1
fi

#parted -s $SD mklabel msdos
parted -s $SD mklabel gpt
#parted -s $SD mkpart primary fat32 2MiB 130MiB
#parted -s $SD mkpart primary 130MiB 2178MiB
#parted -s $SD mkpart primary 2178MiB 100%
#parted -s $SD mkpart primary 130MiB 642MiB
#parted -s $SD mkpart primary 642MiB 100%
parted -s $SD mkpart primary fat32 2MiB 514MiB
parted -s $SD mkpart primary 514MiB 100%
sleep 1
mkfs.vfat -F 32 -n RPI-BOOT ${SD}1
#mkswap ${SD}2
#mkfs.ext4 -F -L rpi-root ${SD}3
mkfs.ext4 -F -L rpi-root ${SD}2
# -d rootfs-rpi-4-b-64/
#mkfs.btrfs -f -L rpi-root ${SD}3

ROOT_DIR="$(mktemp -d)"
#mount ${SD}3 $ROOT_DIR
#mount ${SD}2 $ROOT_DIR
mount -o compress=zstd ${SD}3 $ROOT_DIR
install -d -m 0755 $ROOT_DIR/boot
mount ${SD}1 $ROOT_DIR/boot
tar -xvf $TARBALL -C $ROOT_DIR

# TODO set root= and rootfstype=

umount $ROOT_DIR/boot
umount $ROOT_DIR/
rm -r $ROOT_DIR
