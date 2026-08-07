#!/bin/bash
set -e

# ==============================================================================
# LSETUP - Dominio Cloudflare para Ubuntu Server 26.04
# Rellena estas variables antes de ejecutar el script.
# ==============================================================================

DOMAIN_NAME="syslab.win"
PROYECTO_DIR="/var/www/laravel"
LARAVEL_USER="laravel"

CLOUDFLARE_CERT="-----BEGIN CERTIFICATE-----
MIIEoDCCA4igAwIBAgIUYYQJmum4r3HBULXxBMcDOKgzfqMwDQYJKoZIhvcNAQEL
BQAwgYsxCzAJBgNVBAYTAlVTMRkwFwYDVQQKExBDbG91ZEZsYXJlLCBJbmMuMTQw
MgYDVQQLEytDbG91ZEZsYXJlIE9yaWdpbiBTU0wgQ2VydGlmaWNhdGUgQXV0aG9y
aXR5MRYwFAYDVQQHEw1TYW4gRnJhbmNpc2NvMRMwEQYDVQQIEwpDYWxpZm9ybmlh
MB4XDTI2MDgwNTE1MTUwMFoXDTQxMDgwMTE1MTUwMFowYjEZMBcGA1UEChMQQ2xv
dWRGbGFyZSwgSW5jLjEdMBsGA1UECxMUQ2xvdWRGbGFyZSBPcmlnaW4gQ0ExJjAk
BgNVBAMTHUNsb3VkRmxhcmUgT3JpZ2luIENlcnRpZmljYXRlMIIBIjANBgkqhkiG
9w0BAQEFAAOCAQ8AMIIBCgKCAQEA39AaHStPJ8oLhT+L2iS0QUZPy0HXYyCi+Qio
5YCbpaIIksQXAjhcZA2JIayhcTsymJrcIW9sKMrxxfR1aDudv1u9Y+qcdHJN4PfJ
oQufwQMPpWnexKNi0ty9aBzS7GgA53+jDY2ZR2GMbvB0yfPfRFsEpNw4RqxpKjrA
BV5YutlxCP24JPWIfdkIR7e9TG0AdQMHgoyB3klw/SoRBMrQVX7enVqST63JRECx
2d8EToBBM5ZXBm0ijvGK1rW5VmS5d10ekYHmvR2eGqRqrGmv3aVr5PlcXkw9KohE
2EYs8kmTiso9G2kUpd/9M8RagWQNPTrIA+/L88mJpli5ru1LZQIDAQABo4IBIjCC
AR4wDgYDVR0PAQH/BAQDAgWgMB0GA1UdJQQWMBQGCCsGAQUFBwMCBggrBgEFBQcD
ATAMBgNVHRMBAf8EAjAAMB0GA1UdDgQWBBQgoWBu2pSMIledklmdhNRTB+cYsDAf
BgNVHSMEGDAWgBQk6FNXXXw0QIep65TbuuEWePwppDBABggrBgEFBQcBAQQ0MDIw
MAYIKwYBBQUHMAGGJGh0dHA6Ly9vY3NwLmNsb3VkZmxhcmUuY29tL29yaWdpbl9j
YTAjBgNVHREEHDAaggwqLnN5c2xhYi53aW6CCnN5c2xhYi53aW4wOAYDVR0fBDEw
LzAtoCugKYYnaHR0cDovL2NybC5jbG91ZGZsYXJlLmNvbS9vcmlnaW5fY2EuY3Js
MA0GCSqGSIb3DQEBCwUAA4IBAQBjTJqFN3uROhX87dIMiNZLAOHpt1GVoPf5OisE
TsBrZKcSXiuIGfl0GZV29p3ugGXNpEZF0+aTB98sr+4HdV36UuA4ADazZwEq50j1
53B0VLVYB1Qn5dzpW5/4Ur8WKs1ytqFo1owqSvrYEd2hICzRECfbXVLpZZq79835
nR1SYjqQB6JdPkwU12gs0yhDYWUx1zdBvmFk8hPUGb1ou193oB1YLcItlwZ3Xunw
803f8AVgjwF9JrYWaxuThM7if1PRAQN0VDFFWO+bIcq9PIPjlrAE32gVnjWEnFx0
qa8G1L5/IoshlRsb3S+PtOSL8X1sfmIge0fT3xga2rbfUvt/
-----END CERTIFICATE-----"

CLOUDFLARE_KEY="-----BEGIN PRIVATE KEY-----
MIIEvgIBADANBgkqhkiG9w0BAQEFAASCBKgwggSkAgEAAoIBAQDf0BodK08nyguF
P4vaJLRBRk/LQddjIKL5CKjlgJulogiSxBcCOFxkDYkhrKFxOzKYmtwhb2woyvHF
9HVoO52/W71j6px0ck3g98mhC5/BAw+lad7Eo2LS3L1oHNLsaADnf6MNjZlHYYxu
8HTJ899EWwSk3DhGrGkqOsAFXli62XEI/bgk9Yh92QhHt71MbQB1AweCjIHeSXD9
KhEEytBVft6dWpJPrclEQLHZ3wROgEEzllcGbSKO8YrWtblWZLl3XR6Rgea9HZ4a
pGqsaa/dpWvk+VxeTD0qiETYRizySZOKyj0baRSl3/0zxFqBZA09OsgD78vzyYmm
WLmu7UtlAgMBAAECggEALOn+X5WqIh4//xrARkPg34uMZkn9fxFU2zyDZmEPeyb/
6PIMev/T/KkhuJ4D3O0IC4tiOxx43FvTtonHCOaT0svGfzdc89pfahLXxeeHBO0I
FgYftB7krVOqd+r24gXCDrL0xfrBRIudKsM68K8twjIwxaPC8F3Xkeet0rX7AO3T
Idp5tnTXiJWvJMbeV5uOMSC8EDND0vtmoojILov6VrU2j2EG36Bz5tSfqc4w8oiZ
1l0ubeYgfxq3QqEK0Z3d2xN5FkANWepk/DBIaL1ZA4+IF6jQQkhRbYr10riExsQK
82ZSmiyyeB0vie8mflRuIeF1n2AQ1/M/43Qd6N/CSQKBgQD/4Q2tNkjIDDxfdbZm
ULPYc7/mw8U1sl56lHoDbZBlIXlS0hhwayGj8Cpj8n01BhdfNDOvyWxlRXknAJll
ERAzUlNazz362Zu+wiNpEfpCQKUHkbiTQ9Nm9FOUnZp3LjzGY3QrlsZF311ZPuGi
Jp+uASMCRjjj/ozrUU8AyI/DyQKBgQDf6yuhAS9fVri4A3r6zA4lDqkWUqw4m/Ra
J3i26UF/HgPvWyq6/hCPuBkn9AINFwGgvJhsvAGzOVHhhUam9JcZmoSmRQ7rv4pw
Y2Jy8/ICeW7c79n/Myv1zSolUqFnP3KVwdNHD892c46LlX5G3R3VlNAd0uYIG+57
4AEHZdvAvQKBgQC/ZhqS3C4o5W4rgaOEeQ1t9XcwKHRVrCybyIBUHBqMazOTTfBV
9uzc8gLjbDlX9kx5PFUFQsfAIO10zS/wt4jEuun63VZhU3D6icFvELF/6VcIiGnm
Ti/NrSjv28v1JjLzuuTkzg1VqrTq0ux4HCgJQnRreReJA5lpVBKiZWOUcQKBgQCW
MZEPKtNSuMGoNDVuOicWtjG2lneMdRc+zZEL54OWN1TeXSFZUgdbz1mYUfR6QT9H
SJlY/faJ992zTokofZFIjDuDp3itqsm6Pv+PKY/gFwHE0mE/61wGQLqPVFCNB6Ld
Tqhf1vwKcNJhUEHmWHSliW7bQlYnhEy/7G3kP29aZQKBgH8BT+jQCrcrz01ciZyK
7faWuHsdyaZWSYpRx0rLZs/Zff7QJ9WXSeDRlkqUXhd8Ku294vetRjI6h/aBeTWY
DlmKDbdG3P8Ql3LUrQzrHxFbr8Q+Wk/PAVGmzC2kDugEzGXhSB7uuc47bin52T1n
BL13FJCDz2JOFK2cffr9Xplx
-----END PRIVATE KEY-----"

if [ "$EUID" -ne 0 ]; then
    echo "Ejecuta este script como root o con sudo."
    exit 1
fi

if [ -z "$DOMAIN_NAME" ] || [ "$DOMAIN_NAME" = "tu-dominio.com" ]; then
    echo "Error: configura DOMAIN_NAME al principio del script."
    exit 1
fi

if ! [[ "$DOMAIN_NAME" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]]; then
    echo "Error: DOMAIN_NAME no es valido."
    exit 1
fi

if [[ "$CLOUDFLARE_CERT" != *"-----BEGIN CERTIFICATE-----"* ]] || [[ "$CLOUDFLARE_CERT" != *"-----END CERTIFICATE-----"* ]]; then
    echo "Error: pega el certificado Origin de Cloudflare en CLOUDFLARE_CERT."
    exit 1
fi

if [[ "$CLOUDFLARE_KEY" != *"-----BEGIN"*"PRIVATE KEY-----"* ]] || [[ "$CLOUDFLARE_KEY" != *"-----END"*"PRIVATE KEY-----"* ]]; then
    echo "Error: pega la clave privada de Cloudflare en CLOUDFLARE_KEY."
    exit 1
fi

if [ ! -f "$PROYECTO_DIR/artisan" ]; then
    echo "Error: no se encontro un proyecto Laravel en $PROYECTO_DIR."
    exit 1
fi

if ! id "$LARAVEL_USER" >/dev/null 2>&1; then
    echo "Error: el usuario '$LARAVEL_USER' no existe."
    exit 1
fi

LARAVEL_HOME="$(getent passwd "$LARAVEL_USER" | cut -d: -f6)"
CERT_FILE="/etc/ssl/certs/${DOMAIN_NAME}.pem"
KEY_FILE="/etc/ssl/private/${DOMAIN_NAME}.key"
NGINX_SITE="/etc/nginx/sites-available/${DOMAIN_NAME}"
NGINX_ENABLED="/etc/nginx/sites-enabled/${DOMAIN_NAME}"
LEGACY_NGINX_SITE="/etc/nginx/conf.d/${DOMAIN_NAME}.conf"

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
echo " Configurando dominio Cloudflare: $DOMAIN_NAME"
echo "=========================================================================="

echo "[1/5] Guardando certificado Origin..."
install -d -m 755 /etc/ssl/certs
install -d -m 700 /etc/ssl/private
printf '%s\n' "$CLOUDFLARE_CERT" > "$CERT_FILE"
printf '%s\n' "$CLOUDFLARE_KEY" > "$KEY_FILE"
chmod 644 "$CERT_FILE"
chmod 600 "$KEY_FILE"

echo "[2/5] Sustituyendo la configuracion Nginx heredada..."
# El setup anterior definia proxy_cache my_cache sin declarar esa zona. No se
# usa cache de proxy para Laravel: podria cachear cookies, sesiones o paneles.
if [ -f /etc/nginx/nginx.conf ]; then
    sed -i -E '/^[[:space:]]*proxy_cache[[:space:]]+my_cache;[[:space:]]*$/d' /etc/nginx/nginx.conf

    if ! grep -qE '^[[:space:]]*include /etc/nginx/sites-enabled/\*;' /etc/nginx/nginx.conf; then
        if grep -qE '^[[:space:]]*include /etc/nginx/conf\.d/\*\.conf;' /etc/nginx/nginx.conf; then
            sed -i '/include \/etc\/nginx\/conf\.d\/\*\.conf;/a\    include /etc/nginx/sites-enabled/*;' /etc/nginx/nginx.conf
        else
            echo "Error: nginx.conf no incluye conf.d ni sites-enabled."
            exit 1
        fi
    fi
fi
rm -f "$LEGACY_NGINX_SITE"
rm -f /etc/nginx/conf.d/laravel.conf
rm -f /etc/nginx/sites-enabled/laravel
rm -f /etc/nginx/sites-enabled/default

cat > "$NGINX_SITE" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN_NAME www.$DOMAIN_NAME;

    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name $DOMAIN_NAME www.$DOMAIN_NAME;

    ssl_certificate $CERT_FILE;
    ssl_certificate_key $KEY_FILE;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;

    client_max_body_size 64m;

    location / {
        proxy_pass http://127.0.0.1:8000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    location ~ /\. {
        deny all;
    }
}
EOF

ln -sfn "$NGINX_SITE" "$NGINX_ENABLED"
nginx -t
systemctl reload nginx

echo "[3/5] Actualizando APP_URL y proxies de Laravel..."
set_env_var "APP_URL" "https://${DOMAIN_NAME}" "$PROYECTO_DIR/.env"

TRUST_PATCH="$PROYECTO_DIR/.lsetup-trust-proxies.php"
cat > "$TRUST_PATCH" <<'PHP'
<?php

declare(strict_types=1);

$bootstrap = __DIR__ . '/bootstrap/app.php';
$contents = file_get_contents($bootstrap);

if ($contents === false) {
    throw new RuntimeException('No se pudo leer bootstrap/app.php.');
}

if (str_contains($contents, 'trustProxies')) {
    exit(0);
}

$pattern = '/->withMiddleware\(function \(Middleware \$middleware\)(?:: void)? \{/';
if (preg_match($pattern, $contents, $match, PREG_OFFSET_CAPTURE) === 1) {
    $position = $match[0][1] + strlen($match[0][0]);
    $contents = substr($contents, 0, $position)
        . "\n        \$middleware->trustProxies(at: '*');"
        . substr($contents, $position);
} else {
    $needle = '    ->withExceptions(';
    $position = strpos($contents, $needle);

    if ($position === false) {
        throw new RuntimeException('No se encontro un punto valido para configurar TrustProxies.');
    }

    $middleware = "    ->withMiddleware(function (Middleware \$middleware): void {\n"
        . "        \$middleware->trustProxies(at: '*');\n"
        . "    })\n";
    $contents = substr($contents, 0, $position) . $middleware . substr($contents, $position);
}

if (file_put_contents($bootstrap, $contents) === false) {
    throw new RuntimeException('No se pudo actualizar bootstrap/app.php.');
}
PHP
chown "$LARAVEL_USER:$LARAVEL_USER" "$TRUST_PATCH"
as_laravel "cd '$PROYECTO_DIR' && php .lsetup-trust-proxies.php"
rm -f "$TRUST_PATCH"
chown "$LARAVEL_USER:$LARAVEL_USER" "$PROYECTO_DIR/bootstrap/app.php"

echo "[4/5] Reconstruyendo caches de Laravel..."
as_laravel "cd '$PROYECTO_DIR' && php artisan optimize:clear"
as_laravel "cd '$PROYECTO_DIR' && php artisan config:cache && php artisan route:cache && php artisan view:cache"

echo "[5/5] Reiniciando Octane y verificando servicios..."
systemctl restart octane
systemctl is-active --quiet nginx
systemctl is-active --quiet octane
ss -ltn | grep -q '127.0.0.1:8000'

echo "=========================================================================="
echo " Dominio configurado: https://$DOMAIN_NAME"
echo " Vhost: $NGINX_SITE"
echo "=========================================================================="
