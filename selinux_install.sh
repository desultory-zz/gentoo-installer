#!/bin/bash

function phase_1() {
	echo '%wheel ALL=(ALL) ROLE=sysadm_r TYPE=sysadm_t ALL' > /etc/sudoers.d/wheel
	chmod 0400 /etc/sudoers.d/wheel
	FEATURES="-selinux" emerge -1 selinux-base
	nano /etc/selinux/config
	rc-update add auditd default
	echo 'tmpfs                   /tmp    tmpfs   defaults,noexec,nosuid,rootcontext=system_u:object_r:tmp_t      0 0' >> /etc/fstab
	echo 'tmpfs                   /run    tmpfs   mode=0755,nosuid,nodev,rootcontext=system_u:object_r:var_run_t  0 0' >> /etc/fstab
	FEATURES="-selinux -sesandbox" emerge -1 selinux-base
	FEATURES="-selinux -sesandbox" emerge selinux-base-policy
	emerge -uDNq @world
	nano /etc/pam.d/run_init
	echo 'You now need to reboot and run part 2 of this script'
	echo 'NOTE: Some things like sudo will be broken when you reboot for the first time, make sure you have your root password'
}

function phase_2() {
	mkdir /mnt/gentoo
	mount -o bind / /mnt/gentoo
	setfiles -r /mnt/gentoo /etc/selinux/strict/contexts/files/file_contexts /mnt/gentoo/{dev,home,proc,run,sys,tmp} 
	umount /mnt/gentoo
	rlpkg -a -r
	setsebool -P global_ssp on
	setsebool -P tmpfiles_manage_all_non_security on
	echo -n 'Enter the username of your staff account: '
	read account_name
	semanage login -a -s staff_u $account_name
	restorecon -R -F /home/${account_name}
}

echo -n 'Type "1" if you are running this script for the first time, otherwise type "2" to run the second phase: '
read choice
if [[ "$choice" == '1' ]] ; then
	phase_1
else 
	phase_2
fi
