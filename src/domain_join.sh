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
PERMITTED_GROUPS=""
JOIN_PASSWORD=""
DOMAIN_NAME=""
TIMEZONE="Europe/Berlin"
DOMAIN_CONTROLLER=""
FULLY_QUALIFIED_DN=0
SDDM_CONF_FILE="/etc/sddm.conf"
KRB5_CONF="/etc/krb5.conf"
NSSWITCH_FILE="/etc/nsswitch.conf"
DNS_IP=""

if [ "$(id -u)" -ne 0 ]; then
        echo "This script must be run as root in order to join to the given domain. Exiting..."
        exit
fi

# choose the time zone 
choose_timezone () {
        local TIMELIST
        local COUNTER
        local RADIOLIST
        local TIMEZONE_NR
        local TIMEZONE
        
        TIMELIST=$(timedatectl list-timezones)
        COUNTER=1
        RADIOLIST=""  # variable where we will keep the list entries for radiolist dialog
        TIMEZONE_NR=0
        
        for i in $TIMELIST; do
                RADIOLIST="$RADIOLIST $COUNTER $i off "
                # shellcheck disable=SC2219
                let COUNTER=COUNTER+1
        done
        
        # shellcheck disable=SC2086
        TIMEZONE_NR=$(dialog --backtitle "choose timezone" --radiolist "Select option:" 0 0 $COUNTER $RADIOLIST 3>&1 1>&2 2>&3 3>&-)

        COUNTER=1
        for i in $TIMELIST; do
                if [ $COUNTER -eq "$TIMEZONE_NR" ]; then
                        TIMEZONE=$i
                        break
                fi
                # shellcheck disable=SC2219
                let COUNTER=COUNTER+1
        done
        
        #set the timezone
        timedatectl set-timezone "${TIMEZONE}"
}


# set the groups that can log in 
# first param: the join user that is used to setup domain membership
set_group_policies () {
        local JOIN_USER
        local PERMITTED_GROUPS
        JOIN_USER="${1}"
        PERMITTED_GROUPS=$(dialog --title "permitted groups"  --inputbox "Enter the groups of the domain that shall be permitted to log in. Groups must be comma separated.\\nLeave blank if you want allow all domain users to login." 12 50 "" 3>&1 1>&2 2>&3 3>&-)

        #remove spaces
        PERMITTED_GROUPS=$(echo "${PERMITTED_GROUPS}" | tr -d '[:space:]')

        clear

        if [ -z "${PERMITTED_GROUPS}" ]; then
                echo "permit all users to login"
                realm permit --all
        else
                #allow all groups that shall be able to log in
                echo "allow given groups"
                realm deny --all
                realm permit "${JOIN_USER}@${DOMAIN_NAME}"
                SAVEIFS=$IFS
                IFS=","
                for i in ${PERMITTED_GROUPS}
                do
                        realm permit -g "${i}" 
                done
                IFS=$SAVEIFS
        fi
}

# configure krb5-user package in order to not get any dialogs presented, since the configuration files must be there, first.
# first param: domain name
# second param: admin server (main domain controller)
configure_krb5_package() {
        local KRB5_UNCONF
        local DOMAIN_NAME
        local ADMIN_SERVER
        local DOMAIN_REALM
        local DOMAIN_UPPER
        local REALM_DEFINITION
        
        KRB5_UNCONF="/etc/krb5.conf.unconfigured"
        DOMAIN_NAME="${1}"
        ADMIN_SERVER="${2}"
        echo "install krb5-user"
        if [ -f "${KRB5_UNCONF}" ]; then
                cp "${KRB5_UNCONF}" "${KRB5_CONF}"
                #realm name
                sed -i "s/REALM_NAME/${DOMAIN_NAME^^}/g" "${KRB5_CONF}"
                
                #realm definiton
                DOMAIN_UPPER=${DOMAIN_NAME^^}
                REALM_DEFINITION="${DOMAIN_UPPER} = {"
                DC_DNS_LIST=$(nslookup -type=srv _kerberos._tcp."${DOMAIN_NAME}" | grep "${DOMAIN_NAME}" | pcregrep -o1 "(\S+)\.$")
                DC_LIST=()
                while IFS= read -r DC; do
                        DC_LIST+=("${DC}")
                done <<< "$DC_DNS_LIST"

                for i in "${DC_LIST[@]}"
                do
                        REALM_DEFINITION="${REALM_DEFINITION}\n        kdc = $i"
                done
                
                REALM_DEFINITION="${REALM_DEFINITION}\n        admin_server = ${ADMIN_SERVER}\n}"
                sed -i "s/REALM_DEFINITION/${REALM_DEFINITION}/g" "${KRB5_CONF}"
                
                # domain realm
                DOMAIN_REALM="        .${DOMAIN_NAME} = ${DOMAIN_UPPER}\n        ${DOMAIN_NAME} = ${DOMAIN_UPPER}"
                sed -i "s/DOMAIN_REALM/${DOMAIN_REALM}/g" "${KRB5_CONF}"                
        fi        
}

# install krb5-user package. Configuring of the files belonging to the package must be done first, meaning first to call configure_krb5_package before calling this method.
install_krb5_package() {
        apt install krb5-user -y
}

# set the domanin name in realmd configuration
# first param: domain name
set_domain_realmd() {
        local DOMAIN_NAME
        DOMAIN_NAME="${1}"
        REALMD_FILE="/etc/realmd.conf"
        
        if [ -f "${REALMD_FILE}" ]; then
                sed -i "s/DOMAIN_NAME/${DOMAIN_NAME}/g" "${REALMD_FILE}"
        fi
}

# set the domanin in /etc/hosts
# first param: domain name
set_domain_hosts() {
        local DOMAIN_NAME
        DOMAIN_NAME="${1}"
        HOSTS_FILE="/etc/hosts"
        HOSTNAME_STR=$(hostname)
        HOSTNAME_ENTRY=$(grep "127.0.1.1" "${HOSTS_FILE}")
        
        if [ -f "${HOSTS_FILE}" ]; then     
                if ! echo "${HOSTNAME_ENTRY}" | grep -q "${DOMAIN_NAME}"; then
                        sed -i "s/127.0.1.1.*/127.0.1.1       ${HOSTNAME_STR}.${DOMAIN_NAME}  ${HOSTNAME_STR}/g" "${HOSTS_FILE}"
                fi
        fi
}

# set the timeserver to use
# first param:  domain controller
set_timeserver() {
        local NTP_SERVER
        local DOMAIN_CONTROLLER
        
        DOMAIN_CONTROLLER="${1}"
        
        echo "set timeserver"
        NTP_SERVER=$(dialog --title "NTP server" --inputbox "Enter the NTP server (domain controller) you want to use. \\nE.g.: srv-dc01.example.local" 12 40 "${DOMAIN_CONTROLLER}" 3>&1 1>&2 2>&3 3>&-)
        TIMESYNCD_FILE="/etc/systemd/timesyncd.conf"
        if grep -q "#[[:space:]]*NTP" "$TIMESYNCD_FILE"; then
                # if NTP is commented out
                sed -i "s/#[[:space:]]*NTP=/NTP=/g" "$TIMESYNCD_FILE"
        fi
        sed -i "s/^NTP=.*/NTP=${NTP_SERVER}/g" "$TIMESYNCD_FILE"

        systemctl restart systemd-timesyncd.service
}

# configure available shares for automatic mounting on login
# first param: domain controller
configure_shares() { 
        local DOMAIN_CONTROLLER
        local FILE_SERVER
        local DRIVE_LIST
        local MNT_POINT
        local PAM_MOUNT_FILE
        local MOUNT_STR
        local FILE_SERVER
        local CHECKLIST
        
        PAM_MOUNT_FILE="/etc/security/pam_mount.conf.xml"
        DOMAIN_CONTROLLER="${1}"
        FILE_SERVER=$(dialog --title "fileserver" --inputbox "Enter the fileserver to use for mounting of drives when a user logs in. \\nE.g.: srv-file01.example.local" 12 40 "${DOMAIN_CONTROLLER}" 3>&1 1>&2 2>&3 3>&-) 
        DRIVE_LIST=$(smbclient -k -N  -U "${JOIN_USER}" -L "${FILE_SERVER}" 2> /dev/null | grep Disk  | grep -v -E "ADMIN\\$|SYSVOL|NETLOGON" | cut -d " " -f 1 | grep -E "[a-zA-Z0-9]{2,}(\\$)*" | tr -d '\t')
        CHECKLIST=""


        if [ -n "${DRIVE_LIST}" ]; then
                set +e
                dialog --title "Add options for this fileserver?" --defaultno --yesno "Do you want to add options for this fileserver (e.g. vers=2.0)?" 12 40 
                ADD_OPTIONS=$?
                set -e
                if [ 0 -eq ${ADD_OPTIONS} ]; then
                        FILESERVER_OPTIONS=$(dialog --title "fileserver options"  --inputbox "Enter the additional fileserver options for the current fileserver (give them with commas if more than one option is provided. e.g. vers=2.0,guest)." 12 50 "" 3>&1 1>&2 2>&3 3>&-)
                fi        
        
                for i in ${DRIVE_LIST}; do
                        MNT_POINT=$(echo "${i}" | tr -d '$')
                        CHECKLIST+=("${i} /media/\$USER/${MNT_POINT} off ")
                done
                
                
                # shellcheck disable=SC2068
                DRIVE_LIST=$(dialog --single-quoted --backtitle "Choose Drives to mount" --checklist "Choose which drives shall be mounted when a user logs in..." 20 60 ${#CHECKLIST[@]} ${CHECKLIST[@]} 3>&1 1>&2 2>&3 3>&-)        
                dialog --clear
                clear

                for i in ${DRIVE_LIST}; do
                        i=$(echo "${i}" | tr -d "'")
                        MNT_POINT=$(echo "${i}" | tr -d '$')
                        MOUNT_STR="volume fstype=\"cifs\" server=\"${FILE_SERVER}\" path=\"${i}\" mountpoint=\"/media/%(USER)/${MNT_POINT}\" options=\"iocharset=utf8,nosuid,nodev,${FILESERVER_OPTIONS}\" uid=\"5000-999999999\""
                        if [ -f "${PAM_MOUNT_FILE}" ]; then
                                xmlstarlet ed --inplace -s '/pam_mount' -t elem -n "${MOUNT_STR}" "${PAM_MOUNT_FILE}"
                        else
                                dialog --msgbox "error writing mount entries in ${PAM_MOUNT_FILE}" 5 40 3>&1 1>&2 2>&3 3>&-
                                exit 2
                        fi
                done
        else
                dialog --msgbox "No Drives found for given fileserver ${FILE_SERVER}" 5 40 3>&1 1>&2 2>&3 3>&-
        fi
}

# configure available shares for automatic mounting on login
# first param: domain controller
configure_file_servers() { 
        local DOMAIN_CONTROLLER
        DOMAIN_CONTROLLER="${1}"
        
        local AGAIN=1
        while [ 1 -eq  ${AGAIN} ]
        do
                configure_shares "${DOMAIN_CONTROLLER}"
                set +e
                dialog --title "Add shares of another fileserver?" --defaultno --yesno "Do you want to add the shares of another fileserver?" 12 40 
                AGAIN=$?
                set -e
                if [ 0 -eq ${AGAIN} ]; then
                        AGAIN=1
                else
                        AGAIN=0
                fi
        done
}

# configure to use fully qualified names
use_fully_qualified_names() {
        REALMD_FILE="/etc/realmd.conf"
        
        if [ -f "${REALMD_FILE}" ]; then
                sed -i "/^default-home\s=/s/=.*/= \/home\/%u@%d/" "${REALMD_FILE}"
                sed -i "/^fully-qualified-names\s=/s/=.*/= yes/" "${REALMD_FILE}"
        fi
}

# set administrative rights for domain users/groups 
# first param: 0 if no FQDNs are used, 1 if FQDNs are used for users/groups
# second param: the fully qualified domain name
set_sudo_users_or_groups() {
        local FQDN 
        local DN
        local PERMITTED_AD_ENTITIES
        local SAVEIFS
        local SUDOERS_AD_FILE
        local DU_SUDO_FILE
        FQDN=$1
        DN="${2}"
        SUDOERS_AD_FILE="/etc/sudoers.d/active_directory"
        DU_SUDO_FILE="/etc/domain_user_for_sudo.conf"
        PERMITTED_AD_ENTITIES=$(dialog --title "administrative rights for domain users/groups"  --inputbox "Enter the domain users or groups that shall be allowed to gain administrative rights. \\nUsers/groups must be comma separated. \\nGroups must be prepended by a '%' sign.\\nLeave blank if you don't want allow any user/group in the domain to gain administrative rights.\\nHint: Some environments like KDE require to give the users with administrative rights here in order for the password popups to work - giving the groups the users are in will not work.\\n " 15 60 "" 3>&1 1>&2 2>&3 3>&-)

        clear

        if [ -n "${PERMITTED_AD_ENTITIES}" ]; then
                echo "administrative rights for given users/groups"
                SAVEIFS=$IFS
                IFS=","
                for i in ${PERMITTED_AD_ENTITIES}
                do
                        I_NO_SPACE="$(echo -e "${i}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
                        # shellcheck disable=SC2086
                        if [ $FQDN -eq 1 ]; then
                                #use fully qualified domain names
                                echo "\"${I_NO_SPACE}@${DN}\" ALL=(ALL:ALL) ALL" >> "${SUDOERS_AD_FILE}"
                                if ! [[ "${I_NO_SPACE}" = %* ]]; then
                                        usermod -aG sudo "${I_NO_SPACE}@${DN}"
                                        echo "${I_NO_SPACE}@${DN}" >> "${DU_SUDO_FILE}"
                                fi
                        else
                                echo "\"${I_NO_SPACE}\" ALL=(ALL:ALL) ALL" >> "${SUDOERS_AD_FILE}"
                                if ! [[ "${I_NO_SPACE}" = %* ]]; then
                                        usermod -aG sudo "${I_NO_SPACE}"
                                        echo "${I_NO_SPACE}" >> "${DU_SUDO_FILE}"
                                fi
                        fi
                        
                done
                IFS=$SAVEIFS
        fi
}

# set the standard groups for domain users
set_std_groups_for_domain() {
        local GROUPS_FILE
        GROUPS_FILE="/etc/security/group.conf"
        if [ -f "${GROUPS_FILE}" ]; then
                sed -i '/^#xsh; tty\* ;%admin;Al0000-2400;plugdev.*/a \\n*;*;*;Al0000-2400;adm,cdrom,dip,plugdev,lpadmin,lxd,sambashare' "${GROUPS_FILE}"
        fi
}

# add possibility to login with xrdp when used
allow_xrdp_login() {
# add some options to sssd.conf to allow login with xrdp
        SSSD_CONF_FILE="/etc/sssd/sssd.conf"
        if [ -f ${SSSD_CONF_FILE} ]; then
                sed -i '/^\[domain\/.*/a ad_gpo_access_control = enforcing\nad_gpo_map_remote_interactive = +xrdp-sesman' "${SSSD_CONF_FILE}"
        fi
}

# remove input method from /etc/sddm.conf file
correct_input_method() {
        if [ -f "${SDDM_CONF_FILE}" ]; then
                sed -i "s/^InputMethod=.*/InputMethod=/g" "${SDDM_CONF_FILE}"
        fi
}

# activate weak crypto (DES)
activate_weak_crypto() {
        sed -i "s/#[[:space:]]*allow_weak_crypto.*/        allow_weak_crypto = true/g" "${KRB5_CONF}"
        sed -i "s/#[[:space:]]*default_tgs_enctypes.*/        default_tgs_enctypes = aes256-cts-hmac-sha1-96 rc4-hmac des-cbc-crc des-cbc-md5/g" "${KRB5_CONF}"
        sed -i "s/#[[:space:]]*default_tkt_enctypes.*/        default_tkt_enctypes = aes256-cts-hmac-sha1-96 rc4-hmac des-cbc-crc des-cbc-md5/g" "${KRB5_CONF}"
        sed -i "s/#[[:space:]]*permitted_enctypes.*/        permitted_enctypes = aes256-cts-hmac-sha1-96 rc4-hmac des-cbc-crc des-cbc-md5/g" "${KRB5_CONF}"
}

# correct nsswitch.conf so that a .local TLD domain can be resolved
correct_dns_for_local () {
        if [ -f "${NSSWITCH_FILE}" ]; then
                sed -i "s/hosts:[[:space:]]*files.*/hosts:          files dns mdns4_minimal [NOTFOUND=return] /g" "${NSSWITCH_FILE}"
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

# try to find domain controller automatically
find_domain_controller () {
        local DNS
        local IP_CHECK
        
        set +e
        systemd-resolve --status &> /dev/null
        RESOLVE_STATUS=$?
        set -e
        if [ $RESOLVE_STATUS -eq 0 ]; then
                DNS=$(systemd-resolve --status | grep "DNS Servers" | cut -d ':' -f 2 | cut -d ' ' -f 2 | tr -d '[:space:]')
        else
                DNS=$(resolvectl status | grep "Current DNS Server" | cut -d ':' -f 2 | tr -d '[:space:]')
        fi
        # check if DNS IP is valid, if not, user can enter it manually
        IP_CHECK=$(echo "${DNS}" | grep -o -E '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}')

        if [ -z "${IP_CHECK}" ]; then
                DNS=$(dialog --title "set DNS Server IP manually"  --inputbox "Unable to determine IP of DNS Server automatically. You can enter it manually. If you leave it empty, script will exit." 12 50 "" 3>&1 1>&2 2>&3 3>&-)
                if [ -z "${DNS}" ]; then
                        exit 3
                fi
        fi
        DNS_IP="${DNS}"
}

# join the given domain 
# first param: domain name
join_domain () {
        local DOMAIN_NAME
        local LOOP
        local DOMAIN_JOIN_RESULT
        local TRY_AGAIN
        DOMAIN_NAME="${1}"
        LOOP=1
        while [ 1 -eq  ${LOOP} ]
        do
                # choose domain user to use for joining the domain
                JOIN_USER=$(dialog --title "User for domain join" --inputbox "Enter the user to use for the domain join" 10 30 "Administrator" 3>&1 1>&2 2>&3 3>&-)
                # enter password for join user
                JOIN_PASSWORD=$(dialog --title "Password" --clear --insecure --passwordbox "Enter your password for user ${JOIN_USER}" 10 30 "" 3>&1 1>&2 2>&3 3>&-)

                # join the given domain with the given user
                set +e
                echo "${JOIN_PASSWORD}" | realm -v join -U "${JOIN_USER}" "${DOMAIN_NAME}"                
                DOMAIN_JOIN_RESULT=$?                
                set -e
                if [ 0 -ne ${DOMAIN_JOIN_RESULT} ]; then
                        dialog --title "Domain join failed!" --yesno "Do you want to reenter user and password?" 12 40 
                        TRY_AGAIN=$?
                        if [ 0 -eq ${TRY_AGAIN} ]; then
                                LOOP=1
                        else
                                LOOP=0
                                exit 3
                        fi
                else
                        LOOP=0
                fi
        done        
}


#find domain controller
find_domain_controller
DNS_SERVER_NAME=$(dig +noquestion -x "${DNS_IP}" | grep in-addr.arpa | awk -F'PTR' '{print $2}' | tr -d '[:space:]' )
DNS_SERVER_NAME=${DNS_SERVER_NAME%?}
DOMAIN_NAME=$(echo "${DNS_SERVER_NAME}" | cut -d '.' -f2-)
DOMAIN_CONTROLLER="${DNS_SERVER_NAME}"

#set domain name in realm configuration
set_domain_realmd "${DOMAIN_NAME}"

#set domain name in /etc/hosts
set_domain_hosts  "${DOMAIN_NAME}"

#choose the timezone
choose_timezone
#set NTP server
set_timeserver "${DOMAIN_CONTROLLER}"

# enter domain controller
DOMAIN_CONTROLLER=$(dialog --title "domain controller" --inputbox "Enter the domain controller you want to use for joining the domain. \\nE.g.: srv-dc01.example.local" 12 40 "${DOMAIN_CONTROLLER}" 3>&1 1>&2 2>&3 3>&-) 
# enter domain name
DOMAIN_NAME=$(dialog --title "domain name" --inputbox "Enter the domain name you want to join to. \\nE.g.: example.com or example.local" 12 40 "${DOMAIN_NAME}" 3>&1 1>&2 2>&3 3>&-)
DOMAIN_OPTIONS=$(dialog --single-quoted --backtitle "options" --checklist "Fully qualified names:\nChoose if to use fully qualified names: users will be of the form user@domain, not just user. If you have more than one domain in your forrest or any trust relationship, then choose this option.\n\nWeak crypto:\nThis option is not recommended, but sometimes needed when connecting to very old Domain Controllers" 20 60 3 'use fully qualified names' "" off 'allow weak crypto' "" off 3>&1 1>&2 2>&3 3>&-)

correct_dns_if_local_TLD "${DOMAIN_NAME}"

case "${DOMAIN_OPTIONS}" in
        *"use fully qualified names"*) 
        FULLY_QUALIFIED_DN=1;
        use_fully_qualified_names;
        ;;
esac

# configure krb5.conf before joining the domain
configure_krb5_package "${DOMAIN_NAME}" "${DOMAIN_CONTROLLER}"
case "${DOMAIN_OPTIONS}" in
        *"allow weak crypto"*) 
        activate_weak_crypto;
        ;;
esac

#join the domain now
join_domain "${DOMAIN_NAME}"

#install krb5-user package 
install_krb5_package

set_group_policies "${JOIN_USER}"

systemctl restart sssd

# get a kerberos ticket for the join user
echo "${JOIN_PASSWORD}" | kinit "${JOIN_USER}"
# delete the password of the join user
JOIN_PASSWORD=""

configure_file_servers "${DOMAIN_CONTROLLER}"

set_sudo_users_or_groups ${FULLY_QUALIFIED_DN} "${DOMAIN_NAME}"

set_std_groups_for_domain 

allow_xrdp_login

#correct input method for sddm - no onscreen keyboard anymore (if sddm is used). 
correct_input_method

echo "############### DOMAIN JOIN  AND SHARES CONFIGURATION SUCCESSFULL #################"
