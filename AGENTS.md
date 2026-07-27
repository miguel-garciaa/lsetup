# AGENTS.md

## Contexto
Colección de scripts Bash para aprovisionar y bastionar un servidor **AlmaLinux/Rocky 10** remoto (stack Laravel 13 + PHP 8.4 + PostgreSQL 18 + Redis 7 + Filament 5 + Octane/FrankenPHP + Nginx). **Este repo se edita en Windows pero los scripts NUNCA se ejecutan aquí**: se copian al servidor por `scp`/`ssh` (ver `ssh.txt`, comando PowerShell para subir clave pública). No hay tests, CI ni build: verificar sintaxis con `bash -n <script>.sh` antes de dar por bueno un cambio.

## Scripts y orden de ejecución (en el servidor, como root/sudo)
1. `setup.sh` — instalador completo del stack. Interactivo (prompts). Idempotente por diseño (guardas `|| true`, `if [ ! -d vendor ]`...).
2. `cloudflare.sh` — dominio + cert Origin Cloudflare + vhost Nginx 443→Octane.
3. `secure.sh` — hardening (sysctl, SSH puerto custom, firewalld, Fail2ban, CrowdSec, ClamAV, AIDE). **Ejecutar el último**: cambia el puerto SSH y restringe por IP; requiere clave pública ya en `authorized_keys` o pierdes acceso. Instala el comando `sec-logs` en el servidor.
4. `login.sh` — añade login + Google OAuth a un proyecto Laravel ya desplegado.
- `clear.sh` — **DESTRUCTIVO**: revierte todo lo de `setup.sh` (borra proyecto, BD, paquetes, repos). Ojo: usa valores hardcodeados (`laravel1`/`laravel`), no los prompts de `setup.sh`.

## Convenciones del repo
- Comentarios, mensajes y prompts **en español**. Mantener.
- `set -e` al inicio (excepto `clear.sh`, que usa `set +e` a propósito para limpieza best-effort).
- Comandos como usuario no-root vía helper `as_laravel()` en `setup.sh`: `sudo -u laravel env HOME=/var/lib/laravel bash -lc "..."`. Composer NUNCA como root ni dentro de `/var/www` (el caché vive en `/var/lib/laravel/.composer`).
- Parches de código PHP con `php -r` o heredoc PHP, **no `sed`** (comentario explícito en `setup.sh`: escaping de backslashes con sed es frágil).
- Heredocs: comillas en `'EOF'` cuando el contenido debe ser literal; sin comillas cuando hay que expandir `$VARS` (y escapar `\$` para vars de Laravel/Nginx). Respetar este patrón al editar.
- Stack target fijo: `dnf`, `systemctl`, `firewalld`, SELinux (`setsebool`/`semanage`/`restorecon`), repos Remi + PGDG. No usar sintaxis apt/Debian.

## Notas verificadas
- `login.sh` tiene su propio helper `as_laravel()` (mismo patrón que `setup.sh`) tras el `cd` al proyecto. Todo composer/artisan va por ahí; los archivos generados se hace `chown` a `laravel` antes de migrar.
- `login.sh`: `cat << 'EOF' > "$MIGRATION_FILE"` usa comillas simples en el heredoc dentro de un script con `set -e` — correcto, no tocar (contenido literal de la migración).
- `cloudflare.sh` exige root (EUID check): los redirects a `/etc/ssl` no usan `sudo`.
- `setup.sh`: `.env` lleva `APP_ENV=local`/`APP_DEBUG=false`, pero `octane.service` exporta `APP_ENV=production` (las vars de entorno reales ganan a `.env` en Laravel). Intencionado; no "corregir" sin hablar con el usuario.
- `setup.sh`: detecta `nproc` y `MemTotal` y calcula tuning dinámico: workers de Octane/FrankenPHP (cap 8; FrankenPHP no usa task-workers), `shared_buffers`/`effective_cache_size`/`work_mem`/`maintenance_work_mem`/`wal_buffers`/parallel workers de PostgreSQL 18 (vía `ALTER SYSTEM` + restart), y `maxmemory`/`io-threads` de Redis. No hardcodear estos valores: se derivan de `CPU_CORES`/`RAM_MB`.
- `setup.sh`: Octane usa **FrankenPHP** (no Swoole). `octane:install --server=frankenphp` descarga el binario estático de FrankenPHP (embeds PHP 8.4 + extensiones: pgsql, pdo_pgsql, redis, gd, intl, bcmath, opcache). El `php-pecl-swoole` ya no se instala; el binario es independiente del PHP de sistema (que sigue usándose para artisan/composer). `.env` lleva `OCTANE_SERVER=frankenphp`.
- `setup.sh`: `DB_NAME`/`DB_USER` validados contra `^[A-Za-z_][A-Za-z0-9_]*$`; `DB_PASS` escapado para SQL (doble comilla simple). No usar `sed`/`psql` con estos valores sin mantener el escapado.
- `login.sh`: `set_env_var()` reescribe `.env` con `grep -v` + `printf` (no `sed`) para evitar inyección desde `GOOGLE_CLIENT_SECRET`. Mantiene ownership `laravel:laravel`.
- `login.sh`: POST `/login` lleva `throttle:5,1` (anti-brute-force).
- `cloudflare.sh`: vhost 443 incluye HSTS + `ssl_session_cache`.
- `secure.sh`: sshd endurecido con `MaxAuthTries 3`, `LoginGraceTime 30`, `ClientAliveInterval 300`, `ClientAliveCountMax 2`, `AllowUsers $SSH_USER`.
- `clear.sh`: **no** revierte `secure.sh` (avisa al inicio). Hardening SSH/firewalld/Fail2ban/CrowdSec/AIDE/sudoers permanece.

## Seguridad al editar
- No introducir `chmod 777`, ejecución como root innecesaria ni `PasswordAuthentication yes`.
- `secure.sh` puede dejar al usuario fuera del servidor: cualquier cambio en la lógica de puerto/firewall/claves debe mantener la validación previa de `authorized_keys`.
