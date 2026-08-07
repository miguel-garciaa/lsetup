# AGENTS.md - LSETUP

## 1. Contexto y Entorno

- **Objetivo actual:** LSETUP vuelve temporalmente a ser un instalador Bash para desarrollo. El punto de entrada es `lsetup.sh`, que ejecuta `scripts/setup.sh` y despues `scripts/dominio.sh`.
- **Sin binario Go por ahora:** no crear, compilar ni distribuir `lsetup.exe` o binarios Go salvo que el usuario lo pida explicitamente en el futuro.
- **Stack objetivo:** Ubuntu Server 26.04, Laravel 13, PHP 8.5, PostgreSQL 18, Redis 8, Octane con FrankenPHP, Nginx y systemd.
- **Seguridad y backups:** WAF, hardening, 2FA, auditoria avanzada y backups quedan fuera del flujo principal de desarrollo. Los scripts pueden existir en `seguridad/` y `backup/`, pero no se ejecutan desde `lsetup.sh`.
- **Skills del repo:** antes de tocar scripts Bash, Laravel, DB/Redis o seguridad, cargar la skill local correspondiente desde `skills/`. Para Bash usar `skills/bash-scripting/SKILL.md`.
- **Validacion:** no hay CI. Verificar los scripts modificados con `bash -n <script>.sh` en un entorno con Bash real. En Windows se puede intentar si hay Bash disponible; si no, indicarlo.

## 2. Flujo Principal

`lsetup.sh` es el instalador principal para Ubuntu Server 26.04:

1. Ejecuta `scripts/setup.sh`.
2. Conserva `PROYECTO_DIR` calculado por el setup.
3. Ejecuta `scripts/dominio.sh` usando esa ruta del proyecto.

Uso previsto en servidor:

```bash
sudo bash lsetup.sh
```

El script requiere root porque instala paquetes, escribe en `/etc` y configura systemd, Nginx y certificados.

## 3. Scripts Base

### `scripts/setup.sh`

Instalador base del servidor y del proyecto Laravel.

- Las variables del proyecto y de los servicios se configuran al principio del script.
- Instala PostgreSQL 18, Redis 8, PHP 8.5, Composer, Laravel 13, Octane/FrankenPHP y Nginx.
- Crea el proyecto en `/var/www/laravel` por defecto.
- Genera `.env`, configura Octane en `127.0.0.1:8000` y deja Nginx como reverse proxy.
- No debe instalar Filament, Shield, WAF, hardening avanzado, 2FA ni backups.

### `scripts/dominio.sh`

Configura dominio y certificado Origin de Cloudflare.

- Pide `DOMAIN_NAME` si no llega por entorno.
- Pide o recibe por entorno `CLOUDFLARE_CERT` y `CLOUDFLARE_KEY`.
- Escribe certificado y clave en `/etc/ssl`.
- Crea el vhost HTTPS de Nginx.
- Abre HTTPS en firewalld.
- Actualiza `APP_URL=https://<dominio>` en el `.env`.
- Aplica TrustProxies/HTTPS en Laravel cuando el proyecto existe.

## 4. Componentes Post-Deploy

Despues de `sudo bash lsetup.sh`, el proyecto Laravel queda desplegado y sirviendo, pero la web puede seguir vacia. `COMPONENTS/` contiene scripts independientes para montar funcionalidades segun el cliente.

### `COMPONENTS/panel-install.sh`

Instala la base limpia de Filament 5 tras el setup.

- Se ejecuta sobre un proyecto Laravel ya creado.
- Instala Filament y crea/actualiza el primer administrador.
- No instala Shield, roles, permisos, Debugbar ni modulos de negocio.
- Hasta instalar Shield, el acceso al panel se restringe al correo del administrador inicial.

### `COMPONENTS/panel-shield.sh`

Modulo posterior para roles y permisos.

- Se ejecutara despues de `panel-install.sh`.
- Debe asignar rol `Admin` al usuario inicial ya creado por `panel-install.sh`.
- Debe instalar Shield/Spatie Permission sin reinstalar Filament ni recrear el panel base.
- Debe dejar `Consultor` como rol de solo lectura cuando se implemente.

### `COMPONENTS/auth/login.sh`

Automatizacion de login Laravel y Google OAuth.

- Usa `/var/www/laravel`, el usuario `laravel` y el HOME `/home/laravel` por defecto.
- `APP_URL`, `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET` y `GOOGLE_REDIRECT_URI` se configuran como variables al principio del script.
- No debe pedir interactivamente la ruta ni las credenciales.
- Las credenciales reales se rellenan en la copia del servidor y no deben subirse a Git.

### `COMPONENTS/google-ads.sh`

Automatizacion inicial de Google AdSense. Sigue en desarrollo.

## 5. Scripts Aparcados

Los scripts de estas carpetas no forman parte del flujo principal actual:

- `seguridad/`: WAF, hardening, 2FA y scripts relacionados.
- `backup/`: instalacion, ejecucion, verificacion y restauracion de backups.

No conectarlos a `lsetup.sh` hasta que el usuario pida recuperar seguridad/backups.

## 6. Convenciones de Bash

- Usar `#!/bin/bash` y `set -e` por defecto.
- Scripts que escriben en `/etc`, systemd, Nginx o firewall deben validar root con `EUID`.
- En Ubuntu Server usar `apt` y `systemctl`. No usar `dnf`.
- Composer y Artisan deben ejecutarse como usuario `laravel`, con `HOME=/home/laravel` y `COMPOSER_HOME=/home/laravel/.composer`.
- Evitar `sed` para modificar PHP. Usar `php -r` o heredocs PHP.
- Para `.env`, preferir `awk` o `grep -v` + `printf`.
- No usar `chmod 777`.
- No hardcodear secretos destinados a git.

## 7. Validacion Antes De Terminar

Ejecutar al menos:

```bash
bash -n lsetup.sh
bash -n scripts/setup.sh
bash -n scripts/dominio.sh
```

Si el entorno local no tiene Bash, validar en AlmaLinux antes de ejecutar en produccion.
