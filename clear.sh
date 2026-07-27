#!/bin/bash
# ==============================================================================
# SCRIPT DE LIMPIEZA — revierte todo lo instalado por laravel-installer.sh
# Compatible AlmaLinux / Rocky Linux 10
# Ejecutar como root o con sudo.
# ==============================================================================
set +e

PROYECTO_DIR="/var/www/laravel1"
LARAVEL_USER="laravel"
DB_NAME="laravel"
DB_USER="laravel"

echo "=========================================================================="
echo " INICIANDO LIMPIEZA COMPLETA"
echo "=========================================================================="
echo " AVISO: este script revierte setup.sh, NO secure.sh."
echo "   Permanecen activos: puerto SSH custom, firewalld por IP, Fail2ban,"
echo "   CrowdSec, AIDE, sysctl hardening y /etc/sudoers.d/99-local-path."
echo "   Para revertir secure.sh, revierte esos cambios manualmente."
echo "=========================================================================="

echo "=== 1. DETENER Y DESHABILITAR SERVICIOS ==="
systemctl stop octane 2>/dev/null
systemctl disable octane 2>/dev/null
systemctl stop nginx 2>/dev/null
systemctl disable nginx 2>/dev/null
systemctl stop redis 2>/dev/null
systemctl disable redis 2>/dev/null
systemctl stop postgresql-18 2>/dev/null
systemctl disable postgresql-18 2>/dev/null
systemctl stop php-fpm 2>/dev/null
systemctl disable php-fpm 2>/dev/null

echo "=== 2. ELIMINAR SERVICIO SYSTEMD DE OCTANE ==="
rm -f /etc/systemd/system/octane.service
rm -f /etc/systemd/system/multi-user.target.wants/octane.service
systemctl daemon-reload

echo "=== 3. ELIMINAR PROYECTO LARAVEL Y HOGAR DEL USUARIO ==="
rm -rf "$PROYECTO_DIR"
rm -rf /var/lib/laravel
rm -rf /var/www/laravel
rmdir /var/www 2>/dev/null || true

echo "=== 4. ELIMINAR USUARIO Y GRUPO LARAVEL ==="
userdel "$LARAVEL_USER" 2>/dev/null
groupdel "$LARAVEL_USER" 2>/dev/null

echo "=== 5. ELIMINAR BASE DE DATOS Y USUARIO POSTGRES ==="
if systemctl is-active --quiet postgresql-18; then
    sudo -u postgres psql -c "DROP DATABASE IF EXISTS $DB_NAME;" 2>/dev/null
    sudo -u postgres psql -c "DROP USER IF EXISTS $DB_USER;" 2>/dev/null
fi

echo "=== 6. ELIMINAR CONFIGURACIÓN NGINX ==="
rm -f /etc/nginx/conf.d/laravel.conf
# Restaurar backup si existe
if [ -f /etc/nginx/nginx.conf.bak ]; then
    cp /etc/nginx/nginx.conf.bak /etc/nginx/nginx.conf
    echo "    nginx.conf restaurado desde backup."
fi
rm -rf /var/cache/nginx

echo "=== 7. ELIMINAR REGLAS DE FIREWALL ==="
firewall-cmd --permanent --remove-service=http 2>/dev/null
firewall-cmd --permanent --remove-port=8000/tcp 2>/dev/null
firewall-cmd --reload 2>/dev/null

echo "=== 8. REVERTIR BOLEANOS SELINUX ==="
setsebool -P httpd_can_network_connect 0 2>/dev/null
setsebool -P httpd_can_network_connect_db 0 2>/dev/null
setsebool -P httpd_can_network_connect_redis 0 2>/dev/null
setsebool -P httpd_unified 0 2>/dev/null
# Eliminar contextos de archivo personalizados
semanage fcontext -d "$PROYECTO_DIR/storage(/.*)?" 2>/dev/null
semanage fcontext -d "$PROYECTO_DIR/bootstrap/cache(/.*)?" 2>/dev/null
restorecon -R /var/www 2>/dev/null

echo "=== 9. REVERTIR LÍMITES Y SYSCTL ==="
# Eliminar líneas añadidas a limits.conf
sed -i '/^\* soft nofile 65535$/d' /etc/security/limits.conf
sed -i '/^\* hard nofile 65535$/d' /etc/security/limits.conf
# Eliminar línea añadida a sysctl.conf
sed -i '/^net.core.somaxconn = 65535$/d' /etc/sysctl.conf
sysctl -p 2>/dev/null || true

echo "=== 10. ELIMINAR CONFIG DE REDIS (líneas añadidas) ==="
sed -i '/^maxmemory 512mb$/d' /etc/redis/redis.conf 2>/dev/null
sed -i '/^maxmemory-policy allkeys-lru$/d' /etc/redis/redis.conf 2>/dev/null

echo "=== 11. DESINSTALAR PAQUETES ==="
dnf remove -y \
    postgresql18-server postgresql18 postgresql18-libs \
    php php-cli php-fpm php-pgsql php-zip php-xml php-curl php-intl \
    php-bcmath php-mbstring php-posix php-pcntl php-gd php-opcache \
    php-pecl-swoole php-pecl-redis \
    redis \
    nginx httpd-tools \
    2>/dev/null

# Composer
rm -f /usr/local/bin/composer
rm -f /usr/bin/composer

echo "=== 12. ELIMINAR REPOS DE TERCEROS ==="
dnf remove -y \
    remi-release pgdg-redhat-repo-latest.noarch pgdg-redhat-repo \
    2>/dev/null
rm -f /etc/yum.repos.d/remi*.repo
rm -f /etc/yum.repos.d/pgdg*.repo
dnf clean all

echo "=== 13. RESETEAR MÓDULOS DNF ==="
dnf module reset php -y 2>/dev/null
dnf module reset redis -y 2>/dev/null
dnf module reset postgresql -y 2>/dev/null

echo "=== 14. LIMPIAR DIRECTORIOS DE DATOS RESIDUALES ==="
rm -rf /var/lib/pgsql/18 2>/dev/null
rm -rf /var/lib/redis 2>/dev/null
rm -rf /var/log/nginx 2>/dev/null
rm -rf /var/log/redis 2>/dev/null

echo "=== 15. LIMPIAR USUARIOS DEL SISTEMA ==="
# Por si quedaron procesos
pkill -u "$LARAVEL_USER" 2>/dev/null
userdel "$LARAVEL_USER" 2>/dev/null

echo "=========================================================================="
echo " LIMPIEZA COMPLETADA"
echo "=========================================================================="
echo ""
echo " Estado:"
echo "   - Proyecto /var/www/laravel*    : eliminado"
echo "   - Servicio octane               : eliminado"
echo "   - Nginx config                  : revertido/restaurado"
echo "   - PostgreSQL 18 (bd+usuario)    : eliminado"
echo "   - Redis config                  : revertido"
echo "   - Paquetes PHP/Redis/PG/Nginx   : desinstalados"
echo "   - Repos Remi/PGDG               : eliminados"
echo "   - Composer                      : eliminado"
echo "   - Usuario laravel               : eliminado"
echo "   - Firewall/SELinux/límites      : revertidos"
echo ""
echo " Reinicia el servidor para aplicar cambios de kernel/sysctl:"
echo "   sudo reboot"
echo "=========================================================================="
