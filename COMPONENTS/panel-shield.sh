#!/bin/bash
set -e

# ==============================================================================
# FILAMENT SHIELD + RBAC (MODULO POSTERIOR AL PANEL BASE)
# Ejecutar como root desde la raiz del proyecto Laravel despues de panel-install.
# Promueve al administrador creado por panel-install; no crea ni pide usuarios.
# ==============================================================================

if [ "$EUID" -ne 0 ]; then
    echo "[ERROR] Ejecuta este script como root o con sudo."
    exit 1
fi

if [ "$#" -ne 0 ]; then
    echo "Uso: sudo ./panel-shield.sh"
    echo "El administrador se obtiene de PANEL_ADMIN_EMAIL creado por panel-install.sh."
    exit 1
fi

LARAVEL_USER="laravel"
LARAVEL_HOME="/var/lib/laravel"
PROYECTO_DIR=$(readlink -f -- "$(pwd)")

if ! id "$LARAVEL_USER" &>/dev/null; then
    echo "[ERROR] No existe el usuario de aplicacion: $LARAVEL_USER"
    exit 1
fi

if [ ! -d "$LARAVEL_HOME" ] || [ ! -f "$PROYECTO_DIR/.env" ] \
    || [ ! -f "$PROYECTO_DIR/composer.json" ] || [ ! -f "$PROYECTO_DIR/artisan" ]; then
    echo "[ERROR] Ejecuta el script desde la raiz de un proyecto Laravel valido."
    exit 1
fi

if [ ! -f "$PROYECTO_DIR/app/Providers/Filament/AdminPanelProvider.php" ]; then
    echo "[ERROR] No existe AdminPanelProvider. Ejecuta primero panel-install.sh."
    exit 1
fi

if ! grep -q '"filament/filament"' "$PROYECTO_DIR/composer.json"; then
    echo "[ERROR] Filament no esta instalado. Ejecuta primero panel-install.sh."
    exit 1
fi

ADMIN_EMAIL=$(awk -F= '/^PANEL_ADMIN_EMAIL=/{gsub(/"/, "", $2); print $2; exit}' "$PROYECTO_DIR/.env")
if ! [[ "$ADMIN_EMAIL" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]]; then
    echo "[ERROR] PANEL_ADMIN_EMAIL no existe o no es valido en .env."
    echo "Ejecuta primero panel-install.sh para crear el administrador inicial."
    exit 1
fi

# Composer y Artisan nunca se ejecutan como root. Los argumentos se pasan como
# argv para que la ruta del proyecto no se interpole dentro de una cadena shell.
as_laravel() {
    sudo -u "$LARAVEL_USER" env HOME="$LARAVEL_HOME" COMPOSER_HOME="$LARAVEL_HOME/.composer" \
        bash -c 'cd -- "$1"; shift; exec "$@"' bash "$PROYECTO_DIR" "$@"
}

as_laravel_with_admin_env() {
    sudo -u "$LARAVEL_USER" env HOME="$LARAVEL_HOME" COMPOSER_HOME="$LARAVEL_HOME/.composer" \
        "PANEL_ADMIN_EMAIL=$ADMIN_EMAIL" \
        bash -c 'cd -- "$1"; shift; exec "$@"' bash "$PROYECTO_DIR" "$@"
}

PATCH_SCRIPT="$PROYECTO_DIR/.lsetup-shield-patch.php"
ADMIN_SCRIPT="$PROYECTO_DIR/.lsetup-shield-admin.php"
cleanup() {
    rm -f "$PATCH_SCRIPT" "$ADMIN_SCRIPT"
}
trap cleanup EXIT

echo "========================================================================="
echo " FILAMENT SHIELD + ROLES"
echo "========================================================================="
echo " Administrador inicial: $ADMIN_EMAIL"

# ------------------------------------------------------------------------------
# 1. INSTALACION OFICIAL DE SHIELD Y SPATIE PERMISSION
# ------------------------------------------------------------------------------
echo " [1/7] Instalando Filament Shield..."
as_laravel composer require 'bezhansalleh/filament-shield:^4.3' -W --no-interaction
as_laravel composer dump-autoload -o

if [ ! -f "$PROYECTO_DIR/config/filament-shield.php" ]; then
    as_laravel php artisan vendor:publish --tag=filament-shield-config --no-interaction
fi

if ! find "$PROYECTO_DIR/database/migrations" -maxdepth 1 -type f -name '*create_permission_tables.php' -print -quit | grep -q .; then
    as_laravel php artisan vendor:publish --provider='Spatie\Permission\PermissionServiceProvider' --tag=permission-migrations --no-interaction
fi

as_laravel php artisan shield:install admin --no-interaction

# ------------------------------------------------------------------------------
# 2. GENERADORES DE LARAVEL Y FILAMENT
# ------------------------------------------------------------------------------
echo " [2/7] Generando Seeder, Policy y UserResource..."
if [ ! -f "$PROYECTO_DIR/database/seeders/ShieldSetupSeeder.php" ]; then
    as_laravel php artisan make:seeder ShieldSetupSeeder --no-interaction
fi

if [ ! -f "$PROYECTO_DIR/app/Policies/UserPolicy.php" ]; then
    as_laravel php artisan make:policy UserPolicy --model=User --no-interaction
fi

USER_RESOURCE="$PROYECTO_DIR/app/Filament/Resources/Users/UserResource.php"
if [ ! -f "$USER_RESOURCE" ]; then
    as_laravel php artisan make:filament-resource User --generate --view --no-interaction
fi

# ------------------------------------------------------------------------------
# 3. MODELO, PANEL Y REGLAS GLOBALES
# ------------------------------------------------------------------------------
echo " [3/7] Configurando acceso al panel y plugin Shield..."
cat > "$PATCH_SCRIPT" <<'PHP'
<?php

function failPatch(string $message): never
{
    fwrite(STDERR, $message . PHP_EOL);
    exit(1);
}

function writeFile(string $path, string $contents): void
{
    if (file_put_contents($path, $contents) === false) {
        failPatch("No se pudo escribir {$path}");
    }
}

$userModel = __DIR__ . '/app/Models/User.php';
$source = file_get_contents($userModel);
if ($source === false) {
    failPatch('No se pudo leer app/Models/User.php');
}

if (! str_contains($source, 'Spatie\\Permission\\Traits\\HasRoles')) {
    $source = preg_replace(
        '/(namespace App\\\\Models;\s*)/',
        "$1\nuse Spatie\\Permission\\Traits\\HasRoles;\n",
        $source,
        1,
        $count,
    );
    if ($count !== 1 || $source === null) {
        failPatch('No se pudo importar HasRoles en User.php');
    }
}

// La importacion tambien contiene "HasRoles"; comprobar solo el cuerpo de clase.
$classPosition = strpos($source, 'class User');
if ($classPosition === false) {
    failPatch('No se encontro class User en User.php');
}
$classBody = substr($source, $classPosition);
if (! preg_match('/^\s*use [^;]*\bHasRoles;/m', $classBody)) {
    if (str_contains($source, 'use HasFactory, Notifiable;')) {
        $source = str_replace(
            'use HasFactory, Notifiable;',
            'use HasFactory, Notifiable, HasRoles;',
            $source,
        );
    } else {
        failPatch('No se pudo anadir HasRoles a los traits de User.php');
    }
}

$accessMethod = <<<'METHOD'
    public function canAccessPanel(\Filament\Panel $panel): bool
    {
        return $panel->getId() === 'admin'
            && $this->hasAnyRole(['Admin', 'Consultor']);
    }

METHOD;

if (str_contains($source, 'canAccessPanel(')) {
    $source = preg_replace(
        '/\n    public function canAccessPanel\(.*?\n    \}\n/s',
        "\n" . $accessMethod,
        $source,
        1,
        $count,
    );
    if ($count !== 1 || $source === null) {
        failPatch('No se pudo sustituir canAccessPanel en User.php');
    }
} else {
    $position = strrpos($source, '}');
    if ($position === false) {
        failPatch('No se encontro el cierre de User.php');
    }
    $source = substr($source, 0, $position) . "\n" . $accessMethod . substr($source, $position);
}
writeFile($userModel, $source);

$panelProvider = __DIR__ . '/app/Providers/Filament/AdminPanelProvider.php';
$source = file_get_contents($panelProvider);
if ($source === false) {
    failPatch('No se pudo leer AdminPanelProvider.php');
}

if (! str_contains($source, 'BezhanSalleh\\FilamentShield\\FilamentShieldPlugin')) {
    $source = preg_replace(
        '/(namespace App\\\\Providers\\\\Filament;\s*)/',
        "$1\nuse BezhanSalleh\\FilamentShield\\FilamentShieldPlugin;\n",
        $source,
        1,
        $count,
    );
    if ($count !== 1 || $source === null) {
        failPatch('No se pudo importar FilamentShieldPlugin');
    }
}

if (! str_contains($source, 'FilamentShieldPlugin::make()')) {
    $anchors = ['->login()', '->default()', 'return $panel'];
    $inserted = false;
    foreach ($anchors as $anchor) {
        $position = strpos($source, $anchor);
        if ($position === false) {
            continue;
        }

        $at = $position + strlen($anchor);
        $source = substr($source, 0, $at)
            . "\n            ->plugin(FilamentShieldPlugin::make())"
            . substr($source, $at);
        $inserted = true;
        break;
    }
    if (! $inserted) {
        failPatch('No se encontro un ancla para registrar FilamentShieldPlugin');
    }
}
writeFile($panelProvider, $source);

$appProvider = __DIR__ . '/app/Providers/AppServiceProvider.php';
$source = file_get_contents($appProvider);
if ($source === false) {
    failPatch('No se pudo leer AppServiceProvider.php');
}

$imports = [
    'use App\\Models\\User;',
    'use Illuminate\\Support\\Facades\\Gate;',
    'use Spatie\\Permission\\Models\\Role;',
];
foreach ($imports as $import) {
    if (! str_contains($source, $import)) {
        $source = preg_replace('/(namespace App\\\\Providers;\s*)/', "$1\n{$import}\n", $source, 1, $count);
        if ($count !== 1 || $source === null) {
            failPatch("No se pudo importar {$import}");
        }
    }
}

$source = preg_replace('/\n        \/\/ LSETUP_SHIELD_RBAC_START.*?\/\/ LSETUP_SHIELD_RBAC_END\n/s', "\n", $source);
$boot = strpos($source, 'public function boot');
$brace = $boot === false ? false : strpos($source, '{', $boot);
if ($brace === false) {
    failPatch('No se encontro boot() en AppServiceProvider.php');
}

$rules = <<<'RULES'

        // LSETUP_SHIELD_RBAC_START
        Gate::before(function (User $user, string $ability, mixed ...$arguments): ?bool {
            if ($user->hasRole('Admin')) {
                return true;
            }

            if (! $user->hasRole('Consultor')) {
                return false;
            }

            $subject = $arguments[0] ?? null;
            if ($subject instanceof User || $subject === User::class
                || $subject instanceof Role || $subject === Role::class) {
                return false;
            }

            return in_array($ability, ['viewAny', 'view'], true);
        });
        // LSETUP_SHIELD_RBAC_END
RULES;
$at = $brace + 1;
$source = substr($source, 0, $at) . $rules . substr($source, $at);
writeFile($appProvider, $source);
PHP
chown "$LARAVEL_USER:$LARAVEL_USER" "$PATCH_SCRIPT"
chmod 0600 "$PATCH_SCRIPT"
as_laravel php "$PATCH_SCRIPT"

# ------------------------------------------------------------------------------
# 4. IMPLEMENTACION DE LOS ARTEFACTOS GENERADOS
# ------------------------------------------------------------------------------
echo " [4/7] Completando RBAC y gestion de usuarios..."
cat > "$PROYECTO_DIR/database/seeders/ShieldSetupSeeder.php" <<'PHP'
<?php

namespace Database\Seeders;

use Illuminate\Database\Seeder;
use Spatie\Permission\Models\Permission;
use Spatie\Permission\Models\Role;

class ShieldSetupSeeder extends Seeder
{
    public function run(): void
    {
        app()[\Spatie\Permission\PermissionRegistrar::class]->forgetCachedPermissions();

        $admin = Role::findOrCreate('Admin', 'web');
        $consultor = Role::findOrCreate('Consultor', 'web');
        $permissions = Permission::query()->where('guard_name', 'web')->get();

        $admin->syncPermissions($permissions);

        $lectura = $permissions->filter(function (Permission $permission): bool {
            $name = $permission->name;
            $esLectura = str_starts_with($name, 'ViewAny:') || str_starts_with($name, 'View:');
            $esSensible = str_ends_with($name, ':User') || str_ends_with($name, ':Role');

            return $esLectura && ! $esSensible;
        });

        $consultor->syncPermissions($lectura);
        app()[\Spatie\Permission\PermissionRegistrar::class]->forgetCachedPermissions();
    }
}
PHP

cat > "$PROYECTO_DIR/app/Policies/UserPolicy.php" <<'PHP'
<?php

namespace App\Policies;

use App\Models\User;

class UserPolicy
{
    public function viewAny(User $user): bool
    {
        return $user->hasRole('Admin');
    }

    public function view(User $user, User $model): bool
    {
        return $user->hasRole('Admin');
    }

    public function create(User $user): bool
    {
        return $user->hasRole('Admin');
    }

    public function update(User $user, User $model): bool
    {
        return $user->hasRole('Admin');
    }

    public function delete(User $user, User $model): bool
    {
        return $user->hasRole('Admin');
    }

    public function deleteAny(User $user): bool
    {
        return $user->hasRole('Admin');
    }
}
PHP

mkdir -p "$PROYECTO_DIR/app/Filament/Resources/Users/Pages"
cat > "$USER_RESOURCE" <<'PHP'
<?php

namespace App\Filament\Resources\Users;

use App\Filament\Resources\Users\Pages\CreateUser;
use App\Filament\Resources\Users\Pages\EditUser;
use App\Filament\Resources\Users\Pages\ListUsers;
use App\Filament\Resources\Users\Pages\ViewUser;
use App\Models\User;
use Filament\Actions\BulkActionGroup;
use Filament\Actions\DeleteAction;
use Filament\Actions\DeleteBulkAction;
use Filament\Actions\EditAction;
use Filament\Actions\ViewAction;
use Filament\Forms\Components\Select;
use Filament\Forms\Components\TextInput;
use Filament\Resources\Resource;
use Filament\Schemas\Schema;
use Filament\Tables;
use Filament\Tables\Table;
use Illuminate\Database\Eloquent\Builder;
use Illuminate\Support\Facades\Hash;
use Spatie\Permission\Models\Role;

class UserResource extends Resource
{
    protected static ?string $model = User::class;

    protected static ?string $navigationLabel = 'Usuarios';

    protected static ?string $modelLabel = 'Usuario';

    protected static ?string $pluralModelLabel = 'Usuarios';

    public static function form(Schema $schema): Schema
    {
        return $schema->components([
            TextInput::make('name')->label('Nombre')->required()->maxLength(255),
            TextInput::make('email')->label('Correo')->email()->required()->maxLength(255)->unique(ignoreRecord: true),
            TextInput::make('password')
                ->label('Contrasena')
                ->password()
                ->required(fn (string $operation): bool => $operation === 'create')
                ->dehydrated(fn (?string $state): bool => filled($state))
                ->dehydrateStateUsing(fn (string $state): string => Hash::make($state)),
            Select::make('roles')
                ->label('Rol')
                ->relationship(
                    name: 'roles',
                    titleAttribute: 'name',
                    modifyQueryUsing: fn (Builder $query): Builder => $query->whereIn('name', ['Admin', 'Consultor']),
                )
                ->multiple()
                ->maxItems(1)
                ->preload()
                ->searchable()
                ->required(),
        ]);
    }

    public static function table(Table $table): Table
    {
        return $table
            ->columns([
                Tables\Columns\TextColumn::make('name')->label('Nombre')->searchable()->sortable(),
                Tables\Columns\TextColumn::make('email')->label('Correo')->searchable()->sortable(),
                Tables\Columns\TextColumn::make('roles.name')->label('Rol')->badge(),
            ])
            ->recordActions([
                ViewAction::make(),
                EditAction::make(),
                DeleteAction::make(),
            ])
            ->toolbarActions([
                BulkActionGroup::make([
                    DeleteBulkAction::make(),
                ]),
            ]);
    }

    public static function getPages(): array
    {
        return [
            'index' => ListUsers::route('/'),
            'create' => CreateUser::route('/create'),
            'view' => ViewUser::route('/{record}'),
            'edit' => EditUser::route('/{record}/edit'),
        ];
    }

    public static function canViewAny(): bool
    {
        return auth()->user()?->hasRole('Admin') ?? false;
    }
}
PHP

cat > "$PROYECTO_DIR/app/Filament/Resources/Users/Pages/ListUsers.php" <<'PHP'
<?php

namespace App\Filament\Resources\Users\Pages;

use App\Filament\Resources\Users\UserResource;
use Filament\Actions;
use Filament\Resources\Pages\ListRecords;

class ListUsers extends ListRecords
{
    protected static string $resource = UserResource::class;

    protected function getHeaderActions(): array
    {
        return [Actions\CreateAction::make()];
    }
}
PHP

cat > "$PROYECTO_DIR/app/Filament/Resources/Users/Pages/CreateUser.php" <<'PHP'
<?php

namespace App\Filament\Resources\Users\Pages;

use App\Filament\Resources\Users\UserResource;
use Filament\Resources\Pages\CreateRecord;

class CreateUser extends CreateRecord
{
    protected static string $resource = UserResource::class;
}
PHP

cat > "$PROYECTO_DIR/app/Filament/Resources/Users/Pages/EditUser.php" <<'PHP'
<?php

namespace App\Filament\Resources\Users\Pages;

use App\Filament\Resources\Users\UserResource;
use Filament\Actions;
use Filament\Resources\Pages\EditRecord;

class EditUser extends EditRecord
{
    protected static string $resource = UserResource::class;

    protected function getHeaderActions(): array
    {
        return [Actions\ViewAction::make(), Actions\DeleteAction::make()];
    }
}
PHP

cat > "$PROYECTO_DIR/app/Filament/Resources/Users/Pages/ViewUser.php" <<'PHP'
<?php

namespace App\Filament\Resources\Users\Pages;

use App\Filament\Resources\Users\UserResource;
use Filament\Actions;
use Filament\Resources\Pages\ViewRecord;

class ViewUser extends ViewRecord
{
    protected static string $resource = UserResource::class;

    protected function getHeaderActions(): array
    {
        return [Actions\EditAction::make()];
    }
}
PHP

chown -R "$LARAVEL_USER:$LARAVEL_USER" \
    "$PROYECTO_DIR/app/Models" \
    "$PROYECTO_DIR/app/Policies" \
    "$PROYECTO_DIR/app/Providers" \
    "$PROYECTO_DIR/app/Filament" \
    "$PROYECTO_DIR/database/seeders"

# Shield genera los permisos de los recursos ya existentes, incluido UserResource.
echo " [5/7] Generando permisos Shield y sembrando roles..."
as_laravel env APP_ENV=production php artisan migrate --force
as_laravel php artisan shield:generate --all --panel=admin --no-interaction --ignore-existing-policies
as_laravel env APP_ENV=production php artisan db:seed --class=ShieldSetupSeeder --force

# ------------------------------------------------------------------------------
# 5. PROMOCION DEL ADMINISTRADOR CREADO POR PANEL BASE
# ------------------------------------------------------------------------------
echo " [6/7] Asignando el rol Admin al administrador inicial..."
cat > "$ADMIN_SCRIPT" <<'PHP'
<?php

use Illuminate\Contracts\Console\Kernel;

$app = require __DIR__ . '/bootstrap/app.php';
$app->make(Kernel::class)->bootstrap();

$email = (string) getenv('PANEL_ADMIN_EMAIL');
$user = \App\Models\User::query()->where('email', $email)->first();
if ($user === null) {
    fwrite(STDERR, "No existe el administrador inicial: {$email}" . PHP_EOL);
    exit(1);
}

$user->syncRoles(['Admin']);
echo 'Admin: ' . $user->email . PHP_EOL;
PHP
chown "$LARAVEL_USER:$LARAVEL_USER" "$ADMIN_SCRIPT"
chmod 0600 "$ADMIN_SCRIPT"
as_laravel_with_admin_env php "$ADMIN_SCRIPT"

echo " [7/7] Reconstruyendo cache y reiniciando Octane..."
as_laravel php artisan optimize:clear
as_laravel env APP_ENV=production php artisan config:cache
as_laravel env APP_ENV=production php artisan route:cache
as_laravel env APP_ENV=production php artisan view:cache

systemctl reset-failed octane 2>/dev/null || true
systemctl restart octane || systemctl start octane

for attempt in 1 2 3 4 5 6 7 8; do
    sleep 1
    if ss -ltn 2>/dev/null | grep -q ':8000 '; then
        PANEL_URL=$(awk -F= '/^APP_URL=/{gsub(/"/, "", $2); print $2; exit}' "$PROYECTO_DIR/.env")
        PANEL_URL=${PANEL_URL:-http://localhost}
        echo "========================================================================="
        echo " FILAMENT SHIELD CONFIGURADO"
        echo "========================================================================="
        echo " Admin URL:  ${PANEL_URL}/admin"
        echo " Admin:      $ADMIN_EMAIL"
        echo " Roles:      Admin y Consultor"
        echo "========================================================================="
        exit 0
    fi
done

echo "[ERROR] Octane no escucha en :8000 tras el reinicio."
echo "Revisa: journalctl -u octane -n 80 --no-pager"
exit 1
