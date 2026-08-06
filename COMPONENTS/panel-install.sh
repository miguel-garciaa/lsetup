#!/bin/bash
set -e

# ==============================================================================
# FILAMENT 5 + USUARIO ADMIN (PANEL BASE)
# Ejecutar despues de `lsetup up`. Instala solo la base del panel: sin Shield,
# roles, permisos, Debugbar ni modulos de negocio.
# ==============================================================================

if [ "$EUID" -ne 0 ]; then
    echo "[ERROR] Ejecuta este script como root o con sudo."
    exit 1
fi

LARAVEL_USER="laravel"
LARAVEL_HOME="/var/lib/laravel"

if ! id "$LARAVEL_USER" &>/dev/null; then
    echo "[ERROR] No existe el usuario de aplicacion: $LARAVEL_USER"
    exit 1
fi

if [ ! -d "$LARAVEL_HOME" ]; then
    echo "[ERROR] No existe el HOME de Laravel: $LARAVEL_HOME"
    exit 1
fi

echo "========================================================================="
echo "    FILAMENT 5 + ADMIN (PANEL BASE)"
echo "========================================================================="

# ------------------------------------------------------------------------------
# 1. DETECCION Y VALIDACION DEL PROYECTO
# ------------------------------------------------------------------------------
DEFAULT_DIR="/var/www/laravel1"
if [ -f "./.env" ]; then
    DEFAULT_DIR="$(pwd)"
fi

read -rp "Ruta del proyecto Laravel [$DEFAULT_DIR]: " PROYECTO_DIR
PROYECTO_DIR=${PROYECTO_DIR:-$DEFAULT_DIR}
PROYECTO_DIR=$(readlink -f -- "$PROYECTO_DIR" 2>/dev/null || true)

if [ -z "$PROYECTO_DIR" ] || [ ! -d "$PROYECTO_DIR" ] \
    || [ ! -f "$PROYECTO_DIR/.env" ] || [ ! -f "$PROYECTO_DIR/composer.json" ]; then
    echo "[ERROR] No se encontro un proyecto Laravel valido en la ruta indicada."
    exit 1
fi

# Ejecuta comandos como laravel sin reinyectar PROJECT_DIR en una cadena de shell.
as_laravel() {
    sudo -u "$LARAVEL_USER" env HOME="$LARAVEL_HOME" COMPOSER_HOME="$LARAVEL_HOME/.composer" \
        bash -c 'cd -- "$1"; shift; exec "$@"' bash "$PROYECTO_DIR" "$@"
}

# Igual que as_laravel, pero las credenciales se pasan como argumentos de env,
# nunca interpoladas dentro de codigo PHP o de un comando de shell.
as_laravel_with_admin_env() {
    sudo -u "$LARAVEL_USER" env HOME="$LARAVEL_HOME" COMPOSER_HOME="$LARAVEL_HOME/.composer" \
        "ADMIN_NAME=$ADMIN_NAME" "ADMIN_EMAIL=$ADMIN_EMAIL" "ADMIN_PASS=$ADMIN_PASS" \
        bash -c 'cd -- "$1"; shift; exec "$@"' bash "$PROYECTO_DIR" "$@"
}

set_env_var() {
    local key="$1" value="$2" file="$3" tmp

    tmp=$(mktemp "${file}.tmp.XXXXXX")
    grep -v "^${key}=" "$file" > "$tmp" || true
    printf '%s=%s\n' "$key" "$value" >> "$tmp"
    chown "$LARAVEL_USER:$LARAVEL_USER" "$tmp"
    chmod 0640 "$tmp"
    mv -f "$tmp" "$file"
}

PANEL_PATCH="$PROYECTO_DIR/.lsetup-panel-base.php"
ADMIN_SCRIPT="$PROYECTO_DIR/.lsetup-create-admin.php"
cleanup() {
    rm -f "$PANEL_PATCH" "$ADMIN_SCRIPT"
}
trap cleanup EXIT

# ------------------------------------------------------------------------------
# 2. CREDENCIALES DEL ADMINISTRADOR INICIAL
# ------------------------------------------------------------------------------
echo "--------------------------------------------------------------------------"
echo " CONFIGURACION DEL ADMINISTRADOR DEL PANEL"
echo "--------------------------------------------------------------------------"
read -rp "Nombre usuario admin [Admin]: " ADMIN_NAME
ADMIN_NAME=${ADMIN_NAME:-Admin}
read -rp "Correo del admin (obligatorio): " ADMIN_EMAIL
while ! [[ "$ADMIN_EMAIL" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]]; do
    echo "[ERROR] Introduce un correo valido."
    read -rp "Correo del admin (obligatorio): " ADMIN_EMAIL
done
read -rsp "Contrasena del admin (obligatoria): " ADMIN_PASS
echo
while [ -z "$ADMIN_PASS" ]; do
    echo "[ERROR] La contrasena no puede estar vacia."
    read -rsp "Contrasena del admin (obligatoria): " ADMIN_PASS
    echo
done

# ------------------------------------------------------------------------------
# 3. FILAMENT 5 Y CONFIGURACION DEL PANEL
# ------------------------------------------------------------------------------
echo " [1/5] Instalando o actualizando Filament 5..."
as_laravel composer require 'filament/filament:^5.0' -W --no-interaction
as_laravel composer dump-autoload -o
as_laravel php artisan filament:install --panels --no-interaction

if [ ! -f "$PROYECTO_DIR/app/Providers/Filament/AdminPanelProvider.php" ]; then
    echo "[ERROR] Filament no creo AdminPanelProvider.php."
    exit 1
fi

# Los cambios de PHP se escriben en un heredoc literal para no depender de sed
# ni de escapes de Bash. El fichero temporal se elimina con trap al terminar.
cat > "$PANEL_PATCH" <<'PHP'
<?php

function failPatch(string $message): never
{
    fwrite(STDERR, $message . PHP_EOL);
    exit(1);
}

$provider = __DIR__ . '/app/Providers/Filament/AdminPanelProvider.php';
$source = file_get_contents($provider);
if ($source === false) {
    failPatch('No se pudo leer AdminPanelProvider.php');
}

if (! str_contains($source, '->login(')) {
    $inserted = false;
    foreach (['->default()', 'return $panel'] as $anchor) {
        $position = strpos($source, $anchor);
        if ($position === false) {
            continue;
        }

        $at = $position + strlen($anchor);
        $source = substr($source, 0, $at) . '->login()' . substr($source, $at);
        $inserted = true;
        break;
    }

    if (! $inserted) {
        failPatch('No se encontro un ancla para ->login() en AdminPanelProvider.php');
    }

    file_put_contents($provider, $source);
}

$providers = __DIR__ . '/bootstrap/providers.php';
$source = file_get_contents($providers);
if ($source === false) {
    failPatch('No se pudo leer bootstrap/providers.php');
}

$class = 'App\\Providers\\Filament\\AdminPanelProvider';
if (! str_contains($source, $class)) {
    $updated = preg_replace(
        '/(\])\s*;\s*$/',
        "    \\App\\Providers\\Filament\\AdminPanelProvider::class,\n];",
        $source,
        1,
        $count,
    );
    if ($count !== 1 || $updated === null) {
        failPatch('No se pudo registrar AdminPanelProvider en bootstrap/providers.php');
    }
    file_put_contents($providers, $updated);
}

// Nginx conecta con Octane por loopback. Confiar solo en ese proxy evita que
// clientes externos puedan falsear X-Forwarded-Proto.
$bootstrap = __DIR__ . '/bootstrap/app.php';
$source = file_get_contents($bootstrap);
if ($source === false) {
    failPatch('No se pudo leer bootstrap/app.php');
}

$original = $source;
$source = str_replace('\\->trustProxies', '$middleware->trustProxies', $source);
$source = str_replace("trustProxies(at: '*')", "trustProxies(at: ['127.0.0.1'])", $source);
if (! str_contains($source, 'trustProxies')) {
    // Laravel 13 puede declarar el callback como `): void {`; no depender de
    // una firma exacta evita abortar tras instalar Filament y antes del restart.
    $source = preg_replace(
        '/(->withMiddleware\(function\s*\(\s*Middleware\s+\$middleware\s*\)(?:\s*:\s*[^\{]+)?\s*\{)/',
        "$1\n        \$middleware->trustProxies(at: ['127.0.0.1']);",
        $source,
        1,
        $count,
    );
    if ($count !== 1 || $source === null) {
        failPatch('No se encontro un callback withMiddleware compatible en bootstrap/app.php');
    }
}

if ($source !== $original) {
    file_put_contents($bootstrap, $source);
}

$appProvider = __DIR__ . '/app/Providers/AppServiceProvider.php';
$source = file_get_contents($appProvider);
if ($source === false) {
    failPatch('No se pudo leer AppServiceProvider.php');
}

if (! str_contains($source, 'forceScheme')) {
    $source = str_replace(
        'use Illuminate\\Support\\ServiceProvider;',
        "use Illuminate\\Support\\ServiceProvider;\nuse Illuminate\\Support\\Facades\\URL;",
        $source,
    );
    $position = strpos($source, 'public function boot');
    $brace = $position === false ? false : strpos($source, '{', $position);
    if ($brace === false) {
        failPatch('No se encontro boot() en AppServiceProvider.php');
    }

    $addition = <<<'ADDITION'

        if ($this->app->environment('production')) {
            URL::forceScheme('https');
        }
ADDITION;
    $at = $brace + 1;
    $source = substr($source, 0, $at) . $addition . substr($source, $at);
    file_put_contents($appProvider, $source);
}

$model = __DIR__ . '/app/Models/User.php';
$source = file_get_contents($model);
if ($source === false) {
    failPatch('No se pudo leer app/Models/User.php');
}

if (! str_contains($source, 'use Filament\\Models\\Contracts\\FilamentUser;')) {
    $source = preg_replace(
        '/(namespace App\\\\Models;\s*)/',
        "$1\nuse Filament\\Models\\Contracts\\FilamentUser;\nuse Filament\\Panel;\n",
        $source,
        1,
        $count,
    );
    if ($count !== 1 || $source === null) {
        failPatch('No se pudieron anadir imports de Filament a User.php');
    }
}

if (! preg_match('/class User extends Authenticatable[^{]*\bFilamentUser\b/', $source)) {
    if (preg_match('/class User extends Authenticatable\s+implements\s+([^\{]+)/', $source)) {
        $source = preg_replace(
            '/(class User extends Authenticatable\s+implements\s+[^\{]+)/',
            '$1, FilamentUser',
            $source,
            1,
            $count,
        );
    } else {
        $source = preg_replace(
            '/class User extends Authenticatable\b/',
            'class User extends Authenticatable implements FilamentUser',
            $source,
            1,
            $count,
        );
    }
    if ($count !== 1 || $source === null) {
        failPatch('No se pudo hacer que User implemente FilamentUser');
    }
}

if (! str_contains($source, 'canAccessPanel(')) {
    $method = <<<'METHOD'

    public function canAccessPanel(Panel $panel): bool
    {
        return $panel->getId() === 'admin'
            && hash_equals((string) config('panel-access.admin_email'), (string) $this->email);
    }

METHOD;
    $position = strrpos($source, '}');
    if ($position === false) {
        failPatch('No se encontro el cierre de User.php');
    }
    $source = substr($source, 0, $position) . $method . substr($source, $position);
}

file_put_contents($model, $source);
PHP
chown "$LARAVEL_USER:$LARAVEL_USER" "$PANEL_PATCH"
chmod 0600 "$PANEL_PATCH"
as_laravel php "$PANEL_PATCH"

# ------------------------------------------------------------------------------
# 4. ACCESO SOLO PARA EL ADMIN INICIAL
# Shield sustituira esta regla por roles/permisos en su propio script.
# ------------------------------------------------------------------------------
echo " [2/5] Restringiendo el panel al administrador inicial..."
set_env_var "PANEL_ADMIN_EMAIL" "$ADMIN_EMAIL" "$PROYECTO_DIR/.env"

cat > "$PROYECTO_DIR/config/panel-access.php" <<'PHP'
<?php

return [
    'admin_email' => env('PANEL_ADMIN_EMAIL'),
];
PHP
chown "$LARAVEL_USER:$LARAVEL_USER" "$PROYECTO_DIR/config/panel-access.php"
chmod 0640 "$PROYECTO_DIR/config/panel-access.php"

chown -R "$LARAVEL_USER:$LARAVEL_USER" "$PROYECTO_DIR/app/Models" "$PROYECTO_DIR/app/Providers" "$PROYECTO_DIR/bootstrap" "$PROYECTO_DIR/config"

# ------------------------------------------------------------------------------
# 5. USUARIO, MIGRACIONES, CACHE Y OCTANE
# ------------------------------------------------------------------------------
echo " [3/5] Creando o actualizando el administrador..."
cat > "$ADMIN_SCRIPT" <<'PHP'
<?php

use Illuminate\Contracts\Console\Kernel;
use Illuminate\Support\Facades\Hash;

$app = require __DIR__ . '/bootstrap/app.php';
$app->make(Kernel::class)->bootstrap();

$user = \App\Models\User::updateOrCreate(
    ['email' => (string) getenv('ADMIN_EMAIL')],
    [
        'name' => (string) getenv('ADMIN_NAME'),
        'password' => Hash::make((string) getenv('ADMIN_PASS')),
    ],
);

echo 'Admin: ' . $user->email . PHP_EOL;
PHP
chown "$LARAVEL_USER:$LARAVEL_USER" "$ADMIN_SCRIPT"
chmod 0600 "$ADMIN_SCRIPT"
as_laravel_with_admin_env php "$ADMIN_SCRIPT"

echo " [4/5] Migrando y reconstruyendo cache de produccion..."
as_laravel php artisan storage:link --force || true
as_laravel env APP_ENV=production php artisan migrate --force
as_laravel php artisan optimize:clear
as_laravel env APP_ENV=production php artisan config:cache
as_laravel env APP_ENV=production php artisan route:cache
as_laravel env APP_ENV=production php artisan view:cache

echo " [5/5] Reiniciando Octane..."
systemctl reset-failed octane 2>/dev/null || true
systemctl restart octane || systemctl start octane

for attempt in 1 2 3 4 5 6 7 8; do
    sleep 1
    if ss -ltn 2>/dev/null | grep -q ':8000 '; then
        # El puerto abierto no garantiza que el worker haya cargado las rutas
        # nuevas. Filament redirige /admin a /admin/login para invitados.
        PANEL_STATUS=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 \
            http://127.0.0.1:8000/admin 2>/dev/null || true)
        if [ "$PANEL_STATUS" != "200" ] && [ "$PANEL_STATUS" != "302" ] && [ "$PANEL_STATUS" != "303" ]; then
            echo "[ERROR] Octane escucha en :8000 pero /admin responde HTTP ${PANEL_STATUS:-sin respuesta}."
            echo "Revisa: journalctl -u octane -n 80 --no-pager"
            exit 1
        fi
        PANEL_URL=$(awk -F= '/^APP_URL=/{gsub(/"/,"",$2); print $2; exit}' "$PROYECTO_DIR/.env")
        PANEL_URL=${PANEL_URL:-http://localhost}
        echo "========================================================================="
        echo " FILAMENT 5 CONFIGURADO"
        echo "========================================================================="
        echo " Admin URL:  ${PANEL_URL}/admin"
        echo " Login:      $ADMIN_EMAIL"
        echo " Panel:      Filament 5 base, sin Shield ni modulos de negocio"
        echo "========================================================================="
        exit 0
    fi
done

echo "[ERROR] Octane no escucha en :8000 tras el reinicio."
echo "Revisa: journalctl -u octane -n 80 --no-pager"
exit 1
