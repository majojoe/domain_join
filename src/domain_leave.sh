#!/bin/bash -e

trap onerr ERR
trap onexit EXIT

#trap handler 
onerr() { 
        echo "!!!!!!!!!!!!!!!!! ERROR while executing domain join !!!!!!!!!!!!!!!!!"
        exit 1
}

#trap handler 
onexit() { 
        # delete password on exit
        JOIN_PASSWORD=""
}


JOIN_USER=""
JOIN_PASSWORD=""
DOMAIN_NAME=""
PAM_MOUNT_FILE="/etc/security/pam_mount.conf.xml"
NSSWITCH_FILE="/etc/nsswitch.conf"


if [ "$(id -u)" -ne 0 ]; then
        echo "This script must be run as root in order to join to the given domain. Exiting..."
        exit
fi

# remove the domanin in /etc/hosts
# first param: domain name
remove_domain_hosts() {
        local DOMAIN_NAME
        DOMAIN_NAME="${1}"
        HOSTS_FILE="/etc/hosts"
        HOSTNAME_STR=$(hostname)
        HOSTNAME_ENTRY=$(cat "${HOSTS_FILE}" | grep "127.0.1.1")
        
        if [ -f "${HOSTS_FILE}" ]; then     
                if echo "${HOSTNAME_ENTRY}" | grep -q "${DOMAIN_NAME}"; then
                        sed -i "s/127.0.1.1.*/127.0.1.1       ${HOSTNAME_STR}/g" "${HOSTS_FILE}"
                fi
        fi
}

# correct nsswitch.conf so that a .local TLD domain can be resolved
correct_dns_for_local () {
        if [ -f "${NSSWITCH_FILE}" ]; then
                sed -i "s/hosts:[[:space:]]*files.*/hosts:          files mdns4_minimal [NOTFOUND=return] dns /g" "${NSSWITCH_FILE}"
        fi
}

# check if TLD is .local and if so, correct the nsswitch.conf file so that a resolution of the domain is possible properly
# first param: domain name
correct_dns_if_local_TLD () {
        local DOMAIN_STR
        local TLD_STR
        DOMAIN_STR="${1}"
        TLD_STR="${DOMAIN_STR##*.}"
        TLD_STR="${TLD_STR,,}"
        if [ "${TLD_STR}" = "local" ]; then
                correct_dns_for_local
        fi
}

#find domain controller
DNS_IP=$(systemd-resolve --status | grep "DNS Servers" | cut -d ':' -f 2 | tr -d '[:space:]')
DNS_SERVER_NAME=$(dig +noquestion -x "${DNS_IP}" | grep in-addr.arpa | awk -F'PTR' '{print $2}' | tr -d '[:space:]' )
DNS_SERVER_NAME=${DNS_SERVER_NAME%?}
DOMAIN_NAME=$(echo "${DNS_SERVER_NAME}" | cut -d '.' -f2-)


# enter domain name
DOMAIN_NAME=$(dialog --title "domain name" --inputbox "Enter the domain name you want to leave from. \\nE.g.: example.com or example.local" 12 40 "${DOMAIN_NAME}" 3>&1 1>&2 2>&3 3>&-)
# choose domain user to use for joining the domain
JOIN_USER=$(dialog --title "User for domain join" --inputbox "Enter the user to use for leaving the domain" 10 30 "Administrator" 3>&1 1>&2 2>&3 3>&-)
# enter password for join user
JOIN_PASSWORD=$(dialog --title "Password" --clear --insecure --passwordbox "Enter your password for user ${JOIN_USER}" 10 30 "" 3>&1 1>&2 2>&3 3>&-)

dialog --clear
clear

correct_dns_if_local_TLD "${DOMAIN_NAME}"

# leave the given domain with the given user
echo "${JOIN_PASSWORD}" | realm -v leave -U "${JOIN_USER}" "${DOMAIN_NAME}"
# delete the password of the join user
JOIN_PASSWORD=""

#unconfigure_shares 
xmlstarlet ed --inplace -d "//volume[contains(@server, \"${DOMAIN_NAME}\") and @fstype=\"cifs\"]" "${PAM_MOUNT_FILE}"

SSSD_CONF_FILE="/etc/sssd/sssd.conf"
if [ -f ${SSSD_CONF_FILE} ]; then
        rm "${SSSD_CONF_FILE}"
fi

# remove line that adds the std groups for all domain users
sed -i '/*;*;*;Al0000-2400;adm,cdrom,dip,plugdev,lpadmin,lxd,sambashare/d' /etc/security/group.conf
# remove all domain users from sudo group
DU_SUDO_FILE=/etc/domain_user_for_sudo.conf
if [ -f "${DU_SUDO_FILE}" ]; then
        while read -r username 
        do 
                set +e
                gpasswd -d "${username}" sudo
                set -e
        done < "${DU_SUDO_FILE}"
fi

#remove domain from hosts file
remove_domain_hosts "${DOMAIN_NAME}"

echo "############### LEFT DOMAIN SUCCESSFULL AND SHARES REMOVED #################"
