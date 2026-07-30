#!/bin/bash
set -e


# ==============================================================================
# CONFIGURACIÓN DOMINIO + CERTIFICADO CLOUDFLARE
# ==============================================================================

# Escribe en /etc/ssl y /etc/nginx: requiere root (los redirects no usan sudo).
if [ "$EUID" -ne 0 ]; then
    echo "Ejecuta este script como root o con sudo."
    exit 1
fi


echo "=========================================================================="
echo " CONFIGURACIÓN DE DOMINIO Y CERTIFICADOS SSL CLOUDFLARE"
echo "=========================================================================="


# 1. Solicitar el nombre del dominio
read -p "Introduce tu nombre de dominio: " DOMAIN_NAME


if [ -z "$DOMAIN_NAME" ]; then
    echo "Error: El dominio no puede estar vacío."
    exit 1
fi


# Directorios de destino para los certificados
sudo mkdir -p /etc/ssl/certs
sudo mkdir -p /etc/ssl/private


CERT_FILE="/etc/ssl/certs/${DOMAIN_NAME}.pem"
KEY_FILE="/etc/ssl/private/${DOMAIN_NAME}.key"


# 2. Captura interactiva del Certificado de Origen
echo ""
echo "--------------------------------------------------------------------------"
echo " 1. Copia y pega el 'Certificado de origen' de Cloudflare."
echo "    (Inicia con -----BEGIN CERTIFICATE-----)"
echo "    Una vez pegado, presiona ENTER si el script no avanza solo."
echo "--------------------------------------------------------------------------"


> "$CERT_FILE"
while IFS= read -r line; do
    echo "$line" >> "$CERT_FILE"
    if [[ "$line" =~ END.*CERTIFICATE ]]; then
        break
    fi
done


# 3. Captura interactiva de la Clave Privada
echo ""
echo "--------------------------------------------------------------------------"
echo " 2. Copia y pega la 'Clave privada' de Cloudflare."
echo "    (Inicia con -----BEGIN PRIVATE KEY-----)"
echo "    Una vez pegada, presiona ENTER si el script no avanza solo."
echo "--------------------------------------------------------------------------"


> "$KEY_FILE"
while IFS= read -r line; do
    echo "$line" >> "$KEY_FILE"
    if [[ "$line" =~ END.*KEY ]]; then
        break
    fi
done


# Asignar permisos de seguridad estrictos
sudo chmod 644 "$CERT_FILE"
sudo chmod 600 "$KEY_FILE"


echo ""
echo "=== CERTIFICADOS GUARDADOS CORRECTAMENTE ==="
echo " Certificado: $CERT_FILE"
echo " Clave Privada: $KEY_FILE"


# 4. Creando la configuración de Nginx 
echo ""
echo "=== CONFIGURANDO VHOST DE NGINX EN /etc/nginx/conf.d/${DOMAIN_NAME}.conf ==="


sudo tee "/etc/nginx/conf.d/${DOMAIN_NAME}.conf" > /dev/null << EOF
# Redirección forzada de HTTP (80) a HTTPS (443)
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN_NAME} www.${DOMAIN_NAME};


    return 301 https://\$host\$request_uri;
}


# Servidor HTTPS conectado a Laravel Octane
server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name ${DOMAIN_NAME} www.${DOMAIN_NAME};


    # Certificado y Clave Privada de Cloudflare
    ssl_certificate $CERT_FILE;
    ssl_certificate_key $KEY_FILE;


    # Protocolos y Cifrados modernos (Mozilla intermediate 2024, sin MD5/CBC).
    # alignados con conf.d/00-tls-modern.conf generado por secure.sh.
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256;
    ssl_prefer_server_ciphers off;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;

    # HSTS: fuerza HTTPS en el navegador durante 1 año (subdominios incluidos).
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;


    location / {
        proxy_pass http://127.0.0.1:8000;


        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";


        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;


        proxy_cache my_cache;
        proxy_cache_valid 200 60s;
        proxy_ignore_headers Set-Cookie Cache-Control Expires;
        proxy_cache_min_uses 1;
        proxy_cache_bypass \$http_pragma \$http_authorization;
        proxy_no_cache \$http_pragma \$http_authorization;
        add_header X-Cache-Status \$upstream_cache_status;
    }
}
EOF


# 5. Abrir puerto 443 en el cortafuegos
echo "Asegurando el puerto 443 (HTTPS) en el firewall..."
sudo firewall-cmd --permanent --add-service=https || true
sudo firewall-cmd --reload || true


# 6. Validar y reiniciar Nginx
echo "Probando sintaxis de la configuración de Nginx..."
sudo nginx -t


echo "Recargando Nginx..."
sudo systemctl reload nginx


# 7. Actualizar APP_URL en .env del proyecto Laravel (HTTPS)
# Livewire/Filament generan los endpoints de POST (login, forms) con APP_URL.
# Si APP_URL sigue apuntando a http://<SERVER_IP> (lo que deja setup.sh), el
# login del panel hace POST a http:// desde una página servida por HTTPS ->
# mixed content -> el navegador bloquea la peticion -> submit "no hace nada".
# awk (no sed) para reescribir el valor: consistente con login.sh y evita
# Problemas de escaping si el dominio trae caracteres especiales.
echo ""
echo "=== ACTUALIZANDO APP_URL EN .env (HTTPS) ==="
read -p "Ruta del proyecto Laravel [/var/www/laravel1]: " PROYECTO_DIR
PROYECTO_DIR=${PROYECTO_DIR:-/var/www/laravel1}

if [ -f "$PROYECTO_DIR/.env" ]; then
    NEW_URL="https://${DOMAIN_NAME}"
    sudo cp "$PROYECTO_DIR/.env" "$PROYECTO_DIR/.env.bak.$(date +%s)"
    sudo awk -v url="$NEW_URL" '
        /^APP_URL=/ { print "APP_URL="url; found=1; next }
        { print }
        END { if (!found) print "APP_URL="url }
    ' "$PROYECTO_DIR/.env" | sudo tee "$PROYECTO_DIR/.env.new" > /dev/null
    sudo mv "$PROYECTO_DIR/.env.new" "$PROYECTO_DIR/.env"
    sudo chown laravel:laravel "$PROYECTO_DIR/.env"
    sudo chmod 640 "$PROYECTO_DIR/.env"
    echo "  .env: APP_URL=$NEW_URL"

    # Parchear TrustProxies + forceScheme('https') si no están ya (idempotente).
    # Sin esto, Livewire/Filament ignoran X-Forwarded-Proto de Nginx y generan
    # endpoints http:// desde Octane => el navegador bloquea el POST del login
    # del panel ("botón no hace nada"). Patrón heredoc PHP, no sed.
    if id laravel &>/dev/null; then
        LARAVEL_HOME=$(getent passwd laravel | cut -d: -f6)
        sudo -u laravel -- bash -c "cat > '$PROYECTO_DIR/patch_trust.php' << 'PHP'
<?php
\$bf = __DIR__.'/bootstrap/app.php';
\$bc = file_get_contents(\$bf);
if (strpos(\$bc, 'trustProxies') === false) {
    \$anchor = '->withMiddleware(function (Middleware \$middleware) {';
    \$pos = strpos(\$bc, \$anchor);
    if (\$pos !== false) {
        \$insertAt = \$pos + strlen(\$anchor);
        \$bc = substr(\$bc, 0, \$insertAt)
            . \"\\n        \\\$middleware->trustProxies(at: '*');\"
            . substr(\$bc, \$insertAt);
        file_put_contents(\$bf, \$bc);
        echo \"bootstrap/app.php: trustProxies agregado\\n\";
    } else {
        echo \"bootstrap/app.php: ancla withMiddleware no encontrada\\n\";
    }
} else { echo \"bootstrap/app.php: trustProxies ya presente\\n\"; }

\$af = __DIR__.'/app/Providers/AppServiceProvider.php';
\$ac = file_get_contents(\$af);
if (strpos(\$ac, 'forceScheme') === false) {
    \$ac = str_replace(
        'use Illuminate\\\\Support\\\\ServiceProvider;',
        \"use Illuminate\\\\Support\\\\ServiceProvider;\\nuse Illuminate\\\\Support\\\\Facades\\\\URL;\",
        \$ac
    );
    \$bp = strpos(\$ac, 'public function boot');
    if (\$bp !== false) {
        \$bp2 = strpos(\$ac, '{', \$bp);
        if (\$bp2 !== false) {
            \$ia = \$bp2 + 1;
            \$ac = substr(\$ac, 0, \$ia)
                . \"\\n        if (\\\$this->app->environment('production')) {\\n            URL::forceScheme('https');\\n        }\"
                . substr(\$ac, \$ia);
            file_put_contents(\$af, \$ac);
            echo \"AppServiceProvider: forceScheme agregado\\n\";
        }
    }
} else { echo \"AppServiceProvider: forceScheme ya presente\\n\"; }
PHP"
        sudo chown -R laravel:laravel "$PROYECTO_DIR/bootstrap" "$PROYECTO_DIR/app/Providers" 2>/dev/null || true

        sudo runuser -u laravel -- env HOME="$LARAVEL_HOME" COMPOSER_HOME="$LARAVEL_HOME/.composer" \
            bash -lc "cd '$PROYECTO_DIR' && php patch_trust.php && rm -f patch_trust.php && APP_ENV=production /usr/bin/php artisan optimize:clear && APP_ENV=production /usr/bin/php artisan config:cache && APP_ENV=production /usr/bin/php artisan route:cache" 2>&1 || true
        sudo systemctl restart octane 2>/dev/null || true
        echo "  TrustProxies aplicado y config re-cacheada (APP_ENV=production) y Octane reiniciado."
    else
        echo "  Aviso: usuario 'laravel' no existe; APP_URL actualizado pero Octane NO reiniciado."
    fi
else
    echo "  Aviso: no se encontro $PROYECTO_DIR/.env"
    echo "  Actualiza APP_URL manualmente a https://${DOMAIN_NAME} y re-cachea config."
fi


echo "=========================================================================="
echo " ¡PROCESO COMPLETADO CON ÉXITO!"
echo "=========================================================================="
echo " Dominio: https://$DOMAIN_NAME"
echo " Configuración activa en: /etc/nginx/conf.d/${DOMAIN_NAME}.conf"
echo "=========================================================================="
