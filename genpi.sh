#!/bin/sh

HOSTNAME="raspy"
KEYMAP="dvorak"
#KERNEL_VERSION="5.3.5"
#KERNEL_VERSION="5.5.0"
#KERNEL_VERSION="5.7.8"
#KERNEL_VERSION="5.9.12"
KERNEL_VERSION="5.10.10"

STAGE3_ARMV6J="stage3-armv6j_hardfp-20180831.tar.bz2"
STAGE3_ARMV7A="stage3-armv7a_hardfp-20180831.tar.bz2"
STAGE3_ARM64="stage3-arm64-20201004T190540Z.tar.xz"

THREADS="-j24"

initial_setup() {
	if [ ! -f $STAGE3_ARMV6J ]; then
		wget http://distfiles.gentoo.org/releases/arm/autobuilds/current-stage3-armv6j_hardfp/$STAGE3_ARMV6J
	fi
	if [ ! -f $STAGE3_ARMV7A ]; then
		wget http://distfiles.gentoo.org/releases/arm/autobuilds/current-stage3-armv7a_hardfp/$STAGE3_ARMV7A
	fi
	if [ ! -f $STAGE3_ARM64 ]; then
		wget http://distfiles.gentoo.org/releases/arm64/autobuilds/current-stage3-arm64/$STAGE3_ARM64
	fi
	if [ ! -f portage-latest.tar.xz ]; then
		wget http://distfiles.gentoo.org/snapshots/portage-latest.tar.xz
	fi
}

mount_stuff() {
	ROOTFS_DIR="$1"
	mount --types proc /proc $ROOTFS_DIR/proc
	mount --rbind /sys $ROOTFS_DIR/sys
	mount --make-rslave $ROOTFS_DIR/sys
	mount --rbind /dev $ROOTFS_DIR/dev
	mount --make-rslave $ROOTFS_DIR/dev
}

umount_stuff() {
	ROOTFS_DIR="$1"
	umount $ROOTFS_DIR/proc
	umount -R $ROOTFS_DIR/sys
	umount -R $ROOTFS_DIR/dev
}

common() {
	BOARD=$1
	BITNESS=$2
	DTB="$3"

	if [ $BITNESS -eq 32 ]; then
		if [ "$BOARD" = "rpi-b" ] || [ "$BOARD" = "rpi-b-plus" ]; then
			STAGE3_TARBALL="$STAGE3_ARMV6J"
		else
			STAGE3_TARBALL="$STAGE3_ARMV7A"
		fi
		ARCH="arm"
	elif [ $BITNESS -eq 64 ]; then
		STAGE3_TARBALL="$STAGE3_ARM64"
		ARCH="arm64"
	else
		printf "%s\n" "Invalid bitness"
		exit 1
	fi

	FILES_DIR="files/$BOARD"
	ROOTFS_DIR="rootfs-$BOARD"
	ROOTFS_TARBALL="rootfs-$BOARD.tar.xz"
	if [ -d "$ROOTFS_DIR" ]; then
		printf "%s\n" "rootfs directory already exists, stopping"
		# TODO: prompt to continue
		exit 1
	else
		mkdir $ROOTFS_DIR
		tar -xpvf $STAGE3_TARBALL --xattrs-include='*.*' --numeric-owner -C $ROOTFS_DIR
	fi
	#if [ ! -d "$ROOTFS_DIR/usr/portage" ]; then
	#	tar -xpvf portage-latest.tar.xz -C $ROOTFS_DIR/usr/
	#fi
	
	printf "nameserver 1.1.1.1\n" > $ROOTFS_DIR/etc/resolv.conf
	
	mount_stuff $ROOTFS_DIR
	
	# repos.conf
	install -d $ROOTFS_DIR/etc/portage/repos.conf
	install -m 0644 $ROOTFS_DIR/usr/share/portage/config/repos.conf \
		$ROOTFS_DIR/etc/portage/repos.conf/gentoo.conf

	chroot $ROOTFS_DIR emerge-webrsync
	chroot $ROOTFS_DIR emerge --sync

	install -m 0644 $FILES_DIR/make.conf $ROOTFS_DIR/etc/portage/
	
	install -d $ROOTFS_DIR/etc/portage/package.accept_keywords
	printf "sys-boot/raspberrypi-firmware ~arm64\n" > \
		$ROOTFS_DIR/etc/portage/package.accept_keywords/raspberrypi-firmware
	install -d $ROOTFS_DIR/etc/portage/package.license
	printf "sys-boot/raspberrypi-firmware raspberrypi-videocore-bin\n" >> \
		$ROOTFS_DIR/etc/portage/package.license/raspberrypi-image
	printf "sys-firmware/raspberrypi-wifi-ucode Broadcom\n" >> \
		$ROOTFS_DIR/etc/portage/package.license/raspberrypi-wifi-ucode
	chroot $ROOTFS_DIR emerge raspberrypi-firmware raspberrypi-wifi-ucode

	# If the kernel source directory already exists, don't emerge it again
	if [ ! -d "$ROOTFS_DIR/usr/src/linux" ]; then
		printf "%s\n" "=sys-kernel/gentoo-sources-$KERNEL_VERSION" > $ROOTFS_DIR/etc/portage/package.accept_keywords/gentoo-sources
		chroot $ROOTFS_DIR emerge gentoo-sources
		#chroot $ROOTFS_DIR /bin/bash
	fi
	cp $FILES_DIR/defconfig $ROOTFS_DIR/usr/src/linux/.config
	chroot $ROOTFS_DIR make ARCH=$ARCH oldconfig -C /usr/src/linux
	#chroot $ROOTFS_DIR make ARCH=$ARCH defconfig -C /usr/src/linux
	chroot $ROOTFS_DIR /bin/bash
	chroot $ROOTFS_DIR make ARCH=$ARCH $THREADS -C /usr/src/linux
	chroot $ROOTFS_DIR make ARCH=$ARCH install modules_install dtbs_install -C /usr/src/linux
	printf "%s\n" "kernel=vmlinuz-$KERNEL_VERSION-gentoo" >> $ROOTFS_DIR/boot/config.txt
	if [ "$ARCH" = "arm" ]; then
		printf "%s\n" "device_tree=dtbs/$KERNEL_VERSION-gentoo/$DTB" >> $ROOTFS_DIR/boot/config.txt
	else
		printf "%s\n" "device_tree=dtbs/$KERNEL_VERSION-gentoo/broadcom/$DTB" >> $ROOTFS_DIR/boot/config.txt
	fi
	install -m 644 $FILES_DIR/cmdline.txt $ROOTFS_DIR/boot/

	# Install rngd
	#printf "=sys-apps/rng-tools-5-r2 **\n" > $ROOTFS_DIR/etc/portage/package.keywords/rng-tools
	#chroot $ROOTFS_DIR emerge rng-tools
	#chroot $ROOTFS_DIR rc-update add rngd default

	# Install ntp
	#chroot $ROOTFS_DIR emerge ntp
	#chroot $ROOTFS_DIR rc-update add ntpd default
	chroot $ROOTFS_DIR rc-update del hwclock boot
	chroot $ROOTFS_DIR rc-update add swclock boot

	# fstab
	if [ "$BOARD" = "rpi-4-b" ]; then
		printf "%s\n" "/dev/mmcblk1p1	/boot	vfat	noatime	0 2" >> $ROOTFS_DIR/etc/fstab
		printf "%s\n" "/dev/mmcblk1p2	/	ext4	noatime	0 1" >> $ROOTFS_DIR/etc/fstab
	else
		printf "%s\n" "LABEL=RPI-BOOT	/boot	vfat	noatime	0 2" >> $ROOTFS_DIR/etc/fstab
		#printf "%s\n" "LABEL=rpi-root	/	ext4	noatime	0 1" >> $ROOTFS_DIR/etc/fstab
		printf "%s\n" "LABEL=rpi-root	/	btrfs	noatime,compress=zstd	0 0" >> $ROOTFS_DIR/etc/fstab
	fi

	# Timezone
	printf "%s\n" "America/Los_Angeles" > $ROOTFS_DIR/etc/timezone
	chroot $ROOTFS_DIR emerge --config sys-libs/timezone-data

	# Locale
	printf "%s\n" "en_US.UTF-8 UTF-8" >> $ROOTFS_DIR/etc/locale.gen
	chroot $ROOTFS_DIR locale-gen

	# Networking
	printf "%s\n" "config_eth0=\"dhcp\"" > $ROOTFS_DIR/etc/conf.d/net
	ln -s net.lo $ROOTFS_DIR/etc/init.d/net.eth0
	chroot $ROOTFS_DIR rc-update add net.eth0 default

	# Hostname
	sed -i "/hostname=/c\hostname=\"$HOSTNAME\"" $ROOTFS_DIR/etc/conf.d/hostname

	# Comment out spawning agetty on ttyS0
	sed -i '/s0:12345/ s/^/#/' $ROOTFS_DIR/etc/inittab

	# Set keymap
	sed -i "s/keymap=\"us\"/keymap=\"$KEYMAP\"/" $ROOTFS_DIR/etc/conf.d/keymaps

	# Use empty root password
	sed -i "/root/c\root::10770:0:::::" $ROOTFS_DIR/etc/shadow

	#chroot $ROOTFS_DIR emerge -uavDN world

	umount_stuff $ROOTFS_DIR

	# Tar everything up while using as many threads as cores.
	tar -cvf $ROOTFS_TARBALL -C $ROOTFS_DIR -I "xz --threads=0" .
}

print_usage() {
	printf "Usage: genpi4 <platform>\n"
	printf "Valid platforms:\n"
	printf "                 rpi-b\n"
	printf "                 rpi-b-plus\n"
	printf "                 rpi-2-b\n"
	printf "                 rpi-3-b\n"
	printf "                 rpi-3-b-plus\n"
	printf "                 rpi-4-b\n"
	printf "                 setup\n"
	printf "The rpi-b, rpi-b-plus, and rpi-2-b platforms are 32-bit. All others are 64-bit.\n"
	printf "The 'setup' platform downloads necessary files to create an image.\n"
}


if [ $(id -u) -ne 0 ]; then
	printf "%s\n" "This must be run as root"
	exit 1
fi

BOARD=""
BITNESS=64
DTB=""

case $1 in
	rpi-b)
		BOARD="rpi-b"
		DTB="bcm2835-rpi-b.dtb"
		BITNESS=32
		;;
	rpi-b-plus)
		BOARD="rpi-b-plus"
		DTB="bcm2835-rpi-b-plus.dtb"
		BITNESS=32
		;;
	rpi-2-b)
		BOARD="rpi-2-b"
		DTB="bcm2836-rpi-2-b.dtb"
		BITNESS=32
		;;
	rpi-3-b)
		BOARD="rpi-3-b"
		DTB="bcm2837-rpi-3-b.dtb"
		;;
	rpi-3-b-plus)
		BOARD="rpi-3-b-plus"
		DTB="bcm2837-rpi-3-b-plus.dtb"
		;;
	rpi-4-b)
		BOARD="rpi-4-b"
		DTB="bcm2711-rpi-4-b.dtb"
		;;
	setup)
		initial_setup
		exit 0
		;;
	*)
		print_usage
		exit 1
		;;
esac

common $BOARD $BITNESS $DTB
