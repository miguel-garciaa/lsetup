#!/bin/bash
set -e

# Configuracion
PROYECTO_DIR="/var/www/laravel"
LARAVEL_USER="laravel"
LARAVEL_HOME="/home/laravel"

ADMIN_NAME="Admin"
ADMIN_EMAIL="admin@ejemplo.com"
ADMIN_PASSWORD="cambia-esta-contrasena"

cd "$PROYECTO_DIR"

# Instalar Filament 5
sudo -u "$LARAVEL_USER" env HOME="$LARAVEL_HOME" COMPOSER_HOME="$LARAVEL_HOME/.composer" composer require 'filament/filament:^5.0'
sudo -u "$LARAVEL_USER" env HOME="$LARAVEL_HOME" COMPOSER_HOME="$LARAVEL_HOME/.composer" php artisan filament:install --panels --no-interaction

# Permitir el acceso del administrador en produccion
sudo -u "$LARAVEL_USER" env ADMIN_EMAIL="$ADMIN_EMAIL" php -r '
$path = "app/Models/User.php";
$code = file_get_contents($path);

if (! str_contains($code, "use Filament\\Models\\Contracts\\FilamentUser;")) {
    $code = str_replace(
        "namespace App\\Models;",
        "namespace App\\Models;\n\nuse Filament\\Models\\Contracts\\FilamentUser;\nuse Filament\\Panel;",
        $code,
    );
}

if (! str_contains($code, "implements FilamentUser")) {
    $code = str_replace(
        "class User extends Authenticatable",
        "class User extends Authenticatable implements FilamentUser",
        $code,
    );
}

if (! str_contains($code, "canAccessPanel(")) {
    $email = var_export(getenv("ADMIN_EMAIL"), true);
    $method = "\n    public function canAccessPanel(Panel \$panel): bool\n    {\n"
        . "        return \$panel->getId() === \"admin\" && \$this->email === {$email};\n"
        . "    }\n";
    $position = strrpos($code, "}");
    $code = substr($code, 0, $position) . $method . substr($code, $position);
}

file_put_contents($path, $code);
'

# Crear el usuario administrador
sudo -u "$LARAVEL_USER" env HOME="$LARAVEL_HOME" COMPOSER_HOME="$LARAVEL_HOME/.composer" php artisan migrate --force
sudo -u "$LARAVEL_USER" env HOME="$LARAVEL_HOME" COMPOSER_HOME="$LARAVEL_HOME/.composer" php artisan make:filament-user --name="$ADMIN_NAME" --email="$ADMIN_EMAIL" --password="$ADMIN_PASSWORD" --no-interaction

# Aplicar cambios
sudo -u "$LARAVEL_USER" env HOME="$LARAVEL_HOME" COMPOSER_HOME="$LARAVEL_HOME/.composer" php artisan optimize:clear
sudo systemctl restart octane

echo "Filament instalado: /admin"
