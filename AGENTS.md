# AGENTS.md

## Contexto
Colección de scripts Bash para aprovisionar y bastionar un servidor **AlmaLinux/Rocky 10** remoto (stack Laravel 13 + PHP 8.4 + PostgreSQL 18 + Redis 8 + Filament 5 + Octane/FrankenPHP + Nginx). **Este repo se edita en Windows pero los scripts NUNCA se ejecutan aquí**: se copian al servidor por `scp`/`ssh` (ver `ssh.txt`, comando PowerShell para subir clave pública). No hay tests, CI ni build: verificar sintaxis con `bash -n <script>.sh` antes de dar por bueno un cambio.

## Scripts y orden de ejecución (en el servidor, como root/sudo)
1. `setup.sh` — instalador del stack base (sistema, PG18, PHP 8.4, Redis 8, Laravel 13, Octane/FrankenPHP, Nginx). Interactivo (prompts). Idempotente por diseño (guardas `|| true`, `if [ ! -d vendor ]`...). **Ya NO instala Filament ni crea el admin** (va en `panel.sh`).
2. `panel.sh` — instala Filament 5 + Shield + Spatie Media Library + crea el usuario admin. A ejecutar tras `setup.sh`. Pide credenciales de admin.
3. `cloudflare.sh` — dominio + cert Origin Cloudflare + vhost Nginx 443→Octane.
4. `secure.sh` — hardening (sysctl, SSH puerto custom, firewalld, Fail2ban, CrowdSec, ClamAV 1.4.5, AIDE). **24 secciones**. **Ejecutar el último**: cambia el puerto SSH y restringe por IP; requiere clave pública ya en `authorized_keys` o pierdes acceso. Instala el comando `sec-logs` en el servidor. Al final ejecuta `maybe_reboot` (ver más abajo).

## Sistema de backups (v1, scripts aparte)
5. `backup-install.sh` — **SETUP interactivo** de todo el sistema de backups. Pregunta:
   - Cadencia cron: diario / cada_X_días / semanal / mensual + hora (`HH:MM`).
   - Hora de `backup-verify.sh` semanal (default dom `04:30`).
   - Días de retención (default **14 flat** — no GFS, no weekly/monthly).
   - Genera passphrase GPG **simétrica** AES256 en `/root/.backup-key` (chmod 600 + `chattr +i`). **NUNCA se muestra por stdout**; ver con `sudo cat /root/.backup-key` y guardar en Bitwarden/KeePass externo.
   - Persiste `/etc/backup.conf`, instala los 3 scripts en `/usr/local/sbin`, escribe `/etc/cron.d/backup`, fija `RETENTION_DAYS` en conf, ejecuta `maybe_reboot` si tmpfs /tmp estaba en disco.
- `backup.sh` — **motor** (corre desde cron). 3 snapshots: `.db` (pg_dump custom|gzip), `.dat` (Laravel sin .env/vendor/node_modules/cache/logs), `.keyring` (.env+configs sensibles, GPG simétrico AES256). `flock` anti doble-run, `pipefail`, `sha256sum` por archivo, prune flat `$RETENTION_DAYS` (extrae TAGs únicos, borra los >límite con sus 3 ext + .sha256). Escribe `/var/lib/.system-state/logs/state.txt` para `sec-logs`.
- `backup-verify.sh` — cron dom. Recorre `daily/` (no weekly/monthly): `gzip -t` + `pg_restore --list` (.db), `tar -tzf` (.dat), `gpg --list-packets`/decrypt+`tar -t` (.keyring con passphrase). Escribe `verify.state`.
- `restore.sh` — **interactivo manual**: prompt fecha (TAG `YYYYMMDD-HHMM`) + qué (DB/FILES/SECRETS/TODO). Doble confirmación `typear RESTORE`. Doble backup previo estado actual a `.restored-<ts>/`. `restorecon -R` SELinux tras aplicar secrets. NO prompt tier (flat 14d, solo daily).

## Scripts restantes (modifican proyecto ya desplegado)
6. `login.sh` — añade login + Google OAuth a un proyecto Laravel ya desplegado.
- `clear.sh` — **DESTRUCTIVO**: revierte todo lo de `setup.sh` (borra proyecto, BD, paquetes, repos). Ojo: usa valores hardcodeados (`laravel1`/`laravel`), no los prompts de `setup.sh`. **Sección 16 opt-in** pregunta antes de borrar sistema de backups (`/var/lib/.system-state`, passphrase, cron, scripts). Al final ejecuta `maybe_reboot_clear`.

## Helper `maybe_reboot` (交互)
- Definido inline en `secure.sh` (final) y `clear.sh` (`maybe_reboot_clear`). Patrón idéntico:
  1. detecta cambios pendientes de reboot (tmpfs /tmp en disco, GRUB password, `dnf needs-restarting -r`, sysctl `kernel.sysrq` no aplicado en caliente).
  2. instala `at` + `atd` si falta.
  3. prompt: `now` / `HH:MM` / `YYYY-MM-DD HH:MM` / `sun 04:00` / `tomorrow 03:00` (formatos de `at`).
  4. programa via `at` (fallback `shutdown -r`) o `systemctl reboot` si `now`.
  5. Enter = skip (reboot manual).

## Convenciones del repo
- Comentarios, mensajes y prompts **en español**. Mantener.
- `set -e` al inicio (excepto `clear.sh`, que usa `set +e` a propósito para limpieza best-effort).
- Comandos como usuario no-root vía helper `as_laravel()` en `setup.sh`: `sudo -u laravel env HOME=/var/lib/laravel bash -lc "..."`. Composer NUNCA como root ni dentro de `/var/www` (el caché vive en `/var/lib/laravel/.composer`).
- Parches de código PHP con `php -r` o heredoc PHP, **no `sed`** (comentario explícito en `setup.sh`: escaping de backslashes con sed es frágil).
- Heredocs: comillas en `'EOF'` cuando el contenido debe ser literal; sin comillas cuando hay que expandir `$VARS` (y escapar `\$` para vars de Laravel/Nginx). Respetar este patrón al editar.
- Stack target fijo: `dnf`, `systemctl`, `firewalld`, SELinux (`setsebool`/`semanage`/`restorecon`), repos Remi + PGDG. No usar sintaxis apt/Debian.

## Notas verificadas
- `login.sh` tiene su propio helper `as_laravel()` (mismo patrón que `setup.sh`) tras el `cd` al proyecto. Todo composer/artisan va por ahí; los archivos generados se hace `chown` a `laravel` antes de migrar.
- `panel.sh` replica el helper `as_laravel()` (mismo patrón). Tras `filament:install --panels`, parchea `AdminPanelProvider.php` con `->login()` (vía heredoc PHP): sin ello, `/admin` redirige a la ruta genérica `login` inexistente → `RouteNotFoundException`. No usar `sed` para el parche.
- `login.sh`: `cat << 'EOF' > "$MIGRATION_FILE"` usa comillas simples en el heredoc dentro de un script con `set -e` — correcto, no tocar (contenido literal de la migración).
- `cloudflare.sh` exige root (EUID check): los redirects a `/etc/ssl` no usan `sudo`.
- `setup.sh`: `.env` lleva `APP_ENV=local`/`APP_DEBUG=false`, pero `octane.service` exporta `APP_ENV=production` (las vars de entorno reales ganan a `.env` en Laravel). Intencionado; no "corregir" sin hablar con el usuario.
- `setup.sh`: detecta `nproc` y `MemTotal` y calcula tuning dinámico: workers de Octane/FrankenPHP (cap 8; FrankenPHP no usa task-workers), `shared_buffers`/`effective_cache_size`/`work_mem`/`maintenance_work_mem`/`wal_buffers`/parallel workers de PostgreSQL 18 (vía `ALTER SYSTEM` + restart), y `maxmemory`/`io-threads` de Redis. No hardcodear estos valores: se derivan de `CPU_CORES`/`RAM_MB`.
- `setup.sh`: Octane usa **FrankenPHP** (no Swoole). `octane:install --server=frankenphp` descarga el binario estático de FrankenPHP (embeds PHP 8.4 + extensiones: pgsql, pdo_pgsql, redis, gd, intl, bcmath, opcache). El `php-pecl-swoole` ya no se instala; el binario es independiente del PHP de sistema (que sigue usándose para artisan/composer). `.env` lleva `OCTANE_SERVER=frankenphp`.
- `setup.sh`: `DB_NAME`/`DB_USER` validados contra `^[A-Za-z_][A-Za-z0-9_]*$`; `DB_PASS` escapado para SQL (doble comilla simple). No usar `sed`/`psql` con estos valores sin mantener el escapado.
- `login.sh`: `set_env_var()` reescribe `.env` con `grep -v` + `printf` (no `sed`) para evitar inyección desde `GOOGLE_CLIENT_SECRET`. Mantiene ownership `laravel:laravel`.
- `login.sh`: POST `/login` lleva `throttle:5,1` (anti-brute-force).
- `cloudflare.sh`: vhost 443 incluye HSTS + `ssl_session_cache`.
- `secure.sh`: sshd endurecido con `MaxAuthTries 3`, `LoginGraceTime 30`, `ClientAliveInterval 300`, `ClientAliveCountMax 2`, `AllowUsers $SSH_USER`, `MaxStartups 10:30:60`, `MaxSessions 2`, `AllowTcpForwarding no`, `AllowAgentForwarding no`, `PermitTunnel no`, `X11Forwarding no`, crypto moderno (`curve25519-sha256`, `chacha20-poly1305@openssh.com`, `aes256-gcm@openssh.com`, `ssh-ed25519`).
- `secure.sh`: re-escribe `00-hardening.conf` drop-in preservando estado 2FA de `2fa.sh` (detecta `pam_google_authenticator` en PAM + lee `KbdInteractiveAuthentication`/`AuthenticationMethods` actuales). Re-ejecutar `secure.sh` NO desactiva 2FA.
- `secure.sh`: Redis `requirepass` + `rename-command FLUSHALL/FLUSHDB/CONFIG/KEYS/SHUTDOWN/DEBUG ""` parcheando Laravel `.env` `REDIS_PASSWORD=` (chown laravel:laravel, chmod 600).
- `backup.sh`: credenciales DB leídas de `.env` con `awk` (NO `source .env` — evita inyección). `.env` **NUNCA** en `.dat` plano (solo en `.keyring` GPG-cifrado).
- `clear.sh`: **no** revierte `secure.sh` (avisa al inicio). Hardening SSH/firewalld/Fail2ban/CrowdSec/AIDE/sudoers permanece.

## Seguridad al editar
- No introducir `chmod 777`, ejecución como root innecesaria ni `PasswordAuthentication yes`.
- `secure.sh` puede dejar al usuario fuera del servidor: cualquier cambio en la lógica de puerto/firewall/claves debe mantener la validación previa de `authorized_keys`.
