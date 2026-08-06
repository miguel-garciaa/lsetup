# AGENTS.md — LSETUP

## 1. Contexto y Entorno

- **Objetivo:** Binario Go `lsetup` que aprovisiona y bastiona un servidor **AlmaLinux 10.x / RHEL 10** con stack Laravel, y orquesta todos los scripts Bash embebidos.
- **Stack:** Laravel 13, **PHP 8.5** (Remi), PostgreSQL 18, Redis 8, Filament 5, Octane (FrankenPHP binario estático), Nginx, systemd, SELinux, firewalld.
- **Flujo de trabajo:** El repo se edita en Windows. El binario `lsetup` se compila y **se ejecuta en el servidor** como root. Los scripts Bash fuente viven en `SH/`; la copia embebible vive en `GO/SH/` porque `//go:embed` no puede leer fuera del directorio del paquete Go. Subida de clave pública previa: ver `SSH/ssh.txt`.
- **Skills del repo:** Antes de tocar codigo, scripts, hardening o DB/Redis, cargar las skills locales relevantes en `AGENTS/skills/` (`golang`, `bash-scripting`, `seguridad-vps`, `postgres-redis`, y las que apliquen al cambio). Si una skill local no se puede leer, indicarlo y seguir con la mejor alternativa.
- **Validación:** Sin tests/CI. Verificar con `go build ./...` (en `GO/`) y `bash -n GO/SH/<script>.sh` antes de dar por bueno un cambio.
- **Componentes post-deploy:** Tras `lsetup up` exitoso el proyecto Laravel queda desplegado y sirviendo, pero la página está vacía. `COMPONENTS/` contiene scripts Bash independientes para automatizar el desarrollo web (login, Google Ads, panel Filament). No forman parte del pipeline `up`.

## 2. Arquitectura: binario Go `GO/`

- **`main.go`** — Dispatcher de subcomandos: `init | up | debug <cmd> | 2fa --on/--off | status | backup | backup-verify | restore`. Soporta alias por basename (si el binario se copia a `/usr/local/bin/status`, `/usr/local/bin/backup`, etc. tras `lsetup up` exitoso, responde a ese nombre sin prefijo).
- **`sections.go`** — Reescritura **nativa Go** de `setup.sh` (no lanza bash). Funciones `s1_repos` … `s11_arranque` ejecutan `dnf`, `systemctl`, `psql`, `composer`, `php artisan` directamente vía `os/exec`. `runSetup()` orquesta s1..s11.
- **`sections_subcmd.go`** — Implementa `cmdUp` (pipeline) y embebe `GO/SH/*.sh` con `//go:embed` (`shSecure`, `shWaf`, `shHarden`, `shDominio`, `shBackupInstall`, `shBackup`, `shBackupVerify`, `shRestore`, `sh2fa`). `runEmbedded()` escribe el script a un tmpfile (strip CRLF→LF) y lo ejecuta con `bash` preservando stdin/stdout/stderr (interactividad).
- **`sections_status.go`** — `cmdStatus` embebe `GO/SH/status.sh` vía `//go:embed statusSh` y lo corre con `bash -s` (stdin). Flag `--install` despliega alias a `/usr/local/bin/status`.
- **`runner.go`** — Helpers de ejecución: `runStrict`/`runIgnore`/`runCmdPassthrough` (streams live), `asLaravel`/`asLaravelStrict` (sudo -u laravel con `HOME`/`COMPOSER_HOME` correctos), `runParallel` (setsebool/semanage en goroutines), `syncClockHTTP` (workaround VBox/PGDG).
- **`config.go`** — Parser INI multi-sección genérico. Soporta `key=val`, `#` comentarios, e inline heredoc `key<<DELIM` (para PEM multi-línea como `cloudflare_cert`). API: `loadConfig`, `Section`, `SectionExists`, `RemoveSection`, `save`, `exportEnv`, `fillInteractive`.
- **`templates.go`** — Plantillas: `tplLsetupConf` (config INI con `__REDIS_PASS__` placeholder), `tplEnv` (Laravel .env), `tplOctaneService` (systemd), `tplNginxConf`, `tplLaravelVhost` (proxy a Octane 127.0.0.1:8000), `tplLimitsAppend`, `tplSysctlAppend`, `tplRedisAppend`.
- **`validate.go`** — Struct `SetupConfig`. Anti-inyección PostgreSQL (`identPG` regex `^[A-Za-z_][A-Za-z0-9_]*$`, `escapeSQLSingleQuote`). `readPassFile` exige perms `&0077 == 0`. `loadSetupConfig` deriva `ProyectosDir=/var/www`, `ProyectoDir=/var/www/<project>`, `LaravelUser=laravel`.
- **Modo debug:** `lsetup debug <cmd>` inyecta `LSETUP_DEBUG=1` en env. Los scripts bash lo inspeccionan: si `1` → `set -x`, logs de `dnf`/`configure`/`make` fluyen directo a stdout/stderr (no a `/tmp/*.log`). Útil en desarrollo.

## 3. Config `lsetup.conf` (multi-sección INI)

Generado por `lsetup init [--force]` (autogen `redis_pass` hex 48 con `openssl rand`, fallback `crypto/rand`). Secciones:

| Sección           | Obligatoria | Claves | Notas |
|-------------------|-------------|--------|-------|
| `[setup]`         | Sí (para `up`) | `project`, `db_name`, `db_user`, `db_pass` o `db_pass_file` | `laravel1` default. Validación regex identPG. |
| `[dominio]`       | No  | `domain_name`, `proyecto_dir`, `cloudflare_cert<<EOF`, `cloudflare_key<<EOF` | Vacía → `up` skip dominio. PEM multi-línea vía heredoc inline. |
| `[github]`        | No  | `github_user`, `github_token` (PAT) | Usado por `waf.sh` para `git clone` libmodsecurity sin rate-limit anónimo. Vacía → clone anónimo (puede fallar). |
| `[harden]`        | No  | `enc_confirm` (s=aplicar `SESSION_ENCRYPT` default, n=posponer) | Vacía → `up` aplica default `s` silencioso (sin prompt). |
| `[secure]`        | No  | `allowed_ip`, `ssh_port`, `ssh_user`, `redis_pass` (REQUERIDOS), `report_email`, `reboot_schedule` | Vacía → `up` skip hardening. |
| `[backup-install]`| No  | `cad_opt`, `bk_time`, `x_days`, `wd`, `md`, `vf_time`, `ret_days` | Vacía → `up` skip backups. |

**Auto-shred:** tras cada paso del pipeline exitoso, `cmdUp` borra del config la sección consumida (`cf.RemoveSection`). Si era la última sección, borra el archivo físico.

## 4. Pipeline `lsetup up` (orden estricto)

1. **setup** — REQUIRED. Reescritura Go-native (`sections.go` s1..s11). Auto-shred `[setup]` tras éxito. Idempotente vía `vendor/` existe.
2. **dominio** — skip si `[dominio]` vacío. Exporta solo `domain_name`/`proyecto_dir`/`cloudflare_cert`/`cloudflare_key`.
3. **waf** — siempre. Pre-exporta creds `[github]` si existen.
4. **harden** — siempre. Default `ENC_CONFIRM=s` silence (sin prompt) si `[harden]` vacía.
5. **secure** — skip si `[secure]` vacío. **REQUIRES** `allowed_ip`, `ssh_port`, `ssh_user`, `redis_pass`. Último paso de hardening.
6. **backup-install** — skip si `[backup-install]` vacío.

Tras pipeline completo y exitoso: despliega aliases `status`/`backup`/`backup-verify`/`restore` a `/usr/local/bin/` (chmod 0755), activando invocación `sudo status` == `sudo lsetup status`.

## 5. Scripts `SH/` — detalle por script

Todos embebidos en el binario Go vía `//go:embed` y ejecutados con `bash` vía `runEmbedded` (preserva interactividad). Se editan en el repo Windows; tras rebuild del binario, se reempaquetan.

### 5.1 `setup.sh` (552 líneas) — Instalador base
Cabecera: "INSTALADOR LARAVEL 13 + PHP 8.5 + PostgreSQL 18 + Redis 8 + Filament 5". **No** instala Filament ni crea admin. Tuning dinámico de recursos derivado de `CPU_CORES`/`RAM_MB` (`nproc`/`MemTotal`). Nota: `sections.go` es la reescritura nativa Go de este script; si se edita aquí, actualizar también `sections.go`.
- Secciones: 1 Preparación sistemas+repos / 2 Firewall / 3 PostgreSQL 18 / 4 Usuario laravel (no-root) / 5 PHP 8.5 + Composer / 6 Redis (phpredis) / 7 Creación proyecto Laravel 13 / 8 Generación .env / 9 Octane+FrankenPHP+systemd / 10 Nginx+SELinux+permisos / 11 Arranque final.

### 5.2 `dominio.sh` (275 líneas) — Dominio + Cloudflare
Requiere root estricto (sin `sudo`) por redireccionamientos a `/etc/ssl`. Configura certificado Origin Cloudflare y vhost Nginx 443 con HSTS y `ssl_session_cache`.
- Secciones: 1 Solicitar dominio / 2 Captura certificado origen / 3 Captura clave privada / 4 nginx.conf / 5 Abrir 443 firewall / 6 Validar+reiniciar nginx / 7 Actualizar APP_URL en .env (HTTPS).

### 5.3 `waf.sh` (441 líneas) — ModSecurity v3 + OWASP CRS 4
Defense-in-depth fase 2. **PBE:** `SecRuleEngine DetectionOnly` → 4 días de log → calibrar → flipar a `On`. NUNCA flipar a `On` sin revisar `/var/log/modsec/audit.log` (CRS 4 rompe uploads Filament Media Library por multipart regex 942100). Respeta `LSETUP_DEBUG=1` (verbose total).
- Secciones: 1 Dependencias build+runtime / 2 Localizar módulo ModSecurity precompilado (EPEL/nginx.org) / 3 Fallback compilar libmodsecurity v3 + nginx connector / 4 Descargar OWASP CRS 4 + config ModSecurity / 5 Cargar módulo en nginx.conf + snippet + include vhosts 443 / 6 Validar+recargar nginx.

### 5.4 `harden.sh` (270 líneas) — Capa app Laravel
Idempotente. Solo reporta código PHP (`$fillable`, rutas); parchea `.env` + systemd `EnvironmentFile` (mirror aditivo) + cron audit. **NO** toca `APP_KEY`. Panic guard: `as_laravel` siempre, `chown laravel:laravel` tras `.env`, NO `SESSION_ENCRYPT` sin ventana confirmada (invalida sesiones activas).
- Secciones: 1 Audit `$fillable`/`$guarded` (solo reporta) / 2 `APP_DEBUG=false` + `APP_ENV` consistente / 3 Session hardening (secure cookie + SameSite=lax + prompt ENCRYPT) / 4 Throttle rutas sensibles (solo reporta + snippets) / 5 Secretos → systemd EnvironmentFile (root:root 600) / 6 Cron semanal composer audit + npm audit.

### 5.5 `secure.sh` (1576 líneas) — Bastionado integral
No instala 2FA (lo gestiona `2fa.sh` aparte). Idempotente: re-ejecutable sin romper estado `2fa.sh`. `safe_nginx_apply()` recarga nginx sin restart (evita efecto 521 con config rota).
- Secciones: 0 Recolección parámetros / 0.5 Preflight reloj (chrony) / 1 Kernel + sysctl agresivo / 2 SSH avanzado / 3 Firewalld zona public / 4 Fail2ban / 5 CrowdSec + colecciones anti-portscan/ssh/nginx / 6 Nginx hardening + Cloudflare IPs + bloqueo `/.env` / 7 TLS moderno + headers + rate limiting / 8 Antimalware ClamAV + Rkhunter / 9 Persistencia rootless (linger) / 10 Panel auditoría `sec-logs` ampliado / 11 AIDE / 12 Redis hardening / 13 Modprobe blacklist / 14 Systemd-coredump off / 15 Tmpfs hardening / 16 Auditd + reglas realtime / 17 DNF-automatic / 18 PostgreSQL hardening / 19 PWQUALITY + login.defs / 20 Deshabilitar servicios innecesarios / 23 Cron diario scan security / 24 Sudo hardening para `$SSH_USER`.
- **ADVERTENCIA CRÍTICA:** Cambia el puerto SSH y restringe por IP (`allowed_ip`). Requiere clave pública pre-configurada en `authorized_keys` o se pierde acceso permanentemente.

### 5.6 `status.sh` (143 líneas) — Panel auditoría
Embebido en binario Go (`sections_status.go`). Si `/usr/local/bin/sec-logs` existe (instalado por `secure.sh`), lo invoca y luego añade sección de servicios.
- Secciones: 1 Panel sec-logs / 1.5 Resumen rápido servicios (is-active + octane healthz) / 2 Servicios LSETUP estado profundo (DB+HTTP: `psql SELECT 1`, `redis-cli ping`, `nginx -t`, HTTP GET `/healthz` → 200 `{"status":"UP"}`, `firewall-cmd --state`, `chronyc tracking`, `fail2ban-client status`, `cscli status`, `crowdsec-firewall-bouncer`).

### 5.7 `2fa.sh` (177 líneas) — Toggle 2FA SSH
Requisito: `secure.sh` ya ejecutado (existe `/etc/ssh/sshd_config.d/00-hardening.conf`).
- `sudo lsetup 2fa --on` → activa (genera o reusa secreto TOTP Google Authenticator PAM).
- `sudo lsetup 2fa --off` → desactiva (vuelve a pubkey-only).
- `--install` → despliega alias a `/usr/local/bin/2fa`.

### 5.8 `backup-install.sh` (296 líneas) — Setup sistema backups v1
Configura cron, hora verificación y días retención (**flat 14 días, sin GFS**). Genera passphrase GPG simétrica AES256 en `/root/.backup-key` (invisible por stdout, respaldar externamente). Persiste en `/etc/backup.conf`.
- Secciones: 1 Dependencias / 2 Ruta oculta + estructura (solo `daily/`) / 3 Passphrase GPG (autogen) / 4 Determinar ruta proyecto Laravel / 4b Menú cron — cadencia + hora backup + verify semanal / 5 Instalar scripts en `/usr/local/sbin` / 6 Entradas cron / 7 Test rápido.

### 5.9 `backup.sh` (325 líneas) — Motor cron
Genera 3 snapshots por run: `.db` (`pg_dump --format=custom | gzip -9`), `.dat` (Laravel sin `.env`/vendor/node_modules/storage/logs/cache), `.keyring` (`.env` + configs sensibles — GPG simétrico AES256). Lee credenciales DB del `.env` vía `awk` (nunca `source`). `flock` + `sha256sum`.
- Secciones: 1 Detectar Laravel + creds DB + Redis (de `.env`, NO source) / 2 Snapshot .db PostgreSQL / 3 Snapshot .dat Laravel files / 4 Snapshot .keyring (.env + configs, GPG AES256) / 5 Rotación flat — prune `> $RETENTION_DAYS` días.

### 5.10 `backup-verify.sh` (153 líneas) — Verificación integridad
Cron dom 04:30. `set -uo pipefail` (NO `-e`: reporta todos los fallos, no aborta al primero). Exit 0 si todo OK, 1 si al menos 1 fail.
- `verify_one()` por extensión: `.db` (`gzip -t` + `gunzip | pg_restore --list`), `.dat` (`gzip -t` + `tar -tzf`), `.keyring` (`gpg --decrypt --passphrase-file` + `tar -t`, fallback `gpg --list-packets` sin clave).

### 5.11 `restore.sh` (340 líneas) — Restauración manual interactiva
`set -uo pipefail` (NO `-e`: reporta y para manual cleaner). No destructivo por defecto: copia previas a `/var/lib/.system-state/.restored-<ts>`. Doble confirmación (typear `RESTORE`).
- Pasos: 1 Tier único (flat 14d, solo `daily/`) / 2 Elegir fecha (TAG=YYYYMMDD-HHMM) / 3 Elegir qué restaurar (1 Solo DB / 2 Solo FILES / 3 Solo SECRETS / 4 TODO / 5 Cancelar) / 4 Doble confirmación `RESTORE` / 5 Restore .db PostgreSQL / 6 Restore .dat Laravel files / 7 Restore .keyring (.env + configs, decrypt GPG) / 8 Resumen final.

## 6. `COMPONENTS/` — Automatización post-deploy web

Tras `lsetup up` exitoso, el proyecto Laravel está desplegado y sirviendo pero la página está vacía. Estos scripts Bash **independientes** (no en pipeline `up`) automatizan features web. Se invocan manualmente vía `bash script.sh` desde el directorio del proyecto Laravel.

### 6.1 `panel-vacio.sh` (322 líneas) — Filament 5 base limpio
A ejecutar tras `setup.sh` (requiere proyecto desplegado). **No** instala Shield, **no** Spatie Media Library, **no** roles/permisos. El admin se crea sin rol — el operador decide autorización del panel manualmente (`canAccessPanel`, middleware).
- Secciones: 1 Detección ruta proyecto / 2 Credenciales admin / 3 Diagnóstico pre-Filament (¿Octane bootea?) / 4 Filament 5 / 4.5 Trust proxies (Octane detrás Nginx HTTPS) / 5 Usuario admin panel (sin roles) / 8 Debugbar (solo dev) / 9 Migraciones + storage link + cache / 10 Reiniciar Octane robusto / 11 Banner final.

### 6.2 `panel-shield.sh` (405 líneas) — Filament 5 + Shield + Spatie Permission
Variante con autorización completa. **No** instala Spatie Media Library: el binario estático FrankenPHP no embebe `ext-zip`/`fileinfo` y rompe boot del worker. Re-añadir tras rebuild binario.
- Secciones: 1 Detección ruta proyecto / 2 Credenciales admin / 3 Diagnóstico pre-Filament / 4 Filament 5 / 4.5 Trust proxies / 5 Filament Shield + Spatie Permission / 6 Trait `HasRoles` en `User` / 7 Usuario admin panel / 8 Debugbar (solo dev) / 9 Migraciones + storage link + cache / 10 Reiniciar Octane robusto / 11 Banner final.

### 6.3 `views/login.sh` (~20 KB, 11 secciones) — **WIP**: login Laravel + Google OAuth
Automatización de vista de login. Añade login y Google OAuth a proyectos desplegados. Aplica `throttle:5,1` al `/login` y usa `set_env_var()` con `grep -v` + `printf` (no `sed`) para prevenir inyecciones desde secretos Google. 11 secciones numeradas. En desarrollo.

### 6.4 `google-ads.sh` (53 líneas) — **WIP**: Google AdSense en vistas Laravel
Lee código `gtag` de Google Ads pegado por el operador (vía `cat` hasta Ctrl+D) y genera `resources/views/components/app-layout.blade.php` que embebe el script. A medias — objetivo: posicionar AdSense en cada vista del proyecto Laravel automáticamente.

## 7. `SSH/` — Subida de clave pública

`ssh.txt` contiene comandos PowerShell para:
1. `ssh-keygen -t ed25519 -C "almalinux"` — generar par de claves.
2. Copiar pubkey al servidor: `type $env:USERPROFILE\.ssh\id_ed25519.pub | ssh miguel@192.168.1.10 "mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"`.

Pre-requisito de `secure.sh`: sin clave pública en `authorized_keys` antes de restringir SSH por IP/puerto, se pierde acceso permanentemente.

## 8. Convenciones de código y seguridad

- **Idioma:** Comentarios, mensajes y prompts en **español**.
- **Errores:** `set -e` por defecto. Excepciones intencionadas: `backup-verify.sh` y `restore.sh` usan `set -uo pipefail` (NO `-e`) para reportar todos los fallos sin abortar al primero.
- **Contexto Laravel:** Comandos Composer/Artisan vía `as_laravel()` (`sudo -u laravel env HOME=... COMPOSER_HOME=... bash -lc "cd dir && ..."`). Composer **NUNCA** como root, ni genera caché dentro de `/var/www`.
- **Manipulación de archivos PHP:** Parches vía `php -r` o heredocs. **Jamás `sed`** para evitar roturas por escapes. Heredocs literales: encerrar delimiter en comillas (`'EOF'`); sin comillas si se expanden variables, escapando `\$` de Laravel/Nginx.
- **Integridad de variables:** No modificar config productiva (`APP_ENV=production` forzado por Octane frente al `.env`). Validar DB con regex estricto (`identPG`) y escapar `'` → `''` en contraseñas SQL.
- **Sistema base (RHEL 10):** Sintaxis `dnf` / `systemctl` / `firewalld` / `restorecon` / `semanage`. Prohibido `apt`/Debian.
- **Hardening restricto:** Prohibido `chmod 777`, prohibido `PasswordAuthentication yes`, prohibido root innecesariamente.
- **Edición scripts embebidos:** Tras editar cualquier `SH/*.sh`, sincronizar la copia `GO/SH/*.sh` correspondiente y **recompilar** el binario Go (`cd GO && go build`) para que el embed se reempaquete.

## 9. Helper `maybe_reboot` (`secure.sh`)

Detecta cambios críticos: tmpfs en disco, GRUB, `kernel.sysrq`, `dnf needs-restarting -r`. Instala dependencias `at`/`atd` si faltan y permite programar reinicio vía `at` (hora futura) o ejecutar de inmediato con `systemctl reboot`. Usado por `secure.sh` sección final para aplicar cambios de kernel/sysctl sin dejar el servidor en estado inconsistente.
