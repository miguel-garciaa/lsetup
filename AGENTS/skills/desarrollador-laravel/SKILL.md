---
name: desarrollador-laravel
description: >
  Asesor senior (10 años exp) Infra/DevOps/Linux para decisiones de arquitectura y deploy del stack
  Laravel 13 + PHP 8.4 + Octane/FrankenPHP + Nginx + Filament 5 + Shield en AlmaLinux/RHEL 10. Cubre:
  principios senior (idempotencia, reversibilidad, defense-in-depth, least-privilege, fail-closed,
  medir-antes-tunear, cambio único), seguridad app Laravel (APP_KEY, APP_ENV/APP_DEBUG, throttle
  5,1 en /login, $fillable, CSRF, config:cache/route:cache), Filament/Shield (panel ->login()
  vía heredoc PHP no sed), Octane/FrankenPHP (octane:reload post-deploy, OCTANE_SERVER=frankenphp,
  binario static embeds PHP 8.4 + exts), Nginx vhost (HSTS preload, CSP, X-Frame-Options, TLS 1.2/1.3
  only, ssl_session_cache, OCSP stapling, cert Origin Cloudflare, blocks /.git /.env), zero-downtime
  deploy (symlink swap, migrate --force, queue:restart, ownership laravel:laravel), secrets via systemd
  env (ganan a .env), tradeoff decisions (features PG/queues > código síncrono, separar concerns),
  prevención errores junior típicos, señales para-y-pregunta. Usar cuando el usuario pida
  "qué harías", "es buena idea", "cómo lo abordarías", review de arquitectura/deploy, antes de fusionar
  script grande, editar setup.sh/panel.sh/login.sh/cloudflare.sh, o decidir tradeoffs del proyecto.
---

# Desarrollador senior — Laravel 13 Infra/DevOps/Linux

Asesoría de ingeniero con 10 años sesgada a operar Laravel en Linux: provisioning, hardening, deploy,
Octane/FrankenPHP, Filament/Shield, Nginx. NO cubre arquitectura código Laravel pura (Patrones
Repositories/Services/Actions, testing Pest) — ese dominio queda fuera del alcance de esta skill.

Para decisiones multi-paso o tradeoffs escribir en **prose normal clara** (no caveman) mientras el
análisis se desarrolla. Caveman post-decision para estado/comentarios breves. La claridad gana sobre
compresión cuando arriesga ambigüedad técnica.

## Principios (no negociables)

- **Idempotencia + reversibilidad**: todo cambio debe poder re-ejecutarse sin romper, y tener
  plan de rollback plausible primero. Pregunta: "¿cómo deshago esto si falla a la mitad?" Si no hay
  respuesta → parar y diseñar rollback antes de ejecutar.
- **Defense-in-depth**: nunca único chokepoint. Firewall + SELinux + ACL DB + app validation. Comprometer
  una capa no debe progresar el ataque.
- **Least-privilege**: rol app ≠ superuser (PostgreSQL), ACL Redis restrictiva, firewalld allowlist,
  `AllowUsers` en sshd, sudoers solo lo necesario.
- **Fail-closed default**: ante duda denegar. Whitelist > blacklist. Config ausente → error, no fallback
  abierto.
- **Medir antes de tunear**: perf sin baseline es gasto. `pg_stat_statements`, `EXPLAIN (ANALYZE,
  BUFFERS)`, `redis-cli INFO`, `top` antes y después. Sin métrica, ajuste es adivinanza.
- **Cambio único**: una variable por iteración para bisectar. Si rompe, sabes qué fue. Ver
  `systematic-debugging` Phase 3 (formar hipótesis, test mínimo, una fix cada vez).
- **Documentar el PORQUÉ en comentarios español**: el QUÉ es obvio leyendo código; el porqué no. Mantener
  convención del repo (comentarios español).

## Seguridad app Laravel 13

Revisar tras deploy / al tocar `setup.sh` / `login.sh`:

- `APP_KEY` base64 presente (Laravel 13 lo requiere para cifrar cookies/sesiones/cola). Rotate con
  `key:generate` invalida sesiones y datos cifrados — avisar antes.
- `APP_ENV=production` real. Setup.sh deja `.env` con `APP_ENV=local`/`APP_DEBUG=false`, pero
  `octane.service` exporta `APP_ENV=production` vía systemd (Environment=). En Laravel, las vars de
  entorno reales ganan a `.env`. Intencionado, no "corregir" sin hablar (AGENTS.md). Verificación:
  `systemctl show octane | grep Environment`.
- `APP_DEBUG=false` SIEMPRE en prod. Debug expone stack traces, config, env.
- `throttle:5,1` en `/login` — anti brute-force (ya en `login.sh`). Validar después de tocar rutas.
- CSRF tokens en todos los forms POST/PUT/DELETE. `VerifyCsrfToken` middleware activo.
- `$fillable` / `$guarded` en modelos para evitar mass-assignment. No asignar `$guarded = []`.
- Sin `dd()`, `dump()`, `ray` en prod. PSR-14 listeners que loguean debug fuera.
- `config:cache` + `route:cache` + `view:cache` post-deploy. Sin cache, Laravel lee filesystem cada
  request (Octane mitiga pero cache sigue buena práctica).
- Rate-limit API: `throttle:60,1` en rutas API. Ajustar por endpoint sensible.

## Filament 5 / Shield

- Panel tras login. `AdminPanelProvider` debe llevar `->login()` — sin ello, `/admin` redirige a ruta
  `login` genérica inexistente → `RouteNotFoundException`. Parche vía heredoc PHP (`php -r`), NO `sed`
  (AGENTS.md: backslashes frágiles con sed).
- Roles/permisos granulares con Shield. `Shield::generate` revisar antes de promocionar
  (instalación genera plantilla amplia).
- 2FA del panel: ver `2fa.sh` (separado de secure.sh por diseño — 2fa.sh no antagonist conOctane).
- No `super_admin` autoasignado a usuarios comunes. Admin role manual.

## Octane / FrankenPHP

- `OCTANE_SERVER=frankenphp` en `.env`. `octane:install --server=frankenphp` descarga binario estático
  que embeds PHP 8.4 + extensiones (pgsql, pdo_pgsql, redis, gd, intl, bcmath, opcache). Independiente
  del PHP de sistema (que sigue para `artisan`/`composer`).
- `php-pecl-swoole` ya no se instala en este repo.
- Workers cap 8 (FrankenPHP no usa task-workers). Tuning derivado de `CPU_CORES` (ver setup.sh).
- `php artisan octane:reload` tras deploy — recarga workers sin downtime.
- NUNCA exponer worker con `APP_DEBUG=true` (info sensible).
- Estado interno compartido entre workers: cuidado con singletons statics (Limpiar en `ResetState`).
- Laravel Octane 3 exige `octane:install` antes de arrancar servicio systemd.

## Nginx vhost — seguridad HTTP

Headers obligatorios en vhost 443 (cloudflare.sh):
- HSTS: `Strict-Transport-Security "max-age=31536000; includeSubDomains; preload"` (preload list solo
  tras confirmar todos los subdominios HTTPS — irreversible, documentar).
- CSP estricta: `default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'`. Ajustar
  por Filament assets. Empezar restrictive-up, report-only antes de enforce.
- `X-Frame-Options DENY` o `frame-ancestors 'none'` en CSP.
- `X-Content-Type-Options nosniff`.
- `Referrer-Policy strict-origin-when-cross-origin`.
- `Permissions-Policy geolocation=(), microphone=(), camera=()` reducción superficie.

TLS:
```
ssl_protocols TLSv1.2 TLSv1.3;            # nada TLSv1.0/1.1
ssl_ciphers ECDHE-ECDSA-AES256-GCM-SHA384:...   # modernas
ssl_prefer_server_ciphers on;
ssl_session_cache shared:SSL:10m;
ssl_session_timeout 1d;
ssl_session_tickets off;                  # forward secrecy
ssl_stapling on;
ssl_stapling_verify on;
```

Cert **Origin Cloudflare** (no público, en `/etc/ssl/cloudflare/`). CF_ROUTING restrictions
(puerto custom SSH y firewall IP via `secure.sh`).

Bloquear dotfiles y secrets:
```
location ~ /\. { deny all; }                # .git, .env, .htaccess
location ~ /\.env { deny all; }
location ~ /\..* { deny all; }
```

Redirect 80→443 con host check (no `return 301` sin quizás):
```
server {
    listen 80;
    server_name example.com www.example.com;
    return 301 https://$host$request_uri;
}
```

## Deploy — zero-downtime

Patrón recomendado:
1. Release dir nuevo (`/var/www/releases/<timestamp>`), `git archive` o tar al directorio.
2. `composer install --no-dev --optimize-autoloader` (via `as_laravel`).
3. Symlink swap: `ln -sfn /var/www/releases/<ts> /var/www/laravel1` (atomic).
4. Migrate: `php artisan migrate --force` (no interactivo). Si destructive → confirmar aparte.
5. `php artisan octane:reload` (recarga workers).
6. `php artisan queue:restart` (workers agarran nuevo código tras job actual).
7. `chown -R laravel:laravel /var/www/releases/<ts>` y `chmod -R 775 storage bootstrap/cache`.
8. N+1 releases anteriores retener para rollback (symlink swap atrás). Limpiar viejas con find.

Secrets via env systemd `octane.service` (Environment=). Ganan a `.env`. Cambiar `.env` sin
re-deploy no actualiza octane.service vars. Management: `systemctl edit octane` o reescribir unit
(vía heredoc en setup.sh).

## Secrets management

- `.env` `0640` `laravel:laravel` (no 0644 — nginx no debe leer pass DB).
- Nunca en git. `.gitignore` cubre `.env`.
- Rotate `APP_KEY` avisa: invalida cookies/sesiones/cola cifrada (cola fallida → jobs descartados —
  mensaje a usuario antes).
- Rotación periódica DB pass: actualizar `.env` + octane.service + restart octane.
- Vault externo (HashiCorp Vault, AWS Secrets Manager) para grandes setups; aquí setup.sh autogenera.

## Tradeoff decisions — preferencias senior

- **Features PostgreSQL > código app síncrono**: constraints CHECK, FOREIGN KEY, UNIQUE, partial
  indexes, triggers para integridad. App valida UX; DB valida truth. Doble validación OK.
- **Cola (Redis + Laravel Queue) > código síncrono**: jobs asíncronos para email, procesamiento,
  integraciones externas. Sincrónico solo <100ms.
- **Separar concerns (scripts)**: setup (base) / panel (Filament) / secure (hardening) / login
  (OAuth) / 2fa / cloudflare / backup — ya dividido. No fundir en mega-script. Setup cambia →
  revisar que secure/login no rompan.
- **Scripts pequeños reutilizables vs mega-monolito**: idempotencia más facil en granular.
- **Fallo de un servicio no debe progresar**: Octane caído → Nginx 502 (no colapsa DB). PostgreSQL
  caído → Octane error 500 (no corrompe Redis). Aislamiento.
- **Preferir eliminación sobre adición**: no agregar dependencia si feature existe en Laravel/PG.
  Filament ya trae lo que muchos paquetes terceros reimplementan peor.

## Ductilidad en producción

- Nunca testear script en prod. Clone/snapshot/VM staging primero.
- Dry-run para cambios destructivos.
- Backup verificado antes de destructivo (`backup-verify.sh`).
- Ventana de mantenimiento para cambios grandes.
- Monitor `sec-logs` + auditd durante cambio.
- `bash -n <script>.sh` antes de dar bueno (no hay tests/CI).

## Rollback esperado

- Cada cambio de hardening debe tener "cómo deshacerlo" documentado.
- `clear.sh` (valores hardcodeados `laravel1`/`laravel`) NO revierte `secure.sh` — advertir antes de
  ejecutar clear.sh en servidor securizado (hardening SSH/firewalld/fail2ban/CrowdSec/AIDE/sudoers
  permanece).
- Restore DB probado semanal (`restore.sh`). Backup no testeado no existe.

## Errores junior típicos a evitar

- Catastrofismo: aplicar todo hardening a la vez. Cambio único primero.
- No-idempotente: re-run rompe. Guards `if [ ! -d ]`, `grep -q`, `systemctl is-active`.
- Hardcodear valores dinámicos (CPU/RAM) — setup.sh deriva. No sobreescribir.
- Composer como root o dentro de `/var/www` (corrompe cache `/var/lib/laravel/.composer`).
- Secretos en git.
- `chmod 777`.
- `PasswordAuthentication yes`.
- `setenforce 0` en prod.
- `.env` no re-cacheado tras cambio (`config:cache` congela conexiones).
- Migrate sin `--force` en deploy (se cuelga esperando input).

## Review 3 lentes antes de aprobar cambio grande

Cargar antes de firmar:
1. `seguridad-vps` — capa sistema.
2. `postgres-redis` — capa datos.
3. Esta skill — capa app/deploy/decisiones.

## Señales "para y pregunta"

STOP y pide confirmación al usuario si:
- Lockout posible (cambio puerto SSH sin authorized_keys validado, firewall que puede aislar).
- Irreversible sin backup (migrate destructive, drop, delete, `clear.sh`).
- Secreto potencialmente expuesto (log, commit, archivo 0644).
- Rotura idempotencia sospechada (script segunda ejecución diverge).
- Tradeoff grande sin specs claras (cambio de DB, arquitectura cola, cambio cert strategy).
- Cambio en `secure.sh` que pueda aislar el servidor.

## Reglas oro

1. Plan rollback primero. Si no puedes deshacer, no lo hagas sin backup verificado.
2. Cambio único por iteración para bisectar.
3. Tunear solo con baseline medido.
4. Feature PG/cola > código síncrono siempre que sea razonable.
5. `APP_DEBUG=false`, `APP_ENV=production`, `throttle:5,1` `/login`.
6. `octane:reload` + `queue:restart` tras deploy. `.env` re-cacheado.
7. HSTS preload irreversible — documentar antes de solicitar inclusion.
8. `clear.sh` NO revierte `secure.sh` — advertir.
9. Para y pregunta ante lockout/irreversible/secreto expuesto.