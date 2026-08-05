#!/bin/bash
# ==============================================================================
# VERIFICACIÓN DE INTEGRIDAD DE BACKUPS (v1)
# Cron dom 04:30 (/etc/cron.d/backup). Comprueba TODOS los snapshots en
# daily/. Retención flat (no weekly/monthly). Reporta a $LOG_FILE.
# Sin mail (postfix fuera de scope); monitorizar via sec-logs.
# Exit 0 si todo OK, 1 si al menos 1 fail.
# ==============================================================================

set -uo pipefail   # NO -e: queremos reportar todos los fallos, no abortar al 1ero.

if [ "$EUID" -ne 0 ]; then
  echo "[WARN]  Ejecuta este script como root o con sudo."
  exit 1
fi

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/pgsql-18/bin:$PATH"

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

START_TS=$(date +%s)
TAG=$(date '+%Y%m%d-%H%M')
TOTAL=0; OK=0; FAIL=0
log() { echo "[$(date '+%F %T')] $*" >> "$LOG_FILE"; }
logecho() { echo "$@"; log "$@"; }

logecho "============================================================"
logecho " [SCAN] VERIFICACIÓN BACKUPS ($TAG) empezando..."
logecho "============================================================"

if [ ! -f "$KEY_FILE" ]; then
  logecho "[ERROR] No existe passphrase $KEY_FILE. No puedo test .keyring."
fi

# Verifica 1 archivo dado su path; decide test según extensión.
verify_one() {
  local f="$1"
  TOTAL=$((TOTAL+1))
  local base=$(basename "$f")
  case "$base" in
      *.db)
          # gzip -t valida integrity gzip. gunzip -c | pg_restore --list valida header PG.
          if gzip -t "$f" 2>/dev/null && gunzip -c "$f" 2>/dev/null | pg_restore --list >/dev/null 2>&1; then
              OK=$((OK+1))
              logecho "  [OK] $base (gzip+pg_restore --list OK)"
          else
              FAIL=$((FAIL+1))
              logecho "  [ERROR] $base (gzip -t o pg_restore --list FALLÓ)"
          fi
          ;;
      *.dat)
          if gzip -t "$f" 2>/dev/null && tar -tzf "$f" >/dev/null 2>&1; then
              OK=$((OK+1))
              logecho "  [OK] $base (gzip+tar header OK)"
          else
              FAIL=$((FAIL+1))
              logecho "  [ERROR] $base (gzip -t o tar -tzf FALLÓ)"
          fi
          ;;
      *.keyring)
          # gpg --list-packets valida container AES256 sin desencriptar contenido.
          if [ -f "$KEY_FILE" ]; then
              if gpg --batch --quiet --no-tty --passphrase-file "$KEY_FILE" \
                     --pinentry-mode loopback --decrypt "$f" 2>/dev/null | tar -t >/dev/null 2>&1
              then
                  OK=$((OK+1))
                  logecho "  [OK] $base (GPG decrypt + tar -t OK)"
              else
                  FAIL=$((FAIL+1))
                  logecho "  [ERROR] $base (GPG decrypt o tar -t FALLÓ — ¿passphrase incorrecta?)"
              fi
          else
              # Sin key: solo test que el container GPG es parseable (no contenido).
              if gpg --list-packets "$f" >/dev/null 2>&1; then
                  OK=$((OK+1))
                  logecho "  [OK] $base (GPG packets OK, contenido no validado sin passphrase)"
              else
                  FAIL=$((FAIL+1))
                  logecho "  [ERROR] $base (GPG --list-packets FALLÓ: container corrupto)"
              fi
          fi
          ;;
      *.sha256)
          # Skip archivos de checksum (no son snapshots). Ya contados como par de su snapshot.
          TOTAL=$((TOTAL-1))
          ;;
      *)
          TOTAL=$((TOTAL-1))
          ;;
  esac

  # Verificar SHA256 pareja si existe (.sha256 al lado).
  local sha_file="${f}.sha256"
  if [ -f "$sha_file" ] && [[ "$base" != *.sha256 ]]; then
      if (cd "$(dirname "$f")" && sha256sum -c "$(basename "$sha_file")" >/dev/null 2>&1); then
          :  # OK silencioso; el archivo ya se reportó arriba.
      else
          FAIL=$((FAIL+1))
          TOTAL=$((TOTAL+1))   # contar checksum mal como fallo extra.
          logecho "  [ERROR] $base (SHA256 mismatch respecto $sha_file)"
      fi
  fi
}

# Recorrer solo daily/ (retención flat, no weekly/monthly).
for tier in daily; do
  DIR="$SNAPSHOTS_DIR/$tier"
  if [ ! -d "$DIR" ]; then continue; fi
  COUNT_TIER=$(ls -1 "$DIR" 2>/dev/null | grep -cE '^state-[0-9]{8}-[0-9]{4}\.(db|dat|keyring)$' || echo 0)
  if [ "$COUNT_TIER" = "0" ]; then continue; fi
  logecho ">> Verificando daily/ ($COUNT_TIER snapshots)..."
  # Process substitution (no pipe) para que verify_one mutar OK/FAIL/TOTAL
  # fuera del subshell. Si usáramos pipe el while se ejecuta en subshell
  # y las variables NO se propagarían al reporte final.
  while read -r f; do
      verify_one "$f"
  done < <(find "$DIR" -maxdepth 1 -type f -name 'state-*' ! -name '*.sha256' | sort)
done

# Estado final a /var/lib/.system-state/logs/verify.state (lo lee sec-logs).
VSTATE="$BACKUP_ROOT/logs/verify.state"
cat << EOF > "$VSTATE"
last_verify_ts=$START_TS
last_verify_tag=$TAG
last_verify_ok=$([ "$FAIL" = "0" ] && echo 1 || echo 0)
last_verify_total=$TOTAL
last_verify_pass=$OK
last_verify_fail=$FAIL
EOF
chmod 600 "$VSTATE"

logecho "============================================================"
if [ "$FAIL" = "0" ]; then
  logecho " [OK] VERIFY OK: $OK/$TOTAL snapshots íntegros"
else
  logecho " [WARN]  VERIFY PARCIAL: OK=$OK FAIL=$FAIL TOTAL=$TOTAL (revisar $LOG_FILE)"
fi
logecho " Estado: $VSTATE"
logecho "============================================================"

[ "$FAIL" = "0" ]
exit $?