#!/bin/bash
set -e

# ==============================================================================
# WAF — ModSecurity v3 + OWASP CRS 4 sobre Nginx (DetectionOnly)
# Fase 2 del plan anti-ataques web (defense-in-depth).
# Reversible: clear.sh sección 17 elimina config + módulo.
# PBE: SecRuleEngine DetectionOnly → 4 días de log → calibrar → flipar a On.
# NUNCA flipar a On sin revisar /var/log/modsec/audit.log por false positives
# (CRS 4 rompe uploads Filament Media Library por multipart regex 942100).
# ==============================================================================

# LSETUP_DEBUG=1 (inyectado por `lsetup debug <cmd>`) → verbose total:
#   - set -x traza cada comando
#   - logs de dnf/configure/make fluyen a stdout/stderr (no a /tmp/*.log)
#   - Sin silenciar nada, ver para diagnosticar fallos en desarrollo.
if [ "${LSETUP_DEBUG:-0}" = "1" ]; then
  set -x
fi

if [ "$EUID" -ne 0 ]; then
  echo "[WARN] Ejecuta este script como root o con sudo."
  exit 1
fi

# Detección Laravel (para exclusiones Filament/Livewire).
LARAVEL_DIR=""
ENV_FILE=$(find /var/www -maxdepth 2 -mindepth 2 -name '.env' -type f 2>/dev/null | head -1)
if [ -n "$ENV_FILE" ]; then
  CANDIDATE=$(dirname "$ENV_FILE")
  [ -f "$CANDIDATE/artisan" ] && [ -d "$CANDIDATE/vendor" ] && LARAVEL_DIR="$CANDIDATE"
fi

# Nginx debe estar instalado (lo deja setup.sh).
if ! command -v nginx &>/dev/null; then
  echo "[ERROR] Nginx no instalado. Ejecuta setup.sh primero."
  exit 1
fi

echo "=========================================================================="
echo "   WAF ModSecurity v3 + OWASP CRS 4 (DetectionOnly)"
echo "=========================================================================="
if [ -n "$LARAVEL_DIR" ]; then
  echo " Laravel detectado: $LARAVEL_DIR (exclusiones Filament/Livewire aplicadas)"
else
  echo " Laravel NO detectado (exclusiones base CRS sin Filament)"
fi

# ------------------------------------------------------------------------------
# 1. DEPENDENCIAS build + runtime
# ------------------------------------------------------------------------------
echo ">> [1/6] Instalando dependencias build + runtime..."
# Deps críticas (si falta alguna, configure/build fallan). Instalar primero
# con log visible para diagnosticar paquetes inexistentes en AlmaLinux 10.
# yajl-devel movido a opcional: NO existe en AL10 default (lib unavailable en
# CRB/EPEL10). ModSecurity compila sin él (JSON parsing limitado pero funcional).
CRIT_DEPS="git gcc gcc-c++ make automake autoconf libtool pkgconfig \
  pcre2-devel libxml2-devel curl-devel openssl-devel wget"
if [ "${LSETUP_DEBUG:-0}" = "1" ]; then
  if ! dnf install -y $CRIT_DEPS; then
    echo "[ERROR] dnf install deps críticas falló (verbose arriba)."
    exit 1
  fi
else
  if ! dnf install -y $CRIT_DEPS >/tmp/waf_deps.log 2>&1; then
    echo "[ERROR] dnf install deps críticas falló. Últimas 40 líneas:"
    tail -n 40 /tmp/waf_deps.log
    exit 1
  fi
fi

# Deps opcionales (pueden no existir en AlmaLinux 10 — configure las ignora
# si faltan, módulos esos features quedan deshabilitados, no es fatal).
# yajl-devel: JSON parser avanzado (no en AL10 default).
# ssdeep-devel: fuzzy hashing (recomendado pero opcional).
# libmaxminddb-devel: GeoIP2 (recomendado pero opcional).
# geoip-devel: GeoIP1 legado (deprecated, solo si lo quieres).
OPT_DEPS="yajl-devel ssdeep-devel libmaxminddb-devel geoip-devel"
MISSING_OPT=""
for pkg in $OPT_DEPS; do
  if dnf install -y "$pkg" >/dev/null 2>&1; then
      echo "   >> $pkg instalado"
  else
      MISSING_OPT="$MISSING_OPT $pkg"
  fi
done
[ -n "$MISSING_OPT" ] && echo "   >> Deps opcionales no disponibles (no fatal):$MISSING_OPT"

# Verificar que las deps críticas estén realmente presentes (binarios en PATH).
MISSING=""
for bin in git gcc g++ make automake autoconf libtool pkg-config wget; do
  command -v "$bin" >/dev/null 2>&1 || MISSING="$MISSING $bin"
done
if [ -n "$MISSING" ]; then
  echo "[ERROR] Dependencias build faltantes (binarios no en PATH):$MISSING"
  echo "   Verifica /tmp/waf_deps.log para detalle del fallo dnf."
  exit 1
fi

# ------------------------------------------------------------------------------
# 2. Localizar módulo nginx ModSecurity precompilado (EPEL / nginx.org repo)
# ------------------------------------------------------------------------------
echo ">> [2/6] Buscando módulo nginx ModSecurity precompilado..."
MODSEC_SO=""
for pkg in nginx-mod_security nginx-module-modsecurity mod_security-nginx; do
  if dnf install -y "$pkg" >/dev/null 2>&1; then
      MODSEC_SO=$(find /usr/lib64/nginx/modules /usr/lib/nginx/modules \
                  -name 'ngx_http_modsecurity_module.so' 2>/dev/null | head -1)
      if [ -n "$MODSEC_SO" ]; then
          echo "   >> Módulo instalado vía dnf ($pkg): $MODSEC_SO"
          break
      fi
  fi
done

# ------------------------------------------------------------------------------
# Helper: run_log CMD... — ejecuta CMD; silencia a /tmp/waf_*.log si no debug,
# pasa stdout/stderr al terminal si LSETUP_DEBUG=1. En fallo: tail del log + exit 1.
# Uso ( desde llamada bash, sin +set):
#   run_log "msg descriptiva" /tmp/waf_X.log ./build.sh
# ------------------------------------------------------------------------------
run_log() {
  local desc="$1"; shift
  local logfile="$1"; shift
  if [ "${LSETUP_DEBUG:-0}" = "1" ]; then
    # Modo verbose: nada de logs, output fluye al terminal.
    if ! "$@"; then
      echo "[ERROR] $desc falló (verbose arriba)."
      exit 1
    fi
  else
    # Modo normal: silencioso, captura a logfile para tail en error.
    if ! "$@" >"$logfile" 2>&1; then
      echo "[ERROR] $desc falló. Últimas 60 líneas de $logfile:"
      tail -n 60 "$logfile"
      exit 1
    fi
  fi
}

# ------------------------------------------------------------------------------
# 3. Fallback: compilar libmodsecurity v3 + nginx connector (módulo dinámico)
# ------------------------------------------------------------------------------
if [ -z "$MODSEC_SO" ]; then
  echo "   >> No hay paquete precompilado. Compilando desde fuente..."
  BUILD_DIR=/usr/local/src/modsec-build
  mkdir -p "$BUILD_DIR"
  cd "$BUILD_DIR"

  # libmodsecurity v3 (la librería, NO el módulo nginx).
  # Repo movido de SpiderLabs/libmodsecurity → owasp-modsecurity/ModSecurity
  # (SpiderLabs archivado; nueva ubicación oficial OWASP).
  # Si $GITHUB_USER y $GITHUB_TOKEN están set (inyectados por `lsetup up`
  # desde [github] del config), incrustarlos en la URL para evitar rate-limit
  # anónimo de GitHub. Sin creds, clone anónimo estándar.
  # GIT_TERMINAL_PROMPT=0 + credential.helper= asegura que NUNCA cuelga
  # pidiendo login interactivo: si falla, aborta con error claro.
  GH_AUTH=""
  if [ -n "$GITHUB_USER" ] && [ -n "$GITHUB_TOKEN" ]; then
      GH_AUTH="${GITHUB_USER}:${GITHUB_TOKEN}@"
  fi
  if [ ! -d libmodsecurity ]; then
      GIT_TERMINAL_PROMPT=0 git -c credential.helper= clone --depth 1 -b v3/master \
          "https://${GH_AUTH}github.com/owasp-modsecurity/ModSecurity.git" "libmodsecurity" \
          || { echo "[ERROR] git clone libmodsecurity falló (¿sin red, rate-limit o token invalido?)."; exit 1; }
  fi
  cd "$BUILD_DIR/libmodsecurity"
  # Submódulos críticos: build.sh los necesita (cf Dayanna Suzuki, etc.).
  # Sin GIT_TERMINAL_PROMPT=0 + credential.helper= para submódulos GitHub.
  run_log "libmodsecurity submodule update" /tmp/waf_submod.log \
      git submodule update --init --recursive
  if [ ! -f configure ]; then
      echo "   >> Ejecutando build.sh (genera configure)..."
      run_log "libmodsecurity build.sh" /tmp/waf_build.log ./build.sh
  fi
  echo "   >> Ejecutando configure..."
  run_log "libmodsecurity configure" /tmp/waf_configure.log ./configure

  echo "   >> Compilando libmodsecurity (make -j$(nproc))..."
  if [ "${LSETUP_DEBUG:-0}" = "1" ]; then
      if ! make -j"$(nproc)"; then
          echo "[ERROR] libmodsecurity make falló (verbose arriba)."
          echo "   Causas típicas: OOM (baja RAM para -j$(nproc)), falta gcc-c++."
          echo "   Alternativa: ejecuta 'make -j1' manualmente en $BUILD_DIR/libmodsecurity"
          exit 1
      fi
  else
      if ! make -j"$(nproc)" >/tmp/waf_make.log 2>&1; then
          echo "[ERROR] libmodsecurity make falló. Últimas 40 líneas:"
          tail -n 40 /tmp/waf_make.log
          echo ""
          echo "   Causas típicas: OOM (baja RAM para -j$(nproc)), falta gcc-c++."
          echo "   Alternativa: ejecuta 'make -j1' manualmente en $BUILD_DIR/libmodsecurity"
          exit 1
      fi
  fi
  make install >/tmp/waf_make_install.log 2>&1 || true
  ldconfig

  # nginx connector como módulo dinámico contra nginx source de la versión instalada.
  NGINX_VER=$(nginx -v 2>&1 | sed -E 's|.*nginx/||')
  [ -z "$NGINX_VER" ] && { echo "[ERROR] No se detectó versión nginx."; exit 1; }
  cd "$BUILD_DIR"
  if [ ! -f "nginx-$NGINX_VER.tar.gz" ]; then
      wget -q "https://nginx.org/download/nginx-$NGINX_VER.tar.gz" -O "nginx-$NGINX_VER.tar.gz" \
          || { echo "[ERROR] download nginx-$NGINX_VER source falló."; exit 1; }
  fi
  [ -d "nginx-$NGINX_VER" ] || tar xzf "nginx-$NGINX_VER.tar.gz"
  [ -d ModSecurity-nginx ] || GIT_TERMINAL_PROMPT=0 git -c credential.helper= clone --depth 1 \
      "https://${GH_AUTH}github.com/SpiderLabs/ModSecurity-nginx.git" \
      || { echo "[ERROR] git clone connector falló (¿sin red, rate-limit o token invalido?)."; exit 1; }

  # Reproducir configure args del nginx instalado (nginx -V) + add-dynamic-module.
  # --with-compat permite módulo portable si el nginx instalado también lo usó.
  #
  # El spec rpm de AlmaLinux pasa opciones inválidas para compilar desde fuente
  # vanilla; hay que filtrarlas:
  #   --without-engine          flag del spec rpm, NO existe en nginx source
  #   --with-openssl-opt=...    requiere --with-openssl=<path> (no aplicable)
  #   --with-cc-opt / --with-ld-opt  quoting complejo; con --with-compat la ABI
  #                                  solo depende de la versión, no de estos flags
  # Además los args llevan quoting interno (--with-cc-opt='-O2 ...') que word
  # splitting simple rompería → se usa eval para preservarlo.
  NGINX_CONFIG_ARGS=$(nginx -V 2>&1 | sed -n 's/.*configure arguments: //p')
  NGINX_CONFIG_ARGS=$(printf '%s' "$NGINX_CONFIG_ARGS" | sed -E \
      "s/--with-cc-opt='[^']*'//g; s/--with-ld-opt='[^']*'//g; s/--without-engine//g; s/--with-openssl-opt=[^ ]+//g")

  cd "nginx-$NGINX_VER"
  # Limpiar restos de configure previo fallido (objs/ puede quedar inconsistente).
  [ -d objs ] && rm -rf objs
  echo "   >> Configurando connector nginx (vs nginx $NGINX_VER)..."
  configure_ok=0
  if [ "${LSETUP_DEBUG:-0}" = "1" ]; then
      # shellcheck disable=SC2086
      eval "./configure --with-compat --add-dynamic-module=../ModSecurity-nginx $NGINX_CONFIG_ARGS" \
          && configure_ok=1
  else
      # shellcheck disable=SC2086
      eval "./configure --with-compat --add-dynamic-module=../ModSecurity-nginx $NGINX_CONFIG_ARGS" \
          >/tmp/waf_nginx_configure.log 2>&1 && configure_ok=1
  fi
  if [ "$configure_ok" = "0" ]; then
      echo "   >> Replay de args falló; intentando configure mínimo (--with-compat + módulo)..."
      if [ "${LSETUP_DEBUG:-0}" = "1" ]; then
          ./configure --with-compat --add-dynamic-module=../ModSecurity-nginx \
              || { echo "[ERROR] configure mínimo también falló."; exit 1; }
      else
          if ! ./configure --with-compat --add-dynamic-module=../ModSecurity-nginx \
                  >>/tmp/waf_nginx_configure.log 2>&1; then
              echo "[ERROR] nginx connector configure falló. Últimas 60 líneas:"
              tail -n 60 /tmp/waf_nginx_configure.log
              echo ""
              echo "   Alternativa: añade el repo nginx.org (nginx-stable) y dnf install"
              echo "   nginx-module-modsecurity (módulo precompilado compatible)."
              echo "   Logs: /tmp/waf_nginx_configure.log"
              exit 1
          fi
      fi
  fi
  echo "   >> Compilando módulo nginx (make modules)..."
  run_log "make modules" /tmp/waf_nginx_make.log make modules
  mkdir -p /usr/lib64/nginx/modules
  cp objs/ngx_http_modsecurity_module.so /usr/lib64/nginx/modules/ \
      || { echo "[ERROR] copia .so falló."; exit 1; }
  MODSEC_SO=/usr/lib64/nginx/modules/ngx_http_modsecurity_module.so
  echo "   >> Módulo compilado: $MODSEC_SO"
fi

# ------------------------------------------------------------------------------
# 4. Descargar OWASP CRS 4 + configuración ModSecurity
# ------------------------------------------------------------------------------
echo ">> [4/6] Descargando OWASP CRS 4 (latest release)..."
mkdir -p /etc/nginx/modsec /var/log/modsec
chmod 644 /var/log/modsec 2>/dev/null || true
chown nginx:nginx /var/log/modsec 2>/dev/null || chown root:root /var/log/modsec 2>/dev/null || true
restorecon -Rv /etc/nginx/modsec 2>/dev/null || true

if [ ! -d /etc/nginx/modsec/owasp-crs ]; then
  CRS_VER=$(curl -fsSL https://api.github.com/repos/coreruleset/coreruleset/releases/latest \
              2>/dev/null | grep '"tag_name"' | head -1 | sed -E 's/.*"v?([^"]+)".*/\1/')
  [ -z "$CRS_VER" ] && CRS_VER=4.0.0
  echo "   >> CRS versión: $CRS_VER"

  # Desde CRS 4.x (≈4.5+) el release NO publica `coreruleset-X.tar.gz` full —
  # solo la variante `-minimal` (production-ready: rules + setup, sin tests).
  # Estrategia: intentar `-minimal.tar.gz` primero, fallback al auto-archive
  # GitHub (siempre existe para cualquier tag).
  # Extracción con --strip-components=1: evita depender del nombre interno
  # del top-dir (coreruleset-X vs coreruleset-X-minimal vs coreruleset-vX).
  mkdir -p /etc/nginx/modsec/owasp-crs

  URL_MINIMAL="https://github.com/coreruleset/coreruleset/releases/download/v${CRS_VER}/coreruleset-${CRS_VER}-minimal.tar.gz"
  URL_ARCHIVE="https://github.com/coreruleset/coreruleset/archive/refs/tags/v${CRS_VER}.tar.gz"

  if [ "${LSETUP_DEBUG:-0}" = "1" ]; then
    echo "   >> Download: $URL_MINIMAL"
  fi
  if ! curl -fsSL "$URL_MINIMAL" -o /tmp/crs.tar.gz; then
    echo "   >> -minimal no disponible (404 o red). Fallback a auto-archive GitHub..."
    [ "${LSETUP_DEBUG:-0}" = "1" ] && echo "   >> Download: $URL_ARCHIVE"
    curl -fsSL "$URL_ARCHIVE" -o /tmp/crs.tar.gz || { echo "[ERROR] CRS download falló (minimal + archive)."; exit 1; }
  fi

  tar xzf /tmp/crs.tar.gz -C /etc/nginx/modsec/owasp-crs --strip-components=1 \
      || { echo "[ERROR] tar extract CRS falló."; rm -f /tmp/crs.tar.gz; exit 1; }
  rm -f /tmp/crs.tar.gz
fi

# crs-setup.conf desde el ejemplo (idempotente: no sobreescribe si ya existe).
[ -f /etc/nginx/modsec/owasp-crs/crs-setup.conf ] || \
  cp /etc/nginx/modsec/owasp-crs/crs-setup.conf.example \
      /etc/nginx/modsec/owasp-crs/crs-setup.conf 2>/dev/null || true

# modsecurity.conf global (DetectionOnly).
cat << 'EOF' > /etc/nginx/modsec/modsecurity.conf
# === añadido por waf.sh — ModSecurity v3 (DetectionOnly inicial) ===
# NO cambiar a On sin revisar /var/log/modsec/audit.log 4 días.
SecRuleEngine DetectionOnly
SecRequestBodyAccess On
SecRequestBodyLimit 20971520
SecRequestBodyJsonDepth 100
SecDebugLogLevel 1
SecAuditEngine RelevantOnly
SecAuditLog /var/log/modsec/audit.log
SecAuditLogFormat JSON
SecAuditLogType Serial
SecAuditLogParts ABIJDEFHZ
# Cargar OWASP CRS 4 + setup + exclusiones Filament.
Include /etc/nginx/modsec/owasp-crs/crs-setup.conf
Include /etc/nginx/modsec/owasp-crs/rules/*.conf
Include /etc/nginx/modsec/filament-exclusions.conf
EOF

# Exclusiones Filament/Livewire (CRS-native: SecRule REQUEST_URI + ctl:ruleRemoveById).
# Evita Location Match (Apache-only) y conflictos con locations nginx existentes.
if [ -n "$LARAVEL_DIR" ]; then
  cat << 'EOF' > /etc/nginx/modsec/filament-exclusions.conf
# === Exclusiones Filament/Livewire (waf.sh) — CRS-native, no LocationMatch ===
# Filament/admin: desactivar SQLi/XSS false-positivos comunes del panel.
SecRule REQUEST_URI "@beginsWith /admin" \
  "id:100000,phase:1,pass,nolog,ctl:ruleRemoveById=942100,ctl:ruleRemoveById=942200,ctl:ruleRemoveById=941100"
# Livewire: POST body de updates dispara 920350 (body too long). Desactivar ahí.
SecRule REQUEST_URI "@beginsWith /livewire" \
  "id:100001,phase:1,pass,nolog,ctl:ruleRemoveById=920350"
EOF
else
  # Sin Laravel: exclusión genérica mínima (comentar / desactivar tras calibrar).
  cat << 'EOF' > /etc/nginx/modsec/filament-exclusions.conf
# === Exclusiones (waf.sh) — sin Filament detectado, placeholder ===
# Añade SecRule REQUEST_URI "@beginsWith <ruta>" "id:N,phase:1,pass,nolog,ctl:ruleRemoveById=ID"
# tras revisar /var/log/modsec/audit.log y localizar false positives.
EOF
fi

# ------------------------------------------------------------------------------
# 5. Cargar módulo en nginx.conf + snippet + include en vhosts 443
# ------------------------------------------------------------------------------
echo ">> [5/6] Activando módulo en nginx.conf + vhosts..."
NGINX_CONF=/etc/nginx/nginx.conf

# load_module en main context (debe ir al inicio, antes de events/http).
# Idempotente.
if ! grep -q "ngx_http_modsecurity_module.so" "$NGINX_CONF" 2>/dev/null; then
  # Insertar tras la primera línea de comentarios (#!) no bloque, o al inicio.
  # nginx permite load_module como primera directiva del main context.
  sed -i "1i load_module \"$MODSEC_SO\";" "$NGINX_CONF"
fi

# Snippet reutilizable: activa modsec + apunta al rules_file global.
# mkdir -p: /etc/nginx/snippets puede no existir (setup.sh nginx base no lo crea).
mkdir -p /etc/nginx/snippets
cat << 'EOF' > /etc/nginx/snippets/modsec.conf
# === waf.sh: activar ModSecurity v3 en este contexto ===
modsecurity on;
modsecurity_rules_file /etc/nginx/modsec/modsecurity.conf;
EOF

# Inyectar include snippets/modsec.conf en cada server 443 (idempotente).
for f in /etc/nginx/conf.d/*.conf; do
  [ -f "$f" ] || continue
  case "$f" in *00-*) continue;; esac
  grep -q 'listen .*443' "$f" 2>/dev/null || continue
  grep -q 'snippets/modsec.conf' "$f" 2>/dev/null && continue
  # Insertar tras la apertura del primer server 443 (después de otros includes v3).
  sed -i -E '0,/^server[[:space:]]*\{/{s|^server[[:space:]]*\{|server {\n    include /etc/nginx/snippets/modsec.conf;|}' "$f"
done

# ------------------------------------------------------------------------------
# 6. Validar + recargar nginx
# ------------------------------------------------------------------------------
echo ">> [6/6] Validando configuración nginx..."
if ! nginx -t 2>/tmp/waf_err; then
  echo "   [WARN]  AVISO: nginx -t falló. Detalle:"
  cat /tmp/waf_err
  echo ""
  echo "   El módulo NO se activó en runtime. Revisa el error arriba."
  echo "   Posibles causas: ABI incompatible (nginx sin --with-compat),"
  echo "   o load_module en contexto erróneo. clear.sh sección 17 revierte."
  echo "   .conf escritos pero no cargados (nginx sigue en config anterior)."
else
  systemctl reload nginx 2>/dev/null || systemctl restart nginx 2>/dev/null || true
  echo "   >> nginx recargado con ModSecurity DetectionOnly."
fi

# ------------------------------------------------------------------------------
# RESUMEN
# ------------------------------------------------------------------------------
echo "=========================================================================="
echo "   WAF MODSECURITY INSTALADO (DetectionOnly)"
echo "=========================================================================="
echo " Módulo:        $MODSEC_SO"
echo " Config:        /etc/nginx/modsec/modsecurity.conf"
echo " CRS:           /etc/nginx/modsec/owasp-crs (v${CRS_VER:-}) "
echo " Exclusiones:   /etc/nginx/modsec/filament-exclusions.conf"
echo " Audit log:     /var/log/modsec/audit.log"
echo " Engine:        DetectionOnly (NO bloquea, solo loguea)"
echo ""
echo " PRÓXIMOS PASOS:"
echo "   1. Deja correr 2-4 días con tráfico real/Filament."
echo "   2. Revisa false positives:"
echo "      sudo grep -oE 'id \"[0-9]+\"' /var/log/modsec/audit.log | sort | uniq -c | sort -rn"
echo "   3. Añade exclusiones a filament-exclusions.conf (más SecRule REQUEST_URI)."
echo "   4. Cuando estable: cambia SecRuleEngine DetectionOnly → On y recarga:"
echo "      sudo sed -i 's/SecRuleEngine DetectionOnly/SecRuleEngine On/' /etc/nginx/modsec/modsecurity.conf"
echo "      sudo nginx -t && sudo systemctl reload nginx"
echo "   5. Monitoriza: sudo sec-logs (sección [+] WAF MODSECURITY)."
echo ""
echo " RIESGO: CRS 4 rompe uploads Filament Media Library (rule 942100 multipart)."
echo " Exclusiones de /livewire + /admin mitigadas; revisa uploads manualmente."
echo "=========================================================================="