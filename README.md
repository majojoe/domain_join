**Table of Contents**

# Why domain join?
In a Enterprise environment it is state of the art to have a network that is managed by a domain controller. In Linux it can be a pain to join to a AD domain. In order to make it nearly as convenient as in windows to join the domain, this script has been written.
# Installation
Download [here](https://github.com/majojoe/domain_join/releases/download/v0.0.3/domain-join-0.0.3-linux-amd64.deb) and install the \*.deb package provided using the following command:
```bash
sudo apt install ./domain-join-0.0.2-linux-amd64.deb
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
 
