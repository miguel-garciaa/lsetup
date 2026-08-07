---
name: seguridad-vps
description: >
  Hardening de SISTEMA en AlmaLinux/RHEL 10 (VPS o VM local — mismo crispado). Cubre: sshd endurecido,
  firewalld con IP/CIDR validado, SELinux enforcing + booleans, sysctl kernel anti-DoS/spoofing,
 _fail2ban backend systemd, CrowdSec + bouncer, ClamAV 1.4.5, AIDE baseline, auditd watch de archivos
  sensibles, chrony/journald/rsyslog offsite. Alineado a secure.sh (24 secciones) y a AGENTS.md:
  prohibido chmod 777, PasswordAuthentication yes, setenforce 0 en prod. REGLA CRÍTICA: antes de
  cambiar puerto SSH/firewall/claves, validar authorized_keys presente (si no → lockout). Usar cuando
  el usuario pida asegurar el servidor, hardening, lock-down, firewall, revisar/expandir secure.sh.
---

# Seguridad VPS — AlmaLinux/RHEL 10 (capa sistema)

VPS y VM local son el mismo hardening. Diferencia: IP pública estática vs IP privada LAN (DHCP fijo
en el router para VM).

## REGLA CRÍTICA — antes de tocar SSH/firewall

**Cualquier cambio en puerto SSH, firewall ingress, o claves DEBE preservar la validación previa de
`~/.ssh/authorized_keys`.** Si no → lockout permanente del VPS (sin consola de rescate no recuperable).

```bash
USER_HOME=$(eval echo "~$SSH_USER")
if [ ! -f "$USER_HOME/.ssh/authorized_keys" ] || [ ! -s "$USER_HOME/.ssh/authorized_keys" ]; then
    echo "⚠️ ALERTA CRÍTICA: sin claves en authorized_keys. Aborto para evitar lockout."
    exit 1
fi
```

`secure.sh` se ejecuta el ÚLTIMO en la cadena (setup → panel → cloudflare → secure). Cambia el puerto
SSH y restringe por IP. Indocumentado el orden → se pierde el acceso.

## Stack prohibido

- `chmod 777` cualquier ruta.
- `PasswordAuthentication yes` / `PermitRootLogin yes` / `KbdInteractiveAuthentication yes`.
- `setenforce 0` en prod (debug ventana corta OK + rearmado explícito documentado).
- Root innecesario para tareas de app.

## sshd — drop-in, no editar /etc/ssh/sshd_config directo

`/etc/ssh/sshd_config.d/99-hardening.conf` (overwrite limpio, no `sed`):
```
Port $SSH_PORT
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitEmptyPasswords no
MaxAuthTries 3
LoginGraceTime 30
ClientAliveInterval 300
ClientAliveCountMax 2
AllowUsers $SSH_USER
HostKey /etc/ssh/ssh_host_ed25519_key
```

Validar config antes de reiniciar:
```bash
sshd -t && systemctl reload sshd
```

Hostkeys: preferir ed25519 (generar `ssh-keygen -t ed25519 -f` si falta).

## firewalld — default deny, allowlist explícita

Zona default `public` con drop implícito. Regla SSH solo por IP/CIDR validada con regex IPv4/CIDR:

```bash
firewall-cmd --permanent --zone=public --add-rich-rule="rule family=ipv4 source address=$ALLOWED_IP port port=$SSH_PORT protocol=tcp accept"
firewall-cmd --permanent --zone=public --add-service=http --add-service=https
firewall-cmd --permanent --zone=public --remove-service=ssh
firewall-cmd --permanent --zone=public --add-rich-rule="rule family=ipv4 source NOT address='$ALLOWED_IP' port port=$SSH_PORT protocol=tcp reject"
firewall-cmd --reload
```

Quitar `ssh` service default (22). Todo lo demás no explícito → dropped. Verificar:
```bash
firewall-cmd --list-all --zone=public
iptables -L INPUT -n -v --line-numbers  # inspección final
```

## SELinux — enforcing jamás disabled

```bash
getenforce   # debe ser Enforcing
setenforce 1
sed -i 's/^SELINUX=.*/SELINUX=enforcing/' /etc/selinux/config
```

Booleans relevantes:
```bash
setsebool -P httpd_can_network_connect_db on    # PHP → PostgreSQL
setsebool -P httpd_unified off                   # reducir superficie
setsebool -P nis_enabled off                    # legado ret
```

Puerto SSH custom exige etiqueta:
```bash
semanage port -a -t ssh_port_t -p tcp $SSH_PORT
```

Tras mover vhost/certs:
```bash
restorecon -Rv /etc/nginx/conf.d/ /etc/ssl/cloudflare/
```

NUNCA `setenforce 0` en prod. Debug symp → `setenforce 0`, minuto contado, `setenforce 1` + log.

## Kernel sysctl — anti-DoS, anti-spoofing

`/etc/sysctl.d/99-hardening.conf` (heredoc literal, sin expandir):
```
# Anti spoofing / DoS
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv6.conf.all.accept_redirects = 0

# Hardening kernel
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
kernel.yama.ptrace_scope = 1
fs.protected_hardlinks = 1
fs.protected_symlinks = 1
fs.protected_fifos = 2
fs.protected_regular = 2

# IPv6 off si no se usa
net.ipv6.conf.all.disable_ipv6 = 1
```

Aplicar: `sysctl --system`. Persistir en `/etc/sysctl.d/` (no `sysctl.conf` global).

## fail2ban — backend systemd

`/etc/fail2ban/jail.local` (heredoc expandible para `$ALLOWED_IP`):
```
[DEFAULT]
backend = systemd
banaction = firewallcmd-rich-rulesaction
ignoreip = 127.0.0.1/8 ::1 $ALLOWED_IP
bantime = 1h
findtime = 5m
maxretry = 3

[sshd]
enabled = true
port = $SSH_PORT
logpath = %(sshd_log)s
```

## CrowdSec — bouncer firewall antes de fail2ban

Instalar `crowdsec` + `crowdsec-firewall-bouncer`. Collections: `crowdsecurity/ssh-bf`,
`crowdsecurity/http-cve`, `crowdsecurity/nginx`. Bouncer programa reglas en firewalld/nftables.
Patrón de remedio: detectar →decidir → bloquear sin intervención. Revisar decisiones:
```bash
cscli decisions list
cscli alerts list
cscli metrics
```

Config `/etc/crowdsec/config/default.yaml` y `/etc/crowdsec/bouncers/`. Whitelist propio en
`/etc/crowdsec/parsers/s02-enrich/` o `acquis.yaml`.

## ClamAV 1.4.5 — socket, scan programado, vendor excluido

Antivirus en servidor web: útil para detectar PHP shells/uploads, no para runtime.
```bash
dnf install -y clamav clamd clamav-update
freshclam
systemctl enable --now clamav-clamd
```

Scan programado `/var/www` (SALTAR `vendor/` — ruido PHP puro, false positives):
```bash
cat << 'EOF' > /etc/cron.weekly/99-clamav-scan
#!/bin/bash
clamscan -r --quiet --log=/var/log/clamav/scan.log \
    --exclude-dir='^/var/www/.*/vendor$' \
    --exclude-dir='^/var/www/.*/node_modules$' \
    /var/www
EOF
chmod +x /etc/cron.weekly/99-clamav-scan
```

`freshclam` daemon para firmas frescas: `systemctl enable --now clamav-freshclam`.

## AIDE — baseline tras hardening, diff cron

Init DB solo DESPUÉS de todo hardening (si no, baseline captura inseguridad):
```bash
dnf install -y aide
aide --init
mv /var/lib/aide/aide.db.new.gz /var/lib/aide/aide.db.gz
```

Cron diff notificado:
```bash
cat << 'EOF' > /etc/cron.daily/99-aide-check
#!/bin/bash
aide --check | mail -s "AIDE diff $(hostname) $(date +%F)" root
EOF
chmod +x /etc/cron.daily/99-aide-check
```

Tras cambios legítimos (upgrade paquete, nueva config) regenerar baseline:
```bash
aide --update && mv /var/lib/aide/aide.db.new.gz /var/lib/aide/aide.db.gz
```
Avisar al usuario antes — false positives en diff tras update son esperados y ruidos.

## auditd — watch archivos sensibles

`/etc/audit/rules.d/hardening.rules`:
```
-w /etc/passwd -p wa -k identity
-w /etc/group -p wa -k identity
-w /etc/shadow -p wa -k identity
-w /etc/sudoers -p wa -k sudoers
-w /etc/sudoers.d -p wa -k sudoers
-w /etc/ssh/sshd_config -p wa -k ssh
-w /var/log/audit -p wa -k audit_log
-w /var/log/secure -p wa -k login
-w /var/log/messages -p wa -k messages

# Syscalls relevantes
-a always,exit -F arch=b64 -S unlink -S unlinkat -S rmdir -k delete
-a always,exit -F arch=b64 -S chmod -S fchmod -S fchmodat -k perm_mod
```

```bash
augenrules --load
systemctl enable --now auditd
```

Encrypted logs opcional (avanzado) — fuera scope inicial.

## Tiempo y logs

**chrony** (tiempo seguro, NTP authenticated):
```bash
dnf install -y chrony
systemctl enable --now chronyd
timedatectl set-ntp true
```

**journald** rotation (disco no se llena):
`/etc/systemd/journald.conf.d/rotation.conf`:
```
[Journal]
SystemMaxUse=500M
MaxRetentionSec=1month
```

`systemctl restart systemd-journald`.

**rsyslog forwarding offsite opcional** (defense-in-depth si logrotate local comprometido):
```
*.* @@log-host-ejemplo:6514   # TLS con cert
```

## sec-logs (ya instalado por secure.sh)

Comando `/usr/local/bin/sec-logs` agrega visiones agregadas de fail2ban/CrowdSec/auditd/clamav.
Usar para diagnosticar: `sec-logs` durante incident response o tras cambios.

## Mapeo mental CIS RHEL 10 Benchmark

No se benchmark textual, pero los controles arriba cubren: 1.x initial setup, 2.x services, 3.x
network, 4.x logging, 5.x access, 6.x boot, 7.x malware. Referencia mental para justificar control.

## Do / Don't checklist

**Don't**:
- `chmod 777`, `PasswordAuthentication yes`, `setenforce 0` prod.
- Quitar regla authorized_keys validation antes de Puerto/f firewall change.
- OLVIDAR `semanage port` tras Puerto SSH custom → SELinux block sshd en Puerto nuevo.
- AIDE init antes de hardening → baseline captura config insegura.

**Do**:
- Drop-in `/etc/ssh/sshd_config.d/` (no editar `sshd_config` global).
- `sshd -t` antes de reload sshd.
- `restorecon -Rv` tras mover vhost/certs.
- `firewall-cmd --list-all` post-reload para verificar estado.
- `sec-logs` durante diagnóstico.

## Orden final (secure.sh)

setup → panel → cloudflare → **secure** (último). secure↔resto: el primero define servicios, secure
los fortifica y restringe. Si invierto → firewall bloca services aún no listos.