---
name: postgres-redis
description: >
  Configuración, tuning y seguridad de PostgreSQL 18 + Redis 8 en AlmaLinux/RHEL 10. Cubre: pg_hba
  con scram-sha-256, roles mínimos (superuser ≠ app), REVOKE PUBLIC, pgcrypto, RLS, tuning derivado
  de RAM/CPU vía ALTER SYSTEM (shared_buffers, effective_cache_size, work_mem, wal_buffers, parallel
  workers — NUNCA hardcodear), pg_stat_statements, backups cifrados con pg_basebackup/dump; Redis:
  bind 127.0.0.1, protected-mode, requirepass SIEMPRE (defense-in-depth inclusive loopback), ACL
  users+permissions (aclfile), renameCommand legacy, maxmemory-policy allkeys-lru, io-threads derivado
  CPU, TLS off-host. Regex ^[A-Za-z_][A-Za-z0-9_]*$ para DB/user, escapado SQL doble comilla simple.
  Usar cuando el usuario pida configurar/tunear/asegurar PostgreSQL o Redis, revisar setup.sh seccion
  PG/Redis, planificar backups/restores, o decidir features PG vs código Laravel app.
---

# PostgreSQL 18 + Redis 8 — config, tuning, seguridad

Tuning DERIVADO de hardware, no hardcoded. Setup.sh detecta `CPU_CORES=$(nproc)` y
`RAM_MB` desde `/proc/meminfo`, calcula valores dinámicos. Respetar al editar — no hardcodear.

## PostgreSQL 18

### pg_hba.conf — scram-sha-256 obligatorio

Editar solo la línea `host all all 127.0.0.1/32` y `::1/128`:
```
host    all    all    127.0.0.1/32    scram-sha-256
host    all    all    ::1/128         scram-sha-256
local   all    all                    peer
```

Prohibido `trust` o `md5`. Sustituir vía regex (sed controlado aquí es OK: patrón estable):
```bash
sudo sed -i 's/^host\s\+all\s\+all\s\+127.0.0.1\/32.*/host    all    all    127.0.0.1\/32    scram-sha-256/' "$PG_HBA"
```

`password_encryption='scram-sha-256'` (afecta NUEVAS passwords, no las existentes):
```bash
sudo -u postgres psql -c "ALTER SYSTEM SET password_encryption = 'scram-sha-256';"
sudo systemctl reload postgresql
```

Re-hash passwords existentes tras el cambio: `ALTER ROLE u PASSWORD 'mismo_pass';` (re-hasea).

### Roles mínimos (least privilege)

Superuser de PostgreSQL JAMÁS es rol de app. Crear rol app dedicated:
```sql
CREATE ROLE app_laravel LOGIN PASSWORD 'pgpass' 
    NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION;
GRANT CONNECT ON DATABASE laravel1 TO app_laravel;
GRANT USAGE ON SCHEMA public TO app_laravel;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO app_laravel;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO app_laravel;
ALTER DEFAULT PRIVILEGES IN SCHEMA public 
    GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO app_laravel;
```

Revocar `CREATE` en PUBLIC schema (evita tablas extrañas):
```sql
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
REVOKE ALL ON DATABASE postgres FROM PUBLIC;
```

### pgcrypto — hash en DB

Para columnas que requieran hash (tokens, etc.) usar `pgcrypto`:
```sql
CREATE EXTENSION pgcrypto;
-- crypt(password, gen_salt('bf', 12)) para bcrypt en DB
```

Preferir password_hash PHP-side (Laravel `Hash::make` → bcrypt/argon2id) salvo necesidad DB-side
(verificar contra columna existente por compat). Buenos casos pgcrypto: tokens opacos, checksums
integridad. Mal caso: almacenar secretos recuperables (usar encriptación app con envelope key
en vez — Laravel `Crypt::encryptString`).

### RLS (Row Level Security)

Cuando app multi-tenant o permiso por fila:
```sql
ALTER TABLE documents ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON documents
    USING (tenant_id = current_setting('app.tenant_id')::bigint);
```

Laravel setea variable sesión: `DB::statement("SET app.tenant_id = $tenantId")`. Atención: owner de
tabla bypassa RLS por defecto → usar `FORCE ROW LEVEL SECURITY` si app es owner.

### Tuning derivado de hardware — ALTER SYSTEM

```bash
CPU_CORES=$(nproc)
RAM_KB=$(awk '/MemTotal/{print $2}' /proc/meminfo)
RAM_MB=$((RAM_KB / 1024))
PG_SHARED_BUFFERS=$((RAM_MB / 4))                 # 25% RAM
PG_EFFECTIVE_CACHE_SIZE=$((RAM_MB * 3 / 4))       # 75% RAM
PG_WORK_MEM=$((RAM_MB / 128))                     # (RAM/128) MB por worker; cap 64
PG_MAINTENANCE_WORK_MEM=$((RAM_MB / 16))          # 6%; cap 512
PG_WAL_BUFFERS=16                                # 16MB suele óptimo
PG_MAX_CONNECTIONS=100
PG_PARALLEL_PER_GATHER=$((CPU_CORES / 2))
```

Aplicar vía `ALTER SYSTEM` (preferido a editar `postgresql.conf`):
```bash
sudo -u postgres psql << EOF
ALTER SYSTEM SET shared_buffers = '${PG_SHARED_BUFFERS}MB';
ALTER SYSTEM SET effective_cache_size = '${PG_EFFECTIVE_CACHE_SIZE}MB';
ALTER SYSTEM SET work_mem = '${PG_WORK_MEM}MB';
ALTER SYSTEM SET maintenance_work_mem = '${PG_MAINTENANCE_WORK_MEM}MB';
ALTER SYSTEM SET wal_buffers = '${PG_WAL_BUFFERS}MB';
ALTER SYSTEM SET max_connections = ${PG_MAX_CONNECTIONS};
ALTER SYSTEM SET max_worker_processes = ${CPU_CORES};
ALTER SYSTEM SET max_parallel_workers = ${CPU_CORES};
ALTER SYSTEM SET max_parallel_workers_per_gather = ${PG_PARALLEL_PER_GATHER};
ALTER SYSTEM SET checkpoint_completion_target = 0.9;
ALTER SYSTEM SET random_page_cost = 1.1;
ALTER SYSTEM SET effective_io_concurrency = 200;
EOF
sudo systemctl restart postgresql    # algunos parámetros requieren restart
```

`restart` para parámetros no reloadables (shared_buffers, max_connections). `reload` para los demás.
Después `SELECT pg_reload_conf();`.

Medir antes y después: `pg_stat_statements`, `pg_stat_activity`, `EXPLAIN (ANALYZE, BUFFERS)`.
Sin baseline, tuning es gasto.

### pg_stat_statements

```sql
CREATE EXTENSION pg_stat_statements;
-- postgresql.conf: shared_preload_libraries = 'pg_stat_statements'
-- (ALTER SYSTEM SET shared_preload_libraries = 'pg_stat_statements'; + restart)
```

Consulta top queries:
```sql
SELECT query, calls, mean_exec_time, total_exec_time
FROM pg_stat_statements ORDER BY total_exec_time DESC LIMIT 10;
```

### Log de consultas lentas

```sql
ALTER SYSTEM SET log_min_duration_statement = '250ms';   # >250ms logged
ALTER SYSTEM SET log_line_prefix = '%m [%p] %u@%d ';
SELECT pg_reload_conf();
```

### Autovacuum

Configurar agresivo en tablas con alta rotación:
```sql
ALTER TABLE logs SET (autovacuum_vacuum_scale_factor = 0.05);
ALTER TABLE logs SET (autovacuum_analyze_scale_factor = 0.02);
```

No deshabilitar autovacuum jamás (wraparound xid → DB caída).

### Backup — cifrado at-rest

```bash
# Dump cifrado vía gpg (rotation keys aparte)
sudo -u postgres pg_dump laravel1 | gpg --symmetric --cipher-algo AES256 \
    --batch --passphrase-file /root/.pgpass-gpg > backup_$(date +%F).sql.gz.gpg
```

`pg_basebackup` para respaldo físico completo (PITR con WAL archive):
```bash
sudo -u postgres pg_basebackup -D /var/backups/pg/base -Ftar -z -P
```

3-2-1 rule: 3 copias, 2 medios, 1 offsite. Restauración probada semanal — backup no testeado no
cuenta (ver `backup-verify.sh`, `restore.sh`).

### Conexión Laravel

`.env`:
```
DB_CONNECTION=pgsql
DB_HOST=127.0.0.1
DB_PORT=5432
DB_DATABASE=laravel1
DB_USERNAME=app_laravel
DB_PASSWORD=...
```

Laravel 13 pool DB ( Conexion TMZ moderna). PHP `pdo_pgsql` + `pgsql` extension via FrankenPHP embed.
`config:cache` congela conexiones — cambiar `.env` sin re-cache = no aplica en producción.

## Redis 8

### bind + protected-mode + requirepass SIEMPRE

Inclusive en `127.0.0.1`: defense-in-depth. Si RCE PHP abre socket local, sin pass alguien podría
leer/modificar cache/colas.

```
bind 127.0.0.1 ::1
protected-mode yes
requirepass $REDIS_PASS
```

`requirepass` validation: prohibir espacios/comillas (redis.conf escaping frágil):
```bash
if [[ "$REDIS_PASS" =~ [[:space:]\'\"] ]]; then
    echo "Error: Pass Redis con espacios/comillas. Reintenta."
    exit 1
fi
REDIS_PASS=$(openssl rand -hex 24 2>/dev/null || head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')
```

### ACL users+permissions (mejor que renameCommand)

Redis 6+ usa ACL file (mejor que `rename-command` legacy). Crear usuario app con privilegios mínimos:
```
# /etc/redis/users.acl
user default off
user laravel on >$REDIS_PASS ~* +@all -@dangerous -flushall -flushdb -keys -config -debug
```

`-@dangerous` revoca grupo peligroso. `+@all` habilita resto. Ajustar `~patrones` para limitar keys
prefijo (mejor isolación multi-app):
```
user app_a on >pass_a ~app_a:* +@all -@dangerous
user app_b on >pass_b ~app_b:* +@all -@dangerous
```

`/etc/redis/redis.conf`:
```
aclfile /etc/redis/users.acl
```

`renameCommand` legacy solo si no se puede usar ACL (Redis <6); no mezclar con ACL.

### maxmemory + política evicción

```
maxmemory 256mb
maxmemory-policy allkeys-lru
```

`noeviction` solo si Redis es cola duradera crítica (no cache). Para cache/colas con reintentos
`allkeys-lru` es mejor. Keys de sesión → `volatile-lru` (con TTL).

### io-threads (Redis 6+) derivado CPU

```
io-threads $((CPU_CORES / 2))
io-threads-do-reads yes
```

Un thread Redis + io-threads escala I/O. No overcommit (4 threads en 8 cores OK; >CPU/2 contraproducente).

### TLS off-host

Si Redis en host distinto de PHP, TLS obligatorio:
```
port 0
tls-port 6379
tls-cert-file /etc/ssl/redis.crt
tls-key-file /etc/ssl/redis.key
tls-ca-cert-file /etc/ssl/ca.crt
```

En loopback no aporta seguridad y resta rendimiento.

### Conexión Laravel

`.env`:
```
REDIS_CLIENT=phpredis
REDIS_HOST=127.0.0.1
REDIS_PASSWORD=$REDIS_PASS
REDIS_USERNAME=laravel   # ACL user
```

Separar cache/queue/session por DB index:
```
CACHE_STORE=redis
REDIS_CACHE_DB=1
REDIS_QUEUE_DB=2
REDIS_SESSION_DB=3
```

`phpredis` extension via FrankenPHP embed. `config:cache` congela — cambiar sin re-cache inerte.

### Monitoreo

```bash
redis-cli -a "$REDIS_PASS" INFO memory
redis-cli -a "$REDIS_PASS" INFO stats
redis-cli -a "$REDIS_PASS" SLOWLOG GET 10
```

Desactivar `KEYS` en prod (bloquea). `SCAN`Iterativo. KEYS ya revocado por ACL `-keys`.

## Validación input (compartido con bash-scripting)

Nombres de DB/usuario validados contra `^[A-Za-z_][A-Za-z0-9_]*$` antes de crear.
SQL escapado con doble comilla simple (`'` → `''`) — no usar `psql` con strings sin escapar.

## Reglas oro

1. Tuning derivado de `nproc`/`MemTotal` — jamás hardcoded.
2. `scram-sha-256` en pg_hba, `password_encryption` set, re-hash tras cambio.
3. Rol app con `NOSUPERUSER`, `REVOKE PUBLIC`, sin `CREATE` en public schema.
4. Redis `bind 127.0.0.1` + `protected-mode yes` + `requirepass` + ACL `aclfile`.
5. Backups cifrados + testeados (`backup-verify.sh`, `restore.sh`).
6. `pg_stat_statements` + `log_min_duration_statement` para baseline antes de tuning.
7. `config:cache` congela conexión Laravel — re-cachear tras cambio `.env`.