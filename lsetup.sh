#!/bin/bash
set -e

# ==============================================================================
# LSETUP Bash - instalador base para desarrollo
# Ejecuta unicamente:
#   1. scripts/setup.sh
#   2. scripts/dominio.sh
#
# No ejecuta binario Go, WAF, hardening, 2FA ni backups.
# ==============================================================================

if [ "$EUID" -ne 0 ]; then
    echo "Ejecuta este script como root o con sudo."
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETUP_SCRIPT="$SCRIPT_DIR/scripts/setup.sh"
DOMINIO_SCRIPT="$SCRIPT_DIR/scripts/dominio.sh"

if [ ! -f "$SETUP_SCRIPT" ]; then
    echo "Error: no se encontro $SETUP_SCRIPT"
    exit 1
fi

if [ ! -f "$DOMINIO_SCRIPT" ]; then
    echo "Error: no se encontro $DOMINIO_SCRIPT"
    exit 1
fi

echo "=========================================================================="
echo " LSETUP Bash"
echo "=========================================================================="
echo " Este instalador ejecutara solo setup + dominio."
echo " Seguridad avanzada, WAF, 2FA y backups quedan fuera por ahora."
echo "=========================================================================="

echo ""
echo ">>> [1/2] Instalacion base Laravel"
# shellcheck source=scripts/setup.sh
. "$SETUP_SCRIPT"

if [ -z "$PROYECTO_DIR" ]; then
    PROYECTO_DIR="/var/www/${PROYECTO_NOMBRE:-laravel1}"
fi
export PROYECTO_DIR

echo ""
echo ">>> [2/2] Dominio + certificado Cloudflare"
# shellcheck source=scripts/dominio.sh
. "$DOMINIO_SCRIPT"

echo ""
echo "=========================================================================="
echo " LSETUP Bash completado"
echo "=========================================================================="
echo " Proyecto: $PROYECTO_DIR"
if [ -n "$DOMAIN_NAME" ]; then
    echo " Dominio:  https://$DOMAIN_NAME"
fi
echo "=========================================================================="
