#!/bin/bash
set -e


# ==============================================================================
# CONFIGURACIÓN DOMINIO + CERTIFICADO CLOUDFLARE
# ==============================================================================


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


    # Protocolos y Cifrados recomendados
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;


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


echo "=========================================================================="
echo " ¡PROCESO COMPLETADO CON ÉXITO!"
echo "=========================================================================="
echo " Dominio: https://$DOMAIN_NAME"
echo " Configuración activa en: /etc/nginx/conf.d/${DOMAIN_NAME}.conf"
echo "=========================================================================="~
