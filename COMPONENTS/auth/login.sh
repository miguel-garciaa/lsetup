#!/bin/bash
set -e

# Configuracion: rellena estas variables antes de ejecutar el script.
PROYECTO_DIR="/var/www/laravel"
LARAVEL_USER="laravel"
LARAVEL_HOME="/home/laravel"

APP_URL="https://syslab.win"
GOOGLE_CLIENT_ID=""
GOOGLE_CLIENT_SECRET=""
GOOGLE_REDIRECT_URI="${APP_URL}/auth/google/callback"

echo "=========================================================================="
echo "    LOGIN + GOOGLE OAUTH    "
echo "=========================================================================="

if [ ! -d "$PROYECTO_DIR" ] || [ ! -f "$PROYECTO_DIR/.env" ]; then
  echo "[ERROR] No se encontro un proyecto Laravel con archivo .env en $PROYECTO_DIR"
  exit 1
fi

if [ -z "$GOOGLE_CLIENT_ID" ] || [ -z "$GOOGLE_CLIENT_SECRET" ]; then
  echo "[ERROR] Rellena GOOGLE_CLIENT_ID y GOOGLE_CLIENT_SECRET al principio del script."
  exit 1
fi

cd "$PROYECTO_DIR"

as_laravel() {
  sudo -u "$LARAVEL_USER" env HOME="$LARAVEL_HOME" COMPOSER_HOME="$LARAVEL_HOME/.composer" bash -c "cd '$PROYECTO_DIR' && $*"
}

# ------------------------------------------------------------------------------
# 3. ACTUALIZAR ARCHIVO .ENV
# ------------------------------------------------------------------------------
echo " [1/9] Actualizando variables en .env..."

set_env_var() {
  local key=$1
  local value=$2
  # Reescribe la línea sin interpretar value en sed (anti-inyección):
  # elimina la clave existente y añade el nuevo valor al final.
  grep -v "^${key}=" .env > .env.tmp || true
  printf '%s="%s"\n' "$key" "$value" >> .env.tmp
  mv .env.tmp .env
  sudo chown "$LARAVEL_USER":"$LARAVEL_USER" .env
}

set_env_var "APP_URL" "$APP_URL"
set_env_var "GOOGLE_CLIENT_ID" "$GOOGLE_CLIENT_ID"
set_env_var "GOOGLE_CLIENT_SECRET" "$GOOGLE_CLIENT_SECRET"
set_env_var "GOOGLE_REDIRECT_URI" "$GOOGLE_REDIRECT_URI"

# ------------------------------------------------------------------------------
# 4. CONFIGURAR TRUSTPROXIES EN LARAVEL
# ------------------------------------------------------------------------------
echo " [2/9] Configurando TrustProxies para HTTPS/Proxies (Cloudflare/Nginx)..."

php -r '
$bootstrapFile = "bootstrap/app.php";
if (file_exists($bootstrapFile)) {
  $content = file_get_contents($bootstrapFile);
  if (!str_contains($content, "trustProxies")) {
      $content = str_replace(
          "->withMiddleware(function (Middleware \$middleware) {",
          "->withMiddleware(function (Middleware \$middleware) {\n        \$middleware->trustProxies(at: \"*\");",
          $content
      );
      file_put_contents($bootstrapFile, $content);
  }
}
'

# ------------------------------------------------------------------------------
# 5. INSTALAR LARAVEL SOCIALITE Y CONFIGURAR SERVICES.PHP (SIN BLOQUEOS)
# ------------------------------------------------------------------------------
echo " [3/9] Verificando paquetes y config/services.php..."

# Verificar directamente en composer.json si ya está instalado para no ejecutar composer innecesariamente
if ! grep -q "laravel/socialite" composer.json; then
  echo " Instalando laravel/socialite..."
  as_laravel "COMPOSER_MEMORY_LIMIT=-1 composer require laravel/socialite --prefer-dist --no-scripts --no-interaction --quiet"
  as_laravel "php artisan package:discover --ansi"
else
  echo "[OK] laravel/socialite ya se encuentra instalado."
fi

php -r '
$servicesFile = "config/services.php";
if (file_exists($servicesFile)) {
  $content = file_get_contents($servicesFile);
  if (!str_contains($content, "\x27google\x27")) {
      $googleConfig = "    \x27google\x27 => [\n        \x27client_id\x27 => env(\x27GOOGLE_CLIENT_ID\x27),\n        \x27client_secret\x27 => env(\x27GOOGLE_CLIENT_SECRET\x27),\n        \x27redirect\x27 => env(\x27GOOGLE_REDIRECT_URI\x27),\n    ],\n\n];";
      $content = preg_replace("/\];\s*$/", $googleConfig, $content);
      file_put_contents($servicesFile, $content);
  }
}
'

# ------------------------------------------------------------------------------
# 6. MIGRACIÓN PARA CAMPOS GOOGLE EN LA TABLA USERS
# ------------------------------------------------------------------------------
echo " [4/9] Creando migración de base de datos..."

TIMESTAMP=$(date +%Y_%m_%d_%H%M%S)
MIGRATION_FILE="database/migrations/${TIMESTAMP}_add_google_fields_to_users_table.php"

cat << 'EOF' > "$MIGRATION_FILE"
<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
  public function up(): void
  {
      Schema::table('users', function (Blueprint $table) {
          if (!Schema::hasColumn('users', 'google_id')) {
              $table->string('google_id')->nullable()->after('id');
          }
          if (!Schema::hasColumn('users', 'avatar')) {
              $table->string('avatar')->nullable()->after('email');
          }
          $table->string('password')->nullable()->change();
      });
  }

  public function down(): void
  {
      Schema::table('users', function (Blueprint $table) {
          if (Schema::hasColumn('users', 'google_id')) {
              $table->dropColumn('google_id');
          }
          if (Schema::hasColumn('users', 'avatar')) {
              $table->dropColumn('avatar');
          }
      });
  }
};
EOF

# ------------------------------------------------------------------------------
# 7. CREAR CONTROLADOR DE AUTENTICACIÓN (SocialiteController.php)
# ------------------------------------------------------------------------------
echo " [5/9] Generando app/Http/Controllers/Auth/SocialiteController.php..."

mkdir -p app/Http/Controllers/Auth

cat << 'EOF' > app/Http/Controllers/Auth/SocialiteController.php
<?php

namespace App\Http\Controllers\Auth;

use App\Http\Controllers\Controller;
use App\Models\User;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\Auth;
use Illuminate\Support\Facades\Log;
use Illuminate\Support\Str;
use Laravel\Socialite\Facades\Socialite;

class SocialiteController extends Controller
{
  public function showLoginForm()
  {
      if (Auth::check()) {
          return redirect()->route('home');
      }
      return view('auth.login');
  }

  public function login(Request $request)
  {
      $credentials = $request->validate([
          'email'    => ['required', 'email'],
          'password' => ['required'],
      ]);

      if (Auth::attempt($credentials, $request->boolean('remember'))) {
          $request->session()->regenerate();
          return redirect()->intended('/home');
      }

      return back()->withErrors([
          'email' => 'Las credenciales no coinciden con nuestros registros.',
      ])->onlyInput('email');
  }

  public function redirectToGoogle()
  {
      return Socialite::driver('google')->redirect();
  }

  public function handleGoogleCallback()
  {
      try {
          $googleUser = Socialite::driver('google')->user();

          $user = User::updateOrCreate(
              ['email' => $googleUser->getEmail()],
              [
                  'name' => $googleUser->getName() ?? $googleUser->getNickname(),
                  'google_id' => $googleUser->getId(),
                  'avatar' => $googleUser->getAvatar(),
                  'password' => bcrypt(Str::random(32)),
              ]
          );

          Auth::login($user, true);
          request()->session()->regenerate();

          return redirect()->intended('/home');

      } catch (\Exception $e) {
          Log::error('Error en callback de Google: ' . $e->getMessage());
          return redirect()->route('login')->with('error', 'Error al autenticar con Google: ' . $e->getMessage());
      }
  }

  public function logout(Request $request)
  {
      Auth::logout();
      $request->session()->invalidate();
      $request->session()->regenerateToken();
      return redirect()->route('login');
  }
}
EOF

# ------------------------------------------------------------------------------
# 8. CREAR VISTA WELCOME EN /home (resources/views/welcome.blade.php)
# ------------------------------------------------------------------------------
echo " [6/9] Creando la vista principal en resources/views/welcome.blade.php..."

cat << 'EOF' > resources/views/welcome.blade.php
<!DOCTYPE html>
<html lang="es" class="dark">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Home</title>
  <script src="https://cdn.tailwindcss.com"></script>
</head>
<body class="bg-slate-950 text-slate-100 min-h-screen flex flex-col justify-between font-sans antialiased">
    
  <header class="w-full max-w-7xl mx-auto p-6 flex justify-between items-center">
      <div class="flex items-center gap-3">
          <span class="text-2xl font-extrabold tracking-wider text-white">SysLab</span>
      </div>

      <nav class="flex items-center gap-4">
          @auth
              <div class="flex items-center gap-3 bg-slate-900 border border-slate-800 px-4 py-2 rounded-full shadow-md">
                  @if(Auth::user()->avatar)
                      <img src="{{ Auth::user()->avatar }}" alt="Avatar" class="w-8 h-8 rounded-full border border-slate-700">
                  @endif
                  <span class="text-sm font-semibold text-slate-200">{{ Auth::user()->name }}</span>
                  <form action="{{ route('logout') }}" method="POST" class="inline">
                      @csrf
                      <button type="submit" class="text-xs bg-red-600/20 hover:bg-red-600 text-red-400 hover:text-white font-semibold px-3 py-1 rounded-full transition duration-150">
                          Cerrar Sesión
                      </button>
                  </form>
              </div>
          @else
              <a href="{{ route('login') }}" class="px-5 py-2.5 bg-red-600 hover:bg-red-500 text-white font-semibold rounded-xl text-sm shadow-md transition duration-150">
                  Iniciar Sesión
              </a>
          @endauth
      </nav>
  </header>

  <main class="flex-1 flex items-center justify-center px-6">
      <div class="max-w-3xl text-center space-y-6">
          <h1 class="text-5xl font-extrabold tracking-tight sm:text-6xl text-white">
              Bienvenido a SysLab
          </h1>
          <p class="text-lg text-slate-400 max-w-2xl mx-auto">
              Estás en la ruta <code class="text-red-400 font-mono bg-slate-900 px-2 py-1 rounded border border-slate-800">/home</code>.
          </p>

          @guest
              <div class="pt-4">
                  <a href="{{ route('login') }}" class="inline-flex items-center justify-center px-8 py-4 text-base font-semibold rounded-xl text-white bg-red-600 hover:bg-red-500 shadow-lg shadow-red-600/25 transition duration-200">
                      Ir al Login / Google OAuth
                  </a>
              </div>
          @else
              <div class="pt-4 bg-slate-900/80 border border-slate-800 rounded-2xl p-6 max-w-md mx-auto shadow-xl">
<p class="text-sm text-slate-400">Has iniciado sesión correctamente como:</p>
                   <p class="text-lg font-bold text-white mt-1">{{ Auth::user()->email }}</p>
               </div>
           @endguest
      </div>
  </main>

  <footer class="py-6 text-center text-sm text-slate-500 border-t border-slate-900">
      SysLab Web Application &bull; Google OAuth2 Integrated
  </footer>
</body>
</html>
EOF

# ------------------------------------------------------------------------------
# 9. CREAR VISTA DE LOGIN (/login)
# ------------------------------------------------------------------------------
echo " [7/9] Creando vista de Login con Tema Oscuro en resources/views/auth/login.blade.php..."

mkdir -p resources/views/auth

cat << 'EOF' > resources/views/auth/login.blade.php
<!DOCTYPE html>
<html lang="es" class="dark">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <meta name="csrf-token" content="{{ csrf_token() }}">
  <title>Iniciar Sesión - SysLab</title>
  <script src="https://cdn.tailwindcss.com"></script>
</head>
<body class="bg-slate-950 text-slate-100 antialiased font-sans selection:bg-red-500 selection:text-white">

  <div class="min-h-screen flex flex-col justify-center items-center p-4 sm:p-6">
      <div class="w-full max-w-md bg-slate-900/90 backdrop-blur-md rounded-2xl shadow-2xl border border-slate-800 p-6 sm:p-8 relative overflow-hidden">
            
          <div class="absolute -top-24 -left-24 w-48 h-48 bg-red-500/10 rounded-full blur-3xl pointer-events-none"></div>

          @if (session('error'))
              <div class="mb-6 p-4 bg-red-500/10 border border-red-500/30 rounded-xl text-red-400 text-sm flex items-start gap-3">
                  <svg class="w-5 h-5 text-red-400 shrink-0 mt-0.5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                      <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 8v4m0 4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z"/>
                  </svg>
                  <span>{{ session('error') }}</span>
              </div>
          @endif

          <div class="text-center mb-8">
              <h1 class="text-3xl font-extrabold text-white tracking-tight">Bienvenido</h1>
              <p class="text-slate-400 text-sm mt-2">Inicia sesión para acceder a tu cuenta</p>
          </div>

          <form id="loginForm" method="POST" action="{{ route('login') }}" class="space-y-5">
              @csrf
              <div>
                  <label for="email" class="block text-sm font-medium text-slate-300 mb-2">Correo Electrónico</label>
                  <input 
                      type="email" 
                      id="email" 
                      name="email" 
                      value="{{ old('email') }}" 
                      required 
                      autofocus
                      placeholder="tu@correo.com"
                      class="w-full px-4 py-3 bg-slate-800/60 border border-slate-700/80 rounded-xl text-white placeholder-slate-500 focus:outline-none focus:ring-2 focus:ring-red-500 focus:border-transparent transition duration-200"
                  >
                  @error('email')
                      <span class="text-xs text-red-400 mt-1 block">{{ $message }}</span>
                  @enderror
              </div>

              <div>
                  <label for="password" class="block text-sm font-medium text-slate-300 mb-2">Contraseña</label>
                  <input 
                      type="password" 
                      id="password" 
                      name="password" 
                      required
                      placeholder="••••••••"
                      class="w-full px-4 py-3 bg-slate-800/60 border border-slate-700/80 rounded-xl text-white placeholder-slate-500 focus:outline-none focus:ring-2 focus:ring-red-500 focus:border-transparent transition duration-200"
                  >
                  @error('password')
                      <span class="text-xs text-red-400 mt-1 block">{{ $message }}</span>
                  @enderror
              </div>

              <button 
                  type="submit" 
                  id="btnSubmit"
                  class="w-full py-3.5 px-4 bg-red-600 hover:bg-red-500 active:bg-red-700 text-white font-semibold rounded-xl shadow-lg shadow-red-600/25 transition duration-200 flex items-center justify-center gap-2"
              >
                  <span id="btnText">Iniciar Sesión</span>
              </button>
          </form>

          <div class="relative my-6">
              <div class="absolute inset-0 flex items-center">
                  <div class="w-full border-t border-slate-800"></div>
              </div>
              <div class="relative flex justify-center text-xs uppercase">
                  <span class="bg-slate-900 px-3 text-slate-500 font-medium">O continúa con</span>
              </div>
          </div>

          <a 
              href="{{ route('google.redirect') }}" 
              class="w-full flex items-center justify-center gap-3 py-3 px-4 bg-slate-800/80 hover:bg-slate-800 border border-slate-700/80 rounded-xl text-slate-200 font-medium transition duration-200 group"
          >
              <svg class="w-5 h-5 transition-transform group-hover:scale-110" viewBox="0 0 24 24">
                  <path fill="#EA4335" d="M12 5c1.6 0 3 .6 4.1 1.6l3.1-3.1C17.3 1.7 14.8 1 12 1 7.5 1 3.7 3.6 1.9 7.3l3.7 2.9C6.5 7.2 9 5 12 5z"/>
                  <path fill="#4285F4" d="M23.5 12.3c0-.8-.1-1.6-.2-2.3H12v4.5h6.5c-.3 1.5-1.1 2.8-2.4 3.7l3.7 2.9c2.2-2 3.7-5 3.7-8.8z"/>
                  <path fill="#FBBC05" d="M5.6 14.8c-.3-.8-.4-1.7-.4-2.8s.1-2 .4-2.8L1.9 6.3C.7 8.7 0 10.3 0 12s.7 3.3 1.9 5.7l3.7-2.9z"/>
                  <path fill="#34A853" d="M12 23c3.2 0 6-1.1 8-3l-3.7-2.9c-1.1.7-2.5 1.2-4.3 1.2-3 0-5.5-2.2-6.4-5.2L1.9 16C3.7 19.7 7.5 23 12 23z"/>
              </svg>
              <span>Inicia sesión con Google</span>
          </a>

          <div class="text-center mt-6">
              <a href="{{ route('home') }}" class="text-sm text-slate-400 hover:text-slate-200 transition inline-flex items-center gap-1">
                  <span>←</span> Volver a Home
              </a>
          </div>

      </div>
  </div>
</body>
</html>
EOF

# ------------------------------------------------------------------------------
# 10. REGISTRAR RUTAS EN ROUTES/WEB.PHP
# ------------------------------------------------------------------------------
echo " [8/9] Configurando rutas en routes/web.php..."

cat << 'EOF' > routes/web.php
<?php

use Illuminate\Support\Facades\Route;
use App\Http\Controllers\Auth\SocialiteController;

Route::redirect('/', '/login');

Route::get('/home', function () {
  return view('welcome');
})->name('home');

Route::get('/login', [SocialiteController::class, 'showLoginForm'])->name('login');
Route::post('/login', [SocialiteController::class, 'login'])->middleware('throttle:5,1');
Route::get('/auth/google/redirect', [SocialiteController::class, 'redirectToGoogle'])->name('google.redirect');
Route::get('/auth/google/callback', [SocialiteController::class, 'handleGoogleCallback'])->name('google.callback');
Route::post('/logout', [SocialiteController::class, 'logout'])->name('logout');
EOF

# ------------------------------------------------------------------------------
# 11. MIGRACIONES Y LIMPIEZA
# ------------------------------------------------------------------------------
echo " [9/9] Ejecutando migraciones y limpiando caché..."

# Archivos creados por este script (controller, vistas, migración) pertenecen
# al usuario laravel, no a root.
chown -R "$LARAVEL_USER":"$LARAVEL_USER" \
  app/Http/Controllers/Auth \
  resources/views/auth \
  resources/views/welcome.blade.php \
  "$MIGRATION_FILE"

as_laravel "php artisan migrate --force"
as_laravel "php artisan optimize:clear"

if systemctl is-active --quiet octane 2>/dev/null; then
  echo " Reiniciando Octane Server..."
  sudo systemctl restart octane
fi

echo "=========================================================================="
echo " CONFIGURACIÓN COMPLETADA "
echo "=========================================================================="
echo " Redirección raíz:  $APP_URL/      -->  $APP_URL/login"
echo " Pantalla de Login: $APP_URL/login (Tema Oscuro)"
echo " Pantalla Home:     $APP_URL/home"
echo " Callback Google:   $GOOGLE_REDIRECT_URI"
echo "=========================================================================="
