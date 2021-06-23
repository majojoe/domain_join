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
DOMAIN_CONTROLLER=""



if [ "$(id -u)" -ne 0 ]; then
        echo "This script must be run as root in order to join to the given domain. Exiting..."
        exit
fi


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
# leave the given domain with the given user
echo "${JOIN_PASSWORD}" | realm -v leave -U "${JOIN_USER}" "${DOMAIN_NAME}"
# delete the password of the join user
JOIN_PASSWORD=""

echo "############### LEFT DOMAIN SUCCESSFUL #################"


#unconfigure_shares "${DOMAIN_CONTROLLER}"


echo "############### SHARES REMOVED #################"
