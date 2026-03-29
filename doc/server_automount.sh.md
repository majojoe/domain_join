### 1. Der `request-key` Mechanismus fehlt

File in `/etc/request-key.d/cifs.spnego.conf` anpassen.


```text
create  cifs.spnego    * * /usr/sbin/cifs.upcall %k

```

Danach den Dienst neu laden: `systemctl restart request-key` (falls vorhanden) oder einfach sicherstellen, dass `cifs-utils` korrekt installiert ist.


### Schritt 3: Keytab für den Benutzer erstellen

Wir erzeugen die Schlüsseldatei, die das Passwort ersetzt. Dies geschieht am besten direkt auf dem Linux-Server.

```bash
ktutil
addent -password -p dein-nutzer@DEINE-DOMAIN.DE -k 1 -e aes256-cts-hmac-sha1-96
# Passwort des AD-Benutzers eingeben
wkt /etc/smb_user.keytab
q

# Berechtigungen einschränken
chmod 600 /etc/smb_user.keytab
chown root:root /etc/smb_user.keytab

```
### Schritt 5: Den Mount in der `/etc/fstab` eintragen

Damit das Laufwerk beim Booten automatisch verbunden wird, nutze diesen Eintrag. Verwende zwingend den **FQDN** des Windows-Servers.

```text
//fileserver.deine-domain.de/share  /mnt/smb  cifs  sec=krb5,multiuser,user=dein-nutzer,noauto,x-systemd.automount,x-systemd.idle-timeout=1min 0 0

Example:
//srv-dc01.maier.localnet/Home$  /mnt  cifs  sec=krb5,user=jo,x-systemd.automount,x-systemd.idle-timeout=1min 0 0

```

Dannach ist ein 

    sudo systemctl daemon-reload

nötig.


*Hinweis: `x-systemd.automount` sorgt dafür, dass der Mount erst ausgelöst wird, wenn tatsächlich auf das Verzeichnis zugegriffen wird – das ist im Netzwerk oft stabiler.*

### Schritt 6: Testen

Löse den Mount manuell aus:

```bash
mount /mnt/smb
ls -l /mnt/smb

```