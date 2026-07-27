#!/bin/bash
set -e


# ==============================================================================
# INSTALADOR LARAVEL 13 + PHP 8.4 + PostgreSQL 18 + Redis 7 + Filament 4
# Octane/Swoole + Nginx + systemd + SELinux + Firewall
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
prompt_var      DB_NAME         "Nombre base de datos PostgreSQL"              "laravel"
prompt_var      DB_USER         "Usuario base de datos"                        "laravel"
prompt_var      DB_PASS         "Contraseña base de datos"                     "laravel" secret
prompt_var      ADMIN_NAME      "Nombre usuario admin del panel"               "Admin"
prompt_required ADMIN_EMAIL     "Correo del admin del panel (obligatorio)"
prompt_required ADMIN_PASS      "Contraseña del admin del panel (obligatoria)" secret
echo "======================================================================="


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


# --- helpers -----------------------------------------------------------------
# Ejecuta un comando como usuario laravel dentro del directorio del proyecto.
# HOME apunta al hogar real del usuario (no al proyecto) para que el caché de
# Composer viva en ~/.composer y no dentro del proyecto.
as_laravel() {
    sudo -u "$LARAVEL_USER" env HOME="$LARAVEL_HOME" COMPOSER_HOME="$LARAVEL_HOME/.composer" bash -lc "cd '$PROYECTO_DIR' && $*"
}


echo "=== 1. PREPARACIÓN DEL SISTEMA Y REPOS ==="
sudo dnf install -y epel-release dnf-plugins-core
sudo dnf config-manager --set-enabled crb || true
sudo dnf install -y --nogpgcheck https://rpms.remirepo.net/enterprise/remi-release-10.rpm || true
curl -fsSL https://rpm.nodesource.com/setup_22.x | sudo bash -
sudo dnf install -y nodejs npm
sudo dnf install -y git


git config --global user.name "miguel"
git config --global user.email "miguel2006ngl@gmail.com"


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
# 8000 interno (Octane) no necesita exponerse: Nginx hace de reverse proxy.
sudo firewall-cmd --reload


echo "=== 3. POSTGRESQL 18 ==="
sudo dnf install -y --nogpgcheck https://download.postgresql.org/pub/repos/yum/reporpms/EL-10-x86_64/pgdg-redhat-repo-latest.noarch.rpm || true
sudo dnf -qy module disable postgresql || true
sudo dnf install -y postgresql18-server


if [ ! -f /var/lib/pgsql/18/data/PG_VERSION ]; then
    sudo /usr/pgsql-18/bin/postgresql-18-setup initdb
fi


# Autenticación por contraseña (scram-sha-256) para conexiones locales TCP
PG_HBA=/var/lib/pgsql/18/data/pg_hba.conf
sudo sed -i 's/^host\s\+all\s\+all\s\+127.0.0.1\/32.*/host    all    all    127.0.0.1\/32    scram-sha-256/' "$PG_HBA"
sudo sed -i 's/^host\s\+all\s\+all\s\+::1\/128.*/host    all    all    ::1\/128         scram-sha-256/' "$PG_HBA"


sudo systemctl enable --now postgresql-18


sudo -u postgres psql -c "CREATE USER $DB_USER WITH PASSWORD '$DB_PASS';" || true
sudo -u postgres psql -c "CREATE DATABASE $DB_NAME OWNER $DB_USER;" || true
sudo -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE $DB_NAME TO $DB_USER;" || true


echo "=== 4. USUARIO LARAVEL (no-root) ==="
# Usuario con hogar real para caché de Composer (separado del proyecto).
sudo useradd -m -s /bin/bash -d "$LARAVEL_HOME" "$LARAVEL_USER" 2>/dev/null || true
sudo mkdir -p "$LARAVEL_HOME"
sudo chown -R "$LARAVEL_USER":"$LARAVEL_USER" "$LARAVEL_HOME"


sudo mkdir -p /var/www
sudo chown "$LARAVEL_USER":"$LARAVEL_USER" /var/www


echo "=== 5. PHP 8.4 + COMPOSER ==="
sudo dnf module reset php -y || true
sudo dnf module enable php:remi-8.4 -y || true


sudo dnf install -y \
    php php-cli php-fpm php-pgsql php-zip php-xml php-curl php-intl \
    php-bcmath php-mbstring php-posix php-pcntl php-gd php-opcache \
    php-pecl-swoole php-pecl-redis


# Composer global en /usr/local/bin (no se ejecuta como root más adelante)
if [ ! -x /usr/local/bin/composer ]; then
    curl -sS https://getcomposer.org/installer | sudo php -- --install-dir=/usr/local/bin --filename=composer
    sudo chmod +x /usr/local/bin/composer
fi
# Asegurar que el binario es accesible para el usuario laravel
sudo ln -sf /usr/local/bin/composer /usr/bin/composer || true


echo "=== 6. REDIS (phpredis) ==="
sudo dnf module reset redis -y || true
sudo dnf module enable redis:remi-7.2 -y || true
sudo dnf install -y redis


sudo systemctl enable --now redis


if ! grep -q "^maxmemory 512mb" /etc/redis/redis.conf 2>/dev/null; then
    sudo bash -c 'cat << "EOF" >> /etc/redis/redis.conf
maxmemory 512mb
maxmemory-policy allkeys-lru
EOF'
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
OCTANE_SERVER=swoole
EOF


sudo cp /tmp/laravel.env.tmp "$PROYECTO_DIR/.env"
sudo chown "$LARAVEL_USER":"$LARAVEL_USER" "$PROYECTO_DIR/.env"
rm -f /tmp/laravel.env.tmp


as_laravel "php artisan key:generate --force"
as_laravel "php artisan migrate --force"


echo "=== 9. FILAMENT 4 + SOCIALITE + SHIELD + SPATIE MEDIA LIBRARY ==="
as_laravel "composer require laravel/socialite --no-interaction"


# Filament 4
as_laravel "composer require filament/filament:\"^4.0\" -W --no-interaction"
as_laravel "php artisan filament:install --panels --no-interaction"


# Filament Shield
as_laravel "composer require bezhansalleh/filament-shield --no-interaction"
# Filament Shield — el argumento "admin" (id del panel) es obligatorio:
# sin él lanza NonInteractiveValidationException en modo --no-interaction.
as_laravel "php artisan shield:install admin --no-interaction"
# spatie/laravel-permission: publicar migraciones y migrar ANTES de generate,
# si no, shield:generate falla con "relation permissions does not exist".
as_laravel "php artisan vendor:publish --provider=\"Spatie\Permission\PermissionServiceProvider\" --tag=\"permission-migrations\" --force"
as_laravel "php artisan migrate --force"
as_laravel "php artisan shield:generate --all --panel=admin --no-interaction"


# Trait HasRoles en el modelo User — obligatorio para assignRole() (spatie).
# Sin esto el tinker de abajo falla con BadMethodCallException.
# Se parchea con PHP (no sed): comportamiento idéntico en cualquier sed evita
# problemas de escaping de backslashes.
sudo -u "$LARAVEL_USER" bash -c "cat > '$PROYECTO_DIR/patch_user.php' << 'PHP'
<?php
\$f = __DIR__ . '/app/Models/User.php';
\$c = file_get_contents(\$f);
if (strpos(\$c, 'HasRoles') === false) {
    \$c = str_replace(
        'use Illuminate\\\\Notifications\\\\Notifiable;',
        \"use Illuminate\\\\Notifications\\\\Notifiable;\nuse Spatie\\\\Permission\\\\Traits\\\\HasRoles;\",
        \$c
    );
    \$c = str_replace(
        'use HasFactory, Notifiable;',
        'use HasFactory, Notifiable, HasRoles;',
        \$c
    );
    file_put_contents(\$f, \$c);
    echo \"User.php parcheado con HasRoles\n\";
} else {
    echo \"User.php ya tiene HasRoles\n\";
}
PHP"
as_laravel "php patch_user.php && rm -f patch_user.php"


# Usuario admin del panel (credenciales pedidas al inicio).
# Se pasan por env para no romper el quoting de tinker.
as_laravel "export ADMIN_NAME='$ADMIN_NAME' ADMIN_EMAIL='$ADMIN_EMAIL' ADMIN_PASS='$ADMIN_PASS'; \
    php artisan tinker --execute='
\$u = \App\Models\User::firstOrCreate(
    [\"email\" => env(\"ADMIN_EMAIL\")],
    [\"name\" => env(\"ADMIN_NAME\"), \"password\" => bcrypt(env(\"ADMIN_PASS\"))]
);
\$u->assignRole(\"super_admin\");
echo \"Admin: {\$u->email}\" . PHP_EOL;'"


# Spatie Media Library (núcleo + plugin Filament)
as_laravel "composer require spatie/laravel-medialibrary --no-interaction"
as_laravel "composer require filament/spatie-laravel-media-library-plugin:\"^4.0\" -W --no-interaction"
as_laravel "php artisan vendor:publish --provider=\"Spatie\MediaLibrary\MediaLibraryServiceProvider\" --tag=\"medialibrary-migrations\" --force"


# Debugbar solo dev
as_laravel "composer require barryvdh/laravel-debugbar --dev --no-interaction"


as_laravel "php artisan storage:link --force || true"
as_laravel "php artisan migrate --force"


echo "=== 10. OCTANE + SWOOLE + SERVICIO SYSTEMD ==="
as_laravel "composer require laravel/octane --no-interaction"
as_laravel "php artisan octane:install --server=swoole --no-interaction"


sudo bash -c "cat << EOF > /etc/systemd/system/octane.service
[Unit]
Description=Laravel Octane Server (Swoole)
After=network.target postgresql-18.service redis.service


[Service]
Type=simple
User=$LARAVEL_USER
Group=$LARAVEL_USER
WorkingDirectory=$PROYECTO_DIR
ExecStart=/usr/bin/php artisan octane:start --server=swoole --host=127.0.0.1 --port=8000 --workers=2 --task-workers=4 --max-requests=1500
Restart=always
RestartSec=5
Environment=APP_ENV=production


[Install]
WantedBy=multi-user.target
EOF"


sudo chown root:root /etc/systemd/system/octane.service
sudo systemctl daemon-reload
sudo systemctl enable octane


echo "=== 11. NGINX + SELINUX + PERMISOS ==="
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


echo "=== 12. ARRANQUE FINAL ==="
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
echo " Admin:   http://$SERVER_IP/admin"
echo " Login:   $ADMIN_EMAIL  (contraseña: la introducida al inicio)"
echo " BD:      PostgreSQL 18  (db=$DB_NAME user=$DB_USER)"
echo " Cache:   Redis (phpredis)"
echo " Server:  Octane/Swoole + Nginx reverse proxy"
echo " Panel:   Filament 4 + Shield + Spatie Media Library"
echo "=========================================================================="
