#!/bin/bash

re='^[0-9]+$'

function mount_boot() {
	mkdir -p /boot
	mount /dev/sda1 /boot
}

function emerge_sync() {
	emerge-webrsync
	emerge --sync
}

function emerge_select_profile() {
	items=$(( $(eselect profile list | wc -l) - 1))
	eselect profile list

	while : ; do
		echo -n 'Select the profile you want to use: '
		read choice

	  	if [[ "$choice" =~ $re ]] && [[ $choice -ge 1 ]] && [[ $choice -le $items ]] ; then
			eselect profile set --force $choice
			break;
		else
			echo 'Invalid choice'
		fi
	done
}

function update_packages() {
	emerge -uDNq @world
}

function set_timezone() {
	echo 'Available time zones: https://en.wikipedia.org/wiki/List_of_tz_database_time_zones'
	echo -n 'Enter your time zone [America/Chicago] : '
	read time_zone

	if [[ -z $time_zone ]] ; then
		time_zone='America/Chicago'
	fi

	echo $time_zone > /etc/timezone
	emerge --config sys-libs/timezone-data
}

function set_locales() {
	echo -n 'Press n to manually set locales, otherwise press enter: '
	read choice

	if [[ "$choice" == 'n' ]] ; then
		nano -w /etc/locale.gen
	else
		echo 'en_US ISO-8859-1' >> /etc/locale.gen
		echo 'en_US.UTF-8 UTF-8' >> /etc/locale.gen
	fi

	locale-gen
	list_size=$(( $(eselect locale list | wc -l) - 2))
	default_locale=$(eselect locale list | grep "en_US.utf8" | cut -d "[" -f 2 | cut -d "]" -f 1)
	eselect locale list
	echo -n "Which locale would you like to use? [${default_locale}]: "
	read choice

	if [[ -z $choice ]] && ! [[ -z $default_locale ]]; then
		eselect locale set $default_locale
	fi

	if [[ "$choice" =~ $re ]] && [[ $choice -ge 1 ]] && [[ $choice -le $list_size ]] ; then
		eselect locale set $choice
	fi
	env-update
	source /etc/profile
}

function kernel_install() {
	echo 'Downlading kernel sources and utilties'
	emerge -q sys-kernel/gentoo-sources
	emerge -q sys-apps/pciutils
	echo 'Moving default config to directory, please add appropriate changes'

	if [[ -f '/usr/src/linux/.config' ]] ; then
		cp /usr/src/linux/.config /usr/src/linux/copy.config
	fi

	echo -n 'Type vm to load vm config, otherwise a barebones config will be loaded: '
	read choice

	if [ "$choice" == 'vm' ] ; then
		cp vm.config /usr/src/linux/.config
	else
		cp kernel.config /usr/src/linux/.config
	fi

	cd /usr/src/linux
	echo 'sys-kernel/gentoo-sources symlink' > /etc/portage/package.use/kernel
	make menuconfig
	make -j$(nproc)
	make modules_install
	make headers_install
	make install
}

function network_setup() {
	echo -n 'Enter your desired hostname: '
	read host_name
	echo "HOSTNAME=\"${host_name}\"" > /etc/conf.d/hostname

	echo -n 'Enter your domain name: '
	read domain_name

	echo "dns_domain_lo=\"${domain_name}\"" > /etc/conf.d/ne
	echo "nis_domain_lo=\"${domain_name}\"" >> /etc/conf.d/net

	mapfile -t interfaces < <(ip a | grep 'state UP' | cut -d ':' -f 2 | tr -d ' ')
	length=$(( ${#interfaces[@]} - 1))

	if [[ $length -eq -1 ]] ; then
		echo 'No network interfaces found!'
		echo 'Printing network information'
		ip a
		exit
	fi

	echo 'Found interfaces: '
	for i in $(seq 0 $length); do
		echo "${i}: ${interfaces[$i]}"
	done

	for i in $(seq 0 $length); do
		echo -n "Would you like to use dhcp for interface ${i}? [y]: "
		read choice
		if [[ "$choice" == 'n' ]] ; then
			echo -n "Enter the ip/cidr for interface ${i} [ex. 192.168.0.2/24]: "
			read ipaddr
			echo -n "Enter the gateway for interface ${i} [ex. 192.168.0.1]: "
			read gateway
			echo -n "Enter teh DNS servers for interface ${i} [ex. 1.1.1.1 1.0.0.1]: "
			read dns
			echo "config_${interfaces[$i]}=\"${ipaddr}\"" >> /etc/conf.d/net
			echo "route_${interfaces[$i]}=\"default via ${gateway}\"" >> /etc/conf.d/net
			echo "dns_servers_${interface[$i]}=\"${dns}\"" >> /etc/conf.d/net
		else
			echo -n "Setting interface ${1} as a DHCP interface"
			echo "config_${interfaces[$i]}=\"dhcp\"" >> /etc/conf.d/net
		fi
		ln -s /etc/init.d/net.lo /etc/init.d/net.${interfaces[$i]}
		rc-update add net.${interfaces[$i]} default
	done

	emerge --noreplace net-misc/netifrc
}

function complete_install() {
	echo -n 'Would you like to install sudo, sysklogd, cronie, sshd, dhcpcd, ntp, bind-utils and htop? [y]: '
	read choice
	if [[ -z $choice ]] || [[ "$choice" == 'y' ]] ; then
		emerge -q sudo app-admin/sysklogd sys-process/cronie net-misc/dhcpcd net-misc/ntp bind-tools htop
		rc-update add sysklogd default
		rc-update add cronie default
		rc-update add sshd default
		rc-update add ntp-client default
		echo '%wheel ALL=(ALL) ALL' >> /etc/sudoers
	fi

	echo "Installing and configuring grub"
	emerge -q sys-boot/grub:2
	mount -o remount,rw '/sys/firmware/efi/efivars'
	grub-install --target=x86_64-efi --efi-directory='/boot'
	nano '/etc/default/grub'
	grub-mkconfig -o '/boot/grub/grub.cfg'

	echo -n 'Would you like to install the linux firmware package (not needed for VMs)? [n]: '
	read choice
	if [[ "$choice" == 'y' ]] ; then
		echo 'sys-kernel/linux-firmware linux-fw-redistributable no-source-code' >> /etc/portage/package.license
		emerge -q sys-kernel/linux-firmware
	fi

	echo -n 'Enter name for user to add: '
	read username
	useradd -m -G users,wheel -s '/bin/bash' "${username}"
	passwd ${username}
	echo 'Enter a new root password'
	passwd
	echo 'The updating the fstab'
	echo -e "/dev/sda2\t\t/\t\text4\t\tnoatime\t\t0 1" >> '/etc/fstab'
	nano '/etc/fstab'
	nano '/etc/selinux/config'

	echo -n 'Would you like to delete installer files and the stage 3 tarball? [y]'
	read choice
	if [[ -z $choice ]] || [[ "$choice" == 'y' ]] ; then
		rm /stage3*
		rm /install2.sh
		rm /vm.config
		rm /kernel.config
		rm /selinux_install.sh
	fi
}

SHELLNOCASEMATCH=`shopt -p nocasematch`
shopt -s nocasematch

mount_boot
emerge_sync
emerge_select_profile
update_packages
set_timezone
set_locales
kernel_install
network_setup
complete_install

$SHELLNOCASEMATCH
