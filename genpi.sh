#!/bin/sh
# Copyright 2015 Robert Joslyn
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

# TODO Use a configuration file to set these parameters.

# Set SD variables as needed for your workstation.
SD="/dev/mmcblk0" # Set to base block device, such as "/dev/sdb".
SD_BOOT="p1" # Set to boot partition suffix, such as "1".
SD_SWAP="p2" # Set to swap partition suffix, such as "2".
SD_ROOT="p3" # Set to root partition suffix, such as "3".

# Set these variables to change the SD card partition layout.
BOOT_SIZE="128" # Size of the boot partition in MiB.
SWAP_SIZE="1024" # Size of the swap partition in MiB.
ROOT_SIZE="100%" # Size of the root partition, either in MiB or "100%".

# Set the version of the Raspberry Pi hardware.
#   0: Create an image for the Raspberry Pi Zero.
#   1: Create an image for the original Raspberry Pi.
#   2: Create an image for the Raspberry Pi 2
#   3: Create an image for the Raspberry Pi 3.
PI_VERSION=3
HOSTNAME="raspy" # Hostname for the image.
TIMEZONE="America/Los_Angeles" # Timezone to set in the image.
KEYMAP="us" # The keymap to use for the console.
LINGUAS="en en_US" # LINGUAS value for make.conf
L10N="en en-US" # L10N value for make.conf

###############################################################################
# Additional internal variables.
ROOT_DIR="$(mktemp -d)" # Location where the SD card will be mounted.
SYNC_URI="rsync://rsync.us.gentoo.org/gentoo-portage" # URI for portage rsync.

###############################################################################
# TODO Develop usage summary.

# Ensure we're running as root.
if [ $(id -u) -ne 0 ]; then
	printf "%s\n" "Error: This script must be run as root."
	exit 1
fi

# Verify mkpasswd is installed.
if [ ! $(command -v mkpasswd) ]; then
	printf "%s" "Error: The mkpasswd utility is not installed. Please "
	printf "%s\n%s" "install it and try again." "In many distributions, "
	printf "%s\n" "it is part of the whois package."
	exit 1
fi

# Verify the SD card does not have mounted partitions.
if [ -n "$(mount | grep "$SD")" ]; then
	printf "%s" "Error: The specified block device, $SD, has mounted "
	printf "%s\n%s\n" "partitions." "       Unmount them and try again."
	exit 1
fi

mkdir -p cache
# Download stage 3 tarball
BASE_ADDRESS="http://distfiles.gentoo.org/releases/arm/autobuilds"
if [ $PI_VERSION -eq 0 ] || [ $PI_VERSION -eq 1 ]; then
	STAGE3_RAW=$(curl -s $BASE_ADDRESS/latest-stage3-armv6j_hardfp.txt)
elif [ $PI_VERSION -eq 2 ] || [ $PI_VERSION -eq 3 ]; then
	STAGE3_RAW=$(curl -s $BASE_ADDRESS/latest-stage3-armv7a_hardfp.txt)
fi
STAGE3_RAW=$(printf "%s" "$STAGE3_RAW" | tr '\n' ' ' | cut -d ' ' -f 13)
STAGE3_DATE=$(printf "%s" "$STAGE3_RAW" | cut -d '/' -f 1)
STAGE3_TARBALL=$(printf "%s" "$STAGE3_RAW" | cut -d '/' -f 2)

# TODO: Check GPG signature of files
if [ -e "./cache/$STAGE3_TARBALL" ]; then
	printf "%s\n" "Stage 3 tarball already downloaded, skipping"
else
	wget -P ./cache/ $BASE_ADDRESS/$STAGE3_DATE/$STAGE3_TARBALL
fi

# Download Portage snapshot
if [ -e "./cache/portage-latest.tar.bz2" ]; then
	printf "%s\n" "Latest Portage snapshot already downloaded, skipping"
else
	wget -P ./cache/ http://distfiles.gentoo.org/snapshots/portage-latest.tar.bz2
fi

# Clone firmware
if [ -d "./cache/firmware" ]; then
	printf "%s\n" "Firmware already downloaded, skipping"
else
	printf "%s\n" "Downloading firmware"
	git clone --depth 1 https://github.com/raspberrypi/firmware.git cache/firmware
fi

# Calculate partition sizes
BOOT_START=2 # Start at
BOOT_END=$(expr 4 + $BOOT_SIZE)
SWAP_START=$BOOT_END
SWAP_END=$(expr $SWAP_START + $SWAP_SIZE)
ROOT_START=$SWAP_END
if [ "$ROOT_SIZE" = "100%" ]; then
	ROOT_END="100%"
else
	ROOT_END="$(expr $ROOT_START + $ROOT_SIZE)MiB"
fi

printf "%s\n" "Partitioning $SD"
parted -s $SD mklabel msdos
parted -s $SD mkpart primary fat32 ${BOOT_START}MiB ${BOOT_END}MiB
parted -s $SD mkpart primary ${SWAP_START}MiB ${SWAP_END}MiB
parted -s $SD mkpart primary ${ROOT_START}MiB $ROOT_END

# Format SD card
printf "%s\n" "Formatting $SD$SD_BOOT"
mkfs.vfat -n RPI-BOOT $SD$SD_BOOT
printf "%s\n" "Formatting $SD$SD_SWAP"
mkswap $SD$SD_SWAP
printf "%s\n" "Formatting $SD$SD_ROOT"
mkfs.ext4 -q -L rpi-root $SD$SD_ROOT

# Mount SD card
printf "%s\n" "Mounting $SD$SD_ROOT at $ROOT_DIR"
mount $SD$SD_ROOT $ROOT_DIR
mkdir $ROOT_DIR/boot
printf "%s\n" "Mounting $SD$SD_BOOT at $ROOT_DIR/boot"
mount $SD$SD_BOOT $ROOT_DIR/boot

# Extract stage 3 to SD card
printf "%s\n" "Extracting stage 3 tarball"
tar xjpf cache/$STAGE3_TARBALL --xattrs -C $ROOT_DIR --xattrs > /dev/null
sync

# Extract Portage snapshot
printf "%s\n" "Extracting Portage snapshot"
tar xjpf cache/portage-latest.tar.bz2 -C $ROOT_DIR/usr
sync

# Place kernel, firmware, and modules
printf "%s\n" "Adding kernel to image"
cp -r cache/firmware/boot/* $ROOT_DIR/boot
cp -r cache/firmware/modules $ROOT_DIR/lib/
touch $ROOT_DIR/boot/cmdline.txt
printf "%s" "dwc_otg.lpm_enable=0 " >> $ROOT_DIR/boot/cmdline.txt
printf "%s" "console=ttyAMA0,115200 " >> $ROOT_DIR/boot/cmdline.txt
printf "%s" "kgdboc=ttyAMA0,115200 " >> $ROOT_DIR/boot/cmdline.txt
printf "%s" "console=tty1 " >> $ROOT_DIR/boot/cmdline.txt
printf "%s" "root=$SD$SD_ROOT " >> $ROOT_DIR/boot/cmdline.txt
printf "%s" "rootfstype=ext4 " >> $ROOT_DIR/boot/cmdline.txt
printf "%s" "elevator=deadline " >> $ROOT_DIR/boot/cmdline.txt
printf "%s\n" "rootwait" >> $ROOT_DIR/boot/cmdline.txt

# Adjust make.conf
if [ $PI_VERSION -eq 0 ] || [ $PI_VERSION -eq 1 ]; then
	CFLAGS="-O2 -pipe -march=armv6kz -mtune=arm1176jzf-s -mfpu=vfp"
	CFLAGS="${CFLAGS} -mfloat-abi=hard -tree-vectorize"
	CHOST="armv6j-hardfloat-linux-gnueabi"
	MAKEOPTS="-j2"
elif [ $PI_VERSION -eq 2 ]; then
	CFLAGS="-O2 -pipe -march=armv7ve -mtune=cortex-a7 -mfpu=neon-vfpv4"
	CFLAGS="${CFLAGS} -mfloat-abi=hard -ftree-vectorize"
	CHOST="armv7a-hardfloat-linux-gnueabi"
	MAKEOPTS="-j5"
elif [ $PI_VERSION -eq 3 ]; then
	CFLAGS="-O2 -pipe -march=armv8-a+crc -mtune=cortex-a53"
	CFLAGS="${CFLAGS} -mfpu=crypto-neon-fp-armv8 -mfloat-abi=hard"
	CFLAGS="${CFLAGS} -ftree-vectorize"
	# Gentoo does not have an armv8a stage3 available at this time.
	CHOST="armv7a-hardfloat-linux-gnueabi"
	MAKEOPTS="-j5"
fi

MAKE_CONF="$ROOT_DIR/etc/portage/make.conf"
printf "%s\n" "CFLAGS=\"${CFLAGS}\"" > $MAKE_CONF
printf "%s\n" "CXXFLAGS=\"\${CFLAGS}\"" >> $MAKE_CONF
printf "%s\n\n" "CHOST=\"${CHOST}\"" >> $MAKE_CONF
printf "%s\n\n" "USE=\"\"" >> $MAKE_CONF
printf "%s\n" "INPUT_DEVICES=\"evdev\"" >> $MAKE_CONF
printf "%s\n" "VIDEO_CARDS=\"vc4\"" >> $MAKE_CONF
printf "%s\n" "LINGUAS=\"$LINGUAS\"" >> $MAKE_CONF
printf "%s\n" "L10N=\"$L10N\"" >> $MAKE_CONF
printf "%s\n" "MAKEOPTS=\"${MAKEOPTS}\"" >> $MAKE_CONF
printf "%s\n" "PORTAGE_NICENESS=\"18\"" >> $MAKE_CONF
printf "%s\n" "PORTDIR=\"/usr/portage\"" >> $MAKE_CONF
printf "%s\n" "DISTDIR=\"/usr/portage/distfiles\"" >> $MAKE_CONF
printf "%s\n" "PKGDIR=\"/usr/portage/packages\"" >> $MAKE_CONF
printf "%s\n" "# This sets the language of build output to English." >> $MAKE_CONF
printf "%s\n" "# Please keep this setting intact when reporting bugs." >> $MAKE_CONF
printf "%s\n" "LC_MESSAGES=C" >> $MAKE_CONF

# Create repos.conf
mkdir -p $ROOT_DIR/etc/portage/repos.conf
printf "%s\n" "[DEFAULT]" > $ROOT_DIR/etc/portage/repos.conf/gentoo.conf
printf "%s\n\n" "main-repo = gentoo" >> $ROOT_DIR/etc/portage/repos.conf/gentoo.conf
printf "%s\n" "[gentoo]" >> $ROOT_DIR/etc/portage/repos.conf/gentoo.conf
printf "%s\n" "location = /usr/portage" >> $ROOT_DIR/etc/portage/repos.conf/gentoo.conf
printf "%s\n" "sync-type = rsync" >> $ROOT_DIR/etc/portage/repos.conf/gentoo.conf
printf "%s\n" "sync-uri = $SYNC_URI" >> $ROOT_DIR/etc/portage/repos.conf/gentoo.conf
printf "%s\n" "auto-sync = yes" >> $ROOT_DIR/etc/portage/repos.conf/gentoo.conf

# Adjust /etc/fstab
sed -i '/dev/ s/^/#/' $ROOT_DIR/etc/fstab
printf "%s\n" "$SD$SD_BOOT	/boot	vfat	noatime	1 2" >> $ROOT_DIR/etc/fstab
printf "%s\n" "$SD$SD_SWAP	none	swap	sw	0 0" >> $ROOT_DIR/etc/fstab
printf "%s\n" "$SD$SD_ROOT	/	ext4	noatime	0 1" >> $ROOT_DIR/etc/fstab

# Set root password
printf "%s\n" "Enter the desired root password"
RS=1
while [ $RS -ne 0 ]; do
	PASSWORD="$(mkpasswd -m sha-512 -R 50000)"
	RS=$?
done
sed -i "/root/c\root:$PASSWORD:10770:0:::::" $ROOT_DIR/etc/shadow

# Set timezone
printf "%s\n" "Setting timezone to $TIMEZONE"
cp $ROOT_DIR/usr/share/zoneinfo/$TIMEZONE $ROOT_DIR/etc/localtime
printf "%s\n" "$TIMEZONE" > $ROOT_DIR/etc/timezone

# Set hostname
sed -i "/hostname=/c\hostname=\"$HOSTNAME\"" $ROOT_DIR/etc/conf.d/hostname

# Comment out spawning agetty on ttyS0
sed -i '/s0:12345/ s/^/#/' $ROOT_DIR/etc/inittab

# Enable networking on boot
ln -sf net.lo $ROOT_DIR/etc/init.d/net.eth0
ln -sf /etc/init.d/net.eth0 $ROOT_DIR/etc/runlevels/default/net.eth0

# Enable sshd on boot
ln -sf /etc/init.d/sshd $ROOT_DIR/etc/runlevels/default/sshd

# Remove hwclock from boot runlevel and add swclock
rm $ROOT_DIR/etc/runlevels/boot/hwclock
ln -sf /etc/init.d/swclock $ROOT_DIR/etc/runlevels/boot/swclock

# Set console keymap
sed -i "s/keymap=\"us\"/keymap=\"$KEYMAP\"/" $ROOT_DIR/etc/conf.d/keymaps

sync
umount $SD$SD_BOOT
umount $SD$SD_ROOT

rm -r $ROOT_DIR
