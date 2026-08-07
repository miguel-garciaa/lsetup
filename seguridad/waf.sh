#!/bin/bash
set -e

# Parametro: develop, production o --off
MODO="${1:-}"

NGINX_WAF_CONF="/etc/nginx/conf.d/00-lsetup-waf.conf"
MODSEC_CONF="/etc/nginx/modsecurity.conf"
MODSEC_INCLUDES="/etc/nginx/modsecurity_includes.conf"
CRS_SETUP="/etc/modsecurity/crs/crs-setup.conf"
CRS_BEFORE="/etc/modsecurity/crs/REQUEST-900-EXCLUSION-RULES-BEFORE-CRS.conf"
CRS_AFTER="/etc/modsecurity/crs/RESPONSE-999-EXCLUSION-RULES-AFTER-CRS.conf"
CRS_RULES="/usr/share/modsecurity-crs/rules"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="/root/lsetup-waf-$TIMESTAMP"

if [ "$EUID" -ne 0 ]; then
    echo "Ejecuta este script con sudo."
    exit 1
fi

if ! command -v nginx >/dev/null 2>&1; then
    echo "Nginx no esta instalado."
    exit 1
fi

if [ "$MODO" = "--off" ]; then
    rm -f "$NGINX_WAF_CONF"
    nginx -t
    systemctl reload nginx
    echo "WAF desactivado. Los paquetes y reglas se conservan."
    exit 0
fi

case "$MODO" in
    develop)
        RULE_ENGINE="DetectionOnly"
        ;;
    production)
        RULE_ENGINE="On"
        read -r -p "Escribe WAF-ON para activar el bloqueo en produccion: " CONFIRMACION
        if [ "$CONFIRMACION" != "WAF-ON" ]; then
            echo "Cancelado."
            exit 1
        fi
        ;;
    *)
        echo "Uso: sudo bash seguridad/waf.sh [develop|production|--off]"
        exit 1
        ;;
esac

apt-get update
apt-get install -y libnginx-mod-http-modsecurity modsecurity-crs

if [ ! -f "$MODSEC_CONF" ] || [ ! -f "$CRS_SETUP" ] || [ ! -d "$CRS_RULES" ]; then
    echo "No se encontraron la configuracion de ModSecurity o las reglas CRS."
    exit 1
fi

mkdir -p "$BACKUP_DIR"
[ -f "$NGINX_WAF_CONF" ] && cp -a "$NGINX_WAF_CONF" "$BACKUP_DIR/00-lsetup-waf.conf"
[ -f "$MODSEC_CONF" ] && cp -a "$MODSEC_CONF" "$BACKUP_DIR/modsecurity.conf"
[ -f "$MODSEC_INCLUDES" ] && cp -a "$MODSEC_INCLUDES" "$BACKUP_DIR/modsecurity_includes.conf"

if grep -qE '^[[:space:]]*SecRuleEngine[[:space:]]+' "$MODSEC_CONF"; then
    sed -i -E "s|^[[:space:]]*SecRuleEngine[[:space:]]+.*|SecRuleEngine $RULE_ENGINE|" "$MODSEC_CONF"
else
    printf '\nSecRuleEngine %s\n' "$RULE_ENGINE" >> "$MODSEC_CONF"
fi

cat > "$MODSEC_INCLUDES" <<EOF
Include $MODSEC_CONF
Include $CRS_SETUP
Include $CRS_BEFORE
Include $CRS_RULES/*.conf
Include $CRS_AFTER
EOF

cat > "$NGINX_WAF_CONF" <<EOF
modsecurity on;
modsecurity_rules_file $MODSEC_INCLUDES;
EOF

if ! nginx -t; then
    cp -a "$BACKUP_DIR/modsecurity.conf" "$MODSEC_CONF"
    if [ -f "$BACKUP_DIR/modsecurity_includes.conf" ]; then
        cp -a "$BACKUP_DIR/modsecurity_includes.conf" "$MODSEC_INCLUDES"
    else
        rm -f "$MODSEC_INCLUDES"
    fi
    if [ -f "$BACKUP_DIR/00-lsetup-waf.conf" ]; then
        cp -a "$BACKUP_DIR/00-lsetup-waf.conf" "$NGINX_WAF_CONF"
    else
        rm -f "$NGINX_WAF_CONF"
    fi
    echo "Nginx rechazo la configuracion. Se ha restaurado el backup."
    exit 1
fi

systemctl reload nginx

echo "WAF activado con SecRuleEngine $RULE_ENGINE."
if [ "$RULE_ENGINE" = "DetectionOnly" ]; then
    echo "Desarrollo: registra ataques, pero no bloquea peticiones."
else
    echo "Produccion: las reglas CRS ya bloquean peticiones maliciosas."
fi
echo "Backup: $BACKUP_DIR"
echo "Consulta el log configurado con: grep -n SecAuditLog $MODSEC_CONF"
