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
NTP_SERVERS=""
SSSD_CONF_FILE="/etc/sssd/sssd.conf"
KEYTAB_FILE="/etc/krb5.keytab"

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
        ADMIN_SERVER="${2^^}"
        if [ -f "${KRB5_UNCONF}" ]; then
                cp "${KRB5_UNCONF}" "${KRB5_CONF}"
                #realm name
                sed -i "s/REALM_NAME/${DOMAIN_NAME^^}/g" "${KRB5_CONF}"
                
                #realm definition
                DOMAIN_UPPER=${DOMAIN_NAME^^}
                REALM_DEFINITION="${DOMAIN_UPPER} = {"
                DC_DNS_LIST=$(nslookup -type=srv _kerberos._tcp."${DOMAIN_NAME}" | grep "${DOMAIN_NAME}" | pcregrep -o1 "(\S+)\.$")
                DC_LIST=()
                while IFS= read -r DC; do
                        DC_LIST+=("${DC}")
                done <<< "$DC_DNS_LIST"

                for i in "${DC_LIST[@]}"
                do
                        REALM_DEFINITION="${REALM_DEFINITION}\n        kdc = ${i^^}"
                done
                
                REALM_DEFINITION="${REALM_DEFINITION}\n        admin_server = ${ADMIN_SERVER}\n}"
                sed -i "s/REALM_DEFINITION/${REALM_DEFINITION}/g" "${KRB5_CONF}"
                
                # domain realm
                DOMAIN_REALM="        .${DOMAIN_NAME} = ${DOMAIN_UPPER}\n        ${DOMAIN_NAME} = ${DOMAIN_UPPER}"
                sed -i "s/DOMAIN_REALM/${DOMAIN_REALM}/g" "${KRB5_CONF}"                
        fi        
}

# find all domain controllers in the domain used and set them all as redundant ntp servers
# first param: domain name
find_ntp_servers() {
        local DOMAIN_NAME
        local NTP_SERVERS_LIST
        local DOMAIN_UPPER
        
        DOMAIN_NAME="${1}"
        NTP_SERVERS_LIST=""
        
        #realm definition
        DOMAIN_UPPER=${DOMAIN_NAME^^}
        DC_DNS_LIST=$(nslookup -type=srv _kerberos._tcp."${DOMAIN_NAME}" | grep "${DOMAIN_NAME}" | pcregrep -o1 "(\S+)\.$")
        DC_LIST=()
        while IFS= read -r DC; do
                DC_LIST+=("${DC}")
        done <<< "$DC_DNS_LIST"

        for i in "${DC_LIST[@]}"
        do
                NTP_SERVERS_LIST="${NTP_SERVERS_LIST} $i"
        done        
        NTP_SERVERS_LIST="${NTP_SERVERS_LIST##' '}"
        NTP_SERVERS="${NTP_SERVERS_LIST}"        
}

# install krb5-user package. Configuring of the files belonging to the package must be done first, meaning first to call configure_krb5_package before calling this method.
install_krb5_package() {
        apt install krb5-user -y
}

# set the domain name in realmd configuration
# first param: domain name
set_domain_realmd() {
        local DOMAIN_NAME
        DOMAIN_NAME="${1}"
        REALMD_FILE="/etc/realmd.conf"
        
        if [ -f "${REALMD_FILE}" ]; then
                sed -i "s/DOMAIN_NAME/${DOMAIN_NAME}/g" "${REALMD_FILE}"
        fi
}

# set the domain in /etc/hosts
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
# first param:  list with ntp servers 
set_timeserver() {
        local DOMAIN_CONTROLLERS
        
        DOMAIN_CONTROLLERS="${1}"
        
        echo "set timeserver"
        TIMESYNCD_FILE="/etc/systemd/timesyncd.conf"
        if grep -q "#[[:space:]]*NTP" "$TIMESYNCD_FILE"; then
                # if NTP is commented out
                sed -i "s/#[[:space:]]*NTP=/NTP=/g" "$TIMESYNCD_FILE"
        fi
        sed -i "s/^NTP=.*/NTP=${DOMAIN_CONTROLLERS}/g" "$TIMESYNCD_FILE"

        systemctl restart systemd-timesyncd.service
}

# configure pam_mount entry for user shares
# first param: file server
# second param: share name
# third param: additional options
write_pam_mount_entry() {
    local FILE_SERVER="${1}"
    local SHARE="${2}"
    local OPTIONS="${3}"
    local PAM_MOUNT_FILE="/etc/security/pam_mount.conf.xml"
    local MNT_POINT
    local MOUNT_STR

    MNT_POINT=$(echo "${SHARE}" | tr -d '$')
    MOUNT_STR="volume fstype=\"cifs\" server=\"${FILE_SERVER}\" path=\"${SHARE}\" mountpoint=\"/media/%(USER)/${MNT_POINT}\" options=\"dir_mode=0700,iocharset=utf8,nosuid,nodev,echo_interval=15,sec=krb5i,cruid=%(USERUID),${OPTIONS}\" uid=\"5000-999999999\""

    if [ -f "${PAM_MOUNT_FILE}" ]; then
        xmlstarlet ed --inplace -s '/pam_mount' -t elem -n "${MOUNT_STR}" "${PAM_MOUNT_FILE}"
    else
        dialog --msgbox "error writing mount entries in ${PAM_MOUNT_FILE}" 5 40 3>&1 1>&2 2>&3 3>&-
        exit 2
    fi
}

# configure fstab entry for technical shares
# first param: file server
# second param: share name
# third param: technical user
write_fstab_entry() {
    local FILE_SERVER="${1}"
    local SHARE="${2}"
    local TECH_USER="${3}"
    local FSTAB_FILE="/etc/fstab"
    local DEFAULT_MNT
    local MNT_POINT
    local FSTAB_STR

    DEFAULT_MNT=$(echo "${SHARE}" | tr -d '$' | tr '[:upper:]' '[:lower:]')
    MNT_POINT=$(dialog --title "Mountpoint" --inputbox "Enter the mountpoint for share ${SHARE}" 10 50 "/mnt/${DEFAULT_MNT}" 3>&1 1>&2 2>&3 3>&-)

    if [ ! -d "${MNT_POINT}" ]; then
        mkdir -p "${MNT_POINT}"
    fi

    # //fileserver.deine-domain.de/share /mnt/smb cifs sec=krb5,multiuser,user=dein-nutzer,noauto,x-systemd.automount,x-systemd.idle-timeout=1min 0 0
    FSTAB_STR="//${FILE_SERVER}/${SHARE} ${MNT_POINT} cifs sec=krb5,multiuser,user=${TECH_USER},noauto,x-systemd.automount,x-systemd.idle-timeout=1min 0 0"

    if ! grep -q "//${FILE_SERVER}/${SHARE}" "${FSTAB_FILE}"; then
        echo "${FSTAB_STR}" >> "${FSTAB_FILE}"
    fi
}

# configure available shares for automatic mounting
# first param: domain controller
# second param: technical user (optional, if set fstab strategy is used)
configure_shares() {
        local DOMAIN_CONTROLLER="${1}"
        local TECH_USER="${2}"
        local FILE_SERVER
        local DRIVE_LIST
        local CHECKLIST
        local FILESERVER_OPTIONS=""

        FILE_SERVER=$(dialog --title "fileserver" --inputbox "Enter the fileserver to use for mounting of drives. \\nE.g.: srv-file01.example.local" 12 40 "${DOMAIN_CONTROLLER}" 3>&1 1>&2 2>&3 3>&-)
        DRIVE_LIST=$(smbclient --use-kerberos=required -N  -U "${JOIN_USER}" -L "${FILE_SERVER}" 2> /dev/null | grep Disk  | grep -v -E "ADMIN\\$|SYSVOL|NETLOGON" | cut -d " " -f 1 | grep -E "[a-zA-Z0-9]{2,}(\\$)*" | tr -d '\t')
        CHECKLIST=""

        if [ -n "${DRIVE_LIST}" ]; then
                # strategy specific pre-configuration
                if [ -z "${TECH_USER}" ]; then
                        set +e
                        dialog --title "Add options for this fileserver?" --defaultno --yesno "Do you want to add options for this fileserver (e.g. vers=2.0)?" 12 40
                        ADD_OPTIONS=$?
                        set -e
                        if [ 0 -eq ${ADD_OPTIONS} ]; then
                                FILESERVER_OPTIONS=$(dialog --title "fileserver options"  --inputbox "Enter the additional fileserver options for the current fileserver (give them with commas if more than one option is provided. e.g. vers=2.0,guest)." 12 50 "" 3>&1 1>&2 2>&3 3>&-)
                        fi
                fi

                for i in ${DRIVE_LIST}; do
                        local MNT_PREVIEW
                        MNT_PREVIEW=$(echo "${i}" | tr -d '$')
                        if [ -z "${TECH_USER}" ]; then
                                CHECKLIST+=("${i} /media/\$USER/${MNT_PREVIEW} off ")
                        else
                                CHECKLIST+=("${i} /mnt/${MNT_PREVIEW} off ")
                        fi
                done

                # shellcheck disable=SC2068
                DRIVE_LIST=$(dialog --single-quoted --backtitle "Choose Drives to mount" --checklist "Choose which drives shall be mounted..." 20 60 ${#CHECKLIST[@]} ${CHECKLIST[@]} 3>&1 1>&2 2>&3 3>&-)
                dialog --clear
                clear

                for i in ${DRIVE_LIST}; do
                        i=$(echo "${i}" | tr -d "'")
                        if [ -z "${TECH_USER}" ]; then
                                write_pam_mount_entry "${FILE_SERVER}" "${i}" "${FILESERVER_OPTIONS}"
                        else
                                write_fstab_entry "${FILE_SERVER}" "${i}" "${TECH_USER}"
                        fi
                done
        else
                dialog --msgbox "No Drives found for given fileserver ${FILE_SERVER}" 5 40 3>&1 1>&2 2>&3 3>&-
        fi
}

# setup technical user and create keytab
# returns technical user name via stdout
setup_technical_user() {
        local TECH_USER
        local TECH_PASS
        local KEYTAB_FILE="/etc/smb_user.keytab"
        local KINIT_RESULT
        local LOOP=1

        while [ 1 -eq ${LOOP} ]
        do
                TECH_USER=$(dialog --title "Technical User" --inputbox "Enter the technical user name (without domain)" 10 50 "" 3>&1 1>&2 2>&3 3>&-)
                if [ -z "${TECH_USER}" ]; then return 1; fi

                TECH_PASS=$(dialog --title "Technical User Password" --clear --insecure --passwordbox "Enter the password for technical user ${TECH_USER}" 10 50 "" 3>&1 1>&2 2>&3 3>&-)

                # Check password with kinit (silent)
                set +e
                echo "${TECH_PASS}" | kinit "${TECH_USER}@${DOMAIN_NAME^^}" &>/dev/null
                KINIT_RESULT=$?
                set -e

                if [ 0 -ne ${KINIT_RESULT} ]; then
                        dialog --title "Authentication failed!" --yesno "Password or user for ${TECH_USER} is wrong. Do you want to reenter?" 12 40
                        if [ 0 -ne $? ]; then
                                return 1
                        fi
                else
                        LOOP=0
                fi
        done

        # Add to keytab (silent)
        printf "addent -password -p %s@%s -k 1 -e aes256-cts-hmac-sha1-96\n%s\nwkt %s\nq\n" "${TECH_USER}" "${DOMAIN_NAME^^}" "${TECH_PASS}" "${KEYTAB_FILE}" | ktutil &>/dev/null

        echo "${TECH_USER}"
}

# ask if and how shares should be configured
# first param: domain controller
choose_share_strategy() {
        local DOMAIN_CONTROLLER="${1}"
        local CHOICE

        CHOICE=$(dialog --clear \
                --backtitle "Share configuration" \
                --title "Choose share configuration strategy" \
                --radiolist "Select option:" 12 80 3 \
                1 "add file shares for users (desktop computers)" on \
                2 "add file shares for a technical user on server systems (e.g. for backup)" off \
                3 "do not add any shares" off \
                3>&1 1>&2 2>&3 3>&-)

        case "${CHOICE}" in
                1)
                        configure_file_servers_loop "${DOMAIN_CONTROLLER}"
                        ;;
                2)
                        local TECH_USER
                        TECH_USER=$(setup_technical_user)
                        if [ -n "${TECH_USER}" ]; then
                            configure_file_servers_loop "${DOMAIN_CONTROLLER}" "${TECH_USER}"
                        fi
                        ;;
                3)
                        return 0
                        ;;
        esac
}

# generic loop for adding shares from multiple file servers
# first param: domain controller
# second param: technical user (optional)
configure_file_servers_loop() {
        local DOMAIN_CONTROLLER="${1}"
        local TECH_USER="${2}"
        local AGAIN=1

        while [ 1 -eq ${AGAIN} ]
        do
                configure_shares "${DOMAIN_CONTROLLER}" "${TECH_USER}"
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
        SUDOERS_AD_FILE="/etc/sudoers.d/50-active_directory"
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
                                        set +e
                                        usermod -aG sudo "${I_NO_SPACE}@${DN}"
                                        set -e
                                        echo "${I_NO_SPACE}@${DN}" >> "${DU_SUDO_FILE}"
                                fi
                        else
                                echo "\"${I_NO_SPACE}\" ALL=(ALL:ALL) ALL" >> "${SUDOERS_AD_FILE}"
                                if ! [[ "${I_NO_SPACE}" = %* ]]; then
                                        set +e
                                        usermod -aG sudo "${I_NO_SPACE}"
                                        set -e
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
        if [ -f ${SSSD_CONF_FILE} ]; then
                sed -i '/^\[domain\/.*/a ad_gpo_access_control = enforcing\nad_gpo_map_remote_interactive = +xrdp-sesman' "${SSSD_CONF_FILE}"
        fi
}

# add possibility to speed up authentication by omitting lookup of group members
speedup_authentication() {
# add some options to sssd.conf to speed up authentication
        if [ -f ${SSSD_CONF_FILE} ]; then
                sed -i '/^\[domain\/.*/a ignore_group_members = True\nsubdomain_inherit = ignore_group_members' "${SSSD_CONF_FILE}"
        fi
}

# make active directory to use LDAPS instead of strartTLS if available
activate_ldaps_if_available() {
        local DOMAIN_CONTROLLER="${1}"
        if openssl s_client -quiet -connect "${DOMAIN_CONTROLLER}":636 </dev/null &>/dev/null; then
                # use LDAPS
                if [ -f ${SSSD_CONF_FILE} ]; then
                        sed -i '/^\[domain\/.*/a ad_use_ldaps = True' "${SSSD_CONF_FILE}"
                fi                                
                # shellcheck disable=SC2260
                openssl s_client -connect "${DOMAIN_CONTROLLER}":636 -showcerts </dev/null &>/dev/null | openssl x509 -outform PEM > /tmp/domain_controller_certificate.pem
                echo "You can find your LDAPS certificate at the following location: /tmp/domain_controller_certificate.pem"
                
        else
                dialog --title "No support for LDAPS" --msgbox "Your domain controller does not support LDAPS. This can be a security issue. You can activate LDAPS by configuring your domain controller in a proper way." 12 40
        fi 
}

remove_sssd_services_line() {

    if [ -f ${SSSD_CONF_FILE} ]; then
        sed -i '/^services[[:space:]]=[[:space:]]*/d' "${SSSD_CONF_FILE}" 2>/dev/null
    fi

    return 0
}

# correct the krb5 template name
correct_krb5_template_name() {
# add some options to sssd.conf to allow login with xrdp
        if [ -f ${SSSD_CONF_FILE} ]; then
                sed -i '/^\[domain\/.*/a krb5_ccname_template=FILE:%d\/krb5cc_%U' "${SSSD_CONF_FILE}"
        fi
}

# remove input method from /etc/sddm.conf file
correct_input_method() {
        if [ -f "${SDDM_CONF_FILE}" ]; then
                sed -i "s/^InputMethod=.*/InputMethod=/g" "${SDDM_CONF_FILE}"
        fi
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
        local PDC
        local IP_CHECK
        local DOMAIN_NAME
        DOMAIN_NAME="${1}"
        
        PDC=$(nslookup -type=srv _ldap._tcp.pdc._msdcs."${DOMAIN_NAME}" | grep "_ldap._tcp.pdc._msdcs." | pcregrep -o1 "(\S+)\.$")
        
        # check if name is valid, if not, user can enter it manually
        set +e
        ping -c1 -W1 -q "${PDC}"        
        IP_CHECK=$?
        set -e

        if [ ${IP_CHECK} -ne 0 ]; then
                PDC=$(dialog --title "set Domain Controller name manually"  --inputbox "Unable to determine Name of primary Domain Controller automatically. You can enter it manually. If you leave it empty, script will exit." 12 50 "" 3>&1 1>&2 2>&3 3>&-)
                if [ -z "${PDC}" ]; then
                        exit 3
                fi
        fi
        DOMAIN_CONTROLLER="${PDC}"
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

#test if keytab is there, if so abort since we are joined to a domain already. This can lead to nasty errors with wrong entries in keytab
if [ -f "${KEYTAB_FILE}" ]; then
        dialog --msgbox "You are already in a domain. Either execute \"domain_leave.sh\" (recommended) or use command \"realm -v leave -U Administrator\" to leave the domain you are currently joined to." 7 100 3>&1 1>&2 2>&3 3>&-
        exit 4
fi

# enter domain name
DOMAIN_NAME=$(dialog --title "domain name" --inputbox "Enter the domain name you want to join to. \\nE.g.: example.com or example.local" 12 40 "${DOMAIN_NAME}" 3>&1 1>&2 2>&3 3>&-)

logger "try to join the domain: ${DOMAIN_NAME}"

#find domain controller
find_domain_controller "${DOMAIN_NAME}"
find_ntp_servers  "${DOMAIN_NAME}"
logger "using the following domain controller as admin server: ${DOMAIN_CONTROLLER}"
logger "using the following time servers: ${NTP_SERVERS}"

#set domain name in realm configuration
set_domain_realmd "${DOMAIN_NAME}"

#set domain name in /etc/hosts
set_domain_hosts  "${DOMAIN_NAME}"

#set NTP server
set_timeserver "${NTP_SERVERS}"

DOMAIN_OPTIONS=$(dialog --single-quoted --backtitle "options" --checklist "Fully qualified names:\nChoose if to use fully qualified names: users will be of the form user@domain, not just user. If you have more than one domain in your forrest or any trust relationship, then choose this option.\n" 20 60 3 'use fully qualified names' "" off 3>&1 1>&2 2>&3 3>&-)

correct_dns_if_local_TLD "${DOMAIN_NAME}"

case "${DOMAIN_OPTIONS}" in
        *"use fully qualified names"*) 
        FULLY_QUALIFIED_DN=1;
        use_fully_qualified_names;
        ;;
esac

# configure krb5.conf before joining the domain
configure_krb5_package "${DOMAIN_NAME}" "${DOMAIN_CONTROLLER}"

logger "start joining the domain"

#join the domain now
join_domain "${DOMAIN_NAME}"

#install krb5-user package 
install_krb5_package

systemctl restart sssd

# get a kerberos ticket for the join user
echo "${JOIN_PASSWORD}" | kinit "${JOIN_USER}"
# delete the password of the join user
JOIN_PASSWORD=""

logger "domain join successful"

choose_share_strategy "${DOMAIN_CONTROLLER}"

set_sudo_users_or_groups ${FULLY_QUALIFIED_DN} "${DOMAIN_NAME}"

set_std_groups_for_domain 

allow_xrdp_login

correct_krb5_template_name

#correct input method for sddm - no onscreen keyboard anymore (if sddm is used). 
correct_input_method

# add possibility to speed up authentication by omitting lookup of group members
speedup_authentication

# make active directory to use LDAPS instead of startTLS
activate_ldaps_if_available "${DOMAIN_CONTROLLER}"

# remove line in sssd.conf with 'services = nss, pam'
remove_sssd_services_line

echo "############### DOMAIN JOIN  AND SHARES CONFIGURATION SUCCESSFUL #################"
