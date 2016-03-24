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

# Set these variables to customize the image.

# Set the version of the Raspberry Pi hardware.
#   1: Creates an armv6j_hardfp image for the original Raspberry Pi
#   2: Creates an armv7a_hardfp image for the Raspberry Pi 2
#   3: Because there is not yet a stage 3 tarball for the Raspberry Pi 3, this
#      creates the same armv7a_hardfp image as the Raspberry Pi 2. Hopefully
#      an armv8a stage 3 tarball will be released in the near future.
PI_VERSION=1
HOSTNAME="raspy" # Hostname for the image.
TIMEZONE="America/Los_Angeles" # Timezone to set in the image.
KEYMAP="us" # The keymap to use for the console.

###############################################################################
# Additional internal variables.
ROOT_DIR="$(mktemp -d)" # Location where the SD card will be mounted.
SYNC_URI="rsync://rsync.us.gentoo.org/gentoo-portage" # URI for portage rsync.

###############################################################################
# TODO Develop usage summary.
#print_usage() {
#	printf "%s\n" "Usage summary:"
#	printf "\t%s\n" "-c <config>"
#	printf "\t\t%s\n" "Specify a configuration file to use."
#	printf "\t%s\n" "-d"
#	printf "\t\t%s\n" "Download new copies of all files and update the cache."
#	printf "\t%s\n" "-z"
#	printf "\t\t%s\n" "Write zeros to the SD card before formatting."
#}

# Ensure we're running as root.
if [ $(id -u) -ne 0 ]; then
	printf "%s\n" "Error: This script must be run as root."
	exit 1
fi

# Verify mkpasswd is installed.
if [ ! $(command -v mkpasswd) ]; then
	printf "%s\n" "Error: The mkpasswd utility is not installed. Please"
	printf "%s\n" "install it and try again. In many distributions, it"
	printf "%s\n" "is part of the whois package."
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
if [ $PI_VERSION -eq 1 ]; then
	STAGE3_RAW=$(curl -s $BASE_ADDRESS/latest-stage3-armv6j_hardfp.txt)
elif [ $PI_VERSION -eq 2 ] || [ $PI_VERSION -eq 3 ]; then
	STAGE3_RAW=$(curl -s $BASE_ADDRESS/latest-stage3-armv7a_hardfp.txt)
fi
STAGE3_RAW=$(printf "%s" "$STAGE3_RAW" | tr '\n' ' ' | cut -d ' ' -f 13)
STAGE3_DATE=$(printf "%s" "$STAGE3_RAW" | cut -d '/' -f 1)
STAGE3_TARBALL=$(printf "%s" "$STAGE3_RAW" | cut -d '/' -f 2)

if [ -e "./cache/$STAGE3_TARBALL" ]; then
	printf "%s\n" "Stage 3 tarball already downloaded, skipping"
else
	wget -P ./cache/ $BASE_ADDRESS/$STAGE3_DATE/$STAGE3_TARBALL cache/
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
mkfs.vfat $SD$SD_BOOT
printf "%s\n" "Formatting $SD$SD_SWAP"
mkswap $SD$SD_SWAP
printf "%s\n" "Formatting $SD$SD_ROOT"
mkfs.ext4 -q $SD$SD_ROOT

# Mount SD card
printf "%s\n" "Mounting $SD$SD_ROOT at $ROOT_DIR"
mount $SD$SD_ROOT $ROOT_DIR
mkdir $ROOT_DIR/boot
printf "%s\n" "Mounting $SD$SD_BOOT at $ROOT_DIR/boot"
mount $SD$SD_BOOT $ROOT_DIR/boot

# Extract stage 3 to SD card
printf "%s\n" "Extracting stage 3 tarball"
tar xjpf cache/$STAGE3_TARBALL -C $ROOT_DIR --xattrs > /dev/null
sync

# Extract Portage snapshot
printf "%s\n" "Extracting Portage snapshot"
tar xjpf cache/portage-latest.tar.bz2 -C $ROOT_DIR/usr
sync

# Place kernel, firmware, and modules
printf "%s\n" "Adding kernel to image"
cp -r cache/firmware/boot/* $ROOT_DIR/boot
cp -r cache/firmware/modules $ROOT_DIR/lib/
#echo "dwc_otg.lpm_enable=0 console=ttyAMA0,115200 kgdboc=ttyAMA0,115200
#console=tty1 root=$SD$SD_ROOT rootfstype=ext4 elevator=deadline
#rootwait" > $ROOT_DIR/boot/cmdline.txt
touch $ROOT_DIR/boot/cmdline.txt
printf "%s" "dwc_otg.lpm_enable=0 " >> $ROOT_DIR/boot/cmdline.txt
printf "%s" "console=ttyAMA0,115200 " >> $ROOT_DIR/boot/cmdline.txt
printf "%s" "kgdboc=ttyAMA0,115200 " >> $ROOT_DIR/boot/cmdline.txt
printf "%s" "console=tty1 " >> $ROOT_DIR/boot/cmdline.txt
printf "%s" "root=%s " "$SD$SD_ROOT" >> $ROOT_DIR/boot/cmdline.txt
printf "%s" "rootfstype=ext4 " >> $ROOT_DIR/boot/cmdline.txt
printf "%s" "elevator=deadline " >> $ROOT_DIR/boot/cmdline.txt
printf "%s\n" "rootwait" >> $ROOT_DIR/boot/cmdline.txt

# Adjust make.conf
printf "%s\n" "INPUT_DEVICES=\"evdev\"" >> $ROOT_DIR/etc/portage/make.conf
printf "%s\n" "LINGUAS=\"en_US en\"" >> $ROOT_DIR/etc/portage/make.conf
printf "%s\n" "MAKEOPTS=\"-j5\"" >> $ROOT_DIR/etc/portage/make.conf
printf "%s\n" "PORTAGE_NICENESS=\"18\"" >> $ROOT_DIR/etc/portage/make.conf

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
