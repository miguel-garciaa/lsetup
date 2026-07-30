#!/bin/bash
# ==============================================================================
# RESTORE INTERACTIVO DE BACKUPS (v1)
# Uso: sudo restore.sh — prompt al usuario por fecha/qué restaurar.
# Tier único: daily/ (retención FLAT $RETENTION_DAYS, no weekly/monthly).
# No destructivo por defecto: copia previas a /var/lib/.system-state/.restored-<ts>
# Doble confirmación (typear "RESTORE") antes de aplicar.
# ==============================================================================

set -uo pipefail  # NO -e: si un paso falla, reportar y parar man cleaner.

if [ "$EUID" -ne 0 ]; then
    echo "⚠️  Ejecuta como root o con sudo."
    exit 1
fi

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/pgsql-18/bin:$PATH"

CONF=/etc/backup.conf
if [ ! -f "$CONF" ]; then
    echo "❌ Falta $CONF. Ejecuta: sudo bash backup-install.sh" >&2
    exit 1
fi
# shellcheck disable=SC1091
. "$CONF"

: "${BACKUP_ROOT:=/var/lib/.system-state}"
: "${SNAPSHOTS_DIR:=$BACKUP_ROOT/snapshots}"
: "${KEY_FILE:=/root/.backup-key}"

NOW=$(date '+%Y%m%d-%H%M%S')
RESTORE_LOG="$BACKUP_ROOT/logs/restore-$NOW.log"
mkdir -p "$(dirname "$RESTORE_LOG")"
chmod 700 "$(dirname "$RESTORE_LOG")"

ok=0; fail=0
log() { echo "[$(date '+%F %T')] $*" | tee -a "$RESTORE_LOG" >&2; }

log "============================================================"
log " 🔄 RESTORE INICIADO ($NOW) host=$(hostname)"
log "============================================================"

# ------------------------------------------------------------------------------
# PASO 1: tier único (flat 14d, solo daily/)
# ------------------------------------------------------------------------------
echo ""
TIER="daily"
TIER_DIR="$SNAPSHOTS_DIR/$TIER"
if [ ! -d "$TIER_DIR" ]; then
    log "❌ $TIER_DIR no existe. Aborto."; exit 1
fi
COUNT=$(ls -1 "$TIER_DIR" 2>/dev/null | grep -cE '^state-[0-9]{8}-[0-9]{4}\.(db|dat|keyring)$' || echo 0)
echo "Tier único: daily/ (retención flat, $COUNT snapshots disponibles)"

# ------------------------------------------------------------------------------
# PASO 2: Elegir fecha (TAG = YYYYMMDD-HHMM)
# ------------------------------------------------------------------------------
echo ""
echo "Fechas disponibles en daily/ (ordenadas desc):"
# Listar TAGs únicos (cada TAG puede tener 3 archivos: .db .dat .keyring).
ls -1 "$TIER_DIR" | grep -oE 'state-[0-9]{8}-[0-9]{4}' | sort -u -r | head -20
echo ""
read -rp "TAG exacto (ej. 20260730-0200): " TAG
if [ -z "$TAG" ] || ! [[ "$TAG" =~ ^[0-9]{8}-[0-9]{4}$ ]]; then
    log "❌ TAG '$TAG' formato inválido. Use YYYYMMDD-HHMM. Aborto."; exit 1
fi

# Verificar qué archivos existen para ese TAG.
declare -A AVAIL
for ext in db dat keyring; do
    if [ -f "$TIER_DIR/state-$TAG.$ext" ]; then
        AVAIL[$ext]=1
        echo "  ✅ state-$TAG.$ext EXISTE ($(numfmt --to=iec "$(stat -c %s "$TIER_DIR/state-$TAG.$ext")" 2>/dev/null))"
    else
        AVAIL[$ext]=0
        echo "  ⚠️  state-$TAG.$ext AUSENTE"
    fi
done

if [ "${AVAIL[db]:-0}" = "0" ] && [ "${AVAIL[dat]:-0}" = "0" ] && [ "${AVAIL[keyring]:-0}" = "0" ]; then
    log "❌ TAG $TAG no tiene ningún snapshot en $TIER_DIR. Aborto."; exit 1
fi

# ------------------------------------------------------------------------------
# PASO 3: Elegir qué restaurar
# ------------------------------------------------------------------------------
echo ""
echo "Qué restaurar:"
echo "  1. Solo DB          (.db → PostgreSQL)"
echo "  2. Solo FILES       (.dat → Laravel storage/public/artisan/.env.no)"
echo "  3. Solo SECRETS     (.keyring → .env + configs sensibles)"
echo "  4. TODO             (DB + FILES + SECRETS)"
echo "  5. Cancelar"
read -rp "Opción [1-5]: " WHAT

case "$WHAT" in
    1) RESTORE_DB=1; RESTORE_FILES=0; RESTORE_SECRETS=0;;
    2) RESTORE_DB=0; RESTORE_FILES=1; RESTORE_SECRETS=0;;
    3) RESTORE_DB=0; RESTORE_FILES=0; RESTORE_SECRETS=1;;
    4) RESTORE_DB=1; RESTORE_FILES=1; RESTORE_SECRETS=1;;
    5) log "Cancelado por usuario."; exit 0;;
    *) log "❌ Opción '$WHAT' inválida. Aborto."; exit 1;;
esac

# Validar que exista lo pedido.
[ "$RESTORE_DB" = "1" ] && [ "${AVAIL[db]:-0}" = "0" ] && { log "❌ Pediste DB pero .db ausente."; exit 1; }
[ "$RESTORE_FILES" = "1" ] && [ "${AVAIL[dat]:-0}" = "0" ] && { log "❌ Pediste FILES pero .dat ausente."; exit 1; }
[ "$RESTORE_SECRETS" = "1" ] && [ "${AVAIL[keyring]:-0}" = "0" ] && { log "❌ Pediste SECRETS pero .keyring ausente."; exit 1; }

# ------------------------------------------------------------------------------
# PASO 4: Doble confirmación — typear "RESTORE"
# ------------------------------------------------------------------------------
echo ""
echo "⚠️  ATENCIÓN — destruirá datos actuales del server en las áreas elegidas."
echo "    Antes de continuar:"
echo "      - Detén Octane:   sudo systemctl stop octane"
echo "      - Detén nginx:     sudo systemctl stop nginx"
[ "$RESTORE_DB" = "1" ] && echo "      - DB actual será reemplazada (pg_restore --clean)"
echo "      - Snapshot previo del estado actual se guarda en:"
echo "        $BACKUP_ROOT/.restored-$NOW/"
echo ""
read -rp "Para confirmar typea 'RESTORE' (otra cosa aborta): " CONFIRM
if [ "$CONFIRM" != "RESTORE" ]; then
    log "Cancelado (no se escribió 'RESTORE')."
    exit 0
fi

# Segunda confirmación (safety belt).
read -rp "ÚLTIMA confirmación. Reescribe 'RESTORE': " CONFIRM2
if [ "$CONFIRM2" != "RESTORE" ]; then
    log "Cancelado."; exit 0
fi

# ------------------------------------------------------------------------------
# Pre-fixtures: guardar dir actual a .restored-$NOW antes de pisar.
# ------------------------------------------------------------------------------
BACKUP_PRE="$BACKUP_ROOT/.restored-$NOW"
mkdir -p "$BACKUP_PRE"
chmod 700 "$BACKUP_PRE"
log ">> Backup previo al restore en: $BACKUP_PRE"

# Detectar LARAVEL_DIR.
ENV_FILE=$(find /var/www -maxdepth 2 -mindepth 2 -name '.env' -type f 2>/dev/null | head -1)
if [ -n "$ENV_FILE" ]; then
    LARAVEL_DIR=$(dirname "$ENV_FILE")
    [ ! -f "$LARAVEL_DIR/artisan" ] && LARAVEL_DIR=""
fi

# ------------------------------------------------------------------------------
# PASO 5: RESTORE .db — PostgreSQL
# ------------------------------------------------------------------------------
if [ "$RESTORE_DB" = "1" ]; then
    log ">> [1/?] Restore DB desde $TIER_DIR/state-$TAG.db..."
    SRC="$TIER_DIR/state-$TAG.db"

    # Creds DB actuales de .env (puede que el user/pass cambie respecto snapshot).
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
    if [ -n "$LARAVEL_DIR" ] && [ -f "$LARAVEL_DIR/.env" ]; then
        DB_NAME=$(read_env DB_DATABASE)
        DB_USER=$(read_env DB_USERNAME)
        DB_PASS=$(read_env DB_PASSWORD)
    fi
    if [ -z "${DB_NAME:-}" ] || [ -z "${DB_USER:-}" ]; then
        log "   ⚠️  Sin creds DB en .env actual. Pregunta manualmente."
        read -rp "   DB name: " DB_NAME
        read -rp "   DB user (de Laravel): " DB_USER
        read -rsp "   DB pass: " DB_PASS; echo
    fi

    # 1) Test gzip + pg_restore --list valida headers antes.
    if ! gzip -t "$SRC" 2>"$BACKUP_ROOT/tmp/rdb.err"; then
        log "   ❌ gzip -t falla: $(cat "$BACKUP_ROOT/tmp/rdb.err" 2>/dev/null)"; fail=1
    elif ! gunzip -c "$SRC" | pg_restore --list >/dev/null 2>&1; then
        log "   ❌ pg_restore --list falla (dump corrupto)"; fail=1
    else
        # 2) Backup de DB actual a .restored-$NOW/dump-pre-restore.db.gz
        log "   >> Respaldo DB actual..."
        if PGPASSWORD="$DB_PASS" pg_dump --format=custom --host=127.0.0.1 --username="$DB_USER" "$DB_NAME" 2>/dev/null \
            | gzip -9c > "$BACKUP_PRE/dump-pre-restore.db.gz"
        then
            log "   >> Backup pre-restore: $BACKUP_PRE/dump-pre-restore.db.gz"
        else
            log "   ⚠️  Backup DB actual falló. Continúo pero asume riesgo."
        fi
        # 3) pg_restore --clean --if-exists (no drop DB completa, borra y recrea tablas).
        log "   >> pg_restore --clean --if-exists..."
        if gunzip -c "$SRC" | PGPASSWORD="$DB_PASS" pg_restore --clean --if-exists \
            --no-owner --no-privileges --dbname="$DB_NAME" --host=127.0.0.1 \
            --username="$DB_USER" 2>"$BACKUP_ROOT/tmp/rdb2.err"
        then
            log "   ✅ DB restaurada."
            ok=1
        else
            log "   ⚠️  pg_restore terminó con avisos (común con --clean). Detalle:"
            tail -5 "$BACKUP_ROOT/tmp/rdb2.err" | tee -a "$RESTORE_LOG"
            # No necesariamente fatal: pg_restore reporta "WARNING" por DROP IF EXISTS.
        fi
    fi
fi

# ------------------------------------------------------------------------------
# PASO 6: RESTORE .dat — Laravel files
# ------------------------------------------------------------------------------
if [ "$RESTORE_FILES" = "1" ]; then
    log ">> [2/?] Restore FILES desde $TIER_DIR/state-$TAG.dat..."
    SRC="$TIER_DIR/state-$TAG.dat"
    if [ -z "$LARAVEL_DIR" ]; then
        log "   ⚠️  No se detectó LARAVEL_DIR actual."
        read -rp "   Ruta destino (/var/www/<dir>): " LARAVEL_DIR
    fi
    if [ ! -d "$LARAVEL_DIR" ]; then
        log "   ❌ $LARAVEL_DIR no existe. Abortar files."; fail=1
    elif ! gzip -t "$SRC" 2>"$BACKUP_ROOT/tmp/rf.err"; then
        log "   ❌ gzip -t falla: $(cat "$BACKUP_ROOT/tmp/rf.err" 2>/dev/null)"; fail=1
    elif ! tar -tzf "$SRC" >/dev/null 2>&1; then
        log "   ❌ tar header corrupto"; fail=1
    else
        # Respaldo de /var/www actual.
        log "   >> Backup previo de directorio actual..."
        mv "$LARAVEL_DIR" "$BACKUP_PRE/$(basename "$LARAVEL_DIR").pre-restore" 2>/dev/null || true
        # Restaurar tar en /var/www (mantiene dirname).
        log "   >> Extrayendo tar a /var/www..."
        mkdir -p /var/www
        if tar -xzf "$SRC" -C /var/www 2>"$BACKUP_ROOT/tmp/rf2.err"; then
            # Restaurar .env actual (tar.dat excluye .env; lo dejamos o viene de secrets).
            if [ -f "$BACKUP_PRE/$(basename "$LARAVEL_DIR").pre-restore/.env" ]; then
                cp -a "$BACKUP_PRE/$(basename "$LARAVEL_DIR").pre-restore/.env" "$LARAVEL_DIR/.env"
            fi
            # Owner Laravel (usuario laravel segun setup.sh).
            LARAVEL_USER=$(stat -c '%U' "$BACKUP_PRE/$(basename "$LARAVEL_DIR").pre-restore" 2>/dev/null | head -1)
            [ -z "$LARAVEL_USER" ] && LARAVEL_USER="laravel"
            chown -R "$LARAVEL_USER:$LARAVEL_USER" "$LARAVEL_DIR"
            chmod 600 "$LARAVEL_DIR/.env" 2>/dev/null || true
            # SELinux relabel (vars de setup.sh: storage, bootstrap/cache).
            restorecon -R "$LARAVEL_DIR" 2>/dev/null || true
            log "   ✅ FILES restaurados a $LARAVEL_DIR (owner $LARAVEL_USER:$LARAVEL_USER, SELinux relabeled)."
        else
            log "   ❌ tar -xzf falló: $(cat "$BACKUP_ROOT/tmp/rf2.err" 2>/dev/null)"; fail=1
        fi
    fi
fi

# ------------------------------------------------------------------------------
# PASO 7: RESTORE .keyring — .env + configs sensibles (DECRYPT GPG)
# ------------------------------------------------------------------------------
if [ "$RESTORE_SECRETS" = "1" ]; then
    log ">> [3/?] Restore SECRETS desde $TIER_DIR/state-$TAG.keyring..."
    SRC="$TIER_DIR/state-$TAG.keyring"
    if [ ! -f "$KEY_FILE" ]; then
        log "   ❌ No existe passphrase $KEY_FILE. Imposible desencriptar .keyring."; fail=1
    elif ! gpg --list-packets "$SRC" >/dev/null 2>&1; then
        log "   ❌ GPG packets corruptos: $SRC"; fail=1
    else
        # Extraer a tmp.
        TMP_SECRETS=$(mktemp -d)
        chmod 700 "$TMP_SECRETS"
        log "   >> Decrypt GPG + extraer tar a $TMP_SECRETS..."
        if gpg --batch --quiet --no-tty --pinentry-mode loopback \
                --passphrase-file "$KEY_FILE" --decrypt "$SRC" 2>"$BACKUP_ROOT/tmp/rs1.err" \
            | tar -x -C "$TMP_SECRETS" 2>"$BACKUP_ROOT/tmp/rs2.err"
        then
            # Backup previo de configs sensibles actuales a $BACKUP_PRE/sec-pre-restore.tar.gz.
            log "   >> Backup previo de configs sensibles actuales..."
            tar -czf "$BACKUP_PRE/sec-pre-restore.tar.gz" \
                /etc/ssh/sshd_config.d /etc/pam.d/sshd /etc/redis/redis.conf \
                /etc/fail2ban/jail.local /etc/sysctl.d/99-* \
                /etc/security/limits.d/99-* /etc/modprobe.d/CIS-* \
                /etc/sudoers.d/99-* /etc/systemd/system/octane.service \
                /etc/dnf/automatic.conf /etc/security/pwquality.conf \
                /etc/systemd/coredump.conf.d /etc/nginx/conf.d /etc/nginx/snippets \
                /usr/local/bin/sec-logs 2>/dev/null || true
            # Copiar archivos del tar extraído a sus rutas absolutas originales.
            log "   >> Aplicando configs desde snapshot al filesystem..."
            ( cd "$TMP_SECRETS" && find . -type f ! -name '.gitignore' | while read -r rel; do
                # rel empieza con './' → strips.
                rel="${rel#./}"
                dst="/$rel"
                mkdir -p "$(dirname "$dst")"
                cp -af "$TMP_SECRETS/$rel" "$dst"
            done ) 2>>"$RESTORE_LOG"
            # Permisos estrictos sobre .env y 00-hardening.conf.
            [ -f /var/www/*/.env ] 2>/dev/null && chown laravel:laravel /var/www/*/.env 2>/dev/null && chmod 600 /var/www/*/.env
            chmod 600 /etc/ssh/sshd_config.d/00-hardening.conf 2>/dev/null || true
            chmod 440 /etc/sudoers.d/99-* 2>/dev/null || true
            chmod 600 /root/.backup-key 2>/dev/null || true
            # SELinux relabel configs críticos.
            restorecon -Rv /etc/ssh /etc/pam.d /etc/redis /etc/sudoers.d /etc/nginx 2>/dev/null || true
            # Validar sintaxis críticas antes de restart.
            sshd -t 2>"$BACKUP_ROOT/tmp/sshd_test.err" || { log "   ⚠️  sshd -t falla tras restore: $(cat "$BACKUP_ROOT/tmp/sshd_test.err" 2>/dev/null)"; }
            visudo -c 2>/dev/null || { log "   ⚠️  visudo -c falla tras restore."; }
            nginx -t 2>/dev/null || { log "   ⚠️  nginx -t falla tras restore."; }
            log "   ✅ SECRETS restaurados. Reinicia servicios cd:"
            log "        sudo systemctl restart sshd nginx redis postgresql-18 fail2ban auditd octane"
            ok=1
        else
            log "   ❌ Decrypt/extract falló. gpg=$(cat "$BACKUP_ROOT/tmp/rs1.err" 2>/dev/null) tar=$(cat "$BACKUP_ROOT/tmp/rs2.err" 2>/dev/null)"; fail=1
        fi
        rm -rf "$TMP_SECRETS" 2>/dev/null || true
    fi
fi

# ------------------------------------------------------------------------------
# PASO 8: Resumen final
# ------------------------------------------------------------------------------
log "============================================================"
if [ "$fail" = "0" ] && [ "$ok" = "1" ]; then
    log " ✅ RESTORE COMPLETADO ($TAG tier=$TIER what=$WHAT)"
    log " Backups previos en: $BACKUP_PRE"
    log " Log detallado:      $RESTORE_LOG"
    log "============================================================"
    log " ACCIONES POST-RESTORE obligatorias:"
    log "   sudo systemctl restart octane nginx"
    [ "$RESTORE_SECRETS" = "1" ] && log "   sudo systemctl restart sshd redis fail2ban auditd"
    log "   sudo sec-logs    (verificar estado tras restore)"
    log "   Verifica web manualmente en navegador"
    log "============================================================"
    exit 0
else
    log " ⚠️  RESTORE PARCIAL/FALLIDO. fail=$fail ok=$ok"
    log " Revisa $RESTORE_LOG y $BACKUP_PRE"
    log "============================================================"
    exit 1
fi