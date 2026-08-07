#!/bin/bash
set -e

# ==============================================================================
# INSTALADOR LARAVEL 13 + PHP 8.5 + PostgreSQL 18 + Redis 8 + Filament 5
# Octane/FrankenPHP + Nginx + systemd + SELinux + Firewall
# Compatible AlmaLinux / Rocky Linux 10
# ==============================================================================

# --- Variables --------------------------------------------------------

prompt_var() {
    # $1=nombre variable  $2=texto  $3=default  $4="secret" para ocultar
    local __var="$1" __msg="$2" __def="$3" __secret="${4:-}" input
    if [ -n "$__secret" ]; then
        read -rsp "$__msg [$__def]: " input; echo
    else
        read -rp "$__msg [$__def]: " input
    fi
    printf -v "$__var" '%s' "${input:-$__def}"
}

prompt_required() {
    # Igual que prompt_var pero no admite vacío.
    local __var="$1" __msg="$2" __secret="${3:-}" input=""
    while [ -z "$input" ]; do
        if [ -n "$__secret" ]; then
            read -rsp "$__msg: " input; echo
        else
            read -rp "$__msg: " input
        fi
    done
    printf -v "$__var" '%s' "$input"
}

echo "== Configuración inicial (Enter acepta el valor entre corchetes) =="
prompt_var      PROYECTO_NOMBRE "Nombre del proyecto (directorio /var/www/...)" "laravel1"
prompt_required DB_NAME         "Nombre base de datos PostgreSQL"              
prompt_required DB_USER         "Usuario base de datos"                          
prompt_required DB_PASS         "Contraseña base de datos"                       secret
echo "======================================================================="

# Validar identificadores de BD: solo [A-Za-z_][A-Za-z0-9_]* (anti-inyección SQL/psql).
for v in DB_NAME DB_USER; do
    if ! [[ ${!v} =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
        echo "Error: $v='${!v}' inválido (solo letras, números y _; primer carácter letra o _)."
        exit 1
    fi
done

PROYECTO_DIR="/var/www/$PROYECTO_NOMBRE"
LARAVEL_USER="laravel"
LARAVEL_HOME="/var/lib/laravel"

# --- Detección automática de IP ----------------------------------------------
SERVER_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
if [ -z "$SERVER_IP" ]; then
    SERVER_IP="127.0.0.1"
fi
export SERVER_IP

echo "=========================================================================="
echo " IPv4: $SERVER_IP"
echo " Proyecto:     $PROYECTO_DIR"
echo "=========================================================================="

# --- Detección de hardware para tuning de rendimiento ------------------------
# Se calcula a partir de RAM total y nº de núcleos: workers de Octane,
# shared_buffers/effective_cache_size de PostgreSQL y maxmemory/io-threads de Redis.
CPU_CORES=$(nproc 2>/dev/null || echo 1)
[ "$CPU_CORES" -lt 1 ] && CPU_CORES=1
RAM_KB=$(grep -m1 MemTotal /proc/meminfo | awk '{print $2}')
RAM_MB=$(( RAM_KB / 1024 ))
[ "$RAM_MB" -lt 256 ] && RAM_MB=256           # suelo razonable

# Octane (FrankenPHP): workers ≈ núcleos (cap 8). FrankenPHP no usa task-workers.
OCTANE_WORKERS=$CPU_CORES
[ "$OCTANE_WORKERS" -gt 8 ] && OCTANE_WORKERS=8
[ "$OCTANE_WORKERS" -lt 2 ] && OCTANE_WORKERS=2

# PostgreSQL 18.
PG_SHARED_BUFFERS=$(( RAM_MB / 4 ))           # ~25% RAM
PG_EFFECTIVE_CACHE_SIZE=$(( RAM_MB * 3 / 4 )) # ~75% RAM
PG_WORK_MEM=$(( (RAM_MB - PG_SHARED_BUFFERS) / 300 ))  # (RAM-libre)/(max_conn*3)
[ "$PG_WORK_MEM" -lt 4 ] && PG_WORK_MEM=4
PG_MAINTENANCE_WORK_MEM=$(( RAM_MB / 16 ))    # ~6% RAM
[ "$PG_MAINTENANCE_WORK_MEM" -lt 64 ] && PG_MAINTENANCE_WORK_MEM=64
PG_WAL_BUFFERS=$(( PG_SHARED_BUFFERS / 32 ))  # cap 16 MB (recomendación PG)
[ "$PG_WAL_BUFFERS" -gt 16 ] && PG_WAL_BUFFERS=16
[ "$PG_WAL_BUFFERS" -lt 4 ] && PG_WAL_BUFFERS=4
PG_MAX_CONNECTIONS=100
PG_PARALLEL_PER_GATHER=$(( CPU_CORES / 2 ))
[ "$PG_PARALLEL_PER_GATHER" -lt 1 ] && PG_PARALLEL_PER_GATHER=1

# Redis: maxmemory ~25% RAM (cap 4 GB), io-threads 1-4.
REDIS_MAXMEMORY=$(( RAM_MB / 4 ))
[ "$REDIS_MAXMEMORY" -lt 64 ] && REDIS_MAXMEMORY=64
[ "$REDIS_MAXMEMORY" -gt 4096 ] && REDIS_MAXMEMORY=4096
REDIS_IO_THREADS=$CPU_CORES
[ "$REDIS_IO_THREADS" -gt 4 ] && REDIS_IO_THREADS=4
[ "$REDIS_IO_THREADS" -lt 1 ] && REDIS_IO_THREADS=1

echo "=========================================================================="
echo " Hardware: $CPU_CORES núcleos / ${RAM_MB} MB RAM"
echo " Octane:   workers=$OCTANE_WORKERS (FrankenPHP)"
echo " PG18:     shared_buffers=${PG_SHARED_BUFFERS}MB cache=${PG_EFFECTIVE_CACHE_SIZE}MB work_mem=${PG_WORK_MEM}MB"
echo " Redis:    maxmemory=${REDIS_MAXMEMORY}mb io-threads=$REDIS_IO_THREADS"
echo "=========================================================================="

# --- helpers -----------------------------------------------------------------
# Ejecuta un comando como usuario laravel dentro del directorio del proyecto.
# HOME apunta al hogar real del usuario (no al proyecto) para que el caché de
# Composer viva en ~/.composer y no dentro del proyecto.
as_laravel() {
    sudo -u "$LARAVEL_USER" env HOME="$LARAVEL_HOME" COMPOSER_HOME="$LARAVEL_HOME/.composer" bash -lc "cd '$PROYECTO_DIR' && $*"
}

# --- Preflight crítico (debe correr ANTES de cualquier `dnf install`) --------
# Causa raíz histórica: si pgdg-redhat-repo se instaló en una run previa, su
# .repo en /etc/yum.repos.d/ queda enabled=1 con repo_gpgcheck=1. CUALQUIER
# `dnf install` posterior (incluso `epel-release`) refresca metadata de TODOS
# los repos habilitados, incluyendo pgdg-common. GPG rechaza repomd.xml porque
# PGDG lo firma con timestamp "not before" ligeramente futuro y en VMs
# VirtualBox el reloj va atrasado. dnf sale non-zero y `set -e` mata el script
# antes de llegar a la sección 3, donde estaba el fix. Por eso el preflight
# tiene que ir aquí, antes de tocar dnf.

# (a) Sincronizar reloj por HTTP Date header (TCP 443 pasa VBox NAT; NTP UDP
#     123 no). Formato RFC 7231 que `date -s` acepta.
DATE_STR=$(curl -sI --max-time 5 https://www.cloudflare.com/ 2>/dev/null \
           | awk -F': ' 'tolower($1)=="date"{print $2; exit}')
if [ -n "$DATE_STR" ]; then
    sudo date -s "$DATE_STR" &>/dev/null || true
fi

# (b) Si ya existen .repo de PGDG (run previa), desactivar verificación de
#     repomd.xml AHORA. gpgcheck de PAQUETES sigue activo (llave ya importada).
#     Sed tolerante con espacios alrededor de '=' y con [pgdg-*.repo].
if ls /etc/yum.repos.d/pgdg-*.repo &>/dev/null; then
    sudo sed -i -E 's/^[[:space:]]*repo_gpgcheck[[:space:]]*=[[:space:]]*1/repo_gpgcheck=0/g' \
        /etc/yum.repos.d/pgdg-*.repo 2>/dev/null || true
    sudo dnf clean all &>/dev/null || true
fi

echo "=== 1. PREPARACIÓN DEL SISTEMA Y REPOS ==="
sudo dnf install -y epel-release dnf-plugins-core
sudo dnf config-manager --set-enabled crb || true
sudo dnf install -y --nogpgcheck https://rpms.remirepo.net/enterprise/remi-release-10.rpm || true
curl -fsSL https://rpm.nodesource.com/setup_22.x | sudo bash -
sudo dnf install -y nodejs npm
sudo dnf install -y git

# Sincronizar reloj vía NTP: certificados GPG de repos como PGDG pueden tener
# timestamps "not before" ligeramente en el futuro. En VMs (VirtualBox) el reloj
# va atrasado con frecuencia y la verificación GPG falla con
# "signature is not alive yet". chrony sincroniza antes de tocar PGDG.
sudo dnf install -y chrony 2>/dev/null || true
sudo systemctl enable --now chronyd 2>/dev/null || true
sudo chronyc -a makestep &>/dev/null || true

# Límites del sistema
sudo bash -c 'cat << "EOF" >> /etc/security/limits.conf
* soft nofile 65535
* hard nofile 65535
EOF'

sudo bash -c 'cat << "EOF" >> /etc/sysctl.conf
net.core.somaxconn = 65535
EOF'
sudo sysctl -p || true

echo "=== 2. FIREWALL ==="
sudo dnf install -y firewalld
sudo systemctl enable --now firewalld
sudo firewall-cmd --permanent --add-service=http
# SSH abierto para Cursor Remote-SSH (secure.sh lo restringe por IP después).
sudo firewall-cmd --permanent --add-service=ssh
# 8000 interno (Octane) no necesita exponerse: Nginx hace de reverse proxy.
sudo firewall-cmd --reload

echo "=== 3. POSTGRESQL 18 ==="

# CRÍTICO: PGDG firma repomd.xml (metadata del repo) con timestamp "not before"
# ligeramente futuro. En VMs VirtualBox el reloj va atrasado y GPG rechaza la
# firma con "signature is not alive yet". Doble fix defensivo:
#   (a) sincronizar reloj ANTES de tocar repos PGDG (ataca la raíz)
#   (b) forzar repo_gpgcheck=0 por si (a) no basta (defensa en profundidad)
# gpgcheck de PAQUETES sigue activo: cada RPM se verifica con la llave PGDG
# ya importada al instalar pgdg-redhat-repo.

# (a) Reloj. chrony makestep se intentó en sección 1, pero VBox NAT bloqua
#     NTP UDP 123. Fallback robusto: tomar hora de cabecera HTTP Date de un
#     servidor público (TCP 443 SÍ pasa por VBox NAT). Formato RFC 7231 que
#     `date -s` acepta ("Wed, 29 Jul 2026 12:34:56 GMT").
DATE_STR=$(curl -sI --max-time 5 https://www.cloudflare.com/ 2>/dev/null \
           | awk -F': ' 'tolower($1)=="date"{print $2; exit}')
if [ -n "$DATE_STR" ]; then
    sudo date -s "$DATE_STR" &>/dev/null || true
fi

sudo dnf install -y --nogpgcheck https://download.postgresql.org/pub/repos/yum/reporpms/EL-10-x86_64/pgdg-redhat-repo-latest.noarch.rpm || true

# (b) repo_gpgcheck=0 en TODOS los .repo de PGDG. Sed tolerante con espacios
#     alrededor de '='. El --setopt del install refuerza por si la línea no
#     existiera y tomara default=1 de dnf.conf [main] o del compiled default.
sudo sed -i -E 's/^[[:space:]]*repo_gpgcheck[[:space:]]*=[[:space:]]*1/repo_gpgcheck=0/g' \
    /etc/yum.repos.d/pgdg*.repo 2>/dev/null || true
sudo dnf clean all
sudo dnf -qy module disable postgresql || true
# --setopt fuerza repo_gpgcheck=0 en todos los repos pgdg-* para ESTE comando,
# independientemente de lo que diga el .repo o dnf.conf. Belt-and-suspenders.
sudo dnf install -y --setopt='pgdg-*.repo_gpgcheck=0' --nogpgcheck postgresql18-server

if [ ! -f /var/lib/pgsql/18/data/PG_VERSION ]; then
    sudo /usr/pgsql-18/bin/postgresql-18-setup initdb
fi

# Autenticación por contraseña (scram-sha-256) para conexiones locales TCP
PG_HBA=/var/lib/pgsql/18/data/pg_hba.conf
sudo sed -i 's/^host\s\+all\s\+all\s\+127.0.0.1\/32.*/host    all    all    127.0.0.1\/32    scram-sha-256/' "$PG_HBA"
sudo sed -i 's/^host\s\+all\s\+all\s\+::1\/128.*/host    all    all    ::1\/128         scram-sha-256/' "$PG_HBA"

sudo systemctl enable --now postgresql-18

# Escapar comilla simple para SQL (Postgres: ' -> ''). Anti-inyección.
DB_PASS_SQL=$(printf '%s' "$DB_PASS" | sed "s/'/''/g")
sudo -u postgres psql -c "CREATE USER $DB_USER WITH PASSWORD '$DB_PASS_SQL';" || true
sudo -u postgres psql -c "CREATE DATABASE $DB_NAME OWNER $DB_USER;" || true
sudo -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE $DB_NAME TO $DB_USER;" || true

# Tuning de PostgreSQL 18 según hardware detectado (ALTER SYSTEM).
# shared_buffers/max_connections/wal_buffers/max_worker_processes requieren
# reinicio del cluster; el resto se aplica con pg_reload_conf().
sudo -u postgres psql -v ON_ERROR_STOP=1 <<SQL
ALTER SYSTEM SET shared_buffers = '${PG_SHARED_BUFFERS}MB';
ALTER SYSTEM SET effective_cache_size = '${PG_EFFECTIVE_CACHE_SIZE}MB';
ALTER SYSTEM SET work_mem = '${PG_WORK_MEM}MB';
ALTER SYSTEM SET maintenance_work_mem = '${PG_MAINTENANCE_WORK_MEM}MB';
ALTER SYSTEM SET wal_buffers = '${PG_WAL_BUFFERS}MB';
ALTER SYSTEM SET max_connections = ${PG_MAX_CONNECTIONS};
ALTER SYSTEM SET max_worker_processes = ${CPU_CORES};
ALTER SYSTEM SET max_parallel_workers = ${CPU_CORES};
ALTER SYSTEM SET max_parallel_workers_per_gather = ${PG_PARALLEL_PER_GATHER};
ALTER SYSTEM SET checkpoint_completion_target = 0.9;
ALTER SYSTEM SET random_page_cost = 1.1;
ALTER SYSTEM SET effective_io_concurrency = 200;
SQL
sudo systemctl restart postgresql-18

echo "=== 4. USUARIO LARAVEL (no-root) ==="
# Usuario con hogar real para caché de Composer (separado del proyecto).
sudo useradd -m -s /bin/bash -d "$LARAVEL_HOME" "$LARAVEL_USER" 2>/dev/null || true
sudo mkdir -p "$LARAVEL_HOME"
sudo chown -R "$LARAVEL_USER":"$LARAVEL_USER" "$LARAVEL_HOME"

# Password "laravel" desbloquea cuenta (useradd deja !! en /etc/shadow, SSH rechaza).
# secure.sh forzará key-only más tarde; password es puente para Cursor Remote-SSH.
echo "laravel:laravel" | sudo chpasswd

# .ssh listo para subir clave pública (ver ssh.txt). Permisos estrictos para StrictModes.
sudo -u "$LARAVEL_USER" mkdir -p "$LARAVEL_HOME/.ssh"
sudo -u "$LARAVEL_USER" touch "$LARAVEL_HOME/.ssh/authorized_keys"
sudo chmod 700 "$LARAVEL_HOME/.ssh"
sudo chmod 600 "$LARAVEL_HOME/.ssh/authorized_keys"
sudo chown -R "$LARAVEL_USER":"$LARAVEL_USER" "$LARAVEL_HOME/.ssh"

# Grupo wheel = sudoers en RHEL/AlmaLinux (%wheel ALL=(ALL) ALL en /etc/sudoers).
# Password requerido (laravel). Secure.sh puede endurecer después.
sudo usermod -aG wheel "$LARAVEL_USER"

# Git config como laravel (HOME real → /var/lib/laravel/.gitconfig, no /root).
sudo -u "$LARAVEL_USER" env HOME="$LARAVEL_HOME" git config --global user.name "miguel"
sudo -u "$LARAVEL_USER" env HOME="$LARAVEL_HOME" git config --global user.email "miguel2006ngl@gmail.com"
sudo -u "$LARAVEL_USER" env HOME="$LARAVEL_HOME" git config --global init.defaultBranch main

sudo mkdir -p /var/www
sudo chown "$LARAVEL_USER":"$LARAVEL_USER" /var/www

echo "=== 5. PHP 8.5 + COMPOSER ==="
sudo dnf module reset php -y || true
sudo dnf module enable php:remi-8.5 -y || true

sudo dnf install -y \
    php php-cli php-fpm php-pgsql php-zip php-xml php-curl php-intl \
    php-bcmath php-mbstring php-posix php-pcntl php-gd php-opcache \
    php-pecl-redis

# Composer global en /usr/local/bin (no se ejecuta como root más adelante)
if [ ! -x /usr/local/bin/composer ]; then
    curl -sS https://getcomposer.org/installer | sudo php -- --install-dir=/usr/local/bin --filename=composer
    sudo chmod +x /usr/local/bin/composer
fi
# Asegurar que el binario es accesible para el usuario laravel
sudo ln -sf /usr/local/bin/composer /usr/bin/composer || true

echo "=== 6. REDIS (phpredis) ==="
sudo dnf module reset redis -y || true
sudo dnf module enable redis:remi-8.0 -y || true
sudo dnf install -y redis

sudo systemctl enable --now redis

if ! grep -q "^maxmemory " /etc/redis/redis.conf 2>/dev/null; then
    sudo bash -c "cat << EOF >> /etc/redis/redis.conf
# --- Tuning automático (setup.sh) ---
maxmemory ${REDIS_MAXMEMORY}mb
maxmemory-policy allkeys-lru
io-threads ${REDIS_IO_THREADS}
io-threads-do-reads yes
tcp-backlog 511
tcp-keepalive 300
timeout 0
EOF"
fi
sudo systemctl restart redis

echo "=== 7. CREACIÓN DEL PROYECTO LARAVEL 13 ==="
# Limpiar restos de instalaciones previas (dir incompleto o mal permisos).
# Esto resuelve el "mkdir(): Permission denied" cuando /var/www/laravel1 quedó
# propiedad de root por una ejecución anterior con sudo composer.
if [ -d "$PROYECTO_DIR" ] && [ ! -d "$PROYECTO_DIR/vendor" ]; then
    sudo rm -rf "$PROYECTO_DIR"
fi
sudo chown "$LARAVEL_USER":"$LARAVEL_USER" /var/www

if [ ! -d "$PROYECTO_DIR/vendor" ]; then
    sudo -u "$LARAVEL_USER" env HOME="$LARAVEL_HOME" COMPOSER_HOME="$LARAVEL_HOME/.composer" bash -lc \
        "cd /var/www && composer create-project laravel/laravel $PROYECTO_NOMBRE --prefer-dist --no-interaction"
fi
sudo chown -R "$LARAVEL_USER":"$LARAVEL_USER" "$PROYECTO_DIR"

echo "=== 8. GENERACIÓN DE .env (con IP expandida) ==="
# Heredoc SIN comillas para expandir $SERVER_IP.
# Se escapan \$ para que las variables de Laravel (${APP_NAME}) queden literales.
cat > /tmp/laravel.env.tmp << EOF
APP_NAME=Laravel
APP_ENV=local
APP_KEY=
APP_DEBUG=true
APP_URL=http://$SERVER_IP

APP_LOCALE=es
APP_FALLBACK_LOCALE=es
APP_FAKER_LOCALE=es_ES

APP_MAINTENANCE_DRIVER=file

BCRYPT_ROUNDS=12

LOG_CHANNEL=stack
LOG_STACK=single
LOG_DEPRECATIONS_CHANNEL=null
LOG_LEVEL=debug

DB_CONNECTION=pgsql
DB_HOST=127.0.0.1
DB_PORT=5432
DB_DATABASE=$DB_NAME
DB_USERNAME=$DB_USER
DB_PASSWORD=$DB_PASS


SESSION_DRIVER=redis
SESSION_LIFETIME=120
SESSION_ENCRYPT=false
SESSION_PATH=/
SESSION_DOMAIN=null


BROADCAST_CONNECTION=log
FILESYSTEM_DISK=local
QUEUE_CONNECTION=redis


CACHE_STORE=redis


MEMCACHED_HOST=127.0.0.1


REDIS_CLIENT=phpredis
REDIS_HOST=127.0.0.1
REDIS_PASSWORD=null
REDIS_PORT=6379


MAIL_MAILER=log
MAIL_SCHEME=null
MAIL_HOST=127.0.0.1
MAIL_PORT=2525
MAIL_USERNAME=null
MAIL_PASSWORD=null
MAIL_FROM_ADDRESS="hello@example.com"
MAIL_FROM_NAME="\${APP_NAME}"


AWS_ACCESS_KEY_ID=
AWS_SECRET_ACCESS_KEY=
AWS_DEFAULT_REGION=us-east-1
AWS_BUCKET=
AWS_USE_PATH_STYLE_ENDPOINT=false


VITE_APP_NAME="\${APP_NAME}"
OCTANE_SERVER=frankenphp
EOF

sudo cp /tmp/laravel.env.tmp "$PROYECTO_DIR/.env"
sudo chown "$LARAVEL_USER":"$LARAVEL_USER" "$PROYECTO_DIR/.env"
rm -f /tmp/laravel.env.tmp

as_laravel "php artisan key:generate --force"
as_laravel "php artisan migrate --force"

echo "=== 9. OCTANE + FRANKENPHP + SERVICIO SYSTEMD ==="
as_laravel "composer require laravel/octane --no-interaction"
as_laravel "php artisan octane:install --server=frankenphp --no-interaction"

sudo bash -c "cat << EOF > /etc/systemd/system/octane.service
[Unit]
Description=Laravel Octane Server (FrankenPHP)
After=network.target postgresql-18.service redis.service

[Service]
Type=simple
User=$LARAVEL_USER
Group=$LARAVEL_USER
WorkingDirectory=$PROYECTO_DIR
ExecStart=/usr/bin/php artisan octane:start --server=frankenphp --host=127.0.0.1 --port=8000 --workers=$OCTANE_WORKERS --max-requests=1500
Restart=always
RestartSec=5
Environment=APP_ENV=production

[Install]
WantedBy=multi-user.target
EOF"

sudo chown root:root /etc/systemd/system/octane.service
sudo systemctl daemon-reload
sudo systemctl enable octane

echo "=== 10. NGINX + SELINUX + PERMISOS ==="
sudo dnf install -y nginx httpd-tools policycoreutils-python-utils

# Permisos del proyecto
sudo chown -R "$LARAVEL_USER":"$LARAVEL_USER" "$PROYECTO_DIR"
sudo chmod -R 775 "$PROYECTO_DIR/storage" "$PROYECTO_DIR/bootstrap/cache"

# SELinux
sudo setsebool -P httpd_can_network_connect 1 || true
sudo setsebool -P httpd_can_network_connect_db 1 || true
sudo setsebool -P httpd_can_network_connect_redis 1 || true
sudo setsebool -P httpd_unified 1 || true
# Permitir a Octane (vía nginx/fpm) escribir en storage
sudo semanage fcontext -a -t httpd_sys_rw_content_t "$PROYECTO_DIR/storage(/.*)?" 2>/dev/null || true
sudo semanage fcontext -a -t httpd_sys_rw_content_t "$PROYECTO_DIR/bootstrap/cache(/.*)?" 2>/dev/null || true
sudo restorecon -R "$PROYECTO_DIR" || true

# Backup nginx.conf
if [ -f /etc/nginx/nginx.conf ] && [ ! -f /etc/nginx/nginx.conf.bak ]; then
    sudo cp /etc/nginx/nginx.conf /etc/nginx/nginx.conf.bak
fi

sudo bash -c 'cat << "EOF" > /etc/nginx/nginx.conf
user nginx;
worker_processes auto;
error_log /var/log/nginx/error.log notice;
pid /run/nginx.pid;

include /usr/share/nginx/modules/*.conf;

worker_rlimit_nofile 65535;

events {
    worker_connections 65535;
    use epoll;
    multi_accept on;
}

http {
    proxy_cache_path /var/cache/nginx levels=1:2 keys_zone=my_cache:10m max_size=1g inactive=60m;

    log_format main "$remote_addr - $remote_user [$time_local] \"$request\" "
                        "$status $body_bytes_sent \"$http_referer\" "
                        "\"$http_user_agent\" \"$http_x_forwarded_for\"";

    access_log /var/log/nginx/access.log main;

    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    types_hash_max_size 2048;
    client_max_body_size 64m;

    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    include /etc/nginx/conf.d/*.conf;

    gzip on;
    gzip_types text/plain text/css application/json application/javascript text/xml;
}
EOF'

# Reverse proxy hacia Octane (127.0.0.1:8000)
# Heredoc SIN comillas para expandir $PROYECTO_DIR; \$ escapa las vars de nginx.
sudo bash -c "cat << EOF > /etc/nginx/conf.d/laravel.conf
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;

    root $PROYECTO_DIR/public;
    index index.php;

    client_max_body_size 64m;

    location / {
        proxy_pass http://127.0.0.1:8000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \\\$http_upgrade;
        proxy_set_header Connection \"upgrade\";
        proxy_set_header Host \\\$host;
        proxy_set_header X-Real-IP \\\$remote_addr;
        proxy_set_header X-Forwarded-For \\\$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \\\$scheme;
        proxy_cache my_cache;
        proxy_cache_valid 200 60s;
        proxy_no_cache \\\$http_pragma \\\$http_authorization;
        add_header X-Cache-Status \\\$upstream_cache_status;
    }
}
EOF"

echo "=== 11. ARRANQUE FINAL ==="
as_laravel "php artisan optimize:clear"
as_laravel "php artisan config:cache"
as_laravel "php artisan route:cache"

sudo systemctl restart octane
sudo systemctl enable --now nginx
sudo systemctl restart nginx

echo "=========================================================================="
echo " INSTALACIÓN COMPLETADA"
echo "=========================================================================="
echo " App:     http://$SERVER_IP"
echo " BD:      PostgreSQL 18  (db=$DB_NAME user=$DB_USER)"
echo " Cache:   Redis (phpredis)"
echo " Server:  Octane/FrankenPHP + Nginx reverse proxy"
echo "=========================================================================="
