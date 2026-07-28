#!/bin/bash
set -e

# ==============================================================================
# FILAMENT 5 + SHIELD + SPATIE MEDIA LIBRARY + USUARIO ADMIN
# A ejecutar DESPUÉS de setup.sh (requiere proyecto Laravel ya desplegado).
# ==============================================================================

echo "=========================================================================="
echo "    FILAMENT 5 + SHIELD + SPATIE MEDIA LIBRARY + ADMIN    "
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
    echo "❌ Error: No se encontró un proyecto Laravel con .env en $PROYECTO_DIR"
    exit 1
fi

cd "$PROYECTO_DIR"

# Composer/artisan NUNCA como root: mismo patrón que setup.sh (as_laravel).
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
# 3. FILAMENT 5
# ------------------------------------------------------------------------------
echo " [1/7] Instalando Filament 5..."
as_laravel "composer require filament/filament:\"^5.0\" -W --no-interaction"
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

# ------------------------------------------------------------------------------
# 4. FILAMENT SHIELD + SPATIE PERMISSION
# ------------------------------------------------------------------------------
echo " [2/7] Instalando Filament Shield..."
as_laravel "composer require bezhansalleh/filament-shield --no-interaction"
# shield:install requiere el id del panel ('admin') en modo --no-interaction:
# sin él lanza NonInteractiveValidationException.
as_laravel "php artisan shield:install admin --no-interaction"
# spatie/laravel-permission: publicar migraciones y migrar ANTES de generate,
# si no, shield:generate falla con "relation permissions does not exist".
as_laravel "php artisan vendor:publish --provider=\"Spatie\Permission\PermissionServiceProvider\" --tag=\"permission-migrations\" --force"
as_laravel "php artisan migrate --force"
as_laravel "php artisan shield:generate --all --panel=admin --no-interaction"

# ------------------------------------------------------------------------------
# 5. TRAIT HasRoles EN User (obligatorio para assignRole de spatie)
# ------------------------------------------------------------------------------
echo " [3/7] Parcheando User.php con HasRoles..."
sudo -u "$LARAVEL_USER" bash -c "cat > '$PROYECTO_DIR/patch_user.php' << 'PHP'
<?php
\$f = __DIR__ . '/app/Models/User.php';
\$c = file_get_contents(\$f);
if (strpos(\$c, 'HasRoles') === false) {
    \$c = str_replace(
        'use Illuminate\\\\Notifications\\\\Notifiable;',
        \"use Illuminate\\\\Notifications\\\\Notifiable;\nuse Spatie\\\\Permission\\\\Traits\\\\HasRoles;\",
        \$c
    );
    \$c = str_replace(
        'use HasFactory, Notifiable;',
        'use HasFactory, Notifiable, HasRoles;',
        \$c
    );
    file_put_contents(\$f, \$c);
    echo \"User.php parcheado con HasRoles\n\";
} else {
    echo \"User.php ya tiene HasRoles\n\";
}
PHP"
as_laravel "php patch_user.php && rm -f patch_user.php"

# ------------------------------------------------------------------------------
# 6. USUARIO ADMIN DEL PANEL
# ------------------------------------------------------------------------------
echo " [4/7] Creando usuario admin..."
# Se pasan por env para no romper el quoting de tinker.
as_laravel "export ADMIN_NAME='$ADMIN_NAME' ADMIN_EMAIL='$ADMIN_EMAIL' ADMIN_PASS='$ADMIN_PASS'; \
    php artisan tinker --execute='
\$u = \App\Models\User::firstOrCreate(
    [\"email\" => env(\"ADMIN_EMAIL\")],
    [\"name\" => env(\"ADMIN_NAME\"), \"password\" => bcrypt(env(\"ADMIN_PASS\"))]
);
\$u->assignRole(\"super_admin\");
echo \"Admin: {\$u->email}\" . PHP_EOL;'"

# ------------------------------------------------------------------------------
# 7. SPATIE MEDIA LIBRARY + PLUGIN FILAMENT
# ------------------------------------------------------------------------------
echo " [5/7] Instalando Spatie Media Library + plugin Filament..."
as_laravel "composer require spatie/laravel-medialibrary --no-interaction"
as_laravel "composer require filament/spatie-laravel-media-library-plugin:\"^5.0\" -W --no-interaction"
as_laravel "php artisan vendor:publish --provider=\"Spatie\MediaLibrary\MediaLibraryServiceProvider\" --tag=\"medialibrary-migrations\" --force"

# ------------------------------------------------------------------------------
# 8. DEBUGBAR (solo dev)
# ------------------------------------------------------------------------------
echo " [6/7] Instalando Debugbar (dev)..."
as_laravel "composer require barryvdh/laravel-debugbar --dev --no-interaction"

# ------------------------------------------------------------------------------
# 9. MIGRACIONES, STORAGE LINK, CACHE
# ------------------------------------------------------------------------------
echo " [7/7] Migrando, storage:link y cacheando..."
as_laravel "php artisan storage:link --force || true"
as_laravel "php artisan migrate --force"
as_laravel "php artisan optimize:clear"
as_laravel "php artisan config:cache"
as_laravel "php artisan route:cache"

# ------------------------------------------------------------------------------
# 10. REINICIAR OCTANE SI ESTÁ ACTIVO
# ------------------------------------------------------------------------------
if systemctl is-active --quiet octane 2>/dev/null; then
    echo "Reiniciando Octane Server..."
    sudo systemctl restart octane
fi

echo "=========================================================================="
echo " FILAMENT 5 CONFIGURADO"
echo "=========================================================================="
echo " Admin URL:  http://<tu-dominio>/admin"
echo " Login:      $ADMIN_EMAIL  (contraseña: la introducida arriba)"
echo " Panel:      Filament 5 + Shield + Spatie Media Library"
echo "=========================================================================="
