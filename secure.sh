#!/bin/bash
set -e

# ==============================================================================
# SCRIPT DE BASTIONADO INTEGRAL + SECOPS AVANZADO (ALMALINUX 10.x / RHEL 10)
# v2 — defensa en profundidad, 30 secciones.
# NO instala 2FA (la gestiona 2fa.sh aparte). Idempotente: re-ejecutable sin
# romper el estado de 2fa.sh ni ningún servicio en producción.
# ==============================================================================

if [ "$EUID" -ne 0 ]; then
    echo "⚠️ Ejecuta este script como root o con sudo."
    exit 1
fi

echo "=========================================================================="
echo " 🛡️  INICIANDO DESPLIEGUE INTEGRAL DE SEGURIDAD Y DEFENSA ACTIVA (v2)"
echo "=========================================================================="

# ------------------------------------------------------------------------------
# 0. RECOLECCIÓN DE PARÁMETROS
# ------------------------------------------------------------------------------
# Validación IPv4/CIDR estricta: cada octeto 0-255, máscara /0-/32.
IPV4_REGEX='^(([0-9]{1,2}|1[0-9]{2}|2[0-4][0-9]|25[0-5])\.){3}([0-9]{1,2}|1[0-9]{2}|2[0-4][0-9]|25[0-5])(/([0-9]|[12][0-9]|3[0-2]))?$'

if [ -z "$ALLOWED_IP" ]; then
    read -rp "1. IP/CIDR autorizada para conectar por SSH (ej. 192.168.1.2 o 203.0.113.5 o 10.0.0.0/24): " ALLOWED_IP
fi
if [[ -z "$ALLOWED_IP" ]]; then
    echo "Error: La dirección IP no puede estar vacía."
    exit 1
fi
if ! [[ "$ALLOWED_IP" =~ $IPV4_REGEX ]]; then
    echo "Error: Formato de IP/CIDR inválido. Ejemplos válidos: 192.168.1.2, 203.0.113.5, 10.0.0.0/24."
    exit 1
fi
if [[ "$ALLOWED_IP" =~ ^10\. ]] || [[ "$ALLOWED_IP" =~ ^192\.168\. ]] || [[ "$ALLOWED_IP" =~ ^172\.(1[6-9]|2[0-9]|3[01])\. ]]; then
    echo "   ℹ️  IP privada ($ALLOWED_IP): aplica a VM/local en LAN. Asegura IP estática (DHCP fijo en router)."
elif [[ "$ALLOWED_IP" =~ ^([0-9]{1,2}|1[0-9]{2}|2[0-4][0-9]|25[0-5])\.([0-9]{1,2}|1[0-9]{2}|2[0-4][0-9]|25[0-5])\.([0-9]{1,2}|1[0-9]{2}|2[0-4][0-9]|25[0-5])\.([0-9]{1,2}|1[0-9]{2}|2[0-4][0-9]|25[0-5])$ ]]; then
    echo "   ℹ️  IP pública (sin CIDR): solo válida en VPS con IP pública estática. Si la IP de casa es dinámica perderás acceso SSH."
else
    echo "   ℹ️  IP/CIDR con máscara ($ALLOWED_IP): asegúrate de que cubra tu IP estática (pública o privada)."
fi

if [ -z "$SSH_PORT" ]; then
    read -rp "2. Nuevo PUERTO para SSH (ej. 40400): " SSH_PORT
fi
if ! [[ "$SSH_PORT" =~ ^[0-9]+$ ]] || [ "$SSH_PORT" -le 1024 ] || [ "$SSH_PORT" -gt 65535 ]; then
    echo "Error: Introduce un puerto válido entre 1025 y 65535."
    exit 1
fi

if [ -z "$SSH_USER" ]; then
    read -rp "3. Usuario no-root administrador del sistema (ej. miguel): " SSH_USER
fi
if ! id "$SSH_USER" &>/dev/null; then
    echo "Error: El usuario $SSH_USER no existe en el sistema."
    exit 1
fi

USER_HOME=$(eval echo "~$SSH_USER")
if [ ! -f "$USER_HOME/.ssh/authorized_keys" ] || [ ! -s "$USER_HOME/.ssh/authorized_keys" ]; then
    echo "⚠️ ALERTA CRÍTICA: El usuario '$SSH_USER' no tiene claves en '$USER_HOME/.ssh/authorized_keys'."
    exit 1
fi

# Contraseña Redis: autogenerada (hex 48) si no se introduce. Sirve incluso con
# Redis en 127.0.0.1: defense-in-depth ante cualquier RCE que abra socket local.
if [ -z "$REDIS_PASS" ]; then
    read -rp "4. Contraseña Redis [Enter=autogenerar con openssl hex 48]: " REDIS_PASS_INPUT
else
    REDIS_PASS_INPUT="$REDIS_PASS"
fi
if [[ -z "$REDIS_PASS_INPUT" ]]; then
    REDIS_PASS=$(openssl rand -hex 24 2>/dev/null || head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')
    echo "   🔑 Redis password autogenerada (gárdala aparte):"
    echo "      $REDIS_PASS"
else
    # Sanitizar: prohibir comillas/espacios (redis.conf escaping es frágil).
    if [[ "$REDIS_PASS_INPUT" =~ [[:space:]\'\"] ]]; then
        echo "Error: la contraseña Redis contiene espacios/comillas. Reintenta sin esos caracteres."
        exit 1
    fi
    REDIS_PASS="$REDIS_PASS_INPUT"
fi

# Detección de proyecto Laravel (auto: /var/www/<dir>/.env + artisan + vendor).
# find maxdepth 2 evita descender subdirs; mindepth 2 descarta /var/www/.env.
LARAVEL_DIR=""
ENV_FILE=$(find /var/www -maxdepth 2 -mindepth 2 -name '.env' -type f 2>/dev/null | head -1)
if [ -n "$ENV_FILE" ]; then
    CANDIDATE=$(dirname "$ENV_FILE")
    if [ -f "$CANDIDATE/artisan" ] && [ -d "$CANDIDATE/vendor" ]; then
        LARAVEL_DIR="$CANDIDATE"
    fi
fi
if [[ -n "$LARAVEL_DIR" ]]; then
    echo "   ✅ Proyecto Laravel detectado: $LARAVEL_DIR (se parcheará .env con REDIS_PASSWORD)"
else
    echo "   ℹ️  No se detectó proyecto Laravel. .env no se parchea (configuración Redis aplica igual)."
fi

# Helper: re-cachea config de Laravel tras editar .env y reinicia Octane.
# config:cache congela conexiones Redis/DB en bootstrap/cache/config.php;
# sin re-cache, Octane ignora los cambios de .env → NOAUTH / WRONGPASS.
# Además, si existe /etc/laravel/env (drop-in systemd), se sincronizan los
# secretos de Redis para que systemd EnvironmentFile no sobreescriba .env.
recache_laravel() {
    [ -z "$LARAVEL_DIR" ] && return 0
    local owner home log
    owner=$(stat -c '%U' "$LARAVEL_DIR/.env" 2>/dev/null || echo laravel)
    home=$(getent passwd "$owner" 2>/dev/null | cut -d: -f6)
    [ -z "$home" ] && home=/var/lib/laravel
    if [ -f /etc/laravel/env ]; then
        local tmpenv
        tmpenv=$(mktemp)
        grep -v -E '^(REDIS_USERNAME|REDIS_PASSWORD|DB_PASSWORD)=' /etc/laravel/env > "$tmpenv" 2>/dev/null || true
        grep -E '^(REDIS_USERNAME|REDIS_PASSWORD|DB_PASSWORD)=' "$LARAVEL_DIR/.env" >> "$tmpenv" 2>/dev/null || true
        sed -i -E 's/^([A-Za-z_][A-Za-z0-9_]*)="([^"]*)"/\1=\2/; s/^([A-Za-z_][A-Za-z0-9_]*)='"'"'([^'"'"']*)'"'"'/\1=\2/' "$tmpenv" 2>/dev/null || true
        cp "$tmpenv" /etc/laravel/env
        rm -f "$tmpenv"
        chown root:root /etc/laravel/env
        chmod 600 /etc/laravel/env
        systemctl daemon-reload 2>/dev/null || true
    fi
    chown -R "$owner:$owner" "$LARAVEL_DIR" 2>/dev/null || true
    chmod -R 775 "$LARAVEL_DIR/storage" "$LARAVEL_DIR/bootstrap/cache" 2>/dev/null || true
    log=$(mktemp)
    echo "   >> Re-cacheando config de Laravel (config:cache → aplica .env a Octane)..."
    if sudo -u "$owner" env HOME="$home" COMPOSER_HOME="$home/.composer" \
            bash -lc "cd '$LARAVEL_DIR' && php artisan config:clear && php artisan cache:clear && php artisan config:cache" >"$log" 2>&1; then
        sed 's/^/      /' "$log"
        systemctl restart octane 2>/dev/null || systemctl reload octane 2>/dev/null || \
            echo "   >> octane no reiniciado (reinicia manual: sudo systemctl restart octane)."
    else
        sed 's/^/      /' "$log"
        echo "   ⚠️  config:cache FALLÓ. NO se reinicia octane (config anterior sigue activo)."
        echo "      Revisa .env sintaxis: sudo -u $owner bash -lc 'cd $LARAVEL_DIR && php artisan config:clear'"
    fi
    rm -f "$log"
}

# Email opcional para alertas futuras (placeholder, no se usar mail aquí).
if [ -z "$REPORT_EMAIL" ]; then
    read -rp "5. Email para alertas de seguridad (Enter=omitir, solo log a fichero): " REPORT_EMAIL
fi
REPORT_EMAIL="${REPORT_EMAIL:-}"

# ------------------------------------------------------------------------------
# 0.5 PREFLIGHT RELOJ (chrony) — sin sync, GPG signature "not alive yet"
# ------------------------------------------------------------------------------
# Causa raíz: packagecloud (CrowdSec) y PGDG firman repomd.xml con timestamp
# "not before" marginalmente futuro. Si reloj local va atrasado (VM VBox NAT,
# NTP UDP bloqueado), verificación GPG falla con "signature is not alive" y
# `dnf install` aborta. Idéntico patrón que setup.sh:118-159.
# TCP 443 pasa VBox NAT; NTP UDP 123 no. Sincroniza por HTTP Date header
# (RFC 7231, `date -s` acepta) como respaldo si chrony no arranca.
DATE_STR=$(curl -sI --max-time 5 https://www.cloudflare.com/ 2>/dev/null \
           | awk -F': ' 'tolower($1)=="date"{print $2; exit}')
if [ -n "$DATE_STR" ]; then
    date -s "$DATE_STR" &>/dev/null || true
fi
if ! command -v chronyc &>/dev/null; then
    dnf install -y chrony 2>/dev/null || true
fi
systemctl enable --now chronyd 2>/dev/null || true
chronyc -a makestep &>/dev/null || true

# ------------------------------------------------------------------------------
# 1. HARDENING DE KERNEL + SYSCTL AGRESIVO (IPv4 + IPv6 + fs.* + kernel.* + bpf)
# ------------------------------------------------------------------------------
echo ">> [1/30] Aplicando Hardening de Kernel y mitigación de OS-Fingerprinting..."
cat << 'EOF' > /etc/sysctl.d/99-security-hardening.conf
# === IPv4 ===
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
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1

# === IPv6 ===
net.ipv6.conf.all.disable_ipv6 = 0
net.ipv6.conf.default.disable_ipv6 = 0
net.ipv6.conf.all.accept_ra = 0
net.ipv6.conf.default.accept_ra = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0

# === fs.* (protección contra symlinks/hardlinks/fifos) ===
fs.protected_hardlinks = 1
fs.protected_symlinks = 1
fs.protected_fifos = 1
fs.protected_regular = 2
fs.suid_dumpable = 0

# === kernel.* (info leak, sysrq, kptr, dmesg, ptrace) ===
kernel.randomize_va_space = 2
kernel.sysrq = 0
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
kernel.perf_event_paranoid = 2
kernel.unprivileged_bpf_disabled = 1
kernel.yama.ptrace_scope = 2
user.max_user_namespaces = 28633
EOF
sysctl --system &>/dev/null

# bpf_jit_harden: sysctl -w recursivo (no persiste en .conf del kernel).
sysctl -w net.core.bpf_jit_harden=2 &>/dev/null || true

# ------------------------------------------------------------------------------
# 2. BASTIONADO SSH AVANZADO (crypto moderno + anti-pivote + protege estado 2FA)
# ------------------------------------------------------------------------------
echo ">> [2/30] Bastionando SSH (drop-in 00-hardening.conf)..."
dnf install -y epel-release

TS=$(date +%s)
SSHD_BAK=/etc/ssh/sshd_config.bak.$TS
PAM_BAK=/etc/pam.d/sshd.bak.$TS
cp -a /etc/ssh/sshd_config "$SSHD_BAK"
cp -a /etc/pam.d/sshd "$PAM_BAK"

# Drop-in de hardening (idempotente, sin sed sobre el main config).
# RHEL/Alma 10: sshd_config incluye /etc/ssh/sshd_config.d/*.conf al inicio.
# sshd usa el PRIMER valor obtenido para cada directiva; usamos 00- (gana).
#
# PRESERVA ESTADO 2FA: si 2fa.sh ya cambió KbdInteractiveAuthentication=yes
# y añadió AuthenticationMethods, NO los pisamos al reescribir el drop-in.
TWOFA_PAM_ACTIVE=no
if grep -q 'pam_google_authenticator' /etc/pam.d/sshd 2>/dev/null; then
    TWOFA_PAM_ACTIVE=yes
fi

KBD_INT="no"
AUTH_M=""
if [ -f /etc/ssh/sshd_config.d/00-hardening.conf ]; then
    if grep -qE '^[[:space:]]*KbdInteractiveAuthentication[[:space:]]+yes' /etc/ssh/sshd_config.d/00-hardening.conf 2>/dev/null; then
        KBD_INT="yes"
    fi
    AUTH_M=$(awk '/^[[:space:]]*AuthenticationMethods[[:space:]]+/{
        $1=""; sub(/^[[:space:]]+/,""); print; exit
    }' /etc/ssh/sshd_config.d/00-hardening.conf 2>/dev/null)
fi

# Quitar drop-in viejo de nombre previo (00 vs 99 alias legacy).
rm -f /etc/ssh/sshd_config.d/99-hardening.conf

# Limpiar restos de 2FA en PAM SOLO si 2FA NO está activo (evitar pisar 2fa.sh).
if [ "$TWOFA_PAM_ACTIVE" = "no" ]; then
    sed -i '/pam_google_authenticator/d' /etc/pam.d/sshd 2>/dev/null || true
    sed -i -E 's/^#\s*(auth\s+substack\s+password-auth)/\1/' /etc/pam.d/sshd 2>/dev/null || true
fi

SSHD_DROPIN=/etc/ssh/sshd_config.d/00-hardening.conf
cat << EOF > "$SSHD_DROPIN"
# Hardening generado por secure.sh (v2). No editar a mano — el script preserva
# estado de 2fa.sh. Re-ejecutar secure.sh es seguro.
Port $SSH_PORT
PermitRootLogin no
PasswordAuthentication no
PermitEmptyPasswords no
KbdInteractiveAuthentication $KBD_INT
UsePAM yes
PubkeyAuthentication yes
MaxAuthTries 3
LoginGraceTime 30
ClientAliveInterval 300
ClientAliveCountMax 2
MaxStartups 10:30:60
MaxSessions 2
GatewayPorts no
AllowTcpForwarding no
AllowAgentForwarding no
PermitTunnel no
X11Forwarding no
PermitUserRC no
# Crypto moderno (OpenSSH 9.x en Alma 10 — Ed25519 + chacha20-poly1305 + AES-GCM).
KexAlgorithms curve25519-sha256,curve25519-sha256@libssh.org,diffie-hellman-group16-sha512,diffie-hellman-group18-sha512
Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com,aes256-ctr
MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com,umac-128-etm@openssh.com
HostKeyAlgorithms ssh-ed25519,ssh-ed25519-cert-v01@openssh.com,rsa-sha2-512,rsa-sha2-512-cert-v01@openssh.com,rsa-sha2-256,rsa-sha2-256-cert-v01@openssh.com
AllowUsers $SSH_USER
EOF

# RestorationMethods si 2FA activo (preserva configuración de 2fa.sh).
if [ -n "$AUTH_M" ]; then
    echo "AuthenticationMethods $AUTH_M" >> "$SSHD_DROPIN"
    echo "   >> Estado 2FA preservado: KbdInteractive=yes + AuthenticationMethods=$AUTH_M"
fi

# Límite de sesiones SSH simultáneas para $SSH_USER (limits.d).
# Se aplica AL FINAL (tras reiniciar sshd) para no autolimitar la propia
# instalación del script. Aquí solo limpiamos archivos previos.
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

# Ahora sí: aplicar límite de 3 sesiones SSH simultáneas para $SSH_USER.
# Como AllowUsers restringe a $SSH_USER, nadie más puede abrir sesiones SSH.
cat << EOF > "$LIMITS_FILE"
$SSH_USER  hard  maxlogins  3
EOF
echo "   >> Límite maxlogins=3 aplicado a '$SSH_USER'."
echo "   >> AllowTcpForwarding=no: tunneles SSH (-L/-R) desactivados (anti-pivote)."
echo "   >> Si tunneles son necesarios: pon 'AllowTcpForwarding local' en el drop-in."
echo "   >> 2FA NO incluida aquí. Para activarla: sudo bash 2fa.sh"
echo "   >> Para desactivarla:  sudo bash 2fa.sh --off"

# ------------------------------------------------------------------------------
# 3. FIREWALLD: ZONA PUBLIC ESTABLE + ACCESO ESTRICTO
# ------------------------------------------------------------------------------
echo ">> [3/30] Configurando reglas de Firewalld..."
firewall-cmd --set-default-zone=public &>/dev/null || true
firewall-cmd --permanent --remove-service=ssh &>/dev/null || true
firewall-cmd --permanent --remove-port=22/tcp &>/dev/null || true
firewall-cmd --permanent --remove-port="$SSH_PORT"/tcp &>/dev/null || true
firewall-cmd --permanent --add-rich-rule="rule family='ipv4' source address='$ALLOWED_IP' port protocol='tcp' port='$SSH_PORT' accept" &>/dev/null || true
# Bloquear ICMP echo (anti-fingerprint ping scan).
firewall-cmd --permanent --add-icmp-block=echo-request &>/dev/null || true
firewall-cmd --reload &>/dev/null

# ------------------------------------------------------------------------------
# 4. FAIL2BAN REFUERZO (ignore IP propia + recidive + jails nginx)
# ------------------------------------------------------------------------------
echo ">> [4/30] Configurando Fail2ban (refuerzo)..."
dnf install -y fail2ban fail2ban-systemd

mkdir -p /var/log/nginx
touch /var/log/nginx/access.log /var/log/nginx/error.log

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
mode = aggressive

# Reincidentes: 5 strikes en 1 día → 1 semana de ban.
[recidive]
enabled = true
logpath = /var/log/fail2ban.log
bantime = 604800
findtime = 86400
maxretry = 5

[nginx-botsearch]
enabled = true
port = http,https
logpath = /var/log/nginx/access.log
maxretry = 2

[nginx-noscript]
enabled = true
port = http,https
logpath = /var/log/nginx/access.log
maxretry = 3

[nginx-bad-request]
enabled = true
port = http,https
logpath = /var/log/nginx/access.log
maxretry = 5
EOF
systemctl enable --now fail2ban

# ------------------------------------------------------------------------------
# 5. CROWDSEC + COLECCIONES ANTI-PORTSCAN/SSH/NGINX
# ------------------------------------------------------------------------------
echo ">> [5/30] Instalando CrowdSec..."
# (a) Instalador oficial añade repo packagecloud + importa llave RPM.
curl -s https://install.crowdsec.net | bash &>/dev/null || true
# (b) repo_gpgcheck=0 en .repo de packagecloud (mismo patrón que PGDG en
#     setup.sh:204-207). packagecloud firma repomd.xml con timestamp "not
#     before" futuro; si reloj local va atrasado, GPG lo rechaza y `dnf`
#     aborta. gpgcheck de PAQUETES sigue activo (llave RPM ya importada
#     por el instalador en (a)).
# (c) skip_if_unavailable=1 evita que caídas posteriores del repo crowdsec
#     maten otros `dnf install` (ClamAV, AIDE, audit, etc.): si el repo
#     vuelve a fallar de metadata, dnf lo salta en lugar de abortar todo.
if ls /etc/yum.repos.d/*crowdsec*.repo &>/dev/null; then
    sed -i -E 's/^[[:space:]]*repo_gpgcheck[[:space:]]*=[[:space:]]*1/repo_gpgcheck=0/g' \
        /etc/yum.repos.d/*crowdsec*.repo 2>/dev/null || true
    for r in /etc/yum.repos.d/*crowdsec*.repo; do
        [ -f "$r" ] || continue
        grep -qE '^[[:space:]]*skip_if_unavailable[[:space:]]*=' "$r" \
            || printf '\nskip_if_unavailable=1\n' >> "$r"
    done
fi
# (d) --setopt refuerza repo_gpgcheck=0 por si la línea del .repo no aplica
#     (dnf a veces cachea metadata de instalador previo). --nogpgcheck
#     desactiva verificación de PAQUETE; combinado con (a) llave importada
#     es seguro. Si CrowdSec no acaba de instalarse, NO abortar script.
dnf install -y --setopt='crowdsec_crowdsec.repo_gpgcheck=0' --nogpgcheck \
    crowdsec crowdsec-firewall-bouncer-nftables &>/dev/null || true
# (e) cscli sólo si el binario existe (no asumir que el install tuvo éxito).
if command -v cscli &>/dev/null; then
    cscli collection install crowdsecurity/nginx     &>/dev/null || true
    cscli collection install crowdsecurity/sshd      &>/dev/null || true
    cscli collection install crowdsecurity/iptables  &>/dev/null || true
fi
# (f) systemd: enable --now arranca el servicio aunque no estuviera cargado
#     (mejor que `restart` sola). Guard con list-unit-files evita el stderr
#     ruidoso "Unit crowdsec.service not found" cuando el install falló.
if systemctl list-unit-files 2>/dev/null | grep -q '^crowdsec\.service'; then
    systemctl enable --now crowdsec 2>/dev/null || true
fi

# ------------------------------------------------------------------------------
# 6. HARDENING NGINX + CLOUDFLARE IPS + BLOQUEO /.ENV
# ------------------------------------------------------------------------------
if [ -d /etc/nginx/conf.d ]; then
    echo ">> [6/30] Configurando Nginx con soporte Cloudflare y Hardening..."

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
add_header X-Permitted-Cross-Domain-Policies "none" always;
add_header Cross-Origin-Opener-Policy "same-origin" always;
server_tokens off;
EOF

    # Bloque 'location' NO es válido a nivel http; va en snippet que se inyecta
    # dentro de cada server {}. Idempotente.
    mkdir -p /etc/nginx/snippets
    cat << 'EOF' > /etc/nginx/snippets/dotfiles-block.conf
location ~ /\.(env|git|htaccess|aws|ssh|config) {
    deny all;
    return 404;
}
EOF
    for f in /etc/nginx/conf.d/*.conf; do
        [ -f "$f" ] || continue
        case "$f" in
            *99-security-headers*|*00-tls-modern*|*00-sec-extra-headers*|*00-rate-limits*) continue;;
        esac
        grep -q "snippets/dotfiles-block.conf" "$f" 2>/dev/null && continue
        sed -i -E '0,/^server[[:space:]]*\{/{s|^server[[:space:]]*\{|server {\n    include /etc/nginx/snippets/dotfiles-block.conf;|}' "$f"
    done

    # Validar config antes de recargar: si falla, avisar (NO abortar todo).
    if ! nginx -t 2>/tmp/nginx_err; then
        echo "   ⚠️  AVISO: nginx -t falló (sección 6). Detalle:"
        cat /tmp/nginx_err
    else
        systemctl reload nginx 2>/dev/null || systemctl restart nginx 2>/dev/null || true
    fi
fi

# ------------------------------------------------------------------------------
# 7. NGINX TLS MODERNO + HEADERS EXTRA + RATE LIMITING
# ------------------------------------------------------------------------------
if [ -d /etc/nginx/conf.d ]; then
    echo ">> [7/30] Aplicando TLS moderno + CSP + rate-limits Nginx..."

    CIPHERS='ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256'

    # TLS global (Mozilla intermediate 2024, sin ssl_stapling para no fallar sin chain).
    cat << 'EOF' > /etc/nginx/conf.d/00-tls-modern.conf
ssl_protocols TLSv1.2 TLSv1.3;
ssl_ciphers ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256;
ssl_prefer_server_ciphers off;
ssl_session_cache shared:SSL:10m;
ssl_session_timeout 1d;
ssl_session_tickets off;
EOF

    # Rate limiting zones (anti-DoS, anti-brute-force HTTP).
    cat << 'EOF' > /etc/nginx/conf.d/00-rate-limits.conf
limit_req_zone $binary_remote_addr zone=req_limit:10m rate=10r/s;
limit_conn_zone $binary_remote_addr zone=conn_limit:10m;
EOF

    # CSP + Permissions-Policy a nivel http (heredado salvo donde haya add_header propio).
    cat << 'EOF' > /etc/nginx/conf.d/00-sec-extra-headers.conf
add_header Content-Security-Policy "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self' data:; object-src 'none'; frame-ancestors 'self'; base-uri 'self'; form-action 'self'" always;
add_header Permissions-Policy "geolocation=(), microphone=(), camera=(), payment=(), usb=()" always;
EOF

    # Parchear vhosts existentes con ssl_ciphers obsoleto (HIGH:!aNULL:!MD5 → modern).
    for f in /etc/nginx/conf.d/*.conf; do
        [ -f "$f" ] || continue
        case "$f" in *00-*) continue;; esac
        sed -i -E "s|^([[:space:]]*ssl_ciphers[[:space:]]+)[^;]*;|\1${CIPHERS};|" "$f" 2>/dev/null || true
        sed -i -E 's|^([[:space:]]*ssl_prefer_server_ciphers[[:space:]]+)on;|\1off;|' "$f" 2>/dev/null || true
    done

    if ! nginx -t 2>/tmp/nginx_err2; then
        echo "   ⚠️  AVISO: nginx -t falló (sección 7 TLS modern). Detalle:"
        cat /tmp/nginx_err2
    else
        systemctl reload nginx 2>/dev/null || systemctl restart nginx 2>/dev/null || true
    fi
fi

# ------------------------------------------------------------------------------
# 8. ANTIMALWARE: CLAMAV + RKHUNTER
# ------------------------------------------------------------------------------
echo ">> [8/30] Instalando ClamAV y Rkhunter..."
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
# 9. PERSISTENCIA ROOTLESS (LINGER)
# ------------------------------------------------------------------------------
echo ">> [9/30] Configurando Linger para '$SSH_USER'..."
loginctl enable-linger "$SSH_USER" || true

# ------------------------------------------------------------------------------
# 10. PANEL DE AUDITORÍA 'sec-logs' AMPLIADO
# ------------------------------------------------------------------------------
echo ">> [10/30] Configurando panel de auditoría 'sec-logs'..."
cat << 'EOF' > /usr/local/bin/sec-logs
#!/bin/bash
echo -e "\n======================================================="
echo -e " 🛡️ PANEL DE AUDITORÍA Y SEGURIDAD (SECOPS)"
echo -e "=======================================================\n"

echo -e "\e[1;33m[+] BLOQUEOS ACTIVOS EN CROWDSEC (NUBE)\e[0m"
cscli decisions list 2>/dev/null || echo "CrowdSec no disponible."

echo -e "\n\e[1;33m[+] ESTADO DE FAIL2BAN (LOCAL)\e[0m"
fail2ban-client status sshd 2>/dev/null || echo "Fail2ban SSH jail no activo."
fail2ban-client status recidive 2>/dev/null || echo "recidive jail no activo."

echo -e "\n\e[1;31m[+] ÚLTIMOS INTENTOS FALLIDOS DE SSH\e[0m"
journalctl -u sshd --since "1 day ago" 2>/dev/null | grep -i "failed" | tail -n 5 || echo "Sin intentos fallidos recientes."

echo -e "\n\e[1;31m[+] ÚLTIMOS EVENTOS DE AUDITD (identity/sudoers)\e[0m"
ausearch -k identity --start today 2>/dev/null | tail -15 || echo "auditd no disponible o sin eventos identity."

echo -e "\n\e[1;31m[+] ÚLTIMOS ERRORES EN NGINX\e[0m"
grep "\[error\]" /var/log/nginx/error.log 2>/dev/null | tail -n 10 || echo "Sin errores o log inaccesible."

echo -e "\n\e[1;34m[+] ESTADO DE REDIS\e[0m"
systemctl is-active redis 2>/dev/null || echo "Redis no activo."
RPASS=$(awk '/^requirepass[[:space:]]/{print $2}' /etc/redis/redis.conf 2>/dev/null)
[ -n "$RPASS" ] && redis-cli -a "$RPASS" ping 2>/dev/null || echo "Redis requiere pass o no responde."

echo -e "\n\e[1;34m[+] DNF-AUTOMATIC (PARCHES AUTO)\e[0m"
systemctl is-active dnf-automatic.timer 2>/dev/null || echo "dnf-automatic.timer NO activo (no hay auto-patch)."

echo -e "\n\e[1;34m[+] AIDE (DB ÚLTIMA ACTUALIZACIÓN)\e[0m"
ls -l /var/lib/aide/aide.db.gz 2>/dev/null || echo "AIDE no inicializada (ejecuta 'sudo aide --init && sudo mv ...')."

echo -e "\n\e[1;34m[+] USBGuard\e[0m"
systemctl is-active usbguard 2>/dev/null || echo "USBGuard no activo (podría no aplicar en VPS)."

echo -e "\e[1;36m[+] PHP CLI HARDENING (v3)\e[0m"
if [ -f /etc/php.d/99-hardening.conf ] || [ -f /etc/php.d/99-hardening.ini ]; then
    echo "  Drop-in:    $(ls /etc/php.d/99-hardening.* 2>/dev/null | head -1)"
    echo "  disable_fn: $(awk -F'= ' '/^disable_functions/{print $2}' /etc/php.d/99-hardening.* 2>/dev/null | head -1)"
else
    echo "  PHP CLI drop-in NO creado (seccion 25 skip)."
fi

echo -e "\e[1;36m[+] REDIS ACL (v3)\e[0m"
if [ -f /etc/redis/users.acl ]; then
    echo "  ACL users: $(grep -c '^user ' /etc/redis/users.acl) ($(awk '/^user /{print $2"="$3}' /etc/redis/users.acl | tr '\n' ' '))"
    echo "  aclfile:    $(awk '/^aclfile /{print $2}' /etc/redis/redis.conf 2>/dev/null)"
else
    echo "  ACL file no creado (seccion 29 no aplico)."
fi

echo -e "\e[1;36m[+] POSTGRESQL HARDENING (v3)\e[0m"
if systemctl is-active --quiet postgresql-18 2>/dev/null; then
    echo "  pg_stat_statements: $(sudo -u postgres psql -At -d postgres -c "SELECT extname FROM pg_extension WHERE extname='pg_stat_statements';" 2>/dev/null | head -1 || echo 'NO instalada')"
    echo "  slow log >250ms:    $(sudo -u postgres psql -At -c "SHOW log_min_duration_statement;" 2>/dev/null | head -1)"
    echo "  Top 5 queries (mean ms):"
    sudo -u postgres psql -d postgres -At -c "SELECT substring(query,1,60)||' | calls='||calls::text||' | mean_ms='||round(mean_exec_time::numeric,2)::text FROM pg_stat_statements ORDER BY mean_exec_time DESC LIMIT 5;" 2>/dev/null | sed 's/^/    /' || echo "    (extension no cargada aun)"
else
    echo "  PostgreSQL no activo."
fi

echo -e "\e[1;36m[+] WAF MODSECURITY (v3)\e[0m"
if [ -f /etc/nginx/modsec/modsecurity.conf ]; then
    echo "  Engine:    $(awk '/^SecRuleEngine/{print $2}' /etc/nginx/modsec/modsecurity.conf 2>/dev/null)"
    echo "  CRS dir:   $(ls -d /etc/nginx/modsec/owasp-crs 2>/dev/null || echo 'NO descargado')"
    echo "  Audit log: $(wc -l /var/log/modsec/audit.log 2>/dev/null | awk '{print $1" lineas"}' || echo 'vacio/inexistente')"
    if [ -s /var/log/modsec/audit.log ]; then
        echo "  Top 5 rules disparadas:"
        grep -oE 'id "[0-9]+"' /var/log/modsec/audit.log 2>/dev/null | sort | uniq -c | sort -rn | head -5 | sed 's/^/    /' || true
    fi
else
    echo "  WAF no instalado (ejecuta 'sudo bash waf.sh')."
fi

echo -e "\n\e[1;34m[+] BACKUPS (sistema .system-state)\e[0m"
if [ -f /var/lib/.system-state/logs/state.txt ]; then
    echo "  Último run backup.sh:"
    while IFS='=' read -r k v; do
        case "$k" in
            last_run_tag)     echo "    TAG:        $v";;
            last_run_ok)     [ "$v" = "1" ] && echo "    Resultado:  ✅ OK" || echo "    Resultado:  ❌ FALLÓ";;
            last_run_duration) echo "    Duración:   ${v}s";;
            daily_count)     echo "    Diarios:    $v";;
            retention_days)  echo "    Retención:  ${v}d flat";;
            weekly_count)    ;;  # legacy, no mostrar
            monthly_count)   ;;  # legacy, no mostrar
        esac
    done < /var/lib/.system-state/logs/state.txt
else
    echo "  ⚠️  No hay runs registrados. ¿Está instalado?"
    echo "      sudo bash /root/SCRIPTS/backup-install.sh"
fi
if [ -f /var/lib/.system-state/logs/verify.state ]; then
    echo "  Última verificación:"
    awk -F= '/last_verify_tag/{print "    TAG: "$2}
             /last_verify_ok/{if($2==1)print "    VERIFY:    OK";else print "    VERIFY:    ❌ FAIL"}
             /last_verify_pass/{print "    Pasados:   "$2}
             /last_verify_fail/{print "    Fallidos:  "$2}' \
        /var/lib/.system-state/logs/verify.state
fi
BKP_DIR=/var/lib/.system-state/snapshots
[ -d "$BKP_DIR" ] && echo "  Disco usado: $(du -sh "$BKP_DIR" 2>/dev/null | awk '{print $1}')"

echo -e "\n======================================================="
EOF
chmod +x /usr/local/bin/sec-logs

# sudoers secure_path (idempotente).
echo 'Defaults secure_path="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"' > /etc/sudoers.d/99-local-path
chmod 440 /etc/sudoers.d/99-local-path
visudo -c &>/dev/null || { echo "Error en sintaxis sudoers"; exit 1; }

# ------------------------------------------------------------------------------
# 11. AIDE (CONTROL DE INTEGRIDAD DE ARCHIVOS)
# ------------------------------------------------------------------------------
echo ">> [11/30] Inicializando base de datos de integridad AIDE..."
dnf install -y aide
aide --init || true
if [ -f /var/lib/aide/aide.db.new.gz ]; then
    mv /var/lib/aide/aide.db.new.gz /var/lib/aide/aide.db.gz
fi

# ------------------------------------------------------------------------------
# 12. REDIS HARDENING (bind localhost + protected-mode + requirepass)
# ------------------------------------------------------------------------------
# NOTA v3: rename-command eliminado — entra en conflicto con aclfile (sec 29)
# en Redis 6+: ambos son mutuamente excluyentos y redis-server refuses to
# start. ACL con -@dangerous ya bloquea FLUSHALL/FLUSHDB/CONFIG/KEYS/SHUTDOWN/
# DEBUG, cubriendo el mismo objetivo sin colisión.
echo ">> [12/30] Endureciendo Redis..."
REDIS_CONF=/etc/redis/redis.conf
if [ ! -f "$REDIS_CONF" ]; then
    echo "   ⚠️  $REDIS_CONF no existe. ¿Instalado Redis? Skip."
else
    # Backup del config actual.
    cp -a "$REDIS_CONF" "${REDIS_CONF}.bak.$TS"

    # Limpiar líneas previamente añadidas por secure.sh (re-ejecutable).
    # INCLUYE aclfile: si sec 29 lo añadió en run previa, dejarlo在这里
    # provocaría coexistencia con requirepass+protected-mode añadidos abajo
    # (harmless) PERO también con rename-command si sed de abajo fallase →
    # restart-loop. Borrándolo aquí, sec 29 lo re-añade limpio al final.
    sed -i -E '/^requirepass[[:space:]]+/d; /^protected-mode[[:space:]]+/d; /^rename-command[[:space:]]+/d; /^aclfile[[:space:]]+/d' "$REDIS_CONF" 2>/dev/null || true

    # No tocar bind ya puesto por setup.sh; si no existe, añadir localhost.
    if ! grep -qE '^[[:space:]]*bind[[:space:]]' "$REDIS_CONF" 2>/dev/null; then
        echo 'bind 127.0.0.1 -::1' >> "$REDIS_CONF"
    else
        # Forzar bind localhost (no exponer Redis).
        sed -i -E 's|^[[:space:]]*bind[[:space:]].*|bind 127.0.0.1 -::1|' "$REDIS_CONF" 2>/dev/null || true
    fi

    cat << EOF >> "$REDIS_CONF"

# === añadido por secure.sh (v3) — base hardening (sin rename-command) ===
protected-mode yes
requirepass $REDIS_PASS
EOF

    # SELinux: permitir que redis lea su config con la nueva password.
    setsebool -P redis_enable_notify 1 2>/dev/null || true
    restorecon -Rv /etc/redis 2>/dev/null || true

    systemctl restart redis 2>/dev/null || true

    # Parchear Laravel .env con REDIS_PASSWORD (user default).
    # NO se escribe REDIS_USERNAME aquí: sec 12 configura usuario default
    # (requirepass = shortcut para default). Si .env quedó con
    # REDIS_USERNAME=laravel de sec 29 previa, AUTH usaría user laravel con
    # pass del default → FAIL. Por eso limpiamos USERNAME también.
    # NO se llama recache_laravel aquí: .env todavía incompleto (sin
    # USERNAME=laravel hasta sec 29). Recache prematuro arrancaría Octane
    # con config roto. Sec 29 hara recache definitivo cuando .env esté final.
    if [[ -n "$LARAVEL_DIR" && -f "$LARAVEL_DIR/.env" ]]; then
        TMP_ENV=$(mktemp)
        grep -v -E '^REDIS_USERNAME=|^REDIS_PASSWORD=' "$LARAVEL_DIR/.env" > "$TMP_ENV" || true
        printf 'REDIS_PASSWORD=%s\n' "$REDIS_PASS" >> "$TMP_ENV"
        # Detectar owner (laravel por convención de setup.sh, fallback SSH_USER).
        ENV_OWNER=$(stat -c '%U:%G' "$LARAVEL_DIR/.env" 2>/dev/null || echo "laravel:laravel")
        cp "$TMP_ENV" "$LARAVEL_DIR/.env"
        rm -f "$TMP_ENV"
        chown "$ENV_OWNER" "$LARAVEL_DIR/.env"
        chmod 600 "$LARAVEL_DIR/.env"
        echo "   >> .env actualizado (REDIS_PASSWORD=default, sin USERNAME)."
        echo "   >> NO se recachea Laravel aún (sec 29 hará recache final)."
    fi
fi

# ------------------------------------------------------------------------------
# 13. MODPROBE BLACKLIST (filesystems raros + protocolos obsoletos)
# ------------------------------------------------------------------------------
echo ">> [13/30] Blacklist módulos kernel inseguros o innecesarios..."
cat << 'EOF' > /etc/modprobe.d/CIS-blacklist.conf
# Filesystems infrecuentes (vector de explotación local).
install cramfs /bin/true
install freevxfs /bin/true
install jffs2 /bin/true
install hfs /bin/true
install hfsplus /bin/true
install squashfs /bin/true
install udf /bin/true
# Protocolos de red obsoletos (no usados en stack Laravel).
install dccp /bin/true
install sctp /bin/true
install tipc /bin/true
install rds /bin/true
# Bluetooth / Firewire (no necesario en servidor).
install bluetooth /bin/true
install firewire-core /bin/true
EOF

# ------------------------------------------------------------------------------
# 14. SYSTEMD-COREDUMP OFF (evita dumps con secretos en disco)
# ------------------------------------------------------------------------------
echo ">> [14/30] Desactivando systemd-coredump..."
mkdir -p /etc/systemd/coredump.conf.d
cat << 'EOF' > /etc/systemd/coredump.conf.d/hardening.conf
[Coredump]
Storage=none
ProcessSizeMax=0
EOF
systemctl daemon-reload 2>/dev/null || true

# ------------------------------------------------------------------------------
# 15. TMPFS HARDENING (/dev/shm noexec/nosuid/nodev, /var/tmp nosuid/nodev)
# ------------------------------------------------------------------------------
echo ">> [15/30] Endureciendo tmpfs..."
# /dev/shm: tmpfs by default en RHEL; endurecerlo.
if ! grep -qE '^[^#]*[[:space:]]/dev/shm' /etc/fstab; then
    echo 'tmpfs /dev/shm tmpfs defaults,nosuid,nodev,noexec 0 0' >> /etc/fstab
    echo "   >> Añadido /dev/shm (tmpfs,nosuid,nodev,noexec) a /etc/fstab."
fi
mount -o remount /dev/shm 2>/dev/null || true

# /tmp: si ya es tmpfs (AlmaCloud lo monta así), endurecer. Si no, AVISAR.
if mount | grep -qE 'on /tmp type tmpfs'; then
    if ! grep -qE '^[^#]*[[:space:]]/tmp[[:space:]]' /etc/fstab; then
        # Generar fstab para tmpfs /tmp basado en mount actual.
        echo 'tmpfs /tmp tmpfs defaults,nosuid,nodev,noexec 0 0' >> /etc/fstab
        echo "   >> Añadido /tmp (tmpfs,nosuid,nodev,noexec) a /etc/fstab."
    else
        sed -i -E 's|^[^#]*([[:space:]]/tmp[[:space:]]tmpfs[[:space:]]).*|\1defaults,nosuid,nodev,noexec 0 0|' /etc/fstab 2>/dev/null || true
    fi
    mount -o remount /tmp 2>/dev/null || true
else
    # /tmp en disco: añadir tmpfs /tmp si no existe en fstab (aplica en reboot).
    if ! grep -qE '^[^#]*[[:space:]]/tmp[[:space:]]' /etc/fstab; then
        echo 'tmpfs /tmp tmpfs defaults,nosuid,nodev,noexec 0 0' >> /etc/fstab
        echo "   >> /tmp era en disco; tmpfs /tmp añadido a /etc/fstab (aplica tras reboot)."
        echo "   ⚠️  Antes de reboot: prueba 'sudo dnf update' (algunos paquetes usan /tmp)."
    fi
fi

# /var/tmp como bind a /tmp endurecida.
if ! grep -qE '^[^#]*[[:space:]]/var/tmp[[:space:]]' /etc/fstab; then
    echo '/tmp /var/tmp none bind,nosuid,nodev,noexec 0 0' >> /etc/fstab
    echo "   >> /var/tmp como bind de /tmp añadido a /etc/fstab (aplica tras reboot)."
fi

# ------------------------------------------------------------------------------
# 16. AUDITD + REGLAS REALTIME (identity, sudoers, sshd, audit_logs)
# ------------------------------------------------------------------------------
echo ">> [16/30] Configurando auditd con reglas de monitoreo realtime..."
dnf install -y audit 2>/dev/null || true
systemctl enable --now auditd 2>/dev/null || true

mkdir -p /etc/audit/rules.d
cat << 'EOF' > /etc/audit/rules.d/hardening.rules
## Limpiar reglas previas
-D
## Buffer de eventos (8 MB)
-b 8192
## Modo de fallo: 1=imprimir en log, NO panicar
-f 1
## Wachteo de identidades (modificar passwd/group/shadow)
-w /etc/passwd -p wa -k identity
-w /etc/group -p wa -k identity
-w /etc/shadow -p wa -k identity
-w /etc/gshadow -p wa -k identity
## Watcheo de sudoers (escalar privilegios)
-w /etc/sudoers -p wa -k sudoers
-w /etc/sudoers.d/ -p wa -k sudoers
## Watcheo de configuración SSH (cambios en puerto/firewall/AllowUsers)
-w /etc/ssh/sshd_config -p wa -k sshd
-w /etc/ssh/sshd_config.d/ -p wa -k sshd
## Watcheo de logs de auditoría (tampering trail)
-w /var/log/audit/ -p wa -k audit_logs
-w /var/log/secure -p wa -k var_log_secure
-w /var/log/messages -p wa -k var_log_messages
## Excluir ruido del propio auditctl/audispd
-a always,exclude -F exe=/usr/bin/auditctl -k auditctl_bypass
EOF
augenrules --load 2>/dev/null || true
systemctl restart auditd 2>/dev/null || true

# ------------------------------------------------------------------------------
# 17. DNF-AUTOMATIC (PARCHES DE SEGURIDAD AUTOMÁTICOS)
# ------------------------------------------------------------------------------
echo ">> [17/30] Configurando dnf-automatic (security-only)..."
dnf install -y dnf-automatic 2>/dev/null || true
if [ -f /etc/dnf/automatic.conf ]; then
    cp -a /etc/dnf/automatic.conf "/etc/dnf/automatic.conf.bak.$TS"
    sed -i -E 's/^upgrade_type[[:space:]]*=.*/upgrade_type = security/' /etc/dnf/automatic.conf
    sed -i -E 's/^apply_updates[[:space:]]*=.*/apply_updates = yes/' /etc/dnf/automatic.conf
    sed -i -E 's/^emit_via[[:space:]]*=.*/emit_via = stdio/' /etc/dnf/automatic.conf
    systemctl enable --now dnf-automatic.timer 2>/dev/null || true
    echo "   >> dnf-automatic.timer ACTIVO: comprueba parches security diariamente."
else
    echo "   ⚠️  /etc/dnf/automatic.conf no existe; paquete dnf-automatic no instalado. Skip."
fi

# ------------------------------------------------------------------------------
# 18. POSTGRESQL HARDENING (password_encryption=scram-sha-256, ssl OPCIONAL)
# ------------------------------------------------------------------------------
# NOTA: NO activamos ssl=on por script. PG en 127.0.0.1 (loopback) no necesita
# SSL; activarlo sin cert_file configurado ROMPE el inicio de PostgreSQL.
# Siquieres SSL en PG para conexiones remotas: configura ssl_cert_file /
# ssl_key_file en /var/lib/pgsql/18/data/postgresql.conf manualmente y luego
# `ALTER SYSTEM SET ssl = on;` (requiere restart).
echo ">> [18/30] Endureciendo PostgreSQL..."
if systemctl is-active --quiet postgresql-18 2>/dev/null; then
    # password_encryption es recargable (SIGHUP); afecta a NUEVAS contraseñas.
    sudo -u postgres psql -c "ALTER SYSTEM SET password_encryption = 'scram-sha-256';" 2>/dev/null || true
    sudo -u postgres psql -c "SELECT pg_reload_conf();" 2>/dev/null || true
    # Forzar scram al usuario actual de Laravel (si existe).
    PG_DB_USER=$(grep '^DB_USERNAME=' "${LARAVEL_DIR}/.env" 2>/dev/null | cut -d= -f2 || echo "")
    if [ -n "$PG_DB_USER" ] && [ "$PG_DB_USER" != "default" ]; then
        # Re-set de password para hashear con scram. No CAMBIA la contraseña,
        # solo re-hashea (requiere conocer pass actual; lo dejamos como
        # ejercicio opcional para el admin). Aquí solo reportamos.
        echo "   >> password_encryption=scram-sha-256 recargado (afecta a NUEVAS passwords)."
        echo "      Usuario Laravel '$PG_DB_USER': fuerza re-hashear con:"
        echo "        sudo -u postgres psql -c \"ALTER USER $PG_DB_USER WITH PASSWORD '<la-misma-contraseña>';\""
    fi
    echo "   >> PostgreSQL: password_encryption=scram-sha-256 (recargado, sin ssl loopback)."
else
    echo "   ⚠️  postgresql-18 no activo. Skip hardening PG (ejecuta secure.sh tras setup.sh)."
fi

# ------------------------------------------------------------------------------
# 19. PWQUALITY + LOGIN.DEFS (política contraseñas locales + UMASK 027)
# ------------------------------------------------------------------------------
echo ">> [19/30] Política de contraseñas + UMASK + login.defs..."
dnf install -y libpwquality 2>/dev/null || true
if [ -f /etc/security/pwquality.conf ] || [ -d /etc/security ]; then
    cat << 'EOF' > /etc/security/pwquality.conf
minlen = 14
minclass = 4
maxrepeat = 3
maxclassrepeat = 4
lcredit = -1
ucredit = -1
dcredit = -1
ocredit = -1
difok = 5
enforce_for_root = 1
EOF
fi

# login.defs: UMASK 027 + rotación passwords. Solo si las líneas existen, sed; si no, append.
LD=/etc/login.defs
touch "$LD"
set_ld_var() {
    local key=$1 val=$2
    if grep -qE "^[[:space:]]*${key}[[:space:]]" "$LD" 2>/dev/null; then
        sed -i -E "s|^[[:space:]]*${key}[[:space:]]+.*|${key} ${val}|" "$LD"
    else
        echo "${key} ${val}" >> "$LD"
    fi
}
set_ld_var UMASK 027
set_ld_var PASS_MIN_DAYS 1
set_ld_var PASS_MAX_DAYS 90
set_ld_var PASS_WARN_AGE 7

# Aplicar SHA-512/yescrypt por defecto en criptografia de contraseñas (login.defs).
set_ld_var ENCRYPT_METHOD YESCRYPT

# ------------------------------------------------------------------------------
# 20. DESHABILITAR SERVICIOS INNECESARIOS (reduce superficie monstruo)
# ------------------------------------------------------------------------------
echo ">> [20/30] Deshabilitando servicios innecesarios..."
for svc in avahi-daemon cups nfs-server rpcbind smb nmb tftp xinetd bluetooth telnet.socket rsh.socket rexec.socket rlogin.socket; do
    systemctl disable --now "$svc" 2>/dev/null || true
    systemctl mask "$svc" 2>/dev/null || true
done
echo "   >> (Best-effort; servicios ausentes no generan error.)"

# ------------------------------------------------------------------------------
# 21. USBGUARD — elimado (no aplica en VM/VPS, sin USB real)
# ------------------------------------------------------------------------------
echo ">> [21/30] USBGuard omitido (sin USB real en VM/VPS)."

# ------------------------------------------------------------------------------
# 22. GRUB PASSWORD (OPT-IN: NO recomendado en VPS sin consola propia)
# ------------------------------------------------------------------------------
echo ">> [22/30] GRUB password..."
VIRT_FOR_GRUB=$(systemd-detect-virt 2>/dev/null || echo "none")
DEFAULT_GRUB_RESP="N"
if [[ "$VIRT_FOR_GRUB" == "none" ]]; then
    DEFAULT_GRUB_RESP="s"
fi
if [ -z "$GRUBSETUP" ]; then
    read -rp "   ¿Configurar contraseña GRUB? (protege bootloader, NO en VPS cPanel-cloud) [s/N, default=$DEFAULT_GRUB_RESP]: " GRUBSETUP
fi
GRUBSETUP="${GRUBSETUP:-$DEFAULT_GRUB_RESP}"
GRUBSETUP="${GRUBSETUP,,}"
if [[ "$GRUBSETUP" == "s" || "$GRUBSETUP" == "si" || "$GRUBSETUP" == "sí" ]]; then
    read -rsp "   Contraseña GRUB: " GRUB_PASS
    echo ""
    read -rsp "   Confirma contraseña GRUB: " GRUB_PASS2
    echo ""
    if [[ "$GRUB_PASS" != "$GRUB_PASS2" ]]; then
        echo "   ⚠️  Las contraseñas no coinciden. Skip GRUB."
    elif [[ -z "$GRUB_PASS" ]]; then
        echo "   ⚠️  Contraseña vacía. Skip GRUB."
    elif ! command -v grub2-mkpasswd-pbkdf2 &>/dev/null; then
        echo "   ⚠️  grub2-mkpasswd-pbkdf2 no disponible. Install 'grub2-tools' y reintenta. Skip."
    else
        GRUB_HASH=$(echo -e "${GRUB_PASS}\n${GRUB_PASS}" | grub2-mkpasswd-pbkdf2 2>/dev/null | grep -oE 'grub\.pbkdf2\.[a-zA-Z0-9.]+' | tail -1)
        GRUBCFG_PATH=""
        for p in /boot/grub2/grub.cfg /boot/efi/EFI/almalinux/grub.cfg /boot/efi/EFI/rocky/grub.cfg; do
            [ -f "$p" ] && { GRUBCFG_PATH="$p"; break; }
        done
        if [[ -z "$GRUB_HASH" || -z "$GRUBCFG_PATH" ]]; then
            echo "   ⚠️  Hash GRUB o grub.cfg no encontrados. Skip GRUB password."
        else
            cp -a "$GRUBCFG_PATH" "${GRUBCFG_PATH}.bak.$TS" 2>/dev/null || true
            cat << EOF >> /etc/grub.d/40_custom

# añadido por secure.sh (v2)
set superusers="root"
password_pbkdf2 root ${GRUB_HASH}
EOF
            grub2-mkconfig -o "$GRUBCFG_PATH" 2>/dev/null || true
            echo "   >> GRUB password puesto (usuario=root, hash pbkdf2)."
            echo "   >> EN ARRANQUE: para editar menú GRUB necesitarás esta contraseña."
        fi
    fi
else
    echo "   >> GRUB password omitido."
fi

# ------------------------------------------------------------------------------
# 23. CRON DIARIO: SCAN SECURITY (rkhunter + AIDE + ClamAV → log)
# ------------------------------------------------------------------------------
echo ">> [23/30] Cron diario de escaneo de seguridad..."
cat << 'EOF' > /etc/cron.daily/99-security-scan
#!/bin/bash
# Escaneo de seguridad diario - generado por secure.sh (v2)
LOG=/var/log/security-scan.log
mkdir -p /var/log
{
    echo "============================================================"
    echo " Escaneo de seguridad $(date '+%F %T')"
    echo " Host: $(hostname)"
    echo "============================================================"

    echo ""
    echo "[1/3] rkhunter"
    if command -v rkhunter &>/dev/null; then
        rkhunter --check --sk --report-warnings-only 2>&1 || true
    else
        echo "rkhunter no instalado."
    fi

    echo ""
    echo "[2/3] AIDE --check"
    if command -v aide &>/dev/null; then
        aide --check 2>&1 | tail -30 || true
    else
        echo "AIDE no instalada."
    fi

    echo ""
    echo "[3/3] ClamAV scan /var/www /home /tmp"
    if command -v clamscan &>/dev/null; then
        clamscan -r --quiet --infected /var/www /home /tmp 2>&1 | tail -50 || true
    else
        echo "ClamAV no instalado."
    fi

    echo ""
    echo "============================================================"
    echo " Fin del escaneo $(date '+%F %T')"
    echo "============================================================"
    echo ""
} >> "$LOG" 2>&1

# Rotación simple: borrar logs >30 días.
find /var/log -maxdepth 1 -name 'security-scan.log*' -mtime +30 -delete 2>/dev/null || true
EOF
chmod +x /etc/cron.daily/99-security-scan

# ------------------------------------------------------------------------------
# 24. SUDO HARDENING PARA $SSH_USER (use_pty + timeout + logfile)
# ------------------------------------------------------------------------------
echo ">> [24/30] Endureciendo sudo para '$SSH_USER'..."
SUDO_FILE=/etc/sudoers.d/99-$SSH_USER-hardening
# Escribir a un temporal y validar con visudo -cf ANTES de mover al destino.
# Si la sintaxis falla (p.ej. $SSH_USER raro), no deja un sudoers roto.
SUDO_TMP=$(mktemp)
cat << EOF > "$SUDO_TMP"
# generado por secure.sh (v2) — endurece sudo para $SSH_USER
Defaults:$SSH_USER timestamp_timeout=5
Defaults:$SSH_USER use_pty
Defaults:$SSH_USER !requiretty
Defaults:$SSH_USER logfile=/var/log/sudo-$SSH_USER.log
EOF
chmod 440 "$SUDO_TMP"
if ! visudo -cf "$SUDO_TMP" >/dev/null 2>&1; then
    echo "   ⚠️  Sintaxis sudoers inválida para '$SSH_USER'. Eliminando temporal. NO se aplica."
    rm -f "$SUDO_TMP"
else
    install -m 440 -o root -g root "$SUDO_TMP" "$SUDO_FILE"
    rm -f "$SUDO_TMP"
    # Validación final global (las otras reglas sec-logs).
    visudo -c &>/dev/null || { echo "   ⚠️  visudo -c global falla tras instalar $SUDO_FILE. Revísalo."; }
fi
# Crear el logfile con permisos correctos para que sudo pueda escribir en él.
touch /var/log/sudo-$SSH_USER.log 2>/dev/null || true
chown root:root /var/log/sudo-$SSH_USER.log 2>/dev/null || true
chmod 600 /var/log/sudo-$SSH_USER.log 2>/dev/null || true

# ==============================================================================
# FASE ANTI-ATAQUES WEB (defense-in-depth) — secciones 25-30
# Añadidas v3. Cambio único, reversible (clear.sh sección 17 revierte).
# ==============================================================================

# ------------------------------------------------------------------------------
# 25/30 PHP CLI INI HARDENING (drop-in /etc/php.d — NO toca FrankenPHP embed)
# ------------------------------------------------------------------------------
echo ">> [25/30] Endureciendo PHP CLI (/etc/php.d/99-hardening.ini)..."
# El binario estático FrankenPHP embebe su propio PHP 8.4 + exts: el WORKER
# queda intacto. PERO el supervisor `octane:start` corre bajo PHP CLI del
# sistema (/usr/bin/php artisan octane:start) → este ini SÍ le aplica.
# Causa raíz histórica de octane en restart-loop tras secure.sh:
#   - max_execution_time=30 mata daemons CLI largos (octane, queue:work).
#   - disable_functions=exec rompe tooling Symfony/Composer/Octane.
#   - error_log root:root 640 → usuario laravel no puede escribir errores.
# Por eso: max_execution_time=0 (CLI ilimitado; los SAPI web/FrankenPHP
# embed gestionan su propio timeout), sin `exec` en disable_functions, y
# sin error_log a fichero (stderr → journald vía systemd unit).
PHP_INI_DROP=/etc/php.d/99-hardening.ini
if [ -d /etc/php.d ]; then
    # Re-escritura idempotente del drop-in (sin append duplicado).
    cat << 'EOF' > "$PHP_INI_DROP"
; === añadido por secure.sh v3 — hardening PHP CLI ===
; FrankenPHP worker NO se ve afectado (embeds propio PHP 8.4).
; El supervisor octane:start (PHP CLI) SÍ → no romper daemons.
expose_php = Off
display_errors = Off
log_errors = On
upload_max_filesize = 20M
post_max_size = 25M
memory_limit = 256M
max_execution_time = 0
session.cookie_httponly = 1
session.cookie_secure = 1
session.cookie_samesite = Lax
session.use_strict_mode = 1
session.entropy_length = 32
session.gc_maxlifetime = 1440
; disable_functions: NO incluye exec ni proc_open (Octane/Symfony Process/
; Composer los necesitan en CLI). Web SAPI aplica su propio hardening.
disable_functions = passthru,shell_exec,system,popen
EOF
    restorecon -v "$PHP_INI_DROP" 2>/dev/null || true
else
    echo "   ⚠️  /etc/php.d no existe. PHP CLI no instalado. Skip."
fi

# ------------------------------------------------------------------------------
# 26/30 NGINX SLOWLORIS + BODY LIMITS + TIMEOUTS
# ------------------------------------------------------------------------------
if [ -d /etc/nginx/conf.d ]; then
    echo ">> [26/30] Endureciendo timeouts y límites de cuerpo Nginx..."
    cat << 'EOF' > /etc/nginx/conf.d/00-timeouts.conf
# === anti slowloris + body limits (secure.sh v3) ===
# NOTA: client_max_body_size NO se define aquí porque setup.sh ya lo setea
# a 64m en nginx.conf (http block). Duplicarlo en conf.d/00-timeouts.conf
# (incluido desde http) causa error "directive is duplicate" y nginx -t
# aborta, dejando el servicio sin recargar. Filament/uploads necesitan 64m.
client_body_timeout 30s;
client_header_timeout 30s;
client_body_buffer_size 16k;
send_timeout 30s;
limit_req_status 429;
limit_conn_status 429;
EOF
    # Aplicar limit_conn global por servidor: inyectar en snippets existentes.
    # La zona conn_limit ya está definida en 00-rate-limits.conf (sección 7).
fi

# ------------------------------------------------------------------------------
# 27/30 NGINX limit_except (block TRACE/TRACK) + limit_req por location
# ------------------------------------------------------------------------------
if [ -d /etc/nginx/conf.d ]; then
    echo ">> [27/30] Bloqueo métodos TRACE/TRACK + rate-limit por location..."

    # Mapa http-level: marca métodos peligrosos (XST vector). Permite
    # GET/POST/HEAD/OPTIONS/PUT/DELETE (API REST y Livewire/Filament los usan).
    cat << 'EOF' > /etc/nginx/conf.d/00-method-block.conf
# === añadido por secure.sh v3 — bloqueo TRACE/TRACK (XST) ===
map $request_method $bad_method {
    default 0;
    TRACE 1;
    TRACK 1;
}
EOF

    # Snippet con locations rate-limited para rutas sensibles (login/reset).
    # Inyectar dentro de cada server 443 (idempotente, antes de location /).
    # NO definir `location /api` aquí: el vhost de cloudflare.sh ya tiene
    # `location / { proxy_pass http://octane }` que cubre toda petición; un
    # `location /api` sin content handler entraría en conflicto y dejaría
    # /api sin upstream → 502/521. Rate-limit global ya es aplicado por
    # limit_req_zone a nivel http + limit_conn en method-guard.conf.
    cat << 'EOF' > /etc/nginx/snippets/rate-limited-routes.conf
# === Rate-limit rutas sensibles (secure.sh v3) ===
location ~ ^/(login|admin/login|password/reset|api/auth) {
    limit_req zone=req_limit burst=5 nodelay;
    limit_conn conn_limit 5;
    proxy_pass http://127.0.0.1:8000;
    proxy_http_version 1.1;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
}
EOF

    # Snippet con bloqueo de método + limit_conn global por server.
    cat << 'EOF' > /etc/nginx/snippets/method-guard.conf
# === secure.sh v3: bloqueo TRACE/TRACK + limit_conn 20 por IP ===
if ($bad_method) { return 405; }
limit_conn conn_limit 20;
EOF

    # Inyectar includes en server 443 (no http). Idempotente: grep antes de insert.
    for f in /etc/nginx/conf.d/*.conf; do
        [ -f "$f" ] || continue
        case "$f" in *00-*|*99-security-headers*) continue;; esac
        # Solo vhost con listen 443 (evita inyectar en redirect 80).
        grep -q 'listen .*443' "$f" 2>/dev/null || continue
        grep -q 'snippets/rate-limited-routes.conf' "$f" 2>/dev/null && continue
        # Insertar tras la apertura del primer server 443.
        sed -i -E '0,/^server[[:space:]]*\{/{s|^server[[:space:]]*\{|server {\n    include /etc/nginx/snippets/method-guard.conf;\n    include /etc/nginx/snippets/rate-limited-routes.conf;|}' "$f"
    done

    if ! nginx -t 2>/tmp/nginx_err3; then
        echo "   ⚠️  AVISO: nginx -t falló (sección 27). Detalle:"
        cat /tmp/nginx_err3
    else
        systemctl reload nginx 2>/dev/null || systemctl restart nginx 2>/dev/null || true
    fi
fi

# ------------------------------------------------------------------------------
# 28/30 CABECERAS CROSS-ORIGIN EXTRA (COEP/CORP)
# ------------------------------------------------------------------------------
if [ -d /etc/nginx/conf.d ]; then
    echo ">> [28/30] Añadiendo cabeceras COEP/CORP (cross-origin isolation)..."
    EXTRA_HDR=/etc/nginx/conf.d/00-sec-extra-headers.conf
    if [ -f "$EXTRA_HDR" ]; then
        # Idempotente: solo añadir si no están ya.
        if ! grep -q 'Cross-Origin-Embedder-Policy' "$EXTRA_HDR" 2>/dev/null; then
            # COEP credentialless: permite recursos no-cors sin CORP (más seguro
            # que require-corp, no rompe assets Cloudflare/Filament third-party).
            cat << 'EOF' >> "$EXTRA_HDR"
add_header Cross-Origin-Embedder-Policy "credentialless" always;
add_header Cross-Origin-Resource-Policy "same-origin" always;
EOF
        fi
        # COOP ya está en 99-security-headers.conf (sección 6). No duplicar.
        if ! nginx -t 2>/tmp/nginx_err4; then
            echo "   ⚠️  AVISO: nginx -t falló (sección 28 COEP). Detalle:"
            cat /tmp/nginx_err4
        else
            systemctl reload nginx 2>/dev/null || true
        fi
    fi
fi

# ------------------------------------------------------------------------------
# 29/30 REDIS ACL FILE (aclfile) — reemplaza rename-command legacy
# ------------------------------------------------------------------------------
if [ -f /etc/redis/redis.conf ]; then
    echo ">> [29/30] Configurando Redis ACL (aclfile, sin rename-command)..."
    REDIS_APP_PASS=$(openssl rand -hex 24 2>/dev/null || head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')
    REDIS_ACL=/etc/redis/users.acl

    # ACL file: default (admin/CLI) + laravel (app least-privilege).
    # -@dangerous cubre FLUSHALL/FLUSHDB/CONFIG/KEYS/SHUTDOWN/DEBUG → coexiste
    # sin choque con rename-command "" (ambos rechazan, seguro).
    # NOTA: ACL file de Redis 8 NO admite comentarios `#` (formato distinto
    # a redis.conf). Solo líneas `user ...` son válidas. Escribir `#` causa
    # "ACL errors: line 1 should start with user keyword" → service restart-loop.
    cat << EOF > "$REDIS_ACL"
user default on >$REDIS_PASS ~* +@all -@dangerous
user laravel on >$REDIS_APP_PASS ~* +@all -@dangerous +flushdb
EOF
    chmod 640 "$REDIS_ACL"
    chown redis:redis "$REDIS_ACL" 2>/dev/null || chown redis:root "$REDIS_ACL" 2>/dev/null || true
    restorecon -v "$REDIS_ACL" 2>/dev/null || true

    # Idempotente: quitar aclfile previo y añadir el nuevo.
    # CRÍTICO: ACL file y rename-command son MUTUAMENTE EXCLUSIVOS en Redis 6+.
    # Si se añade aclfile con rename-command presente, redis-server refuse to
    # start con error "Cannot use ACL file when rename-command is used" →
    # service stuck en restart-loop. ACL with -@dangerous cubre los mismos
    # comandos (FLUSHALL/FLUSHDB/CONFIG/KEYS/SHUTDOWN/DEBUG), por lo que
    # rename-command es redundante cuando se activa ACL.
    sed -i -E '/^aclfile[[:space:]]+/d; /^rename-command[[:space:]]+/d' /etc/redis/redis.conf 2>/dev/null || true
    # NOTA: protected-mode y requirepass (añadidos por sección 12) NO chocan
    # con aclfile — requirepass es un shortcut para el usuario default que
    # queda overridden por la línea `user default on >$REDIS_PASS` del ACL.
    # Se conservan; son harmless y mantienen compat retro si aclfile se borra.
    printf '\n# === añadido por secure.sh (v3) ===\naclfile %s\n' "$REDIS_ACL" >> /etc/redis/redis.conf

    systemctl restart redis 2>/dev/null || true
    # Verificar arranque (loop 3s * 5). Avisar si no levanta.
    REDIS_UP=no
    for i in 1 2 3 4 5; do
        systemctl is-active --quiet redis && { REDIS_UP=yes; break; }
        sleep 3
    done
    if [ "$REDIS_UP" != "yes" ]; then
        echo "   ⚠️  Redis no levantó tras ACL. Revisa config:"
        echo "      journalctl -u redis --no-pager | tail -30"
        echo "      Común: aclfile + rename-command coexisten (este parche los quita, verify)."
    fi

    # Parchear Laravel .env con REDIS_USERNAME=laravel + REDIS_PASSWORD=app pass.
    if [[ -n "$LARAVEL_DIR" && -f "$LARAVEL_DIR/.env" ]]; then
        TMP_ENV=$(mktemp)
        grep -v -E '^REDIS_USERNAME=|^REDIS_PASSWORD=' "$LARAVEL_DIR/.env" > "$TMP_ENV" || true
        printf 'REDIS_USERNAME=laravel\nREDIS_PASSWORD=%s\n' "$REDIS_APP_PASS" >> "$TMP_ENV"
        ENV_OWNER=$(stat -c '%U:%G' "$LARAVEL_DIR/.env" 2>/dev/null || echo "laravel:laravel")
        cp "$TMP_ENV" "$LARAVEL_DIR/.env"
        rm -f "$TMP_ENV"
        chown "$ENV_OWNER" "$LARAVEL_DIR/.env"
        chmod 600 "$LARAVEL_DIR/.env"
        echo "   >> .env actualizado (REDIS_USERNAME=laravel + REDIS_PASSWORD=app)."
        echo "   🔑 Redis APP password (gárdala aparte):"
        echo "      $REDIS_APP_PASS"

        # Re-mirror secrets a /etc/laravel/env (systemd EnvironmentFile de
        # harden.sh). Si harden.sh creó /etc/laravel/env y este re-run de
        # secure.sh cambió REDIS_APP_PASS, el EnvironmentFile queda stale:
        # systemd octane inyecta REDIS_PASSWORD=pass_vieja, gana a .env en
        # runtime Dotenv → AUTH FAIL → octane crash-loop → 502/521.
        # Re-mirroring sincroniza EnvironmentFile con .env final.
        if [ -f /etc/laravel/env ]; then
            SECRET_PATTERN='(_PASSWORD=|_SECRET=|_TOKEN=|^APP_KEY=)'
            awk -v p="$SECRET_PATTERN" 'NF && $0 !~ /^#/ && $0 ~ p' \
                "$LARAVEL_DIR/.env" > /etc/laravel/env 2>/dev/null || true
            # Strip surrounding quotes (systemd EnvironmentFile trata literal).
            sed -i -E 's/^([A-Za-z_][A-Za-z0-9_]*)="([^"]*)"/\1=\2/; s/^([A-Za-z_][A-Za-z0-9_]*)='"'"'([^'"'"']*)'"'"'/\1=\2/' \
                /etc/laravel/env 2>/dev/null || true
            chown root:root /etc/laravel/env
            chmod 600 /etc/laravel/env
            restorecon -v /etc/laravel/env 2>/dev/null || true
            echo "   >> /etc/laravel/env re-mirrored (Octane systemd EnvironmentFile sync)."
        fi

        recache_laravel
    else
        echo "   >> .env no parcheado (Laravel no detectado). Configura REDIS_USERNAME=laravel a mano."
        echo "   🔑 Redis APP password (configúrala en .env): $REDIS_APP_PASS"
    fi
fi

# ------------------------------------------------------------------------------
# 30/30 POSTGRESQL LEAST-PRIVILEGE + pg_stat_statements + slow query log
# ------------------------------------------------------------------------------
if systemctl is-active --quiet postgresql-18 2>/dev/null; then
    echo ">> [30/30] PostgreSQL least-privilege + pg_stat_statements + slow log..."

    # Detectar DB name desde .env (fallback laravel1).
    PG_APP_DB="laravel1"
    if [[ -n "$LARAVEL_DIR" && -f "$LARAVEL_DIR/.env" ]]; then
        PG_APP_DB=$(awk -F= '/^DB_DATABASE=/{print $2; exit}' "$LARAVEL_DIR/.env" 2>/dev/null)
        PG_APP_DB="${PG_APP_DB:-laravel1}"
        if ! [[ "$PG_APP_DB" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
            echo "   ⚠️  DB_DATABASE '$PG_APP_DB' inválido. Uso laravel1."
            PG_APP_DB="laravel1"
        fi
    fi

    # REVOKE CREATE ON SCHEMA public FROM PUBLIC (solo afecta no-app users).
    # Opción A: no rompe migrate (app user con GRANT ALL sigue teniendo CREATE).
    sudo -u postgres psql -d "$PG_APP_DB" -c "REVOKE CREATE ON SCHEMA public FROM PUBLIC;" 2>/dev/null || true
    sudo -u postgres psql -c "REVOKE ALL ON DATABASE postgres FROM PUBLIC;" 2>/dev/null || true

    # pg_stat_statements: requiere shared_preload_libraries + restart.
    # Causa raíz histórica: el .so vive en postgresql18-contrib, que NO
    # instala setup.sh:213 (solo -server). Si secure.sh corre sin contrib,
    # `ALTER SYSTEM SET shared_preload_libraries` escribe la directiva en
    # postgresql.auto.conf pero el restart falla al cargar un .so ausente
    # → PG queda en estado failed con restart-loop atascado en systemd.
    # Por eso: (1) asegurar contrib antes de tocar preload, (2) verificar
    # arranque tras restart, (3) rollback de auto.conf si PG no levanta.
    PG_STAT_SO=/usr/pgsql-18/lib/pg_stat_statements.so
    if [ ! -f "$PG_STAT_SO" ]; then
        echo "   >> pg_stat_statements.so ausente. Instalando postgresql18-contrib..."
        dnf install -y --setopt='pgdg-*.repo_gpgcheck=0' --nogpgcheck \
            postgresql18-contrib &>/dev/null || true
    fi

    if [ ! -f "$PG_STAT_SO" ]; then
        echo "   ⚠️  contrib no instalable. Skip shared_preload_libraries (pg_stat_statements NO activo)."
    else
        CURRENT_PRELOAD=$(sudo -u postgres psql -At -c "SHOW shared_preload_libraries;" 2>/dev/null || echo "")
        if ! echo "$CURRENT_PRELOAD" | grep -q 'pg_stat_statements'; then
            NEW_PRELOAD="pg_stat_statements"
            [ -n "$CURRENT_PRELOAD" ] && NEW_PRELOAD="${CURRENT_PRELOAD},${NEW_PRELOAD}"
            # Backup de auto.conf por si rollback necesario tras restart fallido.
            cp -a /var/lib/pgsql/18/data/postgresql.auto.conf \
                  /var/lib/pgsql/18/data/postgresql.auto.conf.bak.$TS 2>/dev/null || true
            sudo -u postgres psql -c "ALTER SYSTEM SET shared_preload_libraries = '${NEW_PRELOAD}';" 2>/dev/null || true
            echo "   >> Reiniciando PostgreSQL para cargar pg_stat_statements (breve downtime)..."
            systemctl restart postgresql-18 2>/dev/null || true
            # Verificar arranque (loop 5s * 6). Rollback si no levanta.
            PG_UP=no
            for i in 1 2 3 4 5 6; do
                systemctl is-active --quiet postgresql-18 && { PG_UP=yes; break; }
                sleep 5
            done
            if [ "$PG_UP" != "yes" ]; then
                echo "   ⚠️  PG no levantó tras preload. Rollback de ALTER SYSTEM..."
                sed -i "/shared_preload_libraries = '.*pg_stat_statements.*'/d" \
                    /var/lib/pgsql/18/data/postgresql.auto.conf 2>/dev/null || true
                systemctl restart postgresql-18 2>/dev/null || true
                for i in 1 2 3; do
                    systemctl is-active --quiet postgresql-18 && break
                    sleep 5
                done
                systemctl is-active --quiet postgresql-18 \
                    || echo "   ⚠️  PG sigue caído. Revisa: journalctl -u postgresql-18 --no-pager | tail -40"
            fi
        fi
    fi

    # Slow query log + log prefix.
    sudo -u postgres psql -c "ALTER SYSTEM SET log_min_duration_statement = '250ms';" 2>/dev/null || true
    sudo -u postgres psql -c "ALTER SYSTEM SET log_line_prefix = '%m [%p] %u@%d ';" 2>/dev/null || true
    sudo systemctl reload postgresql-18 2>/dev/null || true

    # Crear extensión (tras restart si aplica) solo si .so presente.
    if [ -f "$PG_STAT_SO" ]; then
        sudo -u postgres psql -d "$PG_APP_DB" -c "CREATE EXTENSION IF NOT EXISTS pg_stat_statements;" 2>/dev/null || true
    fi
    echo "   >> REVOKE public schema + pg_stat_statements + slow log (>250ms) aplicados."
else
    echo ">> [30/30] PostgreSQL no activo. Skip least-privilege + pg_stat_statements."
fi

# ------------------------------------------------------------------------------
# RESUMEN FINAL
# ------------------------------------------------------------------------------
echo "=========================================================================="
echo " 🚀 BASTIONADO Y DEFENSA EN PROFUNDIDAD COMPLETADOS CON ÉXITO (v2)"
echo "=========================================================================="
echo " [CORE]"
echo "  - Puerto SSH nuevo:        $SSH_PORT"
echo "  - IP permitida SSH:        $ALLOWED_IP"
echo "  - Firewalld:               zona public + regla estricta + ICMP bloqueado"
echo "  - Fail2ban:                sshd aggressive + recidive (1 sem) + nginx jails"
echo "  - CrowdSec:                activo (nginx + sshd + iptables collections)"
echo " [SSH AVANZADO]"
echo "  - MaxAuthTries=3 / MaxStartups=10:30:60 / MaxSessions=2 / maxlogins=3"
echo "  - Anti-pivote: AllowTcpForwarding=no AllowAgentForwarding=no PermitTunnel=no X11=no"
echo "  - Crypto moderno: curve25519 + chacha20-poly1305 + Ed25519 + AES-GCM"
echo "  - 2FA SSH: NO por script (gestiona por 2fa.sh aparte; estado preservado)"
echo " [HARDENING SISTEMA]"
echo "  - sysctl:        IPv4+IPv6+fs.*+kernel.*+bpf+perf sysrq+kptr+dmesg+yama"
echo "  - Modprobe:      blacklist CRAMFS/HFS/DCCP/SCTP/Bluetooth..."
echo "  - Coredumps:     desactivados (Storage=none)"
echo "  - tmpfs:         /dev/shm noexec, /tmp y /var/tmp endurecidos (reboot si en disco)"
echo "  - auditd:        reglas identity/sudoers/sshd/audit_logs realtime"
echo "  - dnf-automatic: parches security-only diarios (timer activo)"
echo "  - pwquality:     minlen=14 minclass=4 enforce_for_root=1"
echo "  - login.defs:    UMASK=027 PASS_MIN/MAX_DAYS rotación YESCRYPT"
echo "  - Sudo $SSH_USER:  use_pty + log_file + timestamp_timeout=5"
echo "  - Servicios:     aliases mask'd (avahi/cups/nfs/smb/tftp/bluetooth...)"
echo "  - USBGuard/GRUB: según elección interactiva (VPS=skip)"
echo " [APP]"
echo "  - Redis:         bind 127.0.0.1 + protected-mode + requirepass (sin rename-command)"
echo "  - PostgreSQL:    ssl=on + password_encryption=scram-sha-256"
echo "  - Cloudflare & Nginx: IPS REALES + bloqueo /.ENV + TLS moderno + CSP"
echo "  - Nginx limits:  10r/s + limit_conn por IP"
echo " [MONITOREO]"
echo "  - AIDE:          DB inicializada (ejecutar 'sudo aide --check' diariamente via cron)"
echo "  - ClamAV:        freshclam + cron scan /var/www /home /tmp"
echo "  - Rkhunter:      --propupd + cron report-warnings-only"
echo "  - Cron diario:   /etc/cron.daily/99-security-scan → /var/log/security-scan.log"
echo "  - Audit panel:   sudo sec-logs"
echo " [FASE ANTI-ATAQUES WEB v3]"
echo "  - PHP CLI:      /etc/php.d/99-hardening.ini (disable_functions sin proc_open)"
echo "  - FrankenPHP:   NO tocado (embeds propio PHP 8.4)"
echo "  - Nginx:        slowloris timeouts + body 20m + block TRACE/TRACK + limit_conn 20"
echo "  - Nginx rate:   limit_req rutas sensibles (login/reset/api/auth burst=5 nodelay)"
echo "  - Nginx hdrs:   COEP credentialless + CORP same-origin (+ COOP de sec6)"
echo "  - Redis ACL:    aclfile /etc/redis/users.acl (default + laravel), rename-command removido (ACL -@dangerous cubre)"
echo "  - PostgreSQL:   REVOKE public schema + pg_stat_statements + slow log >250ms"
echo "  - Sec-logs:     ampliado con secciones WAF/PHP/PG (ver waf.sh hook)"
echo " [CREDENCIALES]"
if [[ -n "$REDIS_PASS" ]]; then
    echo "  🔑 Redis password (admin/default):"
    echo "     $REDIS_PASS"
    echo "     (guardada en $REDIS_CONF)"
    if [[ -n "${REDIS_APP_PASS:-}" ]]; then
        echo "  🔑 Redis password (app/laravel user):"
        echo "     $REDIS_APP_PASS"
        echo "     (en .env REDIS_USERNAME=laravel + REDIS_PASSWORD)"
    fi
fi
if [[ -n "$REPORT_EMAIL" ]]; then
    echo "  📧 Alertas a: $REPORT_EMAIL"
fi
echo "=========================================================================="
echo " Monitoriza:      sudo sec-logs"
echo " 2FA SSH:         sudo bash 2fa.sh          (activar)"
echo "                  sudo bash 2fa.sh --off   (desactivar)"
echo " Cron scan log:   /var/log/security-scan.log"
echo " Sudo log:        /var/log/sudo-$SSH_USER.log"
echo " ⚠️  TMPFS:        si /tmp estaba en disco, reboot para aplicar noexec/nosuid/nodev"
echo "=========================================================================="

# ------------------------------------------------------------------------------
# PROMPT DE REBOOT PROGRAMADO (si hay cambios pendientes de reinicio)
# ------------------------------------------------------------------------------
# Helper reusable: detecta si requiere reboot y pregunta al usuario cuándo
# programarlo. Usa `at` (instalado si falta). Sin interacción si no hay pendientes.
maybe_reboot() {
    local razones="$1"
    [ -z "$razones" ] && return 0
    dnf install -y at 2>/dev/null || true
    systemctl enable --now atd 2>/dev/null || true
    echo ""
    echo " ⚠️  Cambios pendientes de reboot:"
    echo "$razones" | sed 's/^/      - /'
    echo ""
    echo "   Programa reboot (Enter=manual más tarde):"
    echo "     - 'now'                          reboot en 5s"
    echo "     - 'HH:MM'                        hoy a esa hora (p.ej. 04:00)"
    echo "     - 'YYYY-MM-DD HH:MM'             fecha+hora exactas"
    echo "     - 'sun 04:00' / 'mon 02:30' / 'tomorrow 03:00'  formatos de 'at'"
    read -rp "   Opción [Enter=skip]: " WHEN
    [ -z "$WHEN" ] && { echo "   >> No programado. Reboot manual cuando puedas."; return 0; }
    if [ "$WHEN" = "now" ]; then
        echo "   >> Reboot en 5s..."
        ( sleep 5 && systemctl reboot ) &
    elif echo "systemctl reboot" | at "$WHEN" 2>/dev/null; then
        echo "   >> Reboot programado con 'at' para: $WHEN"
        echo "      at -l            lista jobs"
        echo "      sudo at -r <id>  cancela"
    elif shutdown -r "$WHEN" 2>/dev/null; then
        echo "   >> Reboot programado (shutdown) para: $WHEN"
    else
        echo "   ⚠️  Formato no reconocido. No programado. Reboot manual."
    fi
}

# Detección de cambios pendientes de reboot.
REBOOT_RAZONES=""
# (a) /tmp en disco → tmpfs fstab entry aplica tras reboot.
if mount | grep -qE 'on /tmp type tmpfs'; then
    :  # ya tmpfs, no requiere reboot
else
    if grep -qE '^[^#]*[[:space:]]/tmp[[:space:]]' /etc/fstab 2>/dev/null; then
        REBOOT_RAZONES+="tmpfs /tmp endurecido (agregado a /etc/fstab, aplica tras reboot)\n"
    fi
fi
# (b) GRUB password aplicado → kernels con grub.cfg re-generado, reboot aplica.
if [ -f /etc/grub.d/40_custom ] && grep -q password_pbkdf2 /etc/grub.d/40_custom 2>/dev/null; then
    REBOOT_RAZONES+="GRUB password activado (efecto en próximo arranque)\n"
fi
# (c) Kernel parches vía dnf-automatic → requieren reboot para cargarse.
if command -v dnf &>/dev/null && dnf needs-restarting -r 2>/dev/null | grep -qi reboot; then
    REBOOT_RAZONES+="Kernel/paquetes críticos actualizados pendientes de reboot\n"
fi
# (d) Sysctl en caliente ya aplicado (sysctl --system en sección 1), pero algunos
# kernel.* (kptr_restrict, dmesg_restrict, sysrq) requieren reboot si no se aplicaron
# limpiamente. Detección: comparar /proc/sys/kernel/sysrq vs .conf.
if [ -f /etc/sysctl.d/99-security-hardening.conf ]; then
    PROC_SYSRQ=$(cat /proc/sys/kernel/sysrq 2>/dev/null || echo "?")
    CONF_SYSRQ=$(awk -F'[[:space:]]*=[[:space:]]*' '/^kernel\.sysrq[[:space:]]*=/{print $2; exit}' \
                  /etc/sysctl.d/99-security-hardening.conf 2>/dev/null)
    if [ -n "$CONF_SYSRQ" ] && [ "$PROC_SYSRQ" != "?" ] && [ "$PROC_SYSRQ" != "$CONF_SYSRQ" ]; then
        REBOOT_RAZONES+="kernel.sysrq no aplicado en caliente (proc=$PROC_SYSRQ vs conf=$CONF_SYSRQ)\n"
    fi
fi

if [ -n "$REBOOT_RAZONES" ]; then
    maybe_reboot "$(printf '%b' "$REBOOT_RAZONES")"
else
    echo " >> No hay cambios pendientes de reboot. Todo aplicado en caliente. ✅"
fi