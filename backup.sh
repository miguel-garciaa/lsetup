#!/bin/bash
set -eo pipefail

if [ "$EUID" -ne 0 ]; then
    echo "⚠️  Ejecuta como root o con sudo."
    exit 1
fi

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/pgsql-18/bin:$PATH"

# ==============================================================================
# MOTOR DE BACKUPS (v1) — corre desde /etc/cron.d/backup a la hora configurada
# Genera 3 snapshots por run:
#   .db      → pg_dump --format=custom | gzip -9
#   .dat     → Laravel sin .env/vendor/node_modules/storage/logs/storage/framework/cache
#   .keyring → .env + configs sensibles (GPG simétrico AES256)
# Retención: FLAT $RETENTION_DAYS días (default 14) en daily/. Sin weekly/monthly.
# Sin mail/Alertmanager (logs a $LOG_FILE + futura integración monitoring aparte).
# ==============================================================================

# ------------------------------------------------------------------------------
# CONFIG (lee /etc/backup.conf generado por backup-install.sh)
# ------------------------------------------------------------------------------
CONF=/etc/backup.conf
if [ ! -f "$CONF" ]; then
    echo "[$(date '+%F %T')] [FATAL] falta $CONF. Ejecuta: sudo bash backup-install.sh" >&2
    exit 1
fi
# shellcheck disable=SC1091
. "$CONF"

: "${BACKUP_ROOT:=/var/lib/.system-state}"
: "${SNAPSHOTS_DIR:=$BACKUP_ROOT/snapshots}"
: "${LOG_FILE:=/var/log/.backup.log}"
: "${KEY_FILE:=/root/.backup-key}"
: "${RETENTION_DAYS:=14}"
TMP_DIR="$BACKUP_ROOT/tmp"

START_TS=$(date +%s)
TAG=$(date '+%Y%m%d-%H%M' -d "@$START_TS")
HOST=$(hostname)

# Status global para log final; cero fallidos.
STATUS_OK=1
EXIT_CODE=0
declare -A SIZES

log() { echo "[$(date '+%F %T')] $*" >> "$LOG_FILE"; }
logecho() { echo "$@"; log "$@"; }

mkdir -p "$(dirname "$LOG_FILE")"
chmod 600 "$LOG_FILE" 2>/dev/null || true

logecho "============================================================"
logecho " 💾 BACKUP INICIADO ($TAG) host=$HOST"
logecho "============================================================"

# ------------------------------------------------------------------------------
# LOCK: anti doble-run (flock) si run anterior está corriendo.
# ------------------------------------------------------------------------------
LOCK_FILE=/var/run/.backup.lock
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    logecho "⛔ Otro backup.sh corriendo (flock denial). Aborto."
    exit 1
fi

# Limpieza tmp garantizada al salir (normal o aborto).
trap 'rm -rf "$TMP_DIR"/* 2>/dev/null || true' EXIT

mkdir -p "$TMP_DIR"
chmod 700 "$TMP_DIR"

# Función helper: mueve archivo TMP al tier de pendientes, registra size + sha256.
mover_pending() {
    local tipo="$1" archivo="$2"
    if [ ! -s "$archivo" ]; then
        logecho "❌ [$tipo] archivo vacío. NO se mueve."
        STATUS_OK=0; EXIT_CODE=1; return 1
    fi
    local pend_dir="$SNAPSHOTS_DIR/_pending_$tipo"
    mkdir -p "$pend_dir"
    mv "$archivo" "$pend_dir/"
    chmod 600 "$pend_dir/$(basename "$archivo")"
    chown root:root "$pend_dir/$(basename "$archivo")"
    SIZES["$tipo"]=$(stat -c '%s' "$pend_dir/$(basename "$archivo")")
    (cd "$pend_dir" && sha256sum "$(basename "$archivo")" > "$(basename "$archivo").sha256") 2>/dev/null || true
    logecho "✅ [$tipo] $(basename "$archivo") ($(numfmt --to=iec "${SIZES[$tipo]}" 2>/dev/null || echo "${SIZES[$tipo]}b"))"
}

# ------------------------------------------------------------------------------
# 1. DETECTAR LARAVEL + CREDS DB + REDIS (de .env, NO source para evitar inject)
# ------------------------------------------------------------------------------
logecho ">> [1/5] Detectando proyecto + credenciales DB..."
if [ -z "${LARAVEL_DIR:-}" ] || [ ! -f "$LARAVEL_DIR/.env" ]; then
    ENV_FILE=$(find /var/www -maxdepth 2 -mindepth 2 -name '.env' -type f 2>/dev/null | head -1)
    if [ -n "$ENV_FILE" ]; then
        CANDIDATE=$(dirname "$ENV_FILE")
        [ -f "$CANDIDATE/artisan" ] && [ -d "$CANDIDATE/vendor" ] && LARAVEL_DIR="$CANDIDATE"
    fi
fi

if [ -n "${LARAVEL_DIR:-}" ] && [ -f "$LARAVEL_DIR/.env" ]; then
    logecho "   Proyecto: $LARAVEL_DIR"
    read_env() {
        awk -F= -v k="$1" '
            {
                key = $1;
                sub(/^[ \t]+/, "", key);
                sub(/[ \t]+$/, "", key);
                if (key == k && NF >= 2) {
                    val = substr($0, index($0, "=") + 1);
                    sub(/^[ \t]+/, "", val);
                    sub(/[ \t]+$/, "", val);
                    sub(/^["'\'']/, "", val);
                    sub(/["'\'']$/, "", val);
                    print val;
                    exit;
                }
            }
        ' "$LARAVEL_DIR/.env"
    }
    DB_NAME=$(read_env DB_DATABASE)
    DB_USER=$(read_env DB_USERNAME)
    DB_PASS=$(read_env DB_PASSWORD)
    [ -z "$DB_NAME" ] && { logecho "⚠️  DB_DATABASE vacío en .env. Skip backup DB."; }
    [ -z "$DB_USER" ] && { logecho "⚠️  DB_USERNAME vacío en .env. Skip backup DB."; }
else
    logecho "   ⚠️  No se detectó Laravel. Solo se hará snapshot de configs (.keyring)."
    LARAVEL_DIR=""
fi

# ------------------------------------------------------------------------------
# 2. SNAPSHOT .db  — PostgreSQL
# ------------------------------------------------------------------------------
if [ -n "${DB_NAME:-}" ] && [ -n "${DB_USER:-}" ]; then
    logecho ">> [2/5] pg_dump DB=$DB_NAME (user=$DB_USER)..."
    if systemctl is-active --quiet postgresql-18 2>/dev/null; then
        DB_DUMP="$TMP_DIR/state-$TAG.db"
        # pg_dump --format=custom → pg_restore permite restore parcial.
        # pipefail: si pg_dump falla no enmascarar exitcode del gzip.
        if PGPASSWORD="$DB_PASS" pg_dump --format=custom \
            --no-owner --no-privileges --host=127.0.0.1 --username="$DB_USER" \
            "$DB_NAME" 2>"$TMP_DIR/pd.err" | gzip -9c > "$DB_DUMP"
        then
            mover_pending db "$DB_DUMP" || true
        else
            logecho "❌ [db] pg_dump falló. Detalle: $(cat "$TMP_DIR/pd.err" 2>/dev/null)"
            STATUS_OK=0; EXIT_CODE=1
        fi
    else
        logecho "⚠️  postgresql-18 no activo. Skip DB este run."
    fi
else
    logecho ">> [2/5] Sin creds DB → skip .db."
fi

# ------------------------------------------------------------------------------
# 3. SNAPSHOT .dat  — Laravel files (sin .env/vendor/node_modules/cache/logs)
# ------------------------------------------------------------------------------
if [ -n "${LARAVEL_DIR:-}" ]; then
    logecho ">> [3/5] tar Laravel (excluye .env/vendor/node_modules/cache/logs)..."
    FILES_TAR="$TMP_DIR/state-$TAG.dat"
    if tar --warning=no-file-changed -czf "$FILES_TAR" \
        --exclude='.env' \
        --exclude='vendor' \
        --exclude='node_modules' \
        --exclude='storage/framework/cache/*' \
        --exclude='storage/logs/*.log' \
        --exclude='.git' \
        -C /var/www "$(basename "$LARAVEL_DIR")" 2>"$TMP_DIR/tar.err"
    then
        mover_pending files "$FILES_TAR" || true
    else
        logecho "❌ [files] tar falló. Detalle: $(cat "$TMP_DIR/tar.err" 2>/dev/null)"
        STATUS_OK=0; EXIT_CODE=1
    fi
else
    logecho ">> [3/5] Sin Laravel → skip .dat."
fi

# ------------------------------------------------------------------------------
# 4. SNAPSHOT .keyring  — .env + configs sensibles (GPG simétrico AES256)
# ------------------------------------------------------------------------------
logecho ">> [4/5] Creando .keyring (.env + configs) GPG AES256 simetrico..."
KEYRING="$TMP_DIR/state-$TAG.keyring"
KEYRING_LIST=$(mktemp)
{
    # .env NUNCA falta si existe Laravel; sinh .env es skip directo.
    [ -n "${LARAVEL_DIR:-}" ] && [ -f "$LARAVEL_DIR/.env" ] && echo "$LARAVEL_DIR/.env"
    # Configs sensibles del sistema (sshd, sudoers, ssl, audit, redis, fail2ban, sysctl).
    [ -f /etc/redis/redis.conf ] && echo /etc/redis/redis.conf
    [ -f /var/lib/pgsql/18/data/pg_hba.conf ] && echo /var/lib/pgsql/18/data/pg_hba.conf
    [ -d /etc/ssh/sshd_config.d ] && find /etc/ssh/sshd_config.d -maxdepth 1 -type f -name '*.conf'
    [ -f /etc/pam.d/sshd ] && echo /etc/pam.d/sshd
    [ -d /etc/ssl/private ] && find /etc/ssl/private -maxdepth 1 -type f 2>/dev/null
    [ -d /etc/ssl/certs ] && find /etc/ssl/certs -maxdepth 1 -type f -name '*.pem' 2>/dev/null
    [ -d /etc/audit/rules.d ] && find /etc/audit/rules.d -maxdepth 1 -type f
    [ -f /etc/fail2ban/jail.local ] && echo /etc/fail2ban/jail.local
    [ -d /etc/sysctl.d ] && find /etc/sysctl.d -maxdepth 1 -type f -name '99-*'
    [ -d /etc/security/limits.d ] && find /etc/security/limits.d -maxdepth 1 -type f -name '99-*'
    [ -d /etc/modprobe.d ] && find /etc/modprobe.d -maxdepth 1 -type f -name 'CIS-*'
    [ -d /etc/sudoers.d ] && find /etc/sudoers.d -maxdepth 1 -type f -name '99-*'
    [ -f /etc/systemd/system/octane.service ] && echo /etc/systemd/system/octane.service
    [ -f /etc/dnf/automatic.conf ] && echo /etc/dnf/automatic.conf
    [ -f /etc/security/pwquality.conf ] && echo /etc/security/pwquality.conf
    [ -d /etc/systemd/coredump.conf.d ] && find /etc/systemd/coredump.conf.d -maxdepth 1 -type f
    [ -d /etc/nginx/conf.d ] && find /etc/nginx/conf.d -maxdepth 1 -type f -name '*.conf'
    [ -d /etc/nginx/snippets ] && find /etc/nginx/snippets -maxdepth 1 -type f
    [ -f /usr/local/bin/sec-logs ] && echo /usr/local/bin/sec-logs
    [ -f /etc/nginx/conf.d/cloudflare.conf ] && echo /etc/nginx/conf.d/cloudflare.conf
    [ -f /etc/backup.conf ] && echo /etc/backup.conf
    [ -f /etc/cron.d/backup ] && echo /etc/cron.d/backup
    [ -f /etc/cron.daily/99-security-scan ] && echo /etc/cron.daily/99-security-scan
    [ -d /var/lib/pgsql/18/data ] && [ -f /var/lib/pgsql/18/data/postgresql.conf ] && echo /var/lib/pgsql/18/data/postgresql.conf
} > "$KEYRING_LIST" 2>/dev/null

# Pasar paths existentes + válidos a tar (filter /dev/null noise).
# Validación: tar -T file permite procesar 1 char vacío. filtramos sed.
FILTERED=$(awk 'NF{print}' "$KEYRING_LIST")
rm -f "$KEYRING_LIST"

if [ -z "$FILTERED" ]; then
    logecho "⚠️  No se localizó ningún config sensible. .keyring vacío skip."
else
    printf '%s\n' "$FILTERED" | tar --warning=no-file-changed -cf - -T - 2>"$TMP_DIR/tark.err" \
        | gpg --batch --yes --quiet --no-tty --pinentry-mode loopback --symmetric \
                --cipher-algo AES256 --digest-algo SHA512 \
                --passphrase-file "$KEY_FILE" \
                -o "$KEYRING" 2>"$TMP_DIR/gpg.err"
    if [ -s "$KEYRING" ]; then
        mover_pending keyring "$KEYRING" || true
    else
        logecho "❌ [keyring] GPG/tar falló. tar=$(cat "$TMP_DIR/tark.err" 2>/dev/null) gpg=$(cat "$TMP_DIR/gpg.err" 2>/dev/null)"
        STATUS_OK=0; EXIT_CODE=1
    fi
fi

# ------------------------------------------------------------------------------
# 5. ROTACIÓN FLAT — solo daily/, prune > $RETENTION_DAYS días
# ------------------------------------------------------------------------------
logecho ">> [5/5] Rotación FLAT (keep $RETENTION_DAYS runs en daily/)..."

# Mover del _pending al tier daily/ (todo va a daily).
DAILY_DIR="$SNAPSHOTS_DIR/daily"
mkdir -p "$DAILY_DIR"
for tier in db files keyring; do
    src="$SNAPSHOTS_DIR/_pending_$tier"
    [ -d "$src" ] || continue
    mv "$src"/* "$DAILY_DIR/" 2>/dev/null || true
    rmdir "$src" 2>/dev/null || true
done

# Limpieza legacy: si existen weekly/ monthly/ de versión previa, borrar sus archivos.
for legacy in weekly monthly; do
    if [ -d "$SNAPSHOTS_DIR/$legacy" ]; then
        logecho "   >> Limpiando tier legacy '$legacy' (ya no se usa en v2 flat)."
        rm -rf "$SNAPSHOTS_DIR/$legacy"
    fi
done

# Prune flat: extraer TAGs únicos (sin extensión), ordenar desc, borrar los TAGs
# más allá del límite $RETENTION_DAYS. Por cada TAG borrado eliminar sus 3 ext + .sha256.
# Procesa substitution (no pipe) para que el BODY se ejecute en shell principal.
KEEP=$((RETENTION_DAYS))
# TAGs ordenados DESC lexicográficamente = cronológicamente (formato YYYYMMDD-HHMM).
ALL_TAGS=$(ls -1 "$DAILY_DIR/" 2>/dev/null | grep -oE '^state-[0-9]{8}-[0-9]{4}' | sort -ur)
OLD_TAGS=$(printf '%s\n' "$ALL_TAGS" | tail -n +$((KEEP + 1)))
if [ -n "$OLD_TAGS" ]; then
    while read -r oldtag; do
        [ -z "$oldtag" ] && continue
        rm -f "$DAILY_DIR/$oldtag.db" "$DAILY_DIR/$oldtag.dat" "$DAILY_DIR/$oldtag.keyring" \
                "$DAILY_DIR/$oldtag.db.sha256" "$DAILY_DIR/$oldtag.dat.sha256" "$DAILY_DIR/$oldtag.keyring.sha256" 2>/dev/null
        logecho "   >> Pruned $oldtag (>$RETENTION_DAYS días)"
    done <<< "$OLD_TAGS"
else
    logecho "   >> Sin snapshots que podar (< $KEEP runs)."
fi

COUNT_DAILY=$(ls -1 "$DAILY_DIR" 2>/dev/null | grep -cE '^state-[0-9]{8}-[0-9]{4}\.(db|dat|keyring)$')
logecho "   daily: $COUNT_DAILY archivos (límite teórico $((KEEP * 3)) = $KEEP runs × 3 tipos)"

# ------------------------------------------------------------------------------
# RESUMEN FINAL AL LOG
# ------------------------------------------------------------------------------
END_TS=$(date +%s)
DUR=$((END_TS - START_TS))

logecho "============================================================"
if [ "$STATUS_OK" = "1" ]; then
    logecho " ✅ BACKUP COMPLETADO ($TAG) dur=${DUR}s"
else
    logecho " ⚠️  BACKUP FINALIZADO con fallos ($TAG) dur=${DUR}s — revisa $LOG_FILE"
fi
logecho " Tamaños: db=${SIZES[db]:-0}b files=${SIZES[files]:-0}b keyring=${SIZES[keyring]:-0}b"
logecho " Ruta:    $SNAPSHOTS_DIR"
logecho "============================================================"

# Estado final para sec-logs + restore: escribir último run OK/FAIL+ts a .state.
STATE_FILE="$BACKUP_ROOT/logs/state.txt"
cat << EOF > "$STATE_FILE"
last_run_ts=$START_TS
last_run_tag=$TAG
last_run_ok=$STATUS_OK
last_run_duration=$DUR
last_run_size_db=${SIZES[db]:-0}
last_run_size_files=${SIZES[files]:-0}
last_run_size_keyring=${SIZES[keyring]:-0}
daily_count=$COUNT_DAILY
retention_days=$RETENTION_DAYS
EOF
chmod 600 "$STATE_FILE"
chown root:root "$STATE_FILE"

exit $EXIT_CODE