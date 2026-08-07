# Perfiles de seguridad

Estos perfiles son independientes de `lsetup.sh`. Se aplican manualmente despues de completar el setup y comprobar que Laravel, Nginx y Octane funcionan.

## Desarrollo

Editar las variables del principio de `secure.sh` y ejecutar:

```bash
sudo bash seguridad/secure.sh develop
```

Este perfil:

- mantiene SSH accesible sin cambiar claves, puerto ni autenticacion;
- permite Vite solamente desde `DEV_NETWORK`;
- bloquea el acceso externo directo a PostgreSQL y Redis;
- configura Fail2ban con limites tolerantes;
- aplica cabeceras Nginx compatibles con Filament y Livewire;
- no modifica PHP, `/tmp`, 2FA, CSP ni las herramientas de desarrollo.

## Produccion

Antes de ejecutarlo:

1. Configurar `SSH_USER`, `SSH_PORT` y `ALLOWED_SSH_CIDR` al principio de `secure.sh`.
2. Verificar que `$HOME/.ssh/authorized_keys` funciona abriendo una segunda sesion SSH.
3. Comprobar Google OAuth, Filament, Livewire, subida de archivos y assets.
4. Mantener abierta la sesion SSH actual durante toda la aplicacion del perfil.

Ejecucion:

```bash
sudo bash seguridad/secure.sh production
```

El perfil de produccion:

- exige confirmacion escribiendo `PRODUCTION`;
- crea un backup en `/root/lsetup-security-FECHA`;
- desactiva acceso SSH por password y limita el origen por CIDR;
- conserva exclusivamente el tunel SSH local hacia PostgreSQL;
- elimina la regla de Vite del perfil de desarrollo;
- activa UFW, Fail2ban, auditd y actualizaciones automaticas;
- aplica sysctl conservador, cabeceras Nginx, HSTS y CSP;
- cambia Laravel a `APP_ENV=production` y `APP_DEBUG=false`;

Tras terminar, abrir otra sesion antes de cerrar la actual:

```bash
ssh -p 22 miguel@192.168.1.10
```

Para el tunel de PostgreSQL:

```bash
ssh -N -L 55432:127.0.0.1:5432 -p 22 miguel@192.168.1.10
```

## Secure

`secure.sh` contiene directamente los dos perfiles y acepta un unico parametro:

```bash
sudo bash seguridad/secure.sh develop
sudo bash seguridad/secure.sh production
```

## WAF

Durante el desarrollo se instala ModSecurity con OWASP CRS en modo de deteccion. Registra las coincidencias, pero no bloquea las peticiones de Laravel, Filament o Livewire:

```bash
sudo bash seguridad/waf.sh develop
```

Cuando la aplicacion ya esta probada, activar el bloqueo de produccion:

```bash
sudo bash seguridad/waf.sh production
```

Para desactivar el WAF sin desinstalar sus paquetes ni borrar las reglas:

```bash
sudo bash seguridad/waf.sh --off
```

## 2FA para SSH

Editar `SSH_USER` al principio de `2fa.sh`. Antes de activarlo, comprobar en otra terminal que ese usuario entra mediante su clave publica. Despues ejecutar:

```bash
sudo bash seguridad/2fa.sh --on
```

El script muestra el QR y los codigos de emergencia, exige clave SSH mas codigo TOTP y valida la configuracion antes de recargar SSH. Mantener abierta la sesion actual hasta comprobar un segundo acceso.

Para desactivarlo desde una sesion abierta o desde la consola del servidor:

```bash
sudo bash seguridad/2fa.sh --off
```

Orden recomendado al terminar la aplicacion: `secure.sh production`, `waf.sh production` y, por ultimo, `2fa.sh --on`.

## Recuperacion

`secure.sh production` muestra la ruta exacta del backup creado. Si una configuracion de Nginx o SSH falla durante la validacion, el script retira el archivo nuevo antes de recargar el servicio.

No cerrar la sesion SSH original hasta haber comprobado una segunda conexion. Para una recuperacion manual desde consola, restaurar los archivos de `sshd_config`, `sshd_config.d`, `nginx.conf` y `conf.d` guardados en el directorio de backup y validar antes de recargar:

```bash
sudo sshd -t
sudo nginx -t
sudo systemctl reload ssh
sudo systemctl reload nginx
```
