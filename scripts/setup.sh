#!/bin/bash
set -e

# ==============================================================================
# LSETUP - Ubuntu Server 26.04
# Instalador base: Laravel, PostgreSQL, Redis, Octane y Nginx.
# Cambia estas variables antes de ejecutar el script si necesitas otro proyecto.
# ==============================================================================

PROYECTO_NOMBRE="laravel"
LARAVEL_USER="laravel"
LARAVEL_HOME="/home/laravel"
LARAVEL_PASSWORD="laravel"
PROYECTOS_DIR="/var/www"
PROYECTO_DIR="$PROYECTOS_DIR/$PROYECTO_NOMBRE"

DB_NAME="laravel"
DB_USER="laravel"
DB_PASS="laravel"

REDIS_PASSWORD="laravel"
REDIS_MAXMEMORY="2gb"

APP_ENV="production"
APP_DEBUG="false"
APP_LOCALE="es"
OCTANE_HOST="127.0.0.1"
OCTANE_PORT="8000"
OCTANE_WORKERS="6"
OCTANE_MAX_REQUESTS="1500"

if [ "$EUID" -ne 0 ]; then
    echo "Ejecuta este script como root o con sudo."
    exit 1
fi

if ! [[ "$PROYECTO_NOMBRE" =~ ^[A-Za-z0-9_-]+$ ]]; then
    echo "Error: PROYECTO_NOMBRE no es valido."
    exit 1
fi

if ! [[ "$DB_NAME" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || ! [[ "$DB_USER" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
    echo "Error: DB_NAME y DB_USER solo admiten letras, numeros y guion bajo."
    exit 1
fi

if [[ "$REDIS_PASSWORD" =~ [[:space:]\'\"] ]]; then
    echo "Error: REDIS_PASSWORD no puede contener espacios ni comillas."
    exit 1
fi

DB_PASS_SQL="${DB_PASS//\'/\'\'}"
SERVER_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
SERVER_IP="${SERVER_IP:-127.0.0.1}"
APP_URL="http://$SERVER_IP"

as_laravel() {
    runuser -u "$LARAVEL_USER" -- env \
        HOME="$LARAVEL_HOME" \
        COMPOSER_HOME="$LARAVEL_HOME/.composer" \
        bash -lc "$1"
}

set_env_var() {
    local key="$1"
    local value="$2"
    local env_file="$3"
    local temp_file="${env_file}.lsetup"

    grep -v "^${key}=" "$env_file" > "$temp_file" || true
    printf '%s=%s\n' "$key" "$value" >> "$temp_file"
    mv "$temp_file" "$env_file"
    chown "$LARAVEL_USER:$LARAVEL_USER" "$env_file"
    chmod 640 "$env_file"
}

echo "=========================================================================="
echo " LSETUP - Ubuntu Server 26.04"
echo " Proyecto: $PROYECTO_DIR"
echo "=========================================================================="

export DEBIAN_FRONTEND=noninteractive

echo "[1/10] Actualizando Ubuntu e instalando paquetes base..."
apt update
apt upgrade -y
apt install -y \
    ca-certificates curl git gnupg lsb-release nano sudo tar unzip \
    nodejs npm nginx redis-server \
    postgresql-18 postgresql-client-18 \
    php8.5 php8.5-bcmath php8.5-cli php8.5-curl php8.5-fpm php8.5-gd \
    php8.5-intl php8.5-mbstring php8.5-pgsql php8.5-redis \
    php8.5-xml php8.5-zip

echo "[2/10] Instalando Composer..."
if ! command -v composer >/dev/null 2>&1; then
    composer_installer="$(mktemp)"
    curl -fsSL https://getcomposer.org/installer -o "$composer_installer"
    php "$composer_installer" --install-dir=/usr/local/bin --filename=composer --quiet
    rm -f "$composer_installer"
fi

echo "[3/10] Creando el usuario y los directorios de Laravel..."
if ! id "$LARAVEL_USER" >/dev/null 2>&1; then
    useradd --create-home --home-dir "$LARAVEL_HOME" --shell /bin/bash "$LARAVEL_USER"
else
    CURRENT_LARAVEL_HOME="$(getent passwd "$LARAVEL_USER" | cut -d: -f6)"
    if [ "$CURRENT_LARAVEL_HOME" != "$LARAVEL_HOME" ]; then
        if [ -e "$LARAVEL_HOME" ]; then
            echo "Error: no se puede migrar el HOME de $LARAVEL_USER porque $LARAVEL_HOME ya existe."
            exit 1
        fi
        usermod --home "$LARAVEL_HOME" --move-home "$LARAVEL_USER"
    fi
fi
echo "$LARAVEL_USER:$LARAVEL_PASSWORD" | chpasswd
usermod -aG sudo "$LARAVEL_USER"
install -d -o "$LARAVEL_USER" -g "$LARAVEL_USER" -m 755 "$LARAVEL_HOME/.composer"
install -d -o "$LARAVEL_USER" -g "$LARAVEL_USER" -m 755 "$PROYECTOS_DIR"

echo "[4/10] Configurando PostgreSQL 18..."
systemctl enable --now postgresql
sudo -u postgres psql -c "CREATE USER $DB_USER WITH PASSWORD '$DB_PASS_SQL';" || true
sudo -u postgres psql -c "CREATE DATABASE $DB_NAME OWNER $DB_USER;" || true
sudo -u postgres psql -c "ALTER USER $DB_USER WITH PASSWORD '$DB_PASS_SQL';"
sudo -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE $DB_NAME TO $DB_USER;"

echo "[5/10] Configurando Redis..."
if ! grep -q '^# LSETUP Redis$' /etc/redis/redis.conf; then
    cat >> /etc/redis/redis.conf <<EOF

# LSETUP Redis
bind 127.0.0.1 ::1
protected-mode yes
requirepass $REDIS_PASSWORD
maxmemory $REDIS_MAXMEMORY
maxmemory-policy allkeys-lru
EOF
fi
systemctl enable --now redis-server
systemctl restart redis-server

echo "[6/10] Creando Laravel 13..."
if [ ! -f "$PROYECTO_DIR/artisan" ]; then
    install -d -o "$LARAVEL_USER" -g "$LARAVEL_USER" -m 755 "$PROYECTO_DIR"
    as_laravel "composer create-project laravel/laravel:^13.0 '$PROYECTO_DIR' --prefer-dist --no-interaction"
fi
chown -R "$LARAVEL_USER:$LARAVEL_USER" "$PROYECTO_DIR"
chmod -R ug+rwX "$PROYECTO_DIR/storage" "$PROYECTO_DIR/bootstrap/cache"

echo "[7/10] Configurando .env y migrando la base de datos..."
if [ ! -f "$PROYECTO_DIR/.env" ]; then
    cp "$PROYECTO_DIR/.env.example" "$PROYECTO_DIR/.env"
fi
set_env_var "APP_NAME" "Laravel" "$PROYECTO_DIR/.env"
set_env_var "APP_ENV" "$APP_ENV" "$PROYECTO_DIR/.env"
set_env_var "APP_DEBUG" "$APP_DEBUG" "$PROYECTO_DIR/.env"
set_env_var "APP_URL" "$APP_URL" "$PROYECTO_DIR/.env"
set_env_var "APP_LOCALE" "$APP_LOCALE" "$PROYECTO_DIR/.env"
set_env_var "APP_FALLBACK_LOCALE" "$APP_LOCALE" "$PROYECTO_DIR/.env"
set_env_var "APP_FAKER_LOCALE" "es_ES" "$PROYECTO_DIR/.env"
set_env_var "DB_CONNECTION" "pgsql" "$PROYECTO_DIR/.env"
set_env_var "DB_HOST" "127.0.0.1" "$PROYECTO_DIR/.env"
set_env_var "DB_PORT" "5432" "$PROYECTO_DIR/.env"
set_env_var "DB_DATABASE" "$DB_NAME" "$PROYECTO_DIR/.env"
set_env_var "DB_USERNAME" "$DB_USER" "$PROYECTO_DIR/.env"
set_env_var "DB_PASSWORD" "$DB_PASS" "$PROYECTO_DIR/.env"
set_env_var "CACHE_STORE" "redis" "$PROYECTO_DIR/.env"
set_env_var "QUEUE_CONNECTION" "redis" "$PROYECTO_DIR/.env"
set_env_var "SESSION_DRIVER" "redis" "$PROYECTO_DIR/.env"
set_env_var "REDIS_CLIENT" "phpredis" "$PROYECTO_DIR/.env"
set_env_var "REDIS_HOST" "127.0.0.1" "$PROYECTO_DIR/.env"
set_env_var "REDIS_PASSWORD" "$REDIS_PASSWORD" "$PROYECTO_DIR/.env"
set_env_var "REDIS_PORT" "6379" "$PROYECTO_DIR/.env"
set_env_var "OCTANE_SERVER" "frankenphp" "$PROYECTO_DIR/.env"

as_laravel "cd '$PROYECTO_DIR' && php artisan key:generate --force --no-interaction"
as_laravel "cd '$PROYECTO_DIR' && php artisan migrate --force --no-interaction"

echo "[8/10] Instalando Octane con FrankenPHP y compilando assets..."
as_laravel "cd '$PROYECTO_DIR' && composer require laravel/octane --no-interaction --no-progress"
as_laravel "cd '$PROYECTO_DIR' && php artisan octane:install --server=frankenphp --no-interaction"
as_laravel "cd '$PROYECTO_DIR' && npm install && npm run build"

echo "[9/10] Creando el servicio Octane y el proxy Nginx..."
cat > /etc/systemd/system/octane.service <<EOF
[Unit]
Description=Laravel Octane Server (FrankenPHP)
After=network.target postgresql.service redis-server.service

[Service]
Type=simple
User=$LARAVEL_USER
Group=$LARAVEL_USER
WorkingDirectory=$PROYECTO_DIR
ExecStart=/usr/bin/php artisan octane:start --server=frankenphp --host=$OCTANE_HOST --port=$OCTANE_PORT --workers=$OCTANE_WORKERS --max-requests=$OCTANE_MAX_REQUESTS
Restart=always
RestartSec=5
Environment=APP_ENV=$APP_ENV
Environment=HOME=$LARAVEL_HOME
Environment=COMPOSER_HOME=$LARAVEL_HOME/.composer

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/nginx/sites-available/laravel <<'EOF'
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;

    client_max_body_size 64m;

    location / {
        proxy_pass http://127.0.0.1:8000;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    location ~ /\. {
        deny all;
    }
}
EOF

rm -f /etc/nginx/sites-enabled/default
ln -sfn /etc/nginx/sites-available/laravel /etc/nginx/sites-enabled/laravel
nginx -t
systemctl daemon-reload
systemctl enable --now nginx

echo "[10/10] Generando caches y arrancando servicios..."
as_laravel "cd '$PROYECTO_DIR' && php artisan optimize:clear"
as_laravel "cd '$PROYECTO_DIR' && php artisan config:cache && php artisan route:cache && php artisan view:cache"
systemctl enable --now octane
systemctl restart octane

systemctl is-active --quiet postgresql
systemctl is-active --quiet redis-server
systemctl is-active --quiet nginx
systemctl is-active --quiet octane
ss -ltn | grep -q "127.0.0.1:$OCTANE_PORT"

echo "=========================================================================="
echo " Setup completado"
echo " Proyecto: $PROYECTO_DIR"
echo " URL:      $APP_URL"
echo " Octane:   http://$OCTANE_HOST:$OCTANE_PORT"
echo "=========================================================================="
