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
	printf "Error: This script must be run as root.\n"
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
	printf "Error: The specified block device, $SD, has mounted "
	printf "partitions.\n       Unmount them and try again.\n"
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
	printf "Stage 3 tarball already downloaded, skipping\n"
else
	wget -P ./cache/ $BASE_ADDRESS/$STAGE3_DATE/$STAGE3_TARBALL cache/
fi

# Download Portage snapshot
if [ -e "./cache/portage-latest.tar.bz2" ]; then
	printf "Latest Portage snapshot already downloaded, skipping\n"
else
	wget -P ./cache/ http://distfiles.gentoo.org/snapshots/portage-latest.tar.bz2
fi

# Clone firmware
if [ -d "./cache/firmware" ]; then
	printf "Firmware already downloaded, skipping\n"
else
	printf "Downloading firmware\n"
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

printf "Partitioning $SD\n"
parted -s $SD mklabel msdos
parted -s $SD mkpart primary fat32 ${BOOT_START}MiB ${BOOT_END}MiB
parted -s $SD mkpart primary ${SWAP_START}MiB ${SWAP_END}MiB
parted -s $SD mkpart primary ${ROOT_START}MiB $ROOT_END

# Format SD card
printf "Formatting $SD$SD_BOOT\n"
mkfs.vfat $SD$SD_BOOT
printf "Formatting $SD$SD_SWAP\n"
mkswap $SD$SD_SWAP
printf "Formatting $SD$SD_ROOT\n"
mkfs.ext4 -q $SD$SD_ROOT

# Mount SD card
printf "Mounting $SD$SD_ROOT at $ROOT_DIR\n"
mount $SD$SD_ROOT $ROOT_DIR
mkdir $ROOT_DIR/boot
printf "Mounting $SD$SD_BOOT at $ROOT_DIR/boot\n"
mount $SD$SD_BOOT $ROOT_DIR/boot

# Extract stage 3 to SD card
printf "Extracting stage 3 tarball\n"
tar xjpf cache/$STAGE3_TARBALL -C $ROOT_DIR --xattrs > /dev/null
sync

# Extract Portage snapshot
printf "Extracting Portage snapshot\n"
tar xjpf cache/portage-latest.tar.bz2 -C $ROOT_DIR/usr
sync

# Place kernel, firmware, and modules
printf "Adding kernel to image\n"
cp -r cache/firmware/boot/* $ROOT_DIR/boot
cp -r cache/firmware/modules $ROOT_DIR/lib/
#echo "dwc_otg.lpm_enable=0 console=ttyAMA0,115200 kgdboc=ttyAMA0,115200
#console=tty1 root=$SD$SD_ROOT rootfstype=ext4 elevator=deadline
#rootwait" > $ROOT_DIR/boot/cmdline.txt
touch $ROOT_DIR/boot/cmdline.txt
printf "dwc_otg.lpm_enable=0 " >> $ROOT_DIR/boot/cmdline.txt
printf "console=ttyAMA0,115200 " >> $ROOT_DIR/boot/cmdline.txt
printf "kgdboc=ttyAMA0,115200 " >> $ROOT_DIR/boot/cmdline.txt
printf "console=tty1 " >> $ROOT_DIR/boot/cmdline.txt
printf "root=%s " "$SD$SD_ROOT" >> $ROOT_DIR/boot/cmdline.txt
printf "rootfstype=ext4 " >> $ROOT_DIR/boot/cmdline.txt
printf "elevator=deadline " >> $ROOT_DIR/boot/cmdline.txt
printf "rootwait\n" >> $ROOT_DIR/boot/cmdline.txt

# Adjust make.conf
printf "INPUT_DEVICES=\"evdev\"\n" >> $ROOT_DIR/etc/portage/make.conf
printf "LINGUAS=\"en_US en\"\n" >> $ROOT_DIR/etc/portage/make.conf
printf "MAKEOPTS=\"-j5\"\n" >> $ROOT_DIR/etc/portage/make.conf
printf "PORTAGE_NICENESS=\"18\"\n" >> $ROOT_DIR/etc/portage/make.conf

# Create repos.conf
mkdir -p $ROOT_DIR/etc/portage/repos.conf
printf "[DEFAULT]\n" > $ROOT_DIR/etc/portage/repos.conf/gentoo.conf
printf "main-repo = gentoo\n" >> $ROOT_DIR/etc/portage/repos.conf/gentoo.conf
printf "\n" >> $ROOT_DIR/etc/portage/repos.conf/gentoo.conf
printf "[gentoo]\n" >> $ROOT_DIR/etc/portage/repos.conf/gentoo.conf
printf "location = /usr/portage\n" >> $ROOT_DIR/etc/portage/repos.conf/gentoo.conf
printf "sync-type = rsync\n" >> $ROOT_DIR/etc/portage/repos.conf/gentoo.conf
printf "sync-uri = $SYNC_URI\n" >> $ROOT_DIR/etc/portage/repos.conf/gentoo.conf
printf "auto-sync = yes\n" >> $ROOT_DIR/etc/portage/repos.conf/gentoo.conf

# Adjust /etc/fstab
sed -i '/dev/ s/^/#/' $ROOT_DIR/etc/fstab
printf "$SD$SD_BOOT	/boot	vfat	noatime	1 2\n" >> $ROOT_DIR/etc/fstab
printf "$SD$SD_SWAP	none	swap	sw	0 0\n" >> $ROOT_DIR/etc/fstab
printf "$SD$SD_ROOT	/	ext4	noatime	0 1\n" >> $ROOT_DIR/etc/fstab

# Set root password
printf "Enter the desired root password\n"
RS=1
while [ $RS -ne 0 ]; do
	PASSWORD="$(mkpasswd -m sha-512 -R 50000)"
	RS=$?
done
sed -i "/root/c\root:$PASSWORD:10770:0:::::" $ROOT_DIR/etc/shadow

# Set timezone
printf "Setting timezone to $TIMEZONE\n"
cp $ROOT_DIR/usr/share/zoneinfo/$TIMEZONE $ROOT_DIR/etc/localtime
printf "$TIMEZONE\n" > $ROOT_DIR/etc/timezone

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
