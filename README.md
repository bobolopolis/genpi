# GenPi
Utility to assist in creating Gentoo images for the Raspberry Pi. This program
will automatically partition the SD card and setup a fully working Gentoo
installation that is ready to boot on a Raspberry Pi 1 or 2. To use this
utility, the following variables should be customized prior to use:

	SD="/dev/mmcblk0" # Set to base block device, such as "/dev/sdb".
	SD_BOOT="p1" # Set to boot partition suffix, such as "1".
	SD_SWAP="p2" # Set to swap partition suffix, such as "2".
	SD_ROOT="p3" # Set to root partition suffix, such as "3".

	# Set these variables to change the SD card partition layout.
	BOOT_SIZE="128" # Size of the boot partition in MiB.
	SWAP_SIZE="1024" # Size of the swap partition in MiB.
	ROOT_SIZE="100%" # Size of the root partition, either in MiB or "100%".

	# Set the version of the Raspberry Pi hardware.
	#   1: Creates an armv6j_hardfp image for the original Raspberry Pi
	#   2: Creates an armv7a_hardfp image for the Raspberry Pi 2
	#   3: Because there is not yet a stage 3 tarball for the Raspberry Pi 3, this
	#      creates the same armv7a_hardfp image as the Raspberry Pi 2. Hopefully
	#      an armv8a stage 3 tarball will be released in the near future.
	PI_VERSION=1 # Set to 1 for the original Raspberry Pi, 2 for the Raspberry Pi 2
	HOSTNAME="raspy" # Hostname for the image.
	TIMEZONE="America/Los_Angeles" # Timezone to set in the image.
	KEYMAP="us" # The keymap to use for the console.
Once these parameters are set, simply run the script as root. When creating the
image, a three partition setup is assumed. The SD card will contain a boot
partition, a swap partition, and a root partition.

The script will create a cache directory to store the files it downloads to
create the image. If the necessary files exist in the cache directory, they
will not be downloaded again. The following files are cached:
 * portage snapshot
 * stage 3 tarball
 * Raspberry Pi firmware repository

If the cache is stale, simply delete it and rerun the script:

	$ sudo rm -rf ./cache
