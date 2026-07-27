#!/bin/bash
set -e

# ==============================================================================
# SCRIPT DE BASTIONADO INTEGRAL Y SECOPS (ALMALINUX 10 + LARAVEL / STACK)
# ==============================================================================

if [ "$EUID" -ne 0 ]; then
    echo "⚠️ Ejecuta este script como root o con sudo."
    exit 1
fi

echo "=========================================================================="
echo " 🛡️  INICIANDO DESPLIEGUE INTEGRAL DE SEGURIDAD (ALMALINUX 10)"
echo "=========================================================================="

# ------------------------------------------------------------------------------
# 1. RECOLECCIÓN DE PARÁMETROS
# ------------------------------------------------------------------------------
read -rp "1. IP autorizada para conectar por SSH (ej. 192.168.1.100): " ALLOWED_IP
if [[ -z "$ALLOWED_IP" ]]; then
    echo "Error: La dirección IP no puede estar vacía."
    exit 1
fi

read -rp "2. Nuevo PUERTO para SSH (ej. 40400): " SSH_PORT
if ! [[ "$SSH_PORT" =~ ^[0-9]+$ ]] || [ "$SSH_PORT" -le 1024 ] || [ "$SSH_PORT" -gt 65535 ]; then
    echo "Error: Introduce un puerto válido entre 1025 y 65535."
    exit 1
fi

read -rp "3. Usuario no-root administrador del sistema (ej. miguel): " SSH_USER
if ! id "$SSH_USER" &>/dev/null; then
    echo "Error: El usuario $SSH_USER no existe en el sistema."
    exit 1
fi

USER_HOME=$(eval echo "~$SSH_USER")
if [ ! -f "$USER_HOME/.ssh/authorized_keys" ] || [ ! -s "$USER_HOME/.ssh/authorized_keys" ]; then
    echo "⚠️ ALERTA CRÍTICA: El usuario '$SSH_USER' no tiene claves en '$USER_HOME/.ssh/authorized_keys'."
    echo "Configura tu clave pública SSH antes de continuar para evitar perder el acceso."
    exit 1
fi

# ------------------------------------------------------------------------------
# 2. HARDENING DE KERNEL (SYSCTL)
# ------------------------------------------------------------------------------
echo ">> [1/8] Aplicando Hardening a nivel de Kernel..."
cat << 'EOF' > /etc/sysctl.d/99-security-hardening.conf
# Ignorar pings broadcast y bogus
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1

# Mitigación de SYN Flood (DDoS TCP)
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 2048
net.ipv4.tcp_synack_retries = 2

# Deshabilitar redirecciones e IP Forwarding (Anti-Spoofing / Anti-MITM)
net.ipv4.ip_forward = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1

# ASLR Activo
kernel.randomize_va_space = 2
EOF
sysctl --system &>/dev/null

# ------------------------------------------------------------------------------
# 3. BASTIONADO SSH Y CONFIGURACIÓN DE FIREWALLD
# ------------------------------------------------------------------------------
echo ">> [2/8] Bastionando SSH y aplicando reglas de Firewalld..."
cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak
sed -i "s/^#\?Port.*/Port $SSH_PORT/" /etc/ssh/sshd_config
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config

if command -v semanage &>/dev/null; then
    semanage port -a -t ssh_port_t -p tcp "$SSH_PORT" 2>/dev/null || semanage port -m -t ssh_port_t -p tcp "$SSH_PORT" 2>/dev/null || true
fi
systemctl restart sshd

firewall-cmd --permanent --remove-service=ssh &>/dev/null || true
firewall-cmd --permanent --remove-port=22/tcp &>/dev/null || true
firewall-cmd --permanent --add-rich-rule="rule family='ipv4' source address='$ALLOWED_IP' port protocol='tcp' port='$SSH_PORT' accept" &>/dev/null || true
firewall-cmd --reload &>/dev/null

# ------------------------------------------------------------------------------
# 4. INSTALACIÓN Y CONFIGURACIÓN DE FAIL2BAN
# ------------------------------------------------------------------------------
echo ">> [3/8] Instalando y configurando Fail2ban..."
dnf install -y fail2ban fail2ban-systemd

cat << EOF > /etc/fail2ban/jail.local
[DEFAULT]
ignoreip = 127.0.0.1/8 ::1 $ALLOWED_IP
bantime  = 86400
findtime = 600
maxretry = 3
banaction = firewallcmd-rich-rules
backend = systemd

[sshd]
enabled = true
port = $SSH_PORT
maxretry = 3

[nginx-botsearch]
enabled = true
port = http,https
logpath = /var/log/nginx/access.log
maxretry = 2
EOF
systemctl enable --now fail2ban

# ------------------------------------------------------------------------------
# 5. CROWDSEC (INTELIGENCIA DE AMENAZAS EN LA NUBE)
# ------------------------------------------------------------------------------
echo ">> [4/8] Instalando CrowdSec y Firewall Bouncer..."
curl -s https://install.crowdsec.net | bash &>/dev/null
dnf install -y crowdsec crowdsec-firewall-bouncer-nftables &>/dev/null || true
cscli collection install crowdsecurity/nginx &>/dev/null || true
cscli collection install crowdsecurity/sshd &>/dev/null || true
systemctl restart crowdsec || true

# ------------------------------------------------------------------------------
# 6. CABECERAS DE SEGURIDAD EN NGINX
# ------------------------------------------------------------------------------
if [ -d /etc/nginx/conf.d ]; then
    echo ">> [5/8] Inyectando cabeceras de seguridad en Nginx..."
    cat << 'EOF' > /etc/nginx/conf.d/99-security-headers.conf
add_header X-Frame-Options "SAMEORIGIN" always;
add_header X-Content-Type-Options "nosniff" always;
add_header X-XSS-Protection "1; mode=block" always;
add_header Referrer-Policy "strict-origin-when-cross-origin" always;
server_tokens off;
EOF
    systemctl reload nginx 2>/dev/null || true
fi

# ------------------------------------------------------------------------------
# 7. ANTIMALWARE, RKHUNTER Y FIX DE PERMISOS CLAMAV
# ------------------------------------------------------------------------------
echo ">> [6/8] Instalando escáneres de Malware y corrigiendo permisos ClamAV..."
dnf install -y epel-release
dnf install -y rkhunter clamav clamav-update

# Solución explícita al error de permisos en AlmaLinux 10
mkdir -p /var/lib/clamav
if id "clamupdate" &>/dev/null; then
    chown -R clamupdate:clamupdate /var/lib/clamav
elif id "clamav" &>/dev/null; then
    chown -R clamav:clamav /var/lib/clamav
fi
chmod 755 /var/lib/clamav

freshclam || true
rkhunter --propupd || true

# ------------------------------------------------------------------------------
# 8. COMANDO DASHBOARD 'sec-logs'
# ------------------------------------------------------------------------------
echo ">> [7/8] Creando comando de auditoría 'sec-logs'..."
cat << 'EOF' > /usr/local/bin/sec-logs
#!/bin/bash
echo -e "\n======================================================="
echo -e " 🛡️ PANEL DE AUDITORÍA Y SEGURIDAD (SECOPS)"
echo -e "=======================================================\n"

echo -e "\e[1;33m[+] BLOQUEOS ACTIVOS EN CROWDSEC (NUBE)\e[0m"
cscli decisions list 2>/dev/null || echo "CrowdSec no disponible."

echo -e "\n\e[1;33m[+] ESTADO DE FAIL2BAN (LOCAL)\e[0m"
fail2ban-client status sshd 2>/dev/null || echo "Fail2ban SSH jail no activo."

echo -e "\n\e[1;31m[+] ÚLTIMOS INTENTOS FALLIDOS DE SSH\e[0m"
journalctl -u sshd --since "1 day ago" | grep -i "failed" | tail -n 5 || echo "Sin intentos fallidos recientes."

echo -e "\n\e[1;31m[+] ERRORES CRÍTICOS EN NGINX (ÚLTIMAS 10 LÍNEAS)\e[0m"
tail -n 10 /var/log/nginx/error.log 2>/dev/null || echo "Sin errores o log inaccesible."

echo -e "\n\e[1;34m[+] USO DE RECURSOS (TOP 5 PROCESOS POR CPU)\e[0m"
ps -eo pid,ppid,cmd,%mem,%cpu --sort=-%cpu | head -n 6

echo -e "\n======================================================="
EOF
chmod +x /usr/local/bin/sec-logs

# secure_path por defecto de sudo en RHEL/Alma excluye /usr/local/bin:
# "sudo sec-logs" daría "command not found". Drop-in para incluirlo.
echo 'Defaults secure_path="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"' > /etc/sudoers.d/99-local-path
chmod 440 /etc/sudoers.d/99-local-path
visudo -c &>/dev/null || { echo "Error en sintaxis sudoers"; exit 1; }

# ------------------------------------------------------------------------------
# 9. AIDE (CONTROL DE INTEGRIDAD DE ARCHIVOS)
# ------------------------------------------------------------------------------
echo ">> [8/8] Instalando e inicializando AIDE..."
dnf install -y aide
aide --init || true
if [ -f /var/lib/aide/aide.db.new.gz ]; then
    mv /var/lib/aide/aide.db.new.gz /var/lib/aide/aide.db.gz
fi

# ------------------------------------------------------------------------------
# RESUMEN FINAL
# ------------------------------------------------------------------------------
echo "=========================================================================="
echo " 🚀 BASTIONADO Y DEFENSA EN PROFUNDIDAD COMPLETADA CON ÉXITO"
echo "=========================================================================="
echo " - Puerto SSH nuevo:        $SSH_PORT"
echo " - IP permitida SSH:        $ALLOWED_IP"
echo " - Kernel Hardening:        APLICADO (sysctl)"
echo " - Fail2ban + CrowdSec:     ACTIVOS Y MONITOREANDO"
echo " - Antimalware / Integrity: RKHUNTER + CLAMAV + AIDE LISTOS"
echo "=========================================================================="
echo " Monitoriza todo en cualquier momento con el comando: sudo sec-logs"
echo "=========================================================================="