#!/bin/bash
set -e

# ==============================================================================
# SCRIPT DE BASTIONADO INTEGRAL + SECOPS AVANZADO (ALMALINUX 10.2)
# ==============================================================================

if [ "$EUID" -ne 0 ]; then
    echo "⚠️ Ejecuta este script como root o con sudo."
    exit 1
fi

echo "=========================================================================="
echo " 🛡️  INICIANDO DESPLIEGUE INTEGRAL DE SEGURIDAD Y DEFENSA ACTIVA"
echo "=========================================================================="

# ------------------------------------------------------------------------------
# 1. RECOLECCIÓN DE PARÁMETROS
# ------------------------------------------------------------------------------
read -rp "1. IP/CIDR autorizada para conectar por SSH (ej. 192.168.1.100 o 203.0.113.0/24): " ALLOWED_IP
if [[ -z "$ALLOWED_IP" ]]; then
    echo "Error: La dirección IP no puede estar vacía."
    exit 1
fi
if ! [[ "$ALLOWED_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?$ ]]; then
    echo "Error: Formato de IP/CIDR inválido. Usa ej. 192.168.1.100 o 10.0.0.0/24."
    exit 1
fi
echo "   ⚠️  Asegúrate de que esta IP sea ESTÁTICA. Si es dinámica perderás acceso SSH."

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
    exit 1
fi

# ------------------------------------------------------------------------------
# 2. HARDENING DE KERNEL, ANTI-NMAP Y ROOTLESS (SYSCTL)
# ------------------------------------------------------------------------------
echo ">> [1/11] Aplicando Hardening de Kernel y mitigación de OS-Fingerprinting..."
cat << 'EOF' > /etc/sysctl.d/99-security-hardening.conf
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 2048
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_timestamps = 0
net.ipv4.ip_forward = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
kernel.randomize_va_space = 2
user.max_user_namespaces = 28633
EOF
sysctl --system &>/dev/null

# ------------------------------------------------------------------------------
# 3. BASTIONADO SSH (SIN 2FA — gestionado por 2fa.sh aparte)
# ------------------------------------------------------------------------------
echo ">> [2/11] Bastionando SSH..."
dnf install -y epel-release

TS=$(date +%s)
SSHD_BAK=/etc/ssh/sshd_config.bak.$TS
PAM_BAK=/etc/pam.d/sshd.bak.$TS
cp -a /etc/ssh/sshd_config "$SSHD_BAK"
cp -a /etc/pam.d/sshd "$PAM_BAK"

# Drop-in de hardening (idempotente, sin sed sobre el main config).
# En RHEL/AlmaLinux 10, sshd_config incluye /etc/ssh/sshd_config.d/*.conf
# al inicio. sshd usa el PRIMER valor obtenido para cada directiva, por lo que
# el orden alfabético decide qué drop-in gana. El sistema trae drop-ins como
# 50-redhat.conf; por eso usamos 00- (se carga primero, gana).
# Limpiamos versiones viejas y cualquier resto de 2FA de ejecuciones previas.
rm -f /etc/ssh/sshd_config.d/99-hardening.conf
# Limpia restos de 2FA si secure.sh anterior la preconfiguró.
sed -i '/pam_google_authenticator/d' /etc/pam.d/sshd 2>/dev/null || true
sed -i -E 's/^#\s*(auth\s+substack\s+password-auth)/\1/' /etc/pam.d/sshd 2>/dev/null || true

SSHD_DROPIN=/etc/ssh/sshd_config.d/00-hardening.conf
cat << EOF > "$SSHD_DROPIN"
# Hardening generado por secure.sh
Port $SSH_PORT
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM yes
PubkeyAuthentication yes
MaxAuthTries 3
LoginGraceTime 30
ClientAliveInterval 300
ClientAliveCountMax 2
AllowUsers $SSH_USER
EOF

# Límite de 2 conexiones SSH simultáneas para $SSH_USER.
# Se escribe AL FINAL de la sección (tras reiniciar sshd) para no autolimitar
# la propia instalación. Aquí solo limpiamos archivos previos.
rm -f /etc/security/limits.d/99-ssh-max.conf
LIMITS_FILE=/etc/security/limits.d/99-ssh-max.conf

# SELinux: etiquetar el nuevo puerto SSH.
if command -v semanage &>/dev/null; then
    semanage port -a -t ssh_port_t -p tcp "$SSH_PORT" 2>/dev/null \
        || semanage port -m -t ssh_port_t -p tcp "$SSH_PORT" 2>/dev/null || true
fi

# Validar sintaxis antes de reiniciar: si falla, restaura backup y aborta
# (prioridad absoluta: NO dejar el servidor inaccesible).
if ! sshd -t 2>/tmp/sshd_err; then
    echo "ERROR: sshd -t falló. NO se reinicia sshd. Detalle:"
    cat /tmp/sshd_err
    echo "Restaurando backups de sshd_config y pam.d/sshd..."
    cp -a "$SSHD_BAK" /etc/ssh/sshd_config
    rm -f "$SSHD_DROPIN"
    cp -a "$PAM_BAK" /etc/pam.d/sshd
    rm -f "$LIMITS_FILE"
    exit 1
fi
systemctl restart sshd

# Ahora sí: aplicar límite de 3 conexiones SSH simultáneas para $SSH_USER.
# Como AllowUsers restringe a $SSH_USER, nadie más puede abrir sesiones SSH.
cat << EOF > "$LIMITS_FILE"
$SSH_USER  hard  maxlogins  3
EOF
echo "   >> Límite maxlogins=3 aplicado a '$SSH_USER'."
echo "   >> 2FA NO incluida aquí. Para activarla: sudo bash 2fa.sh"
echo "   >> Para desactivarla:  sudo bash 2fa.sh --off"

# ------------------------------------------------------------------------------
# 4. FIREWALLD: ZONA PUBLIC ESTABLE + ACCESO ESTRICTO
# ------------------------------------------------------------------------------
echo ">> [3/11] Configurando reglas de Firewalld..."
firewall-cmd --set-default-zone=public &>/dev/null || true
firewall-cmd --permanent --remove-service=ssh &>/dev/null || true
firewall-cmd --permanent --remove-port=22/tcp &>/dev/null || true
firewall-cmd --permanent --remove-port="$SSH_PORT"/tcp &>/dev/null || true
firewall-cmd --permanent --add-rich-rule="rule family='ipv4' source address='$ALLOWED_IP' port protocol='tcp' port='$SSH_PORT' accept" &>/dev/null || true
firewall-cmd --reload &>/dev/null

# ------------------------------------------------------------------------------
# 5. INSTALACIÓN Y CONFIGURACIÓN DE FAIL2BAN
# ------------------------------------------------------------------------------
echo ">> [4/11] Configurando Fail2ban..."
dnf install -y fail2ban fail2ban-systemd

mkdir -p /var/log/nginx
touch /var/log/nginx/access.log /var/log/nginx/error.log

cat << EOF > /etc/fail2ban/jail.local
[DEFAULT]
ignoreip = 127.0.0.1/8 ::1
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
# 6. CROWDSEC + COLECCIÓN ANTI-PORTSCAN
# ------------------------------------------------------------------------------
echo ">> [5/11] Instalando CrowdSec..."
curl -s https://install.crowdsec.net | bash &>/dev/null
dnf install -y crowdsec crowdsec-firewall-bouncer-nftables &>/dev/null || true
cscli collection install crowdsecurity/nginx &>/dev/null || true
cscli collection install crowdsecurity/sshd &>/dev/null || true
cscli collection install crowdsecurity/iptables &>/dev/null || true
systemctl restart crowdsec || true

# ------------------------------------------------------------------------------
# 7. HARDENING NGINX, CLOUDFLARE IPS Y BLOQUEOS /.ENV
# ------------------------------------------------------------------------------
if [ -d /etc/nginx/conf.d ]; then
    echo ">> [6/11] Configurando Nginx con soporte Cloudflare y Hardening..."
    
    echo "real_ip_header CF-Connecting-IP;" > /etc/nginx/conf.d/cloudflare.conf
    curl -s https://www.cloudflare.com/ips-v4 | while read ip; do
        echo "set_real_ip_from $ip;" >> /etc/nginx/conf.d/cloudflare.conf
    done || true
    curl -s https://www.cloudflare.com/ips-v6 | while read ip; do
        echo "set_real_ip_from $ip;" >> /etc/nginx/conf.d/cloudflare.conf
    done || true

    # Cabeceras de seguridad a nivel http (heredan salvo donde haya add_header
    # propio, p.ej. en location / del vhost). server_tokens off global.
    cat << 'EOF' > /etc/nginx/conf.d/99-security-headers.conf
add_header X-Frame-Options "SAMEORIGIN" always;
add_header X-Content-Type-Options "nosniff" always;
add_header X-XSS-Protection "1; mode=block" always;
add_header Referrer-Policy "strict-origin-when-cross-origin" always;
server_tokens off;
EOF

    # El bloque 'location' NO es válido a nivel http (conf.d se incluye dentro
    # de http {}). Va en un snippet e se inyecta dentro de cada server {} de los
    # vhosts existentes (laravel.conf, 443 de cloudflare.sh...). Idempotente.
    mkdir -p /etc/nginx/snippets
    cat << 'EOF' > /etc/nginx/snippets/dotfiles-block.conf
location ~ /\.(env|git|htaccess|aws|ssh|config) {
    deny all;
    return 404;
}
EOF
    for f in /etc/nginx/conf.d/*.conf; do
        [ -f "$f" ] || continue
        case "$f" in *99-security-headers*) continue;; esac
        grep -q "snippets/dotfiles-block.conf" "$f" 2>/dev/null && continue
        sed -i -E '0,/^server[[:space:]]*\{/{s|^server[[:space:]]*\{|server {\n    include /etc/nginx/snippets/dotfiles-block.conf;|}' "$f"
    done

    # Validar config antes de recargar: si falla, avisar (NO abortar todo el
    # script, pero el site quedará caído hasta corregir).
    if ! nginx -t 2>/tmp/nginx_err; then
        echo "   ⚠️  AVISO: nginx -t falló. Detalle:"
        cat /tmp/nginx_err
    else
        systemctl reload nginx 2>/dev/null || systemctl restart nginx 2>/dev/null || true
    fi
fi

# ------------------------------------------------------------------------------
# 8. ANTIMALWARE, RKHUNTER Y CLAMAV
# ------------------------------------------------------------------------------
echo ">> [7/11] Instalando ClamAV y Rkhunter..."
# EPEL 10.2 stable trae ClamAV 1.4.x; no fijar versión exacta (1.4.5 puede no existir).
# --enablerepo=epel-testing solo para este comando (no habilita el repo permanentemente).
dnf install -y rkhunter || true
if ! dnf install -y --enablerepo=epel-testing clamav clamav-update clamd &>/dev/null; then
    echo "AVISO: epel-testing no disponible o falla; instalando ClamAV estable de EPEL."
    dnf install -y clamav clamav-update clamd
fi

mkdir -p /var/lib/clamav
if id "clamupdate" &>/dev/null; then
    chown -R clamupdate:clamupdate /var/lib/clamav
elif id "clamav" &>/dev/null; then
    chown -R clamav:clamav /var/lib/clamav
fi
chmod 755 /var/lib/clamav

freshclam || true
systemctl enable --now clamav-freshclam 2>/dev/null || true
rkhunter --propupd || true

# ------------------------------------------------------------------------------
# 9. PERSISTENCIA PARA CONTENEDORES ROOTLESS
# ------------------------------------------------------------------------------
echo ">> [8/11] Configurando persistencia Linger para el usuario $SSH_USER..."
loginctl enable-linger "$SSH_USER" || true

# ------------------------------------------------------------------------------
# 10. AUDITORÍA 'sec-logs' + CONFIGURACIÓN DE PATH EN SUDOERS
# ------------------------------------------------------------------------------
echo ">> [9/11] Configurando panel de auditoría 'sec-logs'..."
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
grep "\[error\]" /var/log/nginx/error.log | tail -n 10 || echo "Sin errores o log inaccesible."

echo -e "\n======================================================="
EOF
chmod +x /usr/local/bin/sec-logs

echo 'Defaults secure_path="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"' > /etc/sudoers.d/99-local-path
chmod 440 /etc/sudoers.d/99-local-path
visudo -c &>/dev/null || { echo "Error en sintaxis sudoers"; exit 1; }

# ------------------------------------------------------------------------------
# 11. AIDE (CONTROL DE INTEGRIDAD DE ARCHIVOS)
# ------------------------------------------------------------------------------
echo ">> [10/11] Inicializando base de datos de integridad AIDE..."
dnf install -y aide
aide --init || true
if [ -f /var/lib/aide/aide.db.new.gz ]; then
    mv /var/lib/aide/aide.db.new.gz /var/lib/aide/aide.db.gz
fi

# ------------------------------------------------------------------------------
# RESUMEN FINAL
# ------------------------------------------------------------------------------
echo "=========================================================================="
echo " 🚀 BASTIONADO Y DEFENSA EN PROFUNDIDAD COMPLETADOS CON ÉXITO"
echo "=========================================================================="
echo " - Puerto SSH nuevo:        $SSH_PORT"
echo " - IP permitida SSH:        $ALLOWED_IP"
echo " - Firewalld:               ZONA PUBLIC + REGLA ESTRICTA APLICADA"
echo " - Cloudflare & Nginx:      IPS REALES RESTAURADAS + BLOQUEO /.ENV"
echo " - Fail2ban + CrowdSec:     ACTIVOS Y MONITOREANDO"
echo " - 2FA SSH:                 NO (gestionada por 2fa.sh aparte)"
echo "=========================================================================="
echo " Monitoriza todo con: sudo sec-logs"
echo " 2FA: sudo bash 2fa.sh        (activar)"
echo "      sudo bash 2fa.sh --off  (desactivar)"
echo "=========================================================================="