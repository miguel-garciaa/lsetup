#!/bin/bash
set -e

# ==============================================================================
# FILAMENT 5 + USUARIO ADMIN (PANEL LIMPIO)
# A ejecutar DESPUÉS de setup.sh (requiere proyecto Laravel ya desplegado).
# Panel base desnudo: NO instala Shield, NO instala Spatie Media Library, NO
# configura roles/permisos. El admin se crea sin rol — el usuario decide cómo
# gestionar autorización del panel manualmente.
# ==============================================================================

echo "=========================================================================="
echo "    FILAMENT 5 + ADMIN (PANEL BASE)     "
echo "=========================================================================="

# ------------------------------------------------------------------------------
# 1. DETECCIÓN DE RUTA DEL PROYECTO LARAVEL
# ------------------------------------------------------------------------------
DEFAULT_DIR="/var/www/laravel1"
if [ -f "./.env" ]; then
  DEFAULT_DIR="$(pwd)"
fi

read -p "Ruta del proyecto Laravel [$DEFAULT_DIR]: " PROYECTO_DIR
PROYECTO_DIR=${PROYECTO_DIR:-$DEFAULT_DIR}

if [ ! -d "$PROYECTO_DIR" ] || [ ! -f "$PROYECTO_DIR/.env" ]; then
  echo "[ERROR] Error: No se encontró un proyecto Laravel con .env en $PROYECTO_DIR"
  exit 1
fi

cd "$PROYECTO_DIR"

# Composer/artisan NUNCA como root: mismo patrón que setup.sh (as_laravel).
# octane.service exporta APP_ENV=production: caches/route:cache se corren bajo
# ese mismo env para que el runtime coincida con lo cacheado.
LARAVEL_USER="laravel"
LARAVEL_HOME="/var/lib/laravel"
as_laravel() {
  sudo -u "$LARAVEL_USER" env HOME="$LARAVEL_HOME" COMPOSER_HOME="$LARAVEL_HOME/.composer" bash -lc "cd '$PROYECTO_DIR' && $*"
}

# ------------------------------------------------------------------------------
# 2. CREDENCIALES DEL ADMINISTRADOR DEL PANEL
# ------------------------------------------------------------------------------
echo "--------------------------------------------------------------------------"
echo " CONFIGURACIÓN DEL ADMINISTRADOR DEL PANEL"
echo "--------------------------------------------------------------------------"
read -p "Nombre usuario admin [Admin]: " ADMIN_NAME
ADMIN_NAME=${ADMIN_NAME:-Admin}
read -p "Correo del admin (obligatorio): " ADMIN_EMAIL
while [ -z "$ADMIN_EMAIL" ]; do read -p "Correo del admin (obligatorio): " ADMIN_EMAIL; done
read -rsp "Contraseña del admin (obligatoria): " ADMIN_PASS; echo
while [ -z "$ADMIN_PASS" ]; do read -rsp "Contraseña del admin (obligatoria): " ADMIN_PASS; echo; done

# ------------------------------------------------------------------------------
# 3. DIAGNÓSTICO PRE-FILAMENT: ¿Octane bootea ya?
# Si setup.sh dejó Octane en crash-loop, instalar Filament por encima solo
# añade ruido. Exponemos el fatal real PHP del worker antes de tocar nada.
# ------------------------------------------------------------------------------
echo "--------------------------------------------------------------------------"
echo " DIAGNÓSTICO: boot actual de Octane (FrankenPHP)"
echo "--------------------------------------------------------------------------"

diagnosticar_octane() {
  echo "  - systemctl is-active octane: $(systemctl is-active octane 2>/dev/null || true)"
  if ss -ltn 2>/dev/null | grep -q ':8000 '; then
      echo "  - Puerto 8000: ESCUCHANDO (octane booteado)"
      return 0
  else
      echo "  - Puerto 8000: NO escucha (octane caído o crash-loop)"
      return 1
  fi
}

diagnosticar_octane || {
  echo "  Octane NO escucha :8000. Capturando fatal real del worker (foreground 6s)…"
  sudo systemctl stop octane 2>/dev/null || true
  # Foreground: arranca worker, deja que FrankenPHP imprima el fatal PHP, mata a 6s.
  sudo timeout 6s runuser -u "$LARAVEL_USER" -- env HOME="$LARAVEL_HOME" \
      bash -lc "cd '$PROYECTO_DIR' && APP_ENV=production /usr/bin/php artisan octane:start \
          --server=frankenphp --host=127.0.0.1 --port=8000 --workers=1 --max-requests=10" \
      2>&1 | tail -40 || true
  # Trazar el worker directamente expone el PHP fatal aunque FrankenPHP se trague stderr.
  if [ -f "$PROYECTO_DIR/public/frankenphp-worker.php" ]; then
      echo "  ---- worker script directo (top fatal) ----"
      sudo timeout 5s runuser -u "$LARAVEL_USER" -- env HOME="$LARAVEL_HOME" \
          bash -lc "cd '$PROYECTO_DIR' && APP_ENV=production /usr/bin/php public/frankenphp-worker.php" \
          2>&1 | head -30 || true
  fi
  # Laravel log (a veces captura antes del fatal si ya booteó partialmente).
  if [ -s "$PROYECTO_DIR/storage/logs/laravel.log" ]; then
      echo "  ---- últimos 30 líneas storage/logs/laravel.log ----"
      sudo tail -n 30 "$PROYECTO_DIR/storage/logs/laravel.log" 2>/dev/null || true
  fi
  echo "--------------------------------------------------------------------------"
  echo " Si el trace anterior muestra un fatal claro (Class not found,undefined"
  echo " method, ext-*, Permission denied), corrige esa causa raíz y re-ejecuta"
  echo " panel.sh. Filament no ara un Octane que no bootea."
  echo "--------------------------------------------------------------------------"
  read -p "¿Continuar instalando Filament igualmente? [s/N]: " CONT
  [ "$CONT" = "s" ] || [ "$CONT" = "S" ] || { echo "Abortado."; exit 1; }
}

# ------------------------------------------------------------------------------
# 4. FILAMENT 5
# ------------------------------------------------------------------------------
echo " [1/4] Instalando Filament 5..."
as_laravel "composer require filament/filament:\"^5.0\" -W --no-interaction"
as_laravel "composer dump-autoload -o"
as_laravel "php artisan filament:install --panels --no-interaction"

# Sin ->login() en el panel, /admin redirige a la ruta genérica 'login'
# (inexistente) → RouteNotFoundException. Se parchea con PHP (no sed) para
# evitar problemas de escaping. Inserta ->login() tras ->default() o, en su
# defecto, tras 'return $panel'.
sudo -u "$LARAVEL_USER" bash -c "cat > '$PROYECTO_DIR/patch_panel.php' << 'PHP'
<?php
\$f = __DIR__.'/app/Providers/Filament/AdminPanelProvider.php';
\$c = file_get_contents(\$f);
if (strpos(\$c, '->login(') === false) {
  \$anchor = '->default()';
  \$pos = strpos(\$c, \$anchor);
  if (\$pos === false) {
      \$anchor = 'return \$panel';
      \$pos = strpos(\$c, \$anchor);
  }
  if (\$pos !== false) {
      \$insertAt = \$pos + strlen(\$anchor);
      \$c = substr(\$c, 0, \$insertAt).'->login()'.substr(\$c, \$insertAt);
      file_put_contents(\$f, \$c);
      echo \"AdminPanelProvider: ->login() añadido\n\";
  } else {
      echo \"AdminPanelProvider: ancla no encontrada, añade ->login() manualmente\n\";
      exit(1);
  }
} else {
  echo \"AdminPanelProvider: ->login() ya presente\n\";
}
PHP"
as_laravel "php patch_panel.php && rm -f patch_panel.php"

# Asegurar registro del provider en bootstrap/providers.php (Filament 5 lo
# suele auto-registrar, pero falla en algunas instalaciones --no-interaction).
sudo -u "$LARAVEL_USER" bash -c "cat > '$PROYECTO_DIR/patch_providers.php' << 'PHP'
<?php
\$f = __DIR__.'/bootstrap/providers.php';
\$c = file_get_contents(\$f);
\$cls = 'App\\\\Providers\\\\Filament\\\\AdminPanelProvider';
if (strpos(\$c, \$cls) === false) {
  \$c = preg_replace(
      '/(\\])\\s*;\\s*\$/',
      \"    \\\\App\\\\Providers\\\\Filament\\\\AdminPanelProvider::class,\n];\",
      \$c
  );
  file_put_contents(\$f, \$c);
  echo \"providers.php: AdminPanelProvider registrado\n\";
} else {
  echo \"providers.php: AdminPanelProvider ya registrado\n\";
}
PHP"
as_laravel "php patch_providers.php && rm -f patch_providers.php"

# ------------------------------------------------------------------------------
# 4.5 TRUST PROXIES (Octane detrás de Nginx HTTPS)
# Livewire/Filament generan endpoints con Request::getScheme()/getHost().
# Octane recibe 127.0.0.1:8000 directo de Nginx; scheme=http. Sin TrustProxies
# Laravel ignora X-Forwarded-Proto=https => endpoints http:// => mixed content
# => navegador bloquea POST del login => "botón no hace nada".
# Capa 1: trustProxies(at: '*') en bootstrap/app.php.
# Capa 2 (defensa): URL::forceScheme('https') en AppServiceProvider en production.
# ------------------------------------------------------------------------------
echo " [extra] Parcheando TrustProxies + forceScheme('https')..."
sudo -u "$LARAVEL_USER" bash -c "cat > '$PROYECTO_DIR/patch_trust.php' << 'PHP'
<?php
// --- bootstrap/app.php: trustProxies ---
\$bf = __DIR__.'/bootstrap/app.php';
\$bc = file_get_contents(\$bf);
\$changed = false;
if (strpos(\$bc, 'trustProxies') === false) {
  \$anchor = '->withMiddleware(function (Middleware \$middleware) {';
  \$pos = strpos(\$bc, \$anchor);
  if (\$pos !== false) {
      \$insertAt = \$pos + strlen(\$anchor);
      \$bc = substr(\$bc, 0, \$insertAt)
          . \"\\n        \\\$middleware->trustProxies(at: '*');\"
          . substr(\$bc, \$insertAt);
      file_put_contents(\$bf, \$bc);
      echo \"bootstrap/app.php: trustProxies(at: '*') agregado\\n\";
      \$changed = true;
  } else {
      echo \"bootstrap/app.php: ancla withMiddleware no encontrada (revisar manualmente)\\n\";
  }
} else {
  echo \"bootstrap/app.php: trustProxies ya presente\\n\";
}

// --- app/Providers/AppServiceProvider.php: forceScheme en production ---
\$af = __DIR__.'/app/Providers/AppServiceProvider.php';
\$ac = file_get_contents(\$af);
if (strpos(\$ac, 'forceScheme') === false) {
  // Encolar el import tras 'use Illuminate\\Support\\ServiceProvider;'
  \$ac = str_replace(
      'use Illuminate\\\\Support\\\\ServiceProvider;',
      \"use Illuminate\\\\Support\\\\ServiceProvider;\\nuse Illuminate\\\\Support\\\\Facades\\\\URL;\",
      \$ac
  );
  // Insertar dentro de boot() -- buscar 'public function boot(): void' y la primera '{' tras el
  \$bootPos = strpos(\$ac, 'public function boot');
  if (\$bootPos !== false) {
      \$bracePos = strpos(\$ac, '{', \$bootPos);
      if (\$bracePos !== false) {
          \$insertAt = \$bracePos + 1;
          \$ac = substr(\$ac, 0, \$insertAt)
              . \"\\n        if (\\\$this->app->environment('production')) {\\n            URL::forceScheme('https');\\n        }\"
              . substr(\$ac, \$insertAt);
          file_put_contents(\$af, \$ac);
          echo \"AppServiceProvider: URL::forceScheme('https') agregado en production\\n\";
          \$changed = true;
      }
  }
} else {
  echo \"AppServiceProvider: forceScheme ya presente\\n\";
}
exit(\$changed ? 0 : 0);
PHP"
as_laravel "php patch_trust.php && rm -f patch_trust.php"
# Forzar re-cache de config tras tocar bootstrap/app.php + providers (se hace en
# el paso [4/4] de todas formas, pero aqui aseguramos chown por si acaso).
sudo chown -R "$LARAVEL_USER":"$LARAVEL_USER" "$PROYECTO_DIR/bootstrap" "$PROYECTO_DIR/app/Providers" 2>/dev/null || true

# ------------------------------------------------------------------------------
# 5. USUARIO ADMIN DEL PANEL (sin roles — panel limpio)
# Sin Shield, el admin se crea como User normal. La autorización del panel
# (canAccessPanel, middleware de Filament) queda a decisión del operador.
# updateOrCreate: re-ejecutar panel.sh actualiza name/pass (intencional) sin
# duplicar. Vars via env(): el --execute va entre single-quotes y $VAR NO se
# expande ahi; export previo + env("VAR") en PHP es el patron seguro del repo
# (mismo de login.sh para evitar inyeccion desde secrets).
# ------------------------------------------------------------------------------
echo " [2/4] Creando/actualizando usuario admin..."
as_laravel "export ADMIN_NAME='$ADMIN_NAME' ADMIN_EMAIL='$ADMIN_EMAIL' ADMIN_PASS='$ADMIN_PASS'; \
  php artisan tinker --execute='
\$u = \App\Models\User::updateOrCreate(
  [\"email\" => env(\"ADMIN_EMAIL\")],
  [\"name\" => env(\"ADMIN_NAME\"), \"password\" => bcrypt(env(\"ADMIN_PASS\"))]
);
echo \"Admin: \" . \$u->email . PHP_EOL;
'"

# ------------------------------------------------------------------------------
# 8. DEBUGBAR (solo dev)
# ------------------------------------------------------------------------------
echo " [3/4] Instalando Debugbar (dev)..."
as_laravel "composer require barryvdh/laravel-debugbar --dev --no-interaction"

# ------------------------------------------------------------------------------
# 9. MIGRACIONES, STORAGE LINK, CACHE
# Las caches se corren con APP_ENV=production para coincidir con octane.service
# (Environment=APP_ENV=production). Cachear bajo local congela config divergente
# y rompe el boot del worker.
# ------------------------------------------------------------------------------
echo " [4/4] Migrando, storage:link y cacheando (APP_ENV=production)..."
as_laravel "php artisan storage:link --force || true"
as_laravel "APP_ENV=production php artisan migrate --force"
as_laravel "php artisan optimize:clear"
as_laravel "APP_ENV=production php artisan config:cache"
as_laravel "APP_ENV=production php artisan route:cache"

# ------------------------------------------------------------------------------
# 10. REINICIAR OCTANE — robusto: reset-failed + restart + healthcheck
# El guard `if is-active` anterior fallaba cuando octane estaba en estado
# `failed`/`activating (auto-restart)`: is-active devuelve false → reinicio
# saltado → workers con rutas viejas → /admin 404.
# ------------------------------------------------------------------------------
echo "Reiniciando Octane Server..."
sudo systemctl reset-failed octane 2>/dev/null || true
sudo systemctl restart octane 2>/dev/null || sudo systemctl start octane 2>/dev/null || true

# Healthcheck retry: esperar :8000 listening.
OCTANE_UP=0
for i in 1 2 3 4 5 6 7 8; do
  sleep 1
  if ss -ltn 2>/dev/null | grep -q ':8000 '; then
      OCTANE_UP=1
      echo "  Octane OK (:8000 listening tras $i intento(s))."
      break
  fi
done

if [ "$OCTANE_UP" -ne 1 ]; then
  echo "  [ERROR] Octane NO escucha :8000 tras restart. Capturando fatal real del worker…"
  sudo systemctl stop octane 2>/dev/null || true
  sudo timeout 6s runuser -u "$LARAVEL_USER" -- env HOME="$LARAVEL_HOME" \
      bash -lc "cd '$PROYECTO_DIR' && APP_ENV=production /usr/bin/php artisan octane:start \
          --server=frankenphp --host=127.0.0.1 --port=8000 --workers=1 --max-requests=10" \
      2>&1 | tail -40 || true
  if [ -s "$PROYECTO_DIR/storage/logs/laravel.log" ]; then
      echo "  ---- últimos 30 líneas storage/logs/laravel.log ----"
      sudo tail -n 30 "$PROYECTO_DIR/storage/logs/laravel.log" 2>/dev/null || true
  fi
  echo "=========================================================================="
  echo " Filament instalado pero Octane no bootea. Revisa el fatal arriba y aplica"
  echo " el fix específico (ext faltante en binario FrankenPHP, config rota, etc)."
  echo " Una vez corregido, basta con: sudo systemctl start octane"
  echo "=========================================================================="
  exit 1
fi

# ----------------------------------------------------------------------------
# 11. BANNER FINAL — URL real desde .env APP_URL (no placeholder).
# ----------------------------------------------------------------------------
PANEL_URL=$(awk -F= '/^APP_URL=/{gsub(/"/,"",$2);print $2; exit}' "$PROYECTO_DIR/.env" 2>/dev/null)
PANEL_URL="${PANEL_URL:-http://<tu-dominio>}"

echo "=========================================================================="
echo " FILAMENT 5 CONFIGURADO"
echo "=========================================================================="
echo " Admin URL:  ${PANEL_URL}/admin"
echo " Login:      $ADMIN_EMAIL  (contraseña: la introducida arriba)"
echo " Panel:      Filament 5 (panel limpio — sin Shield)"
echo "=========================================================================="