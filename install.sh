#!/bin/bash
re='^[0-9]+$'

function get_disks () {
	echo 'Finding local disks'
	mapfile -t drives < <(lsblk -Pn -o PATH,SIZE,TYPE | grep -v "loop\|rom\|part" | cut -d ' ' -f 1 | cut -d '=' -f 2 | tr -d '"')
	mapfile -t sizes < <(lsblk -Pn -o PATH,SIZE,TYPE | grep -v "loop\|rom\|part" | cut -d ' ' -f 2 | cut -d '=' -f 2 | tr -d '"')
	length=$((${#drives[@]} - 1))

	if [ $length -eq -1 ] ; then
		echo 'No drives found'
		echo 'priting block devices'
		lsblk
		exit
	fi
}

function write_partitions() {
	while : ; do
		for i in $(seq 0 $length); do
			echo "${i}:  ${drives[$i]}   ${sizes[$i]}"
		done
		echo -n 'Select the hard drive you want to install Gentoo on [0]: '
		read choice

		if [[ -z $choice ]]; then
			choice=0
			break
		fi

		if [[ "$choice" =~ $re ]] && [[ $choice -ge 0 ]] && [[ $choice -le $length ]] ; then
			break
		else
			choice=-1
			echo 'Invalid choice'
		fi
	done

	while : ; do
		echo -n 'How large would you like your boot partition to be? [128MB]: '
		read size

		if [[ -z $size ]]; then
			size=128
			break
		fi

		if ! [[ "$size" =~ $re ]] || [[ $size -le 0 ]] ; then
			echo 'Invalid input'
			continue
		else
			break
		fi
	done

	size=$((size + 1))
	drive=${drives[$choice]}

	echo 'Wiping partitions on $drive'
	wipefs -faq $drive

	echo 'Writing new partition table'
	parted -s -a optimal $drive mklabel gpt
	parted -s -a optimal $drive unit mb mkpart primary "1 $size"
	parted -s -a optimal $drive name 1 boot
	parted -s -a optimal $drive set 1 boot on
	parted -s -a optimal $drive unit mb mkpart primary "$size -1"
	parted -s -a optimal $drive name 2 rootfs
	parted -s -a optimal $drive print

	echo 'Creating filesystems'
	mkfs.fat -F 32 "${drive}1"
	mkfs.ext4 "${drive}2"

	echo 'Mounting filesystem'
	mount ${drive}2 /mnt/gentoo
}

function download_stage() {
	cd /mnt/gentoo
	stage_dir='https://gentoo.osuosl.org/releases/amd64/autobuilds/current-stage3-amd64/'
	stage=$(curl -s "$stage_dir" | sed -n 's/.*href="\([^"]*\).*/\1/p' | grep "stage3-amd64-2" | grep -v "CONTENTS\|DIGESTS")

	if [[ -z $stage ]] ; then
		echo 'Unable to find the current Gentoo state3 download...'
		break;
	fi

	if [[ -f "$stage" ]] ; then
		echo 'Stage archive already found, deleting and redownloading'
		rm $stage
	fi

	download="${stage_dir}${stage}"
	echo 'Downloading $download'
	wget "$download"

	echo 'Extracting $download'
	tar xpvf "$stage" --xattrs-include='*.*' --numeric-owner

	echo 'Setting permissions on /mnt/gentoo/tmp'
	chmod 1777 /mnt/gentoo/tmp
}

function update_make() {
	make_loc='/mnt/gentoo/etc/portage/make.conf'
	make_orig='/mnt/gentoo/etc/portage/make.orig'

	if ! [[ -f $make_orig ]] ; then
		echo "Creating a copy of the original make file at $make_orig"
		cp $make_loc $make_orig
	fi

	echo -n "Would you like to change the common flags to '-march=native -O2 -pipe'? [y]: "
	read choice
	if [[ "$choice" == 'y' ]] || [[ -z $choice ]] ; then
		sed -i 's/COMMON_FLAGS=\".*/COMMON_FLAGS="-march=native -O2 -pipe"/' "$make_loc"
	fi

	echo -n "Would you like to set the mirrors to be https only? [y]: "
	read choice
	if [[ "$choice" == 'y' ]] || [[ -z $choice ]] ; then
		echo 'GENTOO_MIRRORS="https://gentoo.ussg.indiana.edu/ https://mirrors.lug.mtu.edu/gentoo/ https://gentoo.osuosl.org/ https://mirrors.rit.edu/gentoo/ https://mirror.sjc02.svwh.net/gentoo/"' >> "$make_loc"
	fi

	echo -n "Would you like to set the grub platform to 'efi-64'? [y]: "
	read choice
	if [[ "$choice" == 'y' ]] || [[ -z $choice ]] ; then
		echo 'GRUB_PLATFORMS="efi-64"' >> "$make_loc"
	fi

	echo -n "Would you like to set the SELinux policy type to strict? [y]: "
	read choice
	if [[ "$choice" == 'y' ]] || [[ -z $choice ]] ; then
		echo 'POLICY_TYPES="strict"' >> "$make_loc"
	fi

	echo -n "Would you like to set the secure SELinux use flags? (peer_perms open_perms ubac) [y]: "
	read choice
	if [[ "$choice" == 'y' ]] || [[ -z $choice ]] ; then
		use_flags="peer_perms open_perms ubac"
	else
		use_flags=""
	fi

	echo -n "Would you like to disable ipv6? [y]: "
	read choice
	if [[ "$choice" == 'y' ]] || [[ -z $choice ]] ; then
		use_flags="$use_flags -ipv6"
	fi

	echo "Writing use flags $use_flags"
	echo "USE=\"$use_flags\"" >> $make_loc

	cpus=$(nproc)
	while : ; do
		echo -n "$cpus core(s) found, how many cores would you like the compiler to use? [$cpus]: "
		read cores

		if [[ -z $cores ]]; then
			cores=$cpus
			break
		fi

		if ! [[ "$cores" =~ $re ]] || [[ $cores -le 0 ]] ; then
			echo 'Invalid input'
			continue
		else
			break
		fi
	done
	echo "MAKEOPTS=\"-j${cores}\"" >> $make_loc

	echo 'Make file: '
	cat $make_loc

	conf=''
	while [[ "$conf" != 'ok' ]] || [[ "$conf" != 'reset' ]] ;  do
		echo "Type 'ok' to confirm changes, type 'reset' to reset the config to the defaults: "
		read conf

		if [[ "$conf" == 'reset' ]] ; then
			echo 'Restoring default file'
			cp $make_orig $make_loc
			break
		fi

		if [[ "$conf" == 'ok' ]] ; then
			echo 'Keeping changes'
			break
		fi

		echo 'Invalid input'
	done
}

function move_portage_config() {
	mkdir --parents /mnt/gentoo/etc/portage/repos.conf
	cp /mnt/gentoo/usr/share/portage/config/repos.conf /mnt/gentoo/etc/portage/repos.conf/gentoo.conf
	cp --dereference /etc/resolv.conf /mnt/gentoo/etc/
}

function mount_filesystems() {
	mount --types proc /proc /mnt/gentoo/proc
	mount --rbind /sys /mnt/gentoo/sys
	mount --make-rslave /mnt/gentoo/sys
	mount --rbind /dev /mnt/gentoo/dev
	mount --make-rslave /mnt/gentoo/dev
	test -L /dev/shm && rm /dev/shm && mkdir /dev/shm
	mount --types tmpfs --options nosuid,nodev,noexec shm /dev/shm
	chmod 1777 /dev/shm
	cd
	cp *.config /mnt/gentoo
	cp install2.sh /mnt/gentoo/
	cp selinux_install.sh /mnt/gentoo/
	echo 'Copied part two of this script to /mnt/gentoo'
	echo 'You need to run the following commands:'
	echo 'chroot /mnt/gentoo'
	echo 'source /etc/profile'
	echo 'export PS1="(chroot) ${PS1}"'
	echo './install2.sh'
}

SHELLNOCASEMATCH=`shopt -p nocasematch`
shopt -s nocasematch

get_disks
write_partitions
download_stage
update_make
move_portage_config
mount_filesystems

$SHELLNOCASEMATCH
