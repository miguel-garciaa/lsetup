#!/bin/bash
# ==============================================================================
# status.sh — Panel unificado: sec-logs + SERVICIOS LSETUP (audit DB+HTTP)
# Embebido en binario Go `lsetup`. Desplegable via: lsetup status --install
# Si /usr/local/bin/sec-logs existe (instalado por secure.sh), lo invoca y luego
# añade la sección de servicios. Si no existe, muestra aviso + sección servicios.
# ==============================================================================

# --- 1. Panel sec-logs completo (si está instalado por secure.sh) -----------
if [ -x /usr/local/bin/sec-logs ]; then
  /usr/local/bin/sec-logs
else
  echo "======================================================="
  echo "   PANEL DE AUDITORÍA"
  echo "  (sec-logs no instalado — ejecuta: sudo lsetup secure)"
  echo "======================================================="
fi

# --- 2. SERVICIOS LSETUP (estado profundo DB+HTTP) --------------------------
echo -e "\n\e[1;36m[+] SERVICIOS LSETUP (estado profundo DB+HTTP)\e[0m"

svc_active() {
  systemctl is-active "$1" 2>/dev/null || echo "inactive"
}

# postgresql-18 — SELECT 1 via psql
echo "  postgresql-18:"
echo "    systemctl: $(svc_active postgresql-18)"
if sudo -u postgres psql -At -c "SELECT 1;" 2>/dev/null | grep -q "^1$"; then
  echo "    funcional: OK"
else
  echo "    funcional: FAIL"
fi

# redis — redis-cli ping (respeta requirepass si configurada)
echo "  redis:"
echo "    systemctl: $(svc_active redis)"
RPASS=$(awk '/^requirepass[[:space:]]/{print $2}' /etc/redis/redis.conf 2>/dev/null)
if [ -n "$RPASS" ]; then
  RESULT=$(redis-cli -a "$RPASS" ping 2>/dev/null)
else
  RESULT=$(redis-cli ping 2>/dev/null)
fi
[ "$RESULT" = "PONG" ] && echo "    funcional: OK" || echo "    funcional: FAIL (sin PONG)"

# nginx — nginx -t (sintaxis config)
echo "  nginx:"
echo "    systemctl: $(svc_active nginx)"
if sudo nginx -t 2>/dev/null; then
  echo "    funcional: OK (config syntax válida)"
else
  echo "    funcional: FAIL (config rota)"
fi

# octane — HTTP GET /healthz espera 200 + {"status":"UP"}
echo "  octane:"
echo "    systemctl: $(svc_active octane)"
CODE=$(curl -s -o /tmp/.lsetup_hz -w "%{http_code}" --max-time 2 http://127.0.0.1:8000/healthz 2>/dev/null)
BODY=$(cat /tmp/.lsetup_hz 2>/dev/null); rm -f /tmp/.lsetup_hz
if [ "$CODE" = "200" ] && echo "$BODY" | grep -q '"status":"UP"'; then
  echo "    funcional: OK (healthz UP)"
elif [ "$CODE" = "200" ]; then
  echo "    funcional: WARN (200 pero body inesperado: $BODY)"
else
  echo "    funcional: FAIL (HTTP ${CODE:-0})"
fi

# firewalld — firewall-cmd --state
echo "  firewalld:"
echo "    systemctl: $(svc_active firewalld)"
STATE=$(sudo firewall-cmd --state 2>/dev/null)
if [ -n "$STATE" ]; then
  echo "    funcional: OK ($STATE)"
else
  echo "    funcional: FAIL"
fi

# chronyd — chronyc tracking (muestra stratum/offset)
echo "  chronyd:"
echo "    systemctl: $(svc_active chronyd)"
TRACKING=$(chronyc tracking 2>/dev/null | head -3)
if [ -n "$TRACKING" ]; then
  echo "    funcional: OK"
  echo "$TRACKING" | sed 's/^/      /'
else
  echo "    funcional: FAIL (no sincronizado)"
fi

# fail2ban — fail2ban-client status
echo "  fail2ban:"
echo "    systemctl: $(svc_active fail2ban)"
if sudo fail2ban-client status >/dev/null 2>&1; then
  echo "    funcional: OK"
else
  echo "    funcional: FAIL"
fi

# crowdsec — cscli status
echo "  crowdsec:"
echo "    systemctl: $(svc_active crowdsec)"
if sudo cscli status >/dev/null 2>&1; then
  echo "    funcional: OK"
else
  echo "    funcional: FAIL"
fi

echo "======================================================="