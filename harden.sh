#!/bin/bash
set -e

# ==============================================================================
# LARAVEL HARDEN — capa app (Fase 3 plan anti-ataques web)
# Idempotente. Solo reporta código PHP ($fillable, rutas); parchea .env +
# systemd EnvironmentFile (mirror aditivo) + cron audit. NO toca APP_KEY.
# Reversible: clear.sh sección 17 elimina envfile/cron.
# Panic guards: as_laravel siempre, chown laravel:laravel tras .env, NO
# SESSION_ENCRYPT sin ventana confirmada (invalida sesiones activas).
# ==============================================================================

if [ "$EUID" -ne 0 ]; then
  echo "[WARN] Ejecuta este script como root o con sudo."
  exit 1
fi

LARAVEL_USER="laravel"
LARAVEL_HOME="/var/lib/laravel"

# Detección proyecto Laravel.
LARAVEL_DIR=""
ENV_FILE=$(find /var/www -maxdepth 2 -mindepth 2 -name '.env' -type f 2>/dev/null | head -1)
if [ -n "$ENV_FILE" ]; then
  CANDIDATE=$(dirname "$ENV_FILE")
  if [ -f "$CANDIDATE/artisan" ] && [ -d "$CANDIDATE/vendor" ]; then
      LARAVEL_DIR="$CANDIDATE"
  fi
fi
if [ -z "$LARAVEL_DIR" ]; then
  echo "[ERROR] No se detectó proyecto Laravel bajo /var/www. Aborto (este script es app-layer)."
  exit 1
fi

as_laravel() {
  sudo -u "$LARAVEL_USER" env HOME="$LARAVEL_HOME" COMPOSER_HOME="$LARAVEL_HOME/.composer" \
      bash -lc "cd '$LARAVEL_DIR' && $1"
}
set_env_var() {
  local key="$1" val="$2" file="$3"
  grep -v "^${key}=" "$file" > "$file.tmp" 2>/dev/null || true
  printf '%s=%s\n' "$key" "$val" >> "$file.tmp"
  mv "$file.tmp" "$file"
}

ENV_PATH="$LARAVEL_DIR/.env"

echo "=========================================================================="
echo " LARAVEL HARDEN (capa app) — $LARAVEL_DIR"
echo "=========================================================================="

# ------------------------------------------------------------------------------
# 1. AUDIT $fillable / $guarded (solo reporta, NO toca código)
# ------------------------------------------------------------------------------
echo ">> [1/6] Auditando \$fillable / \$guarded en app/Models/*.php..."
MODELS_DIR="$LARAVEL_DIR/app/Models"
if [ -d "$MODELS_DIR" ]; then
  FILLABLE_ISSUES=0
  GUARDED_ISSUES=0
  while IFS= read -r model; do
      [ -f "$model" ] || continue
      fname=$(basename "$model")
      if grep -qE '\$guarded[[:space:]]*=[[:space:]]*\[\][[:space:]]*;' "$model" 2>/dev/null; then
          echo "   [ERROR] $fname: \$guarded = [] (mass-assignment abierto)"
          GUARDED_ISSUES=$((GUARDED_ISSUES + 1))
      elif ! grep -qE '\$fillable[[:space:]]*=' "$model" 2>/dev/null; then
          echo "   [WARN]  $fname: sin \$fillable definido (revisar asignación manual)"
          FILLABLE_ISSUES=$((FILLABLE_ISSUES + 1))
      fi
  done < <(find "$MODELS_DIR" -maxdepth 2 -name '*.php' -type f 2>/dev/null)
  echo "   >> Resumen: $GUARDED_ISSUES con \$guarded=[], $FILLABLE_ISSUES sin \$fillable."
  echo "   >> Tú decides el parche (Fase 4 manual). Script no edita código PHP."
else
  echo "   >> $MODELS_DIR no existe. Skip audit $fillable."
fi

# ------------------------------------------------------------------------------
# 2. APP_DEBUG=false (forzar) + APP_ENV consistente
# ------------------------------------------------------------------------------
echo ">> [2/6] Verificando APP_DEBUG=false en .env..."
CURRENT_DEBUG=$(awk -F= '/^APP_DEBUG=/{print $2; exit}' "$ENV_PATH" 2>/dev/null)
if [ "$CURRENT_DEBUG" != "false" ]; then
  echo "   [WARN]  APP_DEBUG=$CURRENT_DEBUG → forzando false (prod OBLIGATORIO)."
  cp -a "$ENV_PATH" "${ENV_PATH}.bak.$(date +%s)"
  set_env_var "APP_DEBUG" "false" "$ENV_PATH"
  chown "$LARAVEL_USER":"$LARAVEL_USER" "$ENV_PATH"
  chmod 600 "$ENV_PATH"
else
  echo "   >> APP_DEBUG=false OK."
fi

# ------------------------------------------------------------------------------
# 3. Session hardening: secure cookie + SameSite=lax + (prompt) ENCRYPT
# ------------------------------------------------------------------------------
echo ">> [3/6] Session hardening (SecureCookie + SameSite=lax)..."
cp -a "$ENV_PATH" "${ENV_PATH}.bak.$(date +%s)" 2>/dev/null || true
set_env_var "SESSION_SECURE_COOKIE" "true" "$ENV_PATH"
set_env_var "SESSION_SAME_SITE" "lax" "$ENV_PATH"
echo "   >> SESSION_SECURE_COOKIE=true + SESSION_SAME_SITE=lax."

# SESSION_ENCRYPT invalida sesiones activas → ventana. Recomendado=ventana.
echo ""
echo "   [WARN]  SESSION_ENCRYPT=true INVALIDA todas las sesiones activas (silent re-login)."
echo "       Skill recomendó ventana. ¿Aplicar ahora silenciosamente (re-login) o posponer?"
if [ -z "$ENC_CONFIRM" ]; then
  read -rp "       Aplicar SESSION_ENCRYPT ahora? [s/N]: " ENC_CONFIRM
fi
ENC_CONFIRM="${ENC_CONFIRM:-N}"
ENC_CONFIRM="${ENC_CONFIRM,,}"
if [[ "$ENC_CONFIRM" == "s" || "$ENC_CONFIRM" == "si" || "$ENC_CONFIRM" == "sí" ]]; then
  set_env_var "SESSION_ENCRYPT" "true" "$ENV_PATH"
  echo "   >> SESSION_ENCRYPT=true aplicado (usuarios re-login)."
else
  echo "   >> SESSION_ENCRYPT pospuesto. Queda sin setear (default Laravel=false)."
fi
chown "$LARAVEL_USER":"$LARAVEL_USER" "$ENV_PATH"
chmod 600 "$ENV_PATH"

# ------------------------------------------------------------------------------
# 4. Throttle rutas sensibles (solo reporta + snippets sugeridos)
# ------------------------------------------------------------------------------
echo ">> [4/6] Throttle rutas sensibles (reporte — no auto-parchea PHP)..."
echo "   login.sh ya aplica throttle:5,1 al /login. Verifica presentes en routes/web.php:"
ROUTES_WEB="$LARAVEL_DIR/routes/web.php"
ROUTES_API="$LARAVEL_DIR/routes/api.php"
if [ -f "$ROUTES_WEB" ]; then
  grep -qE 'throttle:5,1' "$ROUTES_WEB" 2>/dev/null \
      && echo "     [OK] routes/web.php tiene throttle:5,1" \
      || echo "     [WARN]  routes/web.php SIN throttle:5,1 (añade ->middleware('throttle:5,1') a /login y /password/*)"
else
  echo "     - routes/web.php no encontrado."
fi
if [ -f "$ROUTES_API" ]; then
  grep -qE 'throttle:60,1|throttle:[0-9]+,1' "$ROUTES_API" 2>/dev/null \
      && echo "     [OK] routes/api.php tiene throttle" \
      || echo "     [WARN]  routes/api.php SIN throttle (añade ->middleware('throttle:60,1') al grupo api)"
else
  echo "     - routes/api.php no encontrado (app sin API REST)."
fi
# Google OAuth callback (login.sh): verificar/configurar throttle reset.
if grep -q 'google' "$ROUTES_WEB" 2>/dev/null; then
  grep -qE 'auth/google.*throttle|password/reset.*throttle' "$ROUTES_WEB" 2>/dev/null \
      && echo "     [OK] rutas google/reset con throttle" \
      || echo "     [WARN]  auth/google/callback o password/reset SIN throttle (recomendado throttle:5,1)"
fi
echo "   >> Script NO edita rutas PHP (riesgo de romper la definición). Tú parcheas (Fase 4)."

# ------------------------------------------------------------------------------
# 5. Secretos → systemd EnvironmentFile (mirror aditivo, root:root 600)
# ------------------------------------------------------------------------------
echo ">> [5/6] Migrando secretos a /etc/laravel/env (systemd EnvironmentFile)..."
mkdir -p /etc/laravel
chmod 755 /etc/laravel
SYSTEMD_ENV=/etc/laravel/env

# Mirror aditivo: copia credenciales de red al EnvironmentFile (root-only).
# NO se quitan de .env: artisan/composer CLI leen .env directo (fuera de systemd);
# si las quitáramos, migrate/tinker rompen. EnvironmentFile gana en runtime Octane
# (Dotenv no sobreescribe env real). Fase 2 (strip .env) requeriría wrapper artisan.
SECRET_PATTERN='(_PASSWORD=|_SECRET=|_TOKEN=|^APP_KEY=)'
cp -a "$ENV_PATH" "${ENV_PATH}.bak.$(date +%s)" 2>/dev/null || true
# Extraer líneas secret (KEY=value) sin comentarios ni vacías, sin expandir.
awk -v p="$SECRET_PATTERN" 'NF && $0 !~ /^#/ && $0 ~ p' "$ENV_PATH" > "$SYSTEMD_ENV" 2>/dev/null || true
# Sanitizar: quitar comillas envolventes (systemd EnvironmentFile las trata literal).
sed -i -E 's/^([A-Za-z_][A-Za-z0-9_]*)="([^"]*)"/\1=\2/; s/^([A-Za-z_][A-Za-z0-9_]*)='"'"'([^'"'"']*)'"'"'/\1=\2/' "$SYSTEMD_ENV" 2>/dev/null || true
chown root:root "$SYSTEMD_ENV"
chmod 600 "$SYSTEMD_ENV"
restorecon -v "$SYSTEMD_ENV" 2>/dev/null || true
echo "   >> /etc/laravel/env (root:root 600): $(wc -l < "$SYSTEMD_ENV" 2>/dev/null) claves espejadas."

# Drop-in octane.service → EnvironmentFile (idempotente).
DROPIN_DIR=/etc/systemd/system/octane.service.d
mkdir -p "$DROPIN_DIR"
if ! grep -q "EnvironmentFile=/etc/laravel/env" "$DROPIN_DIR/secrets.conf" 2>/dev/null; then
  cat << 'EOF' > "$DROPIN_DIR/secrets.conf"
[Service]
EnvironmentFile=/etc/laravel/env
EOF
fi
systemctl daemon-reload
echo "   >> Drop-in octane.service.d/secrets.conf creado."
# Re-cache config: secciones 2/3 tocaron .env (APP_DEBUG, SESSION_*).
# EnvironmentFile de systemd sobreescribe SECRETOS en runtime Octane, pero
# config:cache congela el resto (SESSION_*, APP_DEBUG, conexiones DB). Sin
# re-cache, Octane ignora los cambios → sesiones sin SecureCookie, debug on.
SKIP_OCTANE=0
if [ -f "$LARAVEL_DIR/artisan" ]; then
  CFG_LOG=$(mktemp)
  if as_laravel "php artisan config:cache" >"$CFG_LOG" 2>&1; then
      sed 's/^/      /' "$CFG_LOG"
      echo "   >> config:cache OK (aplica cambios .env de secciones 2/3)."
  else
      sed 's/^/      /' "$CFG_LOG"
      echo "   [WARN]  config:cache FALLÓ. NO se reinicia octane (config anterior sigue activo)."
      echo "      Revisa .env: sudo -u $LARAVEL_USER bash -lc 'cd $LARAVEL_DIR && php artisan config:clear'"
      SKIP_OCTANE=1
  fi
  rm -f "$CFG_LOG"
else
  echo "   >> artisan ausente; skip config:cache."
  SKIP_OCTANE=1
fi
# Reiniciar octane solo si está activo y config:cache pasó (no fallar si no instalado).
if [ "$SKIP_OCTANE" -eq 1 ]; then
  echo "   >> octane NO reiniciado (config:cache skip/falló)."
elif systemctl list-unit-files 2>/dev/null | grep -q '^octane.service'; then
  systemctl restart octane 2>/dev/null && echo "   >> octane reiniciado (secrets via EnvironmentFile)." \
      || echo "   [WARN]  octane NO reinició. Revisa: systemctl status octane. Rollback: rm drop-in + daemon-reload."
else
  echo "   >> octane.service no presente (setup.sh sin ejecutar). Drop-in esperará a setup."
fi

# ------------------------------------------------------------------------------
# 6. Cron semanal composer audit + npm audit → log
# ------------------------------------------------------------------------------
echo ">> [6/6] Activando cron semanal composer/npm audit..."
CRON_FILE=/etc/cron.d/laravel-audit
cat << EOF > "$CRON_FILE"
# === laravel-harden.sh — audit semanal dependencias ===
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
# Domingo 03:30 — composer audit (PHP) + npm audit (front).
30 3 * * 0 root (cd "$LARAVEL_DIR" && sudo -u $LARAVEL_USER env HOME="$LARAVEL_HOME" COMPOSER_HOME="$LARAVEL_HOME/.composer" bash -lc 'composer audit --format=plain 2>&1; [ -f package-lock.json ] && (npm audit --audit-level=high 2>&1 || true)') >> /var/log/laravel-audit.log 2>&1
EOF
chmod 644 "$CRON_FILE"
touch /var/log/laravel-audit.log 2>/dev/null || true
chown root:root /var/log/laravel-audit.log 2>/dev/null || true
chmod 640 /var/log/laravel-audit.log 2>/dev/null || true
restorecon -v "$CRON_FILE" /var/log/laravel-audit.log 2>/dev/null || true
echo "   >> /etc/cron.d/laravel-audit activo (domingo 03:30 → /var/log/laravel-audit.log)."

# Audit inmediato (no aborta el script si composer/npm ausente).
echo "   >> Ejecutando audit inicial..."
as_laravel "(composer audit --format=plain 2>&1 || true) | head -50" >> /var/log/laravel-audit.log 2>&1 || true

# ------------------------------------------------------------------------------
# RESUMEN
# ------------------------------------------------------------------------------
echo "=========================================================================="
echo " LARAVEL HARDEN COMPLETADO"
echo "=========================================================================="
echo " App:           $LARAVEL_DIR"
echo " APP_DEBUG:     false (forzado)"
echo " Session:       SESSION_SECURE_COOKIE=true + SESSION_SAME_SITE=lax"
echo " SESSION_ENCRYPT: $([ "$ENC_CONFIRM" = "s" ] || [ "$ENC_CONFIRM" = "si" ] || [ "$ENC_CONFIRM" = "sí" ] && echo 'true (re-login)' || echo 'pospuesto')"
echo " EnvironmentFile: /etc/laravel/env (root:root 600) — mirror aditivo"
echo " Drop-in:       /etc/systemd/system/octane.service.d/secrets.conf"
echo " Cron audit:    /etc/cron.d/laravel-audit (dom 03:30) → /var/log/laravel-audit.log"
echo ""
echo " FASE 4 (manual, en VS Code/Cursor conectado al servidor):"
echo "   - app/Models/*: define \$fillable con todos los campos legítimos."
echo "     Quita \$guarded = [] de los modelos marcados arriba."
echo "   - app/Policies/*: crea Policy por modelo + authorize() en controllers."
echo "   - FormRequest con rules + enum en endpoints sensibles. Sin \$request->all()."
echo "   - Elimina DB::raw(\$userInput). Usa Eloquent bindings."
echo "   - Filament/Shield: revisa roles. Quita super_admin de users comunes."
echo "   - Telescope DISABLE en prod (APP_ENV=production)."
echo "   - Comentarios var_dump/dump/dd/ray fuera de prod."
echo ""
echo " ROLLBACK: sudo bash clear.sh (sección 17). Elimina envfile + dropin + cron."
echo " Backups .env: ls ${ENV_PATH}.bak.* (preservados antes de cada cambio)."
echo "=========================================================================="
echo " [WARN]  PANIC GUARD: NO se ha tocado APP_KEY (rotate invalida TODO)."
echo " [WARN]  EnvironmentFile es MIRROR: .env conserva secretos (artisan CLI)."
echo "     Fase 2 strip requiere wrapper artisan con env systemd (futuro)."
echo "=========================================================================="