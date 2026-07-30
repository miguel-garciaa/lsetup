Aquí tienes el documento `AGENTS.md` reestructurado y optimizado:

# AGENTS.md (Especificaciones del Sistema)

## 1. Contexto y Entorno

* **Objetivo:** Colección de scripts Bash para aprovisionar y bastionar un servidor remoto **AlmaLinux10.2**.

* **Stack Tecnológico:** Laravel 13, PHP 8.5, PostgreSQL 18, Redis 8, Filament 5, Octane (FrankenPHP) y Nginx.

* **Flujo de Trabajo:** El repositorio se edita en Windows, pero los scripts **NUNCA se ejecutan localmente**. Se copian al servidor mediante `scp`/`ssh` (ver `ssh.txt` para subir la clave pública).

* **Validación:** No hay tests, CI ni build. Es obligatorio verificar la sintaxis con `bash -n <script>.sh` antes de dar por bueno un cambio.

## 2. Scripts y Orden de Ejecución (como `root`/`sudo`)

1. **`setup.sh` (Instalador Base):** Instala el sistema y los componentes base (PG18, PHP 8.4, Redis, Laravel, Octane, Nginx).

* Es interactivo y diseñado de forma idempotente (guardas `|| true`, `if [ ! -d vendor ]`).

* **NO** instala Filament ni crea el administrador.

* Realiza un tuning dinámico de recursos (workers, buffers de PG18, maxmemory de Redis) derivado de `CPU_CORES` y `RAM_MB` detectados automáticamente (`nproc` y `MemTotal`).

* El binario estático de FrankenPHP embebe PHP 8.4 y extensiones, siendo independiente del PHP del sistema (que se mantiene para artisan/composer).

2. **`panel.sh` (Panel de Administración):** Se ejecuta tras el setup.

* Instala Filament 5, Shield y Spatie Media Library.

* Crea el usuario administrador interactivo y parchea `AdminPanelProvider.php` con `->login()` mediante heredoc PHP (sin usar `sed`) para evitar errores `RouteNotFoundException`.


3. **`cloudflare.sh` (Red):** Configura dominio, certificado Origin Cloudflare y vhost Nginx 443 a Octane (incluye HSTS y `ssl_session_cache`). Requiere ejecución estricta como root (sin `sudo`) para redireccionamientos a `/etc/ssl`.

4. **`secure.sh` (Hardening):** Debe ejecutarse al **final** y evalúa `maybe_reboot`.


* Consta de 24 secciones (sysctl, firewalld, Fail2ban, CrowdSec, ClamAV 1.4.5, AIDE) e instala `sec-logs`.
* Endurece `sshd` (crypto moderno, límites estrictos de sesión, prohíbe forwardings) y el `.env` de Laravel para Redis.
* Preserva el estado 2FA de `2fa.sh` al reescribir `00-hardening.conf`.

* **ADVERTENCIA CRÍTICA:** Cambia el puerto SSH y restringe por IP. Requiere tener la clave pública pre-configurada en `authorized_keys` o se perderá el acceso permanentemente.


## 3. Sistema de Backups (v1)

* **`backup-install.sh` (Setup):** Interactivo. Configura cron, hora de verificación y días de retención (flat 14 días, sin GFS). Genera una passphrase GPG simétrica AES256 en `/root/.backup-key` (invisible por stdout, a respaldar externamente) y persiste en `/etc/backup.conf`.

* **`backup.sh` (Motor Cron):** Genera 3 snapshots: `.db` (pg_dump custom/gzip), `.dat` (archivos planos seguros) y `.keyring` (.env cifrado) usando `flock` y `sha256sum`. Lee credenciales DB del `.env` vía `awk` (nunca con `source`).

* **`backup-verify.sh` (Verificación):** Tarea dominical que evalúa integridad con `gzip -t`, `tar -tzf` y descifrado de prueba.

* **`restore.sh` (Manual):** Pide fecha y objetivo (DB/FILES/SECRETS/TODO). Exige escribir "RESTORE", genera un backup del estado previo y ejecuta `restorecon -R` tras volcar secretos.


## 4. Scripts Adicionales

* **`login.sh`:** Añade login y Google OAuth a proyectos desplegados. Aplica `throttle:5,1` al `/login` y usa `set_env_var()` con `grep -v` + `printf` (no `sed`) para prevenir inyecciones desde secretos de Google.


* **`clear.sh` (DESTRUCTIVO):** Revierte el `setup.sh` usando valores hardcodeados. La sección 16 pide confirmación antes de eliminar el sistema de backups. **Atención:** No revierte las políticas de hardening de `secure.sh`.

## 5. Helper `maybe_reboot`

* Detecta cambios críticos (tmpfs en disco, GRUB, `kernel.sysrq`, `dnf needs-restarting -r`).

* Instala dependencias de at/atd si faltan y permite programar un reinicio vía `at` o ejecutarlo de inmediato con `systemctl reboot`.

## 6. Convenciones del Código y Seguridad

* **Idioma:** Comentarios, mensajes y prompts se redactan estrictamente en **español**.

* **Manejo de Errores:** Iniciar con `set -e` por defecto (excepción intencionada: `clear.sh` usa `set +e`).

* **Contexto de Ejecución:** Los comandos Composer/Artisan se lanzan vía `as_laravel()` (`sudo -u laravel...`) tras posicionarse en el proyecto. Composer **NUNCA** se ejecuta como root ni genera caché dentro de `/var/www`.

* **Manipulación de Archivos:** Para parches PHP, usar `php -r` o heredocs, **jamás usar `sed**` para evitar roturas por escapes. Para heredocs literales, encerrar en comillas (`'EOF'`); sin comillas si se requiere expandir variables, escapando `\$` de Laravel/Nginx.


* **Integridad de Variables:** No modificar configuraciones productivas (como `APP_ENV=production` forzado por Octane frente al `.env`). Validar bases de datos con regex estricto y escapar dobles comillas simples en contraseñas SQL.

* **Sistema Base:** Usar sintaxis RHEL (`dnf`, `systemctl`, `firewalld`, `restorecon`). Prohibido usar comandos Debian/Apt.

* **Hardening Restricto:** Terminantemente prohibido introducir `chmod 777`, habilitar `PasswordAuthentication yes` o usar root innecesariamente.

---

### Resumen de la Acción Realizada

* **Estructuración jerárquica:** Se ha transformado el texto plano original en un documento modular con seis categorías claras, empleando listas y viñetas que permiten a cualquier desarrollador escanear los componentes de forma inmediata.
* **Agrupación lógica:** Las "Notas verificadas" y directrices de "Seguridad al editar" (que antes estaban sueltas al final del documento) se han integrado directamente dentro de los apartados de los scripts que afectan y en la sección unificada de Convenciones.
* **Identificación de Riesgos:** Se han resaltado en negrita y como advertencias críticas las operaciones destructivas o que conllevan riesgos de pérdida de acceso (bloqueos SSH en `secure.sh` y el borrado total de `clear.sh`).