#!/bin/bash
set -e

# Parametro: develop o production
MODO="${1:-}"

# Configuracion
PROYECTO_DIR="/var/www/laravel"
LARAVEL_USER="laravel"
LARAVEL_HOME="/home/laravel"
SSH_USER="miguel"
SSH_PORT="22"
DEV_NETWORK="192.168.1.0/24"
ALLOWED_SSH_CIDR="192.168.1.0/24"
VITE_PORT="5173"

IPV4_CIDR_REGEX='^(([0-9]{1,2}|1[0-9]{2}|2[0-4][0-9]|25[0-5])\.){3}([0-9]{1,2}|1[0-9]{2}|2[0-4][0-9]|25[0-5])(/([0-9]|[12][0-9]|3[0-2]))?$'

if [ "$MODO" != "develop" ] && [ "$MODO" != "production" ]; then
    echo "Uso: sudo bash seguridad/secure.sh [develop|production]"
    exit 1
fi

if [ "$EUID" -ne 0 ]; then
    echo "Ejecuta este script con sudo."
    exit 1
fi

if [ ! -f "$PROYECTO_DIR/artisan" ] || [ ! -f "$PROYECTO_DIR/.env" ]; then
    echo "Error: no se encontro Laravel en $PROYECTO_DIR."
    exit 1
fi

if [ "$MODO" = "develop" ]; then
    if ! [[ "$DEV_NETWORK" =~ $IPV4_CIDR_REGEX ]]; then
        echo "Error: DEV_NETWORK no es una direccion IPv4/CIDR valida."
        exit 1
    fi

    echo "=========================================================================="
    echo " SEGURIDAD DE DESARROLLO - Ubuntu Server 26.04"
    echo "=========================================================================="

    echo "[1/6] Instalando firewall y Fail2ban..."
    apt-get update
    apt-get install -y ufw fail2ban

    echo "[2/6] Configurando UFW para desarrollo..."
    ufw default deny incoming
    ufw default allow outgoing
    ufw allow "$SSH_PORT/tcp" comment 'SSH desarrollo'
    ufw allow 80/tcp comment 'HTTP'
    ufw allow 443/tcp comment 'HTTPS'
    ufw allow from "$DEV_NETWORK" to any port "$VITE_PORT" proto tcp comment 'Vite desarrollo'
    ufw deny 5432/tcp comment 'PostgreSQL solo por tunel SSH'
    ufw deny 6379/tcp comment 'Redis solo local'
    ufw --force enable

    echo "[3/6] Configurando Fail2ban tolerante..."
    cat > /etc/fail2ban/jail.d/lsetup-development.local <<EOF
[DEFAULT]
bantime = 15m
findtime = 10m
maxretry = 8
backend = systemd

[sshd]
enabled = true
port = $SSH_PORT
EOF
    systemctl enable --now fail2ban
    systemctl restart fail2ban

    echo "[4/6] Aplicando cabeceras Nginx compatibles con desarrollo..."
    cat > /etc/nginx/conf.d/00-lsetup-development.conf <<'EOF'
server_tokens off;
add_header X-Content-Type-Options "nosniff" always;
add_header Referrer-Policy "strict-origin-when-cross-origin" always;
add_header Permissions-Policy "geolocation=(), microphone=(), camera=()" always;
EOF
    rm -f /etc/nginx/conf.d/00-lsetup-production.conf
    nginx -t
    systemctl reload nginx

    echo "[5/6] Protegiendo archivos sensibles..."
    chown "$LARAVEL_USER:$LARAVEL_USER" "$PROYECTO_DIR/.env"
    chmod 640 "$PROYECTO_DIR/.env"
    chmod -R ug+rwX "$PROYECTO_DIR/storage" "$PROYECTO_DIR/bootstrap/cache"

    echo "[6/6] Limpiando caches de Laravel..."
    sudo -u "$LARAVEL_USER" env HOME="$LARAVEL_HOME" COMPOSER_HOME="$LARAVEL_HOME/.composer" \
        bash -c "cd '$PROYECTO_DIR' && php artisan optimize:clear"

    if systemctl is-active --quiet octane 2>/dev/null; then
        systemctl restart octane
    fi

    echo "Perfil develop aplicado."
    echo "SSH sigue accesible y Vite solo se permite desde $DEV_NETWORK."
    exit 0
fi

if ! [[ "$SSH_PORT" =~ ^[0-9]+$ ]] || [ "$SSH_PORT" -lt 1 ] || [ "$SSH_PORT" -gt 65535 ]; then
    echo "Error: SSH_PORT no es valido."
    exit 1
fi

if ! [[ "$ALLOWED_SSH_CIDR" =~ $IPV4_CIDR_REGEX ]]; then
    echo "Error: ALLOWED_SSH_CIDR no es una direccion IPv4/CIDR valida."
    exit 1
fi

if ! id "$SSH_USER" >/dev/null 2>&1; then
    echo "Error: el usuario SSH '$SSH_USER' no existe."
    exit 1
fi

SSH_HOME="$(getent passwd "$SSH_USER" | cut -d: -f6)"
if [ ! -s "$SSH_HOME/.ssh/authorized_keys" ]; then
    echo "Error: $SSH_USER no tiene authorized_keys. Se aborta para evitar bloqueo SSH."
    exit 1
fi

echo "Se restringira SSH a $ALLOWED_SSH_CIDR y se desactivara el acceso por password."
read -r -p "Escribe PRODUCTION para continuar: " CONFIRMACION
if [ "$CONFIRMACION" != "PRODUCTION" ]; then
    echo "Operacion cancelada."
    exit 1
fi

BACKUP_DIR="/root/lsetup-security-$(date +%Y%m%d-%H%M%S)"
install -d -m 700 "$BACKUP_DIR"
cp -a /etc/ssh/sshd_config "$BACKUP_DIR/" 2>/dev/null || true
cp -a /etc/ssh/sshd_config.d "$BACKUP_DIR/" 2>/dev/null || true
cp -a /etc/nginx/nginx.conf "$BACKUP_DIR/" 2>/dev/null || true
cp -a /etc/nginx/conf.d "$BACKUP_DIR/" 2>/dev/null || true
cp -a /etc/ufw "$BACKUP_DIR/" 2>/dev/null || true
ufw status numbered > "$BACKUP_DIR/ufw-status.txt" 2>/dev/null || true

echo "=========================================================================="
echo " SEGURIDAD DE PRODUCCION - Ubuntu Server 26.04"
echo " Backup: $BACKUP_DIR"
echo "=========================================================================="

echo "[1/9] Instalando controles de seguridad..."
apt-get update
apt-get install -y ufw fail2ban unattended-upgrades auditd

echo "[2/9] Endureciendo SSH..."
cat > /etc/ssh/sshd_config.d/99-lsetup-production.conf <<EOF
Port $SSH_PORT
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitEmptyPasswords no
PubkeyAuthentication yes
UsePAM yes
MaxAuthTries 3
LoginGraceTime 30
MaxSessions 4
AllowUsers $SSH_USER
AllowTcpForwarding local
PermitOpen 127.0.0.1:5432 localhost:5432
X11Forwarding no
PermitTunnel no
EOF

if ! /usr/sbin/sshd -t; then
    if [ -f "$BACKUP_DIR/sshd_config.d/99-lsetup-production.conf" ]; then
        cp "$BACKUP_DIR/sshd_config.d/99-lsetup-production.conf" /etc/ssh/sshd_config.d/99-lsetup-production.conf
    else
        rm -f /etc/ssh/sshd_config.d/99-lsetup-production.conf
    fi
    echo "Error: configuracion SSH invalida. Se retiro el cambio."
    exit 1
fi

echo "[3/9] Cerrando el firewall..."
ufw default deny incoming
ufw default allow outgoing
ufw allow from "$ALLOWED_SSH_CIDR" to any port "$SSH_PORT" proto tcp comment 'SSH administracion'
ufw allow 80/tcp comment 'HTTP'
ufw allow 443/tcp comment 'HTTPS'
ufw --force delete allow "$SSH_PORT/tcp" >/dev/null 2>&1 || true
ufw --force delete allow from "$DEV_NETWORK" to any port "$VITE_PORT" proto tcp >/dev/null 2>&1 || true
ufw deny 5432/tcp comment 'PostgreSQL solo por tunel SSH'
ufw deny 6379/tcp comment 'Redis solo local'
ufw --force enable
systemctl reload ssh

echo "[4/9] Configurando Fail2ban restrictivo..."
cat > /etc/fail2ban/jail.d/lsetup-production.local <<EOF
[DEFAULT]
bantime = 1h
findtime = 10m
maxretry = 3
backend = systemd
ignoreip = 127.0.0.1/8 ::1 $ALLOWED_SSH_CIDR

[sshd]
enabled = true
port = $SSH_PORT
mode = aggressive

[nginx-botsearch]
enabled = true
EOF
rm -f /etc/fail2ban/jail.d/lsetup-development.local
systemctl enable --now fail2ban
systemctl restart fail2ban

echo "[5/9] Aplicando hardening de red y kernel..."
cat > /etc/sysctl.d/99-lsetup-production.conf <<'EOF'
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv6.conf.all.accept_redirects = 0
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
kernel.yama.ptrace_scope = 1
fs.protected_hardlinks = 1
fs.protected_symlinks = 1
EOF
sysctl --system >/dev/null

echo "[6/9] Aplicando cabeceras Nginx de produccion..."
cat > /etc/nginx/conf.d/00-lsetup-production.conf <<'EOF'
server_tokens off;
ssl_protocols TLSv1.2 TLSv1.3;
add_header Strict-Transport-Security "max-age=31536000" always;
add_header X-Content-Type-Options "nosniff" always;
add_header X-Frame-Options "DENY" always;
add_header Referrer-Policy "strict-origin-when-cross-origin" always;
add_header Permissions-Policy "geolocation=(), microphone=(), camera=()" always;
add_header Cross-Origin-Opener-Policy "same-origin" always;
add_header Content-Security-Policy "default-src 'self'; script-src 'self' https://cdn.tailwindcss.com; style-src 'self' 'unsafe-inline'; img-src 'self' data: https://*.googleusercontent.com; font-src 'self' data:; connect-src 'self'; object-src 'none'; frame-ancestors 'none'; base-uri 'self'" always;
EOF
rm -f /etc/nginx/conf.d/00-lsetup-development.conf

if ! nginx -t; then
    rm -f /etc/nginx/conf.d/00-lsetup-production.conf
    if [ -f "$BACKUP_DIR/conf.d/00-lsetup-development.conf" ]; then
        cp "$BACKUP_DIR/conf.d/00-lsetup-development.conf" /etc/nginx/conf.d/00-lsetup-development.conf
    fi
    echo "Error: Nginx rechazo las cabeceras. Se retiro el archivo nuevo."
    exit 1
fi
systemctl reload nginx

echo "[7/9] Activando auditoria y actualizaciones de seguridad..."
cat > /etc/audit/rules.d/99-lsetup.rules <<EOF
-w /etc/passwd -p wa -k identity
-w /etc/group -p wa -k identity
-w /etc/shadow -p wa -k identity
-w /etc/sudoers -p wa -k sudoers
-w /etc/sudoers.d -p wa -k sudoers
-w /etc/ssh/sshd_config -p wa -k ssh
-w /etc/ssh/sshd_config.d -p wa -k ssh
-w $PROYECTO_DIR/.env -p wa -k laravel_env
EOF
augenrules --load
systemctl enable --now auditd

cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF

echo "[8/9] Configurando Laravel para produccion..."
grep -v '^APP_ENV=' "$PROYECTO_DIR/.env" | grep -v '^APP_DEBUG=' > "$PROYECTO_DIR/.env.lsetup"
printf 'APP_ENV=production\nAPP_DEBUG=false\n' >> "$PROYECTO_DIR/.env.lsetup"
mv "$PROYECTO_DIR/.env.lsetup" "$PROYECTO_DIR/.env"
chown "$LARAVEL_USER:$LARAVEL_USER" "$PROYECTO_DIR/.env"
chmod 640 "$PROYECTO_DIR/.env"
chmod -R ug+rwX "$PROYECTO_DIR/storage" "$PROYECTO_DIR/bootstrap/cache"

sudo -u "$LARAVEL_USER" env HOME="$LARAVEL_HOME" COMPOSER_HOME="$LARAVEL_HOME/.composer" \
    bash -c "cd '$PROYECTO_DIR' && php artisan optimize:clear && php artisan config:cache && php artisan route:cache && php artisan view:cache"

echo "[9/9] Reiniciando servicios y comprobando puertos..."
systemctl restart octane
systemctl reload nginx
systemctl is-active --quiet nginx
systemctl is-active --quiet octane
systemctl is-active --quiet fail2ban
ss -ltn | grep -q '127.0.0.1:5432'
ss -ltn | grep -q '127.0.0.1:6379'

echo "Perfil production aplicado."
echo "Abre otra sesion SSH y verifica el acceso antes de cerrar la actual."
echo "Backup: $BACKUP_DIR"
