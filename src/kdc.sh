#!/bin/bash
REALM="maier.localnet"
DC_DNS_LIST=$(nslookup -type=srv _kerberos._tcp."${REALM}" | grep "${REALM}" | pcregrep -o1 "(\S+)\.$")
DC_LIST=()
while IFS= read -r DC; do
    DC_LIST+=("${DC}")
done <<< "$DC_DNS_LIST"

for i in "${DC_LIST[@]}"
do
    echo "    kdc = $i"
done


#sddm.conf.d/kde_settings.conf:11:Current=ExposeBlue
#
#jo@nb-jm:/etc$ cat /etc/sddm.conf
#InputMethod=
