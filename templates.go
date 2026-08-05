package main

// tplLsetupConf es el template autogenerado la primera vez.
// El usuario lo rellena y vuelve a ejecutar: ./lsetup setup --config=./lsetup.conf
const tplLsetupConf = `# Configuración lsetup — rellenar y volver a ejecutar:
#   ./lsetup setup --config=./lsetup.conf
# Líneas con # son comentarios. NO commitear este archivo (contiene secrets).

# Nombre proyecto (directorio /var/www/<project>). Default "laravel1".
project=laravel1

# Base de datos PostgreSQL. Solo [A-Za-z_][A-Za-z0-9_]* (anti-inyección).
db_name=
db_user=

# Password DB — UNA de las dos (al menos una requerida):
#   db_pass=secreto           (texto plano embebido aquí)
#   db_pass_file=/ruta/archivo (externo, chmod 600 recommended)
# Si ambas presentes, gana db_pass_file (defense-in-depth).
db_pass=
db_pass_file=
`

// tplEnv es el .env del proyecto Laravel. Equivalente a setup.sh:335-406.
// Expansiones: %s en orden = SERVER_IP, DB_NAME, DB_USER, DB_PASS.
// Las variables de Laravel (${APP_NAME}) quedan literales: backticks Go no expanden $.
// En el script bash se usaba \$ para escaparlas; en Go backticks no es necesario.
const tplEnv = `APP_NAME=Laravel
APP_ENV=local
APP_KEY=
APP_DEBUG=true
APP_URL=http://%s

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
DB_DATABASE=%s
DB_USERNAME=%s
DB_PASSWORD=%s


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
MAIL_FROM_NAME="${APP_NAME}"


AWS_ACCESS_KEY_ID=
AWS_SECRET_ACCESS_KEY=
AWS_DEFAULT_REGION=us-east-1
AWS_BUCKET=
AWS_USE_PATH_STYLE_ENDPOINT=false


VITE_APP_NAME="${APP_NAME}"
OCTANE_SERVER=frankenphp
`

// tplOctaneService es el unit de systemd para Octane.
// Equivalente a setup.sh:419-436. Expansiones: %s en orden =
// LARAVEL_USER, LARAVEL_USER, PROYECTO_DIR, LARAVEL_USER, LARAVEL_USER,
// PROYECTO_DIR, OCTANE_WORKERS.
const tplOctaneService = `[Unit]
Description=Laravel Octane Server (FrankenPHP)
After=network.target postgresql-18.service redis.service

[Service]
Type=simple
User=%s
Group=%s
WorkingDirectory=%s
ExecStart=/usr/bin/php artisan octane:start --server=frankenphp --host=127.0.0.1 --port=8000 --workers=%d --max-requests=1500
Restart=always
RestartSec=5
Environment=APP_ENV=production

[Install]
WantedBy=multi-user.target
`

// tplNginxConf es el /etc/nginx/nginx.conf. Equivalente a setup.sh:464-504.
// Heredoc CON comillas en bash (literal), todo crudo en Go. Sin expansiones.
const tplNginxConf = `user nginx;
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
`

// tplLaravelVhost es el /etc/nginx/conf.d/laravel.conf (reverse proxy Octane).
// Equivalente a setup.sh:508-534. Expansiones: %s = PROYECTO_DIR.
// Las vars de nginx ($host, $remote_addr, etc.) quedan literales: backticks Go.
// En el script bash se escapaban con \$ para evitar expansión de bash.
const tplLaravelVhost = `server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;

    root %s/public;
    index index.php;

    client_max_body_size 64m;

    location / {
        proxy_pass http://127.0.0.1:8000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_cache my_cache;
        proxy_cache_valid 200 60s;
        proxy_no_cache $http_pragma $http_authorization;
        add_header X-Cache-Status $upstream_cache_status;
    }
}
`

// tplLimitsAppend es el bloque añadido a /etc/security/limits.conf (setup.sh:162-165).
const tplLimitsAppend = `* soft nofile 65535
* hard nofile 65535
`

// tplSysctlAppend es la línea añadida a /etc/sysctl.conf (setup.sh:167-169).
const tplSysctlAppend = `net.core.somaxconn = 65535
`

// tplRedisAppend es el bloque de tuning añadido a /etc/redis/redis.conf (setup.sh:304-313).
// Expansiones: %d = REDIS_MAXMEMORY (MB), %d = REDIS_IO_THREADS.
const tplRedisAppend = `
# --- Tuning automático (lsetup) ---
maxmemory %dmb
maxmemory-policy allkeys-lru
io-threads %d
io-threads-do-reads yes
tcp-backlog 511
tcp-keepalive 300
timeout 0
`
