#!/bin/bash
set -e

# ==============================================================================
# INSTALADOR DEL SISTEMA DE BACKUPS (v1)
# Crea: ruta oculta /var/lib/.system-state, passphrase GPG, cron entries.
# Idempotente: re-ejecutable sin romper passphrase existente.
# Detalle arquitectura en backup.sh. Sin mail/Alertmanager por ahora.
# ==============================================================================

if [ "$EUID" -ne 0 ]; then
    echo "⚠️ Ejecuta este script como root o con sudo."
    exit 1
fi

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/pgsql-18/bin:$PATH"

BACKUP_ROOT="/var/lib/.system-state"
SNAPSHOTS_DIR="$BACKUP_ROOT/snapshots"
LOG_FILE="/var/log/.backup.log"
KEY_FILE="/root/.backup-key"
INSTALL_DIR="/usr/local/sbin"
DOW="$(date +%u)"   # 1=lun ... 7=dom

echo "=========================================================================="
echo " 💾 INSTALADOR DEL SISTEMA DE BACKUPS (v1)"
echo "=========================================================================="

# ------------------------------------------------------------------------------
# 1. DEPENDENCIAS
# ------------------------------------------------------------------------------
echo ">> [1/7] Verificando dependencias..."
for pkg in tar gzip gpg postgresql18-server coreutils util-linux cronie; do
    if ! rpm -q "$pkg" &>/dev/null; then
        echo "   ⚠️  Paquete '$pkg' no instalado. Intentando dnf install..."
        dnf install -y "$pkg" 2>/dev/null || true
    fi
done
# flock via util-linux, sha256sum via coreutils. Garantizar cronie activo.
systemctl enable --now crond 2>/dev/null || true

# ------------------------------------------------------------------------------
# 2. RUTA OCULTA + ESTRUCTURA (sólo daily/, retención flat 14d)
# ------------------------------------------------------------------------------
echo ">> [2/7] Creando estructura oculta /var/lib/.system-state..."
# Camuflaje: dir oculta dentro de /var/lib entre pgsql/redis/dnf. chmod 700.
mkdir -p "$SNAPSHOTS_DIR/daily" "$BACKUP_ROOT/logs" "$BACKUP_ROOT/tmp"
chmod 700 "$BACKUP_ROOT"
chmod 700 "$SNAPSHOTS_DIR" "$SNAPSHOTS_DIR/daily" "$BACKUP_ROOT/logs" "$BACKUP_ROOT/tmp"
chown -R root:root "$BACKUP_ROOT"

# Limpieza de tiers viejos si existed de versión previa (GFS weekly/monthly).
rmdir "$SNAPSHOTS_DIR/weekly" "$SNAPSHOTS_DIR/monthly" 2>/dev/null || true

# SELinux: directorio fuera de contextos habituales. preservar default var_lib_t.
restorecon -Rv "$BACKUP_ROOT" 2>/dev/null || true

# ------------------------------------------------------------------------------
# 3. PASSPHRASE GPG (autogen, NUNCA mostrar contenido en stdout)
# ------------------------------------------------------------------------------
echo ">> [3/7] Configurando passphrase GPG (SIMÉTRICA AES256)..."
if [ -f "$KEY_FILE" ]; then
    echo "   ✅ Passphrase existente en $KEY_FILE. Reutilizando (idempotente)."
else
    # Generar passphrase 64 chars alfanuméricos. /dev/urandom suficiente.
    PASSPHRASE=$(head -c 48 /dev/urandom | base64 | tr -d '/+=' | tr -dc 'A-Za-z0-9' | head -c 64)
    if [ -z "$PASSPHRASE" ]; then
        PASSPHRASE=$(openssl rand -hex 32 2>/dev/null || echo "fallback-$(date +%s)-change-me")
    fi
    # Escribir SIN newline final (gpg --passphrase-file lo exige idempotente).
    printf '%s' "$PASSPHRASE" > "$KEY_FILE"
    chmod 600 "$KEY_FILE"
    chown root:root "$KEY_FILE"
    # Inmutable: protege contra borrado accidental/ransomware on-server.
    chattr +i "$KEY_FILE" 2>/dev/null || echo "   ⚠️  chattr +i falla (¿filesystem no soporta?). Sin inmutable."
    unset PASSPHRASE
    echo "   ✅ Passphrase autogenerada en $KEY_FILE (chmod 600, chattr +i)."
    echo "   ⛔  NO se muestra por pantalla. Para verla: sudo cat $KEY_FILE"
    echo "   ⛔  GUÁRDALA en gestor externo (Bitwarden/KeePass): sin ella NO hay restore .keyring."
fi

# ------------------------------------------------------------------------------
# 4. DETERMINAR RUTA PROYECTO LARAVEL
# ------------------------------------------------------------------------------
echo ">> [4/7] Detectando proyecto Laravel..."
ENV_FILE=$(find /var/www -maxdepth 2 -mindepth 2 -name '.env' -type f 2>/dev/null | head -1)
if [ -n "$ENV_FILE" ]; then
    CANDIDATE=$(dirname "$ENV_FILE")
    if [ -f "$CANDIDATE/artisan" ] && [ -d "$CANDIDATE/vendor" ]; then
        LARAVEL_DIR="$CANDIDATE"
        echo "   ✅ Detectado: $LARAVEL_DIR"
    fi
fi
if [ -z "${LARAVEL_DIR:-}" ]; then
    read -rp "   No se detectó Laravel. Ruta manual (Enter=omitir parche .env): " LARAVEL_DIR
fi
# Persistir ruta en /etc/backup.conf lo lee backup.sh/restore.sh.
CONF=/etc/backup.conf

# ------------------------------------------------------------------------------
# 4b. MENÚ CRON — cadencia + hora del backup diario + verify semanal
# ------------------------------------------------------------------------------
echo ">> [4b/7] Configurar cadencia del backup..."
echo "   Cadencia del backup:"
echo "     1. Diario       (recomendado para retención 14d)"
echo "     2. Cada X días  (introduce X después)"
echo "     3. Semanal      (día fijo de la semana)"
echo "     4. Mensual      (día del mes 1-28)"
read -rp "   Opción [1-4] (default=1): " CAD_OPT
CAD_OPT="${CAD_OPT:-1}"

CADENCIA_MIN=""     # campo `minuto` cron (e.g. "*/30"); aquí usamos siempre 0
CADENCIA_HOUR=""    # campo `hora`
CADENCIA_DOM=""    # campo `día del mes`
CADENCIA_DOW=""   # campo `día de la semana`
CADENCIA_LABEL=""

read -rp "   Hora del backup HH:MM (default=02:00): " BK_TIME
BK_TIME="${BK_TIME:-02:00}"
BK_HH="${BK_TIME%%:*}"
BK_MM="${BK_TIME##*:}"
case "$CAD_OPT" in
    1)
        CADENCIA_MIN="$BK_MM"; CADENCIA_HOUR="$BK_HH"; CADENCIA_DOM="*"; CADENCIA_DOW="*"
        CADENCIA_LABEL="diario @ $BK_TIME"
        ;;
    2)
        read -rp "   Cada cuántos días (X, 2-28): " X_DAYS
        if ! [[ "$X_DAYS" =~ ^[0-9]+$ ]] || [ "$X_DAYS" -lt 2 ] || [ "$X_DAYS" -gt 28 ]; then
            echo "❌ X inválido. Default 3."; X_DAYS=3
        fi
        CADENCIA_MIN="$BK_MM"; CADENCIA_HOUR="$BK_HH"; CADENCIA_DOM="*/$X_DAYS"; CADENCIA_DOW="*"
        CADENCIA_LABEL="cada $X_DAYS días @ $BK_TIME"
        ;;
    3)
        echo "   Día de la semana: 1=lun 2=mar 3=mie 4=jue 5=vie 6=sab 0/7=dom"
        read -rp "   Día [0-7] (default=0=dom): " WD
        WD="${WD:-0}"
        case "$WD" in 0|1|2|3|4|5|6|7) ;; *) echo "❌ Default dom."; WD=0;; esac
        CADENCIA_MIN="$BK_MM"; CADENCIA_HOUR="$BK_HH"; CADENCIA_DOM="*"; CADENCIA_DOW="$WD"
        CADENCIA_LABEL="semanal (dow=$WD) @ $BK_TIME"
        ;;
    4)
        read -rp "   Día del mes [1-28] (default=1): " MD
        MD="${MD:-1}"
        if ! [[ "$MD" =~ ^[0-9]+$ ]] || [ "$MD" -lt 1 ] || [ "$MD" -gt 28 ]; then
            echo "❌ Default día 1."; MD=1
        fi
        CADENCIA_MIN="$BK_MM"; CADENCIA_HOUR="$BK_HH"; CADENCIA_DOM="$MD"; CADENCIA_DOW="*"
        CADENCIA_LABEL="mensual (día $MD) @ $BK_TIME"
        ;;
    *)
        echo "❌ Opción inválida. Default diario @ $BK_TIME."
        CADENCIA_MIN="$BK_MM"; CADENCIA_HOUR="$BK_HH"; CADENCIA_DOM="*"; CADENCIA_DOW="*"
        CADENCIA_LABEL="diario @ $BK_TIME"
        ;;
esac

# Verificación semanal: día fijo domingo (0), hora prompt default 04:30.
read -rp "   Hora verificación semanal HH:MM (default=04:30): " VF_TIME
VF_TIME="${VF_TIME:-04:30}"
VF_HH="${VF_TIME%%:*}"
VF_MM="${VF_TIME##*:}"

# Retención flat 14 días.
read -rp "   Días de retención (default=14, flat purge): " RET_DAYS
RET_DAYS="${RET_DAYS:-14}"
if ! [[ "$RET_DAYS" =~ ^[0-9]+$ ]] || [ "$RET_DAYS" -lt 1 ]; then
    echo "❌ Retención inválida. Default 14."; RET_DAYS=14
fi

# Persistir config (lo leen backup.sh / restore.sh / verify).
cat << EOF > "$CONF"
# Config generado por backup-install.sh (v1). No editar salvo intención.
BACKUP_ROOT="$BACKUP_ROOT"
SNAPSHOTS_DIR="$SNAPSHOTS_DIR"
LOG_FILE="$LOG_FILE"
KEY_FILE="$KEY_FILE"
LARAVEL_DIR="${LARAVEL_DIR:-}"
RETENTION_DAYS=$RET_DAYS
CADENCIA_LABEL="$CADENCIA_LABEL"
EOF
chmod 600 "$CONF"
chown root:root "$CONF"

# ------------------------------------------------------------------------------
# 5. INSTALAR SCRIPTS EN /usr/local/sbin
# ------------------------------------------------------------------------------
echo ">> [5/7] Instalando scripts en $INSTALL_DIR..."
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for script in backup.sh backup-verify.sh restore.sh; do
    SRC="$SELF_DIR/$script"
    DST="$INSTALL_DIR/$script"
    if [ ! -f "$SRC" ]; then
        echo "   ⚠️  $SRC no encontrado en el repo. Skip insta."
        continue
    fi
    install -m 700 -o root -g root "$SRC" "$DST"
    echo "   >> $DST (700 owner root:root)"
done
# restore.sh uso manual: 755 (cualquier sudoer puede), no 700.
[ -f "$INSTALL_DIR/restore.sh" ] && chmod 755 "$INSTALL_DIR/restore.sh"

# ------------------------------------------------------------------------------
# 6. ENTRADAS CRON (cadencia configurada + verificación semanal dom)
# ------------------------------------------------------------------------------
echo ">> [6/7] Instalando entradas cron ($CADENCIA_LABEL, retención ${RET_DAYS}d)..."
CRON_MARKER="# --- backup-system-v1 ---"
CRON_BLOCK=$(cat <<EOF
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/pgsql-18/bin
$CRON_MARKER
# Backup según cadencia elegida: $CADENCIA_LABEL (retención flat ${RET_DAYS}d).
$CADENCIA_MIN $CADENCIA_HOUR $CADENCIA_DOM $CADENCIA_DOW * root /usr/local/sbin/backup.sh >> $LOG_FILE 2>&1
# Verificación integridad cada domingo a $VF_TIME.
$VF_MM $VF_HH * * 0 root /usr/local/sbin/backup-verify.sh >> $LOG_FILE 2>&1
# --- fin backup-system-v1 ---
EOF
)
CRON_FILE=/etc/cron.d/backup
# Idempotente: quitar bloque previo y reinsertar.
touch "$CRON_FILE"
chmod 600 "$CRON_FILE"
chown root:root "$CRON_FILE"
if grep -q "$CRON_MARKER" "$CRON_FILE" 2>/dev/null; then
    sed -i "/$CRON_MARKER/,/--- fin backup-system-v1 ---/d" "$CRON_FILE"
fi
printf '%s\n' "$CRON_BLOCK" >> "$CRON_FILE"
echo "   >> $CRON_FILE (backup: $CADENCIA_LABEL | verify: dom $VF_TIME | retención: ${RET_DAYS}d flat)"

# ------------------------------------------------------------------------------
# 7. TEST RÁPIDO (sin correr full backup)
# ------------------------------------------------------------------------------
echo ">> [7/7] Test rápido de componentes..."
# gpg simétrico disponible.
gpg --version 2>/dev/null | head -1 || { echo "❌ gpg no arranca"; exit 1; }
# pg_dump (postgres18) en PATH.
if ! command -v pg_dump &>/dev/null && ! rpm -q postgresql18 &>/dev/null; then
    echo "   ⚠️  No hay pg_dump. Backup DB fallará. Instala 'postgresql18' client o ejecute tras setup.sh."
fi
# LARAVEL_DIR válido si se especificó.
if [ -n "${LARAVEL_DIR:-}" ] && [ ! -d "$LARAVEL_DIR" ]; then
    echo "   ⚠️  LARAVEL_DIR=$LARAVEL_DIR no existe. Backups files fallarán."
fi
# Log directory escribible.
touch "$LOG_FILE" 2>/dev/null || { echo "❌ No puedo escribir $LOG_FILE"; exit 1; }
chmod 600 "$LOG_FILE"
chown root:root "$LOG_FILE"

# ------------------------------------------------------------------------------
# RESUMEN FINAL
# ------------------------------------------------------------------------------
echo "=========================================================================="
echo " ✅ INSTALACIÓN BACKUP-COMPLETADA"
echo "=========================================================================="
echo " Ruta oculta:    $BACKUP_ROOT"
echo " Passphrase:     $KEY_FILE  (chmod 600 + chattr +i, NUNCA mostrada)"
echo "   Para verla:    sudo cat $KEY_FILE"
echo " Config:         /etc/backup.conf  (chmod 600)"
echo " Scripts:"
echo "   $INSTALL_DIR/backup.sh         (cron: $CADENCIA_LABEL)"
echo "   $INSTALL_DIR/backup-verify.sh  (cron dom $VF_TIME)"
echo "   $INSTALL_DIR/restore.sh        (manual: sudo restore.sh)"
echo " Cron:           /etc/cron.d/backup"
echo " Log:            $LOG_FILE"
echo " Retención:       FLAT ${RET_DAYS} días (no weekly/monthly)"
echo " Tipos snapshot:"
echo "   .db         PostgreSQL pg_dump --format=custom | gzip -9"
echo "   .dat        Laravel sin .env/vendor/node_modules/logs/cache"
echo "   .keyring    .env + configs sensibles (GPG simétrico AES256)"
echo "=========================================================================="
echo " PRIMERA EJECUCIÓN MANUAL (para validar):"
echo "   sudo /usr/local/sbin/backup.sh"
echo " VERIFICAR INTEGRIDAD AHORA:"
echo "   sudo /usr/local/sbin/backup-verify.sh"
echo " MONITOREAR EN sec-logs:"
echo "   sudo sec-logs    (se incluye sección BACKUPS)"
echo "=========================================================================="
echo " ⚠️  RECUPERACIÓN DE DESASTRE: necesitas \$KEY_FILE (/root/.backup-key)"
echo "     para desencriptar .keyring. Si solo restauras .db/.dat no hace falta."
echo "     Guarda passphrase en Bitwarden/KeePass APARTE del server:"
echo "       sudo cat $KEY_FILE   ← copia el contenido a tu gestor externo"
echo "=========================================================================="

# ------------------------------------------------------------------------------
# 8. PROMPT DE REBOOT (si aplica — raro en install, pero tmpfs /tmp en disco lo exige)
# ------------------------------------------------------------------------------
# Helper: questiona reboot programado. Reutilisado por secure.sh / clear.sh.
maybe_reboot() {
    local razones="$1"
    [ -z "$razones" ] && return 0
    # Asegurar `at` instalado y atd activo.
    dnf install -y at 2>/dev/null || true
    systemctl enable --now atd 2>/dev/null || true
    echo ""
    echo " ⚠️  Cambios pendientes de reboot:"
    echo "$razones" | sed 's/^/      - /'
    echo ""
    echo "   Programa reboot ahora (o Enter=manual más tarde):"
    echo "     - 'now'                          reboot en 5s"
    echo "     - 'HH:MM'                        hoy a esa hora (p.ej. 04:00)"
    echo "     - 'YYY-MM-DD HH:MM'              fecha+hora exactas (p.ej. 2026-08-03 04:30)"
    echo "     - 'sun' / 'mon' / ... + HH:MM    próximo día-semana + hora"
    read -rp "   Opción [Enter=skip]: " WHEN
    [ -z "$WHEN" ] && { echo "   >> No programado. Reboot manual cuando puedas."; return 0; }
    if [ "$WHEN" = "now" ]; then
        echo "   >> Reboot en 5s..."
        ( sleep 5 && systemctl reboot ) &
    elif echo "systemctl reboot" | at "$WHEN" 2>/dev/null; then
        echo "   >> Reboot programado con 'at' para: $WHEN"
        echo "      at -l            lista jobs"
        echo "      sudo at -r <id>  cancela"
    elif systemctl reboot --when="$WHEN" 2>/dev/null; then
        echo "   >> Reboot programado (systemd) para: $WHEN"
    else
        echo "   ⚠️  Formato no reconocido. No programado. Reboot manual."
    fi
}

REBOOT_RAZONES=""
if ! mount | grep -qE 'on /tmp type tmpfs'; then
    REBOOT_RAZONES+="tmpfs /tmp noexec/nosuid/nodev (aplica tras reboot)"
fi
if [ -n "$REBOOT_RAZONES" ]; then
    maybe_reboot "$REBOOT_RAZONES"
fi