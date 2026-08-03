#!/bin/bash
# ==============================================================================
# SCRIPT DE LIMPIEZA — revierte todo lo instalado por setup.sh
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
echo "   Backups cifrados (sección 16): opt-in; si no confirmas NO se borran."
echo "   Para revertir capa web v3 (secciones 25-30 + WAF + app harden), ver sección 17."
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

echo "=== 16. ELIMINAR BACKUPS CIFRADOS (opt-in, default=NO) ==="
# NO borra backups por defecto:BD+cifrado configs son caros de perder.
# Pregunta explícita; usuario decide.
BACKUP_ROOT="/var/lib/.system-state"
KEY_FILE="/root/.backup-key"
CRON_FILE="/etc/cron.d/backup"
SCRIPTS_LIST="/usr/local/sbin/backup.sh /usr/local/sbin/backup-verify.sh /usr/local/sbin/restore.sh"

if [ -d "$BACKUP_ROOT" ] || [ -f "$KEY_FILE" ] || [ -f "$CRON_FILE" ] || [ -f /etc/backup.conf ]; then
    echo "    Sistema de backups detectado:"
    [ -d "$BACKUP_ROOT" ] && echo "      - Snapshots:     $BACKUP_ROOT ($(du -sh "$BACKUP_ROOT" 2>/dev/null | awk '{print $1}')"
    [ -f "$KEY_FILE" ]   && echo "      - Passphrase:    $KEY_FILE"
    [ -f "$CRON_FILE" ]  && echo "      - Cron:          $CRON_FILE"
    [ -f /etc/backup.conf ] && echo "      - Config:        /etc/backup.conf"
    for s in $SCRIPTS_LIST; do [ -f "$s" ] && echo "      - Script:        $s"; done
    echo ""
    read -rp "    ¿Borrar TODO el sistema de backups? [s/N]: " BKP_DEL
    BKP_DEL="${BKP_DEL:-N}"
    BKP_DEL="${BKP_DEL,,}"
    if [[ "$BKP_DEL" == "s" || "$BKP_DEL" == "si" || "$BKP_DEL" == "sí" ]]; then
        # Quitar chattr +i del passphrase antes de rm.
        chattr -i "$KEY_FILE" 2>/dev/null || true
        rm -rf "$BACKUP_ROOT"
        rm -f "$KEY_FILE"
        rm -f /etc/backup.conf
        rm -f "$CRON_FILE"
        for s in $SCRIPTS_LIST; do rm -f "$s"; done
        rm -f /var/log/.backup.log
        rm -f /var/run/.backup.lock
        echo "    >> Backups + cron + scripts + passphrase eliminados."
    else
        echo "    >> Backups conservados (default). Verifícalos con:"
        echo "        sudo /usr/local/sbin/backup-verify.sh"
    fi
else
    echo "    No se detectó sistema de backups. Skip."
fi

echo "=== 17. REVERTIR FASE ANTI-ATAQUES WEB v3 (secure.sh secciones 25-30 + WAF + app) ==="
# Best-effort: set +e ya activo. Limpia config creado por secure.sh v3, waf.sh
# y laravel-harden.sh. NO revierte hardening SSH/firewalld/fail2ban (clear.sh
#初衷: revierte setup.sh + capa v3 web; secure.sh core permanece).

# (a) PHP CLI drop-in.
rm -f /etc/php.d/99-hardening.ini 2>/dev/null
echo "    - PHP CLI drop-in:          eliminado (si existía)."

# (b) Nginx timeouts + method block + COEP/CORP + snippets rate-limit.
rm -f /etc/nginx/conf.d/00-timeouts.conf \
      /etc/nginx/conf.d/00-method-block.conf \
      /etc/nginx/snippets/rate-limited-routes.conf \
      /etc/nginx/snippets/method-guard.conf 2>/dev/null
# Eliminar las 2 líneas COEP/CORP añadidas por secure.sh (sección 28) del extra-headers.
if [ -f /etc/nginx/conf.d/00-sec-extra-headers.conf ]; then
    sed -i -E '/Cross-Origin-Embedder-Policy|Cross-Origin-Resource-Policy/d' \
        /etc/nginx/conf.d/00-sec-extra-headers.conf 2>/dev/null || true
fi
# Quitar includes inyectados en vhosts (method-guard + rate-limited-routes).
for f in /etc/nginx/conf.d/*.conf; do
    [ -f "$f" ] || continue
    sed -i -E '/snippets\/method-guard\.conf|snippets\/rate-limited-routes\.conf/d' "$f" 2>/dev/null || true
done
nginx -t 2>/dev/null && systemctl reload nginx 2>/dev/null || systemctl restart nginx 2>/dev/null || true
echo "    - Nginx timeouts/method/COEP: revertidos (recargado si OK)."

# (c) Redis ACL (aclfile). restore-command ya queda en redis.conf; ACL file rm.
if [ -f /etc/redis/redis.conf ]; then
    sed -i -E '/^aclfile[[:space:]]+/d' /etc/redis/redis.conf 2>/dev/null || true
fi
rm -f /etc/redis/users.acl 2>/dev/null
systemctl restart redis 2>/dev/null || true
echo "    - Redis ACL (aclfile):       eliminado (rename-command permanece)."

# (d) PostgreSQL: GRANT revert de REVOKE (solo si cluster sigue vivo).
if systemctl is-active --quiet postgresql-18 2>/dev/null; then
    sudo -u postgres psql -d laravel1 -c "GRANT CREATE ON SCHEMA public TO PUBLIC;" 2>/dev/null || true
    sudo -u postgres psql -c "GRANT ALL ON DATABASE postgres TO PUBLIC;" 2>/dev/null || true
    echo "    - PG REVOKE:                 revertido (GRANT CREATE/ALL)."
else
    echo "    - PG REVOKE:                 skip (cluster ya caído/eliminado)."
fi

# (e) WAF ModSecurity (creado por waf.sh): config + log, optional dnf remove.
rm -rf /etc/nginx/modsec 2>/dev/null
rm -rf /var/log/modsec 2>/dev/null
if [ -f /etc/nginx/conf.d/modsec.conf ] || grep -rq 'modsecurity on' /etc/nginx/conf.d/ 2>/dev/null; then
    for f in /etc/nginx/conf.d/*.conf; do
        [ -f "$f" ] || continue
        sed -i -E '/modsecurity on|modsecurity_rules|snippets\/modsec/d' "$f" 2>/dev/null || true
    done
    rm -f /etc/nginx/conf.d/modsec.conf /etc/nginx/snippets/modsec.conf 2>/dev/null
fi
dnf remove -y mod_security nginx-mod_security 2>/dev/null || true
nginx -t 2>/dev/null && systemctl reload nginx 2>/dev/null || true
echo "    - WAF ModSecurity:           config eliminado."

# (f) laravel-harden.sh: EnvironmentFile drop-in + /etc/laravel/env + audit cron.
rm -f /etc/systemd/system/octane.service.d/secrets.conf 2>/dev/null
rmdir /etc/systemd/system/octane.service.d 2>/dev/null || true
systemctl daemon-reload 2>/dev/null || true
rm -rf /etc/laravel 2>/dev/null
rm -f /etc/cron.d/laravel-audit 2>/dev/null
rm -f /var/log/laravel-audit.log 2>/dev/null
echo "    - App harden (envfile/cron):  eliminado."
rm -f /var/log/php_errors.log 2>/dev/null

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
echo "   - Backups cifrados              : opt-in (ver sección 16)"
echo "   - Fase anti-ataques web v3      : revertida (sección 17)"
echo ""
echo " Reinicia el servidor para aplicar cambios de kernel/sysctl:"
echo "   sudo reboot"
echo "=========================================================================="

# ------------------------------------------------------------------------------
# PROMPT DE REBOOT PROGRAMADO (sysctl persistente se revierte solo tras reboot)
# ------------------------------------------------------------------------------
maybe_reboot_clear() {
    dnf install -y at 2>/dev/null || true
    systemctl enable --now atd 2>/dev/null || true
    echo ""
    echo " ⚠️  Cambios pendientes de reboot tras limpieza:"
    echo "      - sysctl hardening revertido en .conf (en caliente sigue aplicado)"
    echo "      - /tmp noexec tmpfs removido de fstab (aplica tras reboot)"
    echo "      - servicios masked (bluetooth/nfs/etc.) unmasked (reboot los re-llama)"
    echo ""
    echo "   Programa reboot (Enter=manual más tarde):"
    echo "     - 'now'                          reboot en 5s"
    echo "     - 'HH:MM'                        hoy a esa hora (p.ej. 04:00)"
    echo "     - 'YYYY-MM-DD HH:MM'             fecha+hora exactas"
    echo "     - 'sun 04:00' / 'mon 02:30' / 'tomorrow 03:00'  formatos de 'at'"
    read -rp "   Opción [Enter=skip]: " WHEN
    [ -z "$WHEN" ] && { echo "   >> No programado. Reboot manual."; return 0; }
    if [ "$WHEN" = "now" ]; then
        echo "   >> Reboot en 5s..."
        ( sleep 5 && systemctl reboot ) &
    elif echo "systemctl reboot" | at "$WHEN" 2>/dev/null; then
        echo "   >> Reboot programado con 'at' para: $WHEN"
        echo "      at -l            lista jobs | sudo at -r <id>  cancela"
    elif shutdown -r "$WHEN" 2>/dev/null; then
        echo "   >> Reboot programado (shutdown) para: $WHEN"
    else
        echo "   ⚠️  Formato no reconocido. Reboot manual: sudo reboot"
    fi
}
maybe_reboot_clear
