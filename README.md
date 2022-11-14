**Table of Contents**
- [Why domain join?](#why-domain-join)
- [Installation](#installation)
- [Join a domain](#join-a-domain)
- [Leave a Domain](#leave-a-domain)
- [SSO with AD and Apache](#sso-with-ad-and-apache)
  * [Enable Kerberos in Apache](#enable-kerberos-in-apache)
  * [Configure browsers](#configure-browsers)
    + [Firefox](#firefox)
  * [References](#references)



# Why domain join?
In a Enterprise environment it is state of the art to have a network that is managed by a domain controller. In Linux it can be a pain to join to a AD domain. In order to make it nearly as convenient as in windows to join the domain, this script has been written.
# Installation
Download [here](https://github.com/majojoe/domain_join/releases/download/v1.0.8/domain-join-1.0.8-linux-amd64.deb) and install the \*.deb package provided using the following command:
```bash
sudo apt install ./domain-join-1.0.8-linux-amd64.deb
```
# Join a domain
Execute the join script as so:
```bash
sudo domain_join.sh
```
# Leave a Domain
To leave a domain:
```bash
sudo domain_leave.sh
```
 
# SSO with AD and Apache

The package domain_join works also with Apache and Single Sign On. Apart from installing domain_join and executing domain_join.sh the following steps have to be executed:


- Add dedicated Kerberos user

You should create a new Active Directory user which is dedicated for Kerberos usage. For further reference, the username of this user $KERBEROS_USER and his password is $KERBEROS_PASSWORD.
Create keytab file

- On the domain controller you have to create a .keytab file:

ktpass -princ HTTP/webserver.test.ad@TEST.AD -mapuser ${KERBEROS_USERNAME}@TEST.AD -pass ${KERBEROS_PASSWORD} -crypto AES256-SHA1 -ptype KRB5_NT_PRINCIPAL -out C:\Temp\kerberos.keytab
Example:
ktpass -princ HTTP/webserver01.test.ad@TEST.AD -mapuser sso_user@TEST.AD -pass pa$$w0rd -crypto AES256-SHA1 -ptype KRB5_NT_PRINCIPAL -out C:\Temp\kerberos.keytab

Some notes about this:

    - The encryption type should be AES256-SHA1 (recommended). Note that in this case KrbServiceName of the Apache configuration must be Any to work as expected.
    - Please note that the Kerberos principal you are using is case-sensitive. 
    - If you use HTTPS you must use HTTP/webserver.test.ad as principal.
    - Kerberos authentication is only used when you access http://webserver.test.ad and not http://$IP_OF_WEBSERVER.
    

- Copy the kerberos.keytab file securely to the webserver's path /etc/apache2/auth/kerberos.keytab and change the ownership to this file to the Apache user.

```bash
$ sudo chown www-data:www-data /etc/apache2/auth/apache2.keytab
$ sudo chmod 400 /etc/apache2/auth/apache2.keytab
```

check if Authentication works with:
```bash
$ sudo kinit -VV -k -t /etc/apache2/auth/kerberos.keytab HTTP/webserver.test.ad@TEST.AD
```

## Enable Kerberos in Apache

Install mod_auth_kerb:

```bash
$ sudo apt-get install libapache2-mod-auth-kerb
```

To enable Kerberos in your Apache configuration open /etc/apache2/sites-available/000-default.conf or any other vhost configuration file you want to use.

```
 <VirtualHost *:80>
 
	# ...
	ServerName webserver.test.ad      
	<Location />
		AuthType Kerberos
		AuthName "Kerberos authenticated intranet"
		KrbAuthRealms TEST.AD
		KrbServiceName Any
		Krb5Keytab /etc/apache2/auth/kerberos.keytab
		KrbMethodNegotiate On
		KrbMethodK5Passwd On
		require valid-user
	</Location>
</VirtualHost>
```

## Configure browsers

### Firefox
- Open new tab and type about:config 
- Set the following entries to the value: .test.ad
  - network.automatic-ntlm-auth.trusted-uris
  - network.negotiate-auth.trusted-uris


## References
[https://active-directory-wp.com/docs/Networking/Single_Sign_On/Kerberos_SSO_with_Apache_on_Linux.html](https://active-directory-wp.com/docs/Networking/Single_Sign_On/Kerberos_SSO_with_Apache_on_Linux.html)
[https://serverfault.com/questions/721497/enabling-aes-encrypted-single-sign-on-to-apache-in-a-win2008-domain](https://serverfault.com/questions/721497/enabling-aes-encrypted-single-sign-on-to-apache-in-a-win2008-domain)
[https://help.ubuntu.com/community/Kerberos](https://help.ubuntu.com/community/Kerberos)

