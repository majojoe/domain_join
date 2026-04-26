#!/bin/bash -e

trap onerr ERR
trap onexit EXIT

#trap handler 
onerr() { 
        echo "!!!!!!!!!!!!!!!!! ERROR while executing domain manage shares !!!!!!!!!!!!!!!!!"
        exit 1
}


DOMAIN_NAME=""
DOMAIN_CONTROLLER=""

if [ "$(id -u)" -ne 0 ]; then
        echo "This script must be run as root. Exiting..."
        exit
fi

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

    FSTAB_STR="//${FILE_SERVER}/${SHARE} ${MNT_POINT} cifs sec=krb5,multiuser,user=${TECH_USER},noauto,x-systemd.automount,x-systemd.idle-timeout=1min 0 0 #added by domain_join.sh"

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

        if [ -z "${TECH_USER}" ]; then
                        RUN_AS_USER=${USER:-$SUDO_USER}
                        DRIVE_LIST=$(runuser -u "$RUN_AS_USER" smbclient --use-kerberos=required -N  -U "${TECH_USER}" -L "${FILE_SERVER}" 2> /dev/null | grep Disk  | grep -v -E "ADMIN\\$|SYSVOL|NETLOGON" | cut -d " " -f 1 | grep -E "[a-zA-Z0-9]{2,}(\\$)*" | tr -d '\t')
                else
                        DRIVE_LIST=$(smbclient --use-kerberos=required -N  -U "${TECH_USER}" -L "${FILE_SERVER}" 2> /dev/null | grep Disk  | grep -v -E "ADMIN\\$|SYSVOL|NETLOGON" | cut -d " " -f 1 | grep -E "[a-zA-Z0-9]{2,}(\\$)*" | tr -d '\t')
        fi

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

        # Add to keytab using a Here-Document for better robustness
        ktutil <<-EOF &>/dev/null
                addent -password -p ${TECH_USER}@${DOMAIN_NAME^^} -k 1 -e aes256-cts-hmac-sha1-96
                ${TECH_PASS}
                addent -password -p ${TECH_USER}@${DOMAIN_NAME^^} -k 1 -e aes128-cts-hmac-sha1-96
                ${TECH_PASS}
                wkt ${KEYTAB_FILE}
                q
EOF
        TECH_PASS=""
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

# --- Execution ---


DOMAIN_NAME=$(realm list | grep domain-name | head -n1 | cut -d ':' -f2 | tr -d ' ')
if [ -z "${DOMAIN_NAME}" ]; then
        echo "no domain found. Exiting..."
        exit 1
fi

find_domain_controller "${DOMAIN_NAME}"

choose_share_strategy "${DOMAIN_CONTROLLER}"

echo "############### SHARES CONFIGURATION SUCCESSFUL #################"
