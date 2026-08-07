---
name: bash-scripting
description: >
  Patrones para escribir/editar scripts Bash en este repo de aprovisionamiento AlmaLinux/RHEL 10
  (setup.sh, panel.sh, secure.sh, login.sh, cloudflare.sh, backup*.sh, restore.sh, 2fa.sh, clear.sh).
  Cubre: set -e/+e, helper as_laravel(), heredocs literal vs expandible (ESP caprichoso), parches
  PHP vía php -r (NO sed), validación de input (Regex IPv4/CIDR, nombres DB/usuario, puerto,
  usuario existente), escapado SQL/Redis/.env, idempotencia, dnf/firewalld/SELinux (jamás apt),
  verificación final con `bash -n`. Usar cuando el usuario pida crear/editar/automatizar un script,
  corregir sintaxis bash, o revisar convenciones del repo antes de tocar un .sh.
---

# Bash scripting — AlmaLinux/RHEL 10 (este repo)

## Stack target (obligatorio)

`dnf`, `systemctl`, `firewalld`, SELinux (`setsebool`/`semanage`/`restorecon`), repos Remi + PGDG.
NUNCA sintaxis `apt`/Debian. NUNCA `service foo start` (usar `systemctl start foo`).

## set -e / set +e

`set -e` al inicio de TODO script (excepto `clear.sh` → `set +e` best-effort limpieza destructiva).
`|| true` en comandos no-fatales para preservar idempotencia (re-ejecutable no rompe).

```bash
#!/bin/bash
set -e
```

```bash
# clear.sh — destructivo, best-effort
set +e
```

## Root check (EUID)

Scripts que tocan `/etc/*` arrancan con:

```bash
if [ "$EUID" -ne 0 ]; then
    echo "⚠️ Ejecuta como root o con sudo."
    exit 1
fi
```

## Helper as_laravel() — composer/artisan JAMÁS como root

Patrón replicado en `setup.sh:114`, `panel.sh:34`, `login.sh:29`. Composer nunca como root, nunca
dentro de `/var/www` (caché vive en `/var/lib/laravel/.composer`).

```bash
as_laravel() {
    sudo -u laravel env HOME=/var/lib/laravel bash -lc "$1"
}
```

Uso:
```bash
as_laravel "cd /var/www/$PROJECT && composer require filament/filament"
as_laravel "php artisan migrate --force"
```

Tras generar archivos (migración, controlador, vista, .env), siempre:
```bash
chown -R laravel:laravel /var/www/$PROJECT/<archivos_nuevos>
```

## Heredocs — comilla simple es caprichoso

`'EOF'` (comillas simples): contenido LITERAL, sin expandir `$`. Usar para migraciones,
configuración PHP/Nginx estática, código PHP/Blade independiente.

```bash
cat << 'EOF' > "$MIGRATION_FILE"
public function up(): void
{
    Schema::create('foo', function (Blueprint $table) {
        $table->id();
        // $table NO se expande, queda literal en el PHP
    });
}
EOF
```

`EOF` (sin comillas): expandir `$VAR` del shell. ESCAPAR `\$` para vars que Laravel/Nginx debe
interpretar (no el shell). Usar para config con valores dinámicos del host.

```bash
sudo bash -c "cat << EOF >> /etc/redis/redis.conf
bind 127.0.0.1
requirepass $REDIS_PASS
maxmemory-policy allkeys-lru
EOF"
```

```bash
sudo bash -c "cat << EOF > /etc/systemd/system/octane.service
Environment=APP_ENV=production
Environment=APP_KEY=base64:...
# \$argv no se expande aquí, lo lee PHP
EOF"
```

ERROR típico: mezclar comillas → `$VAR` perdido o `\` literal innecesario. Verificar con `cat` tras
escribir antes de dar bueno.

## Parches PHP — php -r o heredoc PHP, NUNCA sed

El escaping de backslashes con `sed` es frágil (anotación explícita en AGENTS.md).
Para crear/escribir archivos PHP enteros: heredoc PHP (`cat << 'PHP' > archivo.php`).
Para mutations quirúrgicas pequeñas: `php -r`.

```bash
php -r '
$src = file_get_contents("app/Providers/Filament/AdminPanelProvider.php");
$src = str_replace(
    "->path(\"admin\")",
    "->path(\"admin\")->login()",
    $src
);
file_put_contents("app/Providers/Filament/AdminPanelProvider.php", $src);
'
```

## Validación de input — regex + existencia

IPv4/CIDR estricta (copia desde `secure.sh:24`):
```bash
IPV4_REGEX='^(([0-9]{1,2}|1[0-9]{2}|2[0-4][0-9]|25[0-5])\.){3}([0-9]{1,2}|1[0-9]{2}|2[0-4][0-9]|25[0-5])(/([0-9]|[12][0-9]|3[0-2]))?$'

read -rp "IP/CIDR autorizada: " ALLOWED_IP
if ! [[ "$ALLOWED_IP" =~ $IPV4_REGEX ]]; then
    echo "Error: IP/CIDR inválido."; exit 1
fi
```

Nombres de DB/usuario (letra o `_` primero, alfanum/`_`):
```bash
if ! [[ "$DB_NAME" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
    echo "Error: nombre inválido."; exit 1
fi
```

Puerto custom SSH (rango dinámico):
```bash
if ! [[ "$SSH_PORT" =~ ^[0-9]+$ ]] || [ "$SSH_PORT" -le 1024 ] || [ "$SSH_PORT" -gt 65535 ]; then
    echo "Error: puerto 1025-65535."; exit 1
fi
```

Usuario existente:
```bash
if ! id "$SSH_USER" &>/dev/null; then
    echo "Error: $SSH_USER no existe."; exit 1
fi
USER_HOME=$(eval echo "~$SSH_USER")
```

`authorized_keys` presente antes de tocar SSH/firewall (CRÍTICO — evita lockout):
```bash
if [ ! -f "$USER_HOME/.ssh/authorized_keys" ] || [ ! -s "$USER_HOME/.ssh/authorized_keys" ]; then
    echo "⚠️ ALERTA: sin claves en authorized_keys. Aborto."; exit 1
fi
```

## Escapado de secretos

SQL — doble comilla simple (`'` → `''`):
```bash
PG_PASS_ESC="${DB_PASS//\'/\'\'}"
sudo -u postgres psql -c "ALTER USER \"$DB_USER\" PASSWORD '$PG_PASS_ESC';"
```

Redis —Rechazar espacios/comillas (redis.conf escaping frágil):
```bash
if [[ "$REDIS_PASS_INPUT" =~ [[:space:]\'\"] ]]; then
    echo "Error: la contraseña Redis trae espacios/comillas. Reintenta sin esos caracteres."
    exit 1
fi
```

Autogenerar (preferido):
```bash
REDIS_PASS=$(openssl rand -hex 24 2>/dev/null || head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')
```

`.env` —`grep -v` + `printf`, NUNCA `sed` (inyección desde `GOOGLE_CLIENT_SECRET`):
```bash
set_env_var() {
    local key="$1" val="$2" file="$3"
    grep -v "^${key}=" "$file" > "$file.tmp" || true
    printf '%s=%s\n' "$key" "$val" >> "$file.tmp"
    mv "$file.tmp" "$file"
    chown laravel:laravel "$file"
}
```

## Idempotencia

Guards antes de instalar/crear:
```bash
if [ ! -d /var/www/$PROJECT/vendor ]; then
    as_laravel "cd /var/www/$PROJECT && composer install --no-dev --optimize-autoloader"
fi

if ! systemctl is-active --quiet postgresql; then
    systemctl enable --now postgresql
fi

dnf install -y php-pgsql || true
```

## SELinux

`setenforce 0` JAMÁS en prod. Booleans:
```bash
setsebool -P httpd_can_network_connect_db on
setsebool -P httpd_can_connect_ldap on   # si aplica
restorecon -Rv /etc/nginx/conf.d/
semanage port -a -t ssh_port_t -p tcp "$SSH_PORT"  # puerto SSH custom
```

## firewalld

Zona default `public`, drop lo no explícito:
```bash
firewall-cmd --permanent --zone=public --add-rich-rule="rule family=ipv4 source address=$ALLOWED_IP port port=$SSH_PORT protocol=tcp accept"
firewall-cmd --permanent --zone=public --add-service=http --add-service=https
firewall-cmd --permanent --zone=public --remove-service=ssh  # quitar 22 por defecto
firewall-cmd --reload
```

## Prohibido (violación de seguridad)

- `chmod 777` en cualquier ruta.
- `PasswordAuthentication yes` / `PermitRootLogin yes` en sshd.
- Ejecutar Composer/Artisan como root.
- `setenforce 0` en prod (debug temporal OK con ventana corta + rearmado explícito).
- Secretos hardcoded en script que entra a git.

## Destructivo (clear.sh y similares)

```bash
set +e   # best-effort: queremos limpiar lo que podamos aunque algo falle
# ... confirmación previa ...
read -rp "¿Borrar todo? Escribe SI: " CONFIRM
if [ "$CONFIRM" != "SI" ]; then echo "Aborto."; exit 1; fi
```

Avisar al usuario: `clear.sh` (valores hardcodeados `laravel1`/`laravel`) NO revierte `secure.sh`
(hardening SSH/firewalld/fail2ban/CrowdSec/AIDE/sudoers permanece).

## Verificación final (NO hay tests/CI en repo)

Antes de dar por bueno un cambio:
```bash
bash -n <script>.sh
```

Si pasa, editor confirma. No hay `npm test` ni CI. `bash -n` es la única malla de sintaxis.

## Reglas oro

1. Editar/crear .sh en este repo → cargar esta skill.
2. `set -e` (+EUID check si toca `/etc`).
3. `as_laravel` para composer/artisan; `chown laravel:laravel` los archivos nuevos.
4. Heredoc: `'EOF'` literal vs `EOF` expandible — capa claro antes de escribir.
5. Parches PHP → `php -r`/heredoc, NO `sed`.
6. Validar input (IPv4/CIDR, `^[A-Za-z_][A-Za-z0-9_]*$`, puerto, `id`).
7. Escapar secretos (SQL `''`, Redis prohíbe espacios/comillas, `.env` con `grep -v`+`printf`).
8. Lockout check: `authorized_keys` presente antes de tocar puerto SSH/firewall.