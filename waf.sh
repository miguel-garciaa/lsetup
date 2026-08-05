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

if [ "$EUID" -ne 0 ]; then
    echo "⚠️ Ejecuta este script como root o con sudo."
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
    echo "❌ Nginx no instalado. Ejecuta setup.sh primero."
    exit 1
fi

echo "=========================================================================="
echo " 🛡️  WAF ModSecurity v3 + OWASP CRS 4 (DetectionOnly)"
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
dnf install -y git gcc gcc-c++ make automake autoconf libtool pkgconfig \
    pcre2-devel yajl-devel libxml2-devel curl-devel ssdeep-devel \
    libmaxminddb-devel geoip-devel openssl-devel wget >/dev/null 2>&1 || true

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
            || { echo "❌ git clone libmodsecurity falló (¿sin red, rate-limit o token invalido?)."; exit 1; }
    fi
    cd "$BUILD_DIR/libmodsecurity"
    git submodule update --init --recursive >/dev/null 2>&1 || true
    if [ ! -f configure ]; then
        ./build.sh >/dev/null 2>&1 || { echo "❌ libmodsecurity build.sh falló (revisa deps)."; exit 1; }
    fi
    ./configure >/dev/null 2>&1 || { echo "❌ libmodsecurity configure falló."; exit 1; }
    make -j"$(nproc)" >/dev/null 2>&1 || { echo "❌ libmodsecurity make falló."; exit 1; }
    make install >/dev/null 2>&1 || true
    ldconfig

    # nginx connector como módulo dinámico contra nginx source de la versión instalada.
    NGINX_VER=$(nginx -v 2>&1 | sed -E 's|.*nginx/||')
    [ -z "$NGINX_VER" ] && { echo "❌ No se detectó versión nginx."; exit 1; }
    cd "$BUILD_DIR"
    if [ ! -f "nginx-$NGINX_VER.tar.gz" ]; then
        wget -q "https://nginx.org/download/nginx-$NGINX_VER.tar.gz" -O "nginx-$NGINX_VER.tar.gz" \
            || { echo "❌ download nginx-$NGINX_VER source falló."; exit 1; }
    fi
    [ -d "nginx-$NGINX_VER" ] || tar xzf "nginx-$NGINX_VER.tar.gz"
    [ -d ModSecurity-nginx ] || GIT_TERMINAL_PROMPT=0 git -c credential.helper= clone --depth 1 \
        "https://${GH_AUTH}github.com/SpiderLabs/ModSecurity-nginx.git" \
        || { echo "❌ git clone connector falló (¿sin red, rate-limit o token invalido?)."; exit 1; }

    # Reproducir configure args del nginx instalado (nginx -V) + add-dynamic-module.
    # --with-compat permite módulo portable si el nginx instalado también lo usó.
    NGINX_CONFIG_ARGS=$(nginx -V 2>&1 | sed -n 's/.*configure arguments: //p')
    cd "nginx-$NGINX_VER"
    # shellcheck disable=SC2086
    if ! ./configure --with-compat --add-dynamic-module=../ModSecurity-nginx \
            $NGINX_CONFIG_ARGS >/dev/null 2>&1; then
        echo "❌ nginx connector configure falló."
        echo "   Alternativa: añade el repo nginx.org (nginx-stable) y dnf install"
        echo "   nginx-module-modsecurity (módulo precompilado compatible)."
        exit 1
    fi
    make modules >/dev/null 2>&1 || { echo "❌ make modules falló."; exit 1; }
    mkdir -p /usr/lib64/nginx/modules
    cp objs/ngx_http_modsecurity_module.so /usr/lib64/nginx/modules/ \
        || { echo "❌ copia .so falló."; exit 1; }
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
    curl -fsSL "https://github.com/coreruleset/coreruleset/releases/download/v${CRS_VER}/coreruleset-${CRS_VER}.tar.gz" \
        -o /tmp/crs.tar.gz || { echo "❌ CRS download falló."; exit 1; }
    tar xzf /tmp/crs.tar.gz -C /tmp
    mv "/tmp/coreruleset-${CRS_VER}" /etc/nginx/modsec/owasp-crs
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
    echo "   ⚠️  AVISO: nginx -t falló. Detalle:"
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
echo " 🛡️  WAF MODSECURITY INSTALADO (DetectionOnly)"
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