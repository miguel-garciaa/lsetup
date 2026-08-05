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

# --- 1.5 RESUMEN RÁPIDO DE SERVICIOS (solo is-active + octane healthz) -----
echo -e "\n\e[1;36m[+] RESUMEN RÁPIDO DE SERVICIOS\e[0m"
svc_state() { systemctl is-active "$1" 2>/dev/null || echo "inactive"; }
printf "  %-22s %s\n" "postgresql-18" "$(svc_state postgresql-18)"
printf "  %-22s %s\n" "redis" "$(svc_state redis)"
printf "  %-22s %s\n" "nginx" "$(svc_state nginx)"
OCT_STATE=$(svc_state octane)
HZ_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 2 http://127.0.0.1:8000/healthz 2>/dev/null)
if [ "$HZ_CODE" = "200" ]; then
  OCT_STATE="$OCT_STATE (healthz UP)"
elif [ -n "$HZ_CODE" ] && [ "$HZ_CODE" != "000" ]; then
  OCT_STATE="$OCT_STATE (healthz HTTP $HZ_CODE)"
else
  OCT_STATE="$OCT_STATE (healthz no responde)"
fi
printf "  %-22s %s\n" "octane" "$OCT_STATE"
printf "  %-22s %s\n" "firewalld" "$(svc_state firewalld)"
printf "  %-22s %s\n" "chronyd" "$(svc_state chronyd)"
printf "  %-22s %s\n" "fail2ban" "$(svc_state fail2ban)"
printf "  %-22s %s\n" "crowdsec" "$(svc_state crowdsec)"
printf "  %-22s %s\n" "crowdsec-firewall-bouncer" "$(svc_state crowdsec-firewall-bouncer)"
printf "  %-22s %s\n" "dnf-automatic.timer" "$(svc_state dnf-automatic.timer)"
printf "  %-22s %s\n" "clamav-freshclam" "$(svc_state clamav-freshclam)"
printf "  %-22s %s\n" "atd" "$(svc_state atd)"
printf "  %-22s %s\n" "auditd" "$(svc_state auditd)"
printf "  %-22s %s\n" "sshd" "$(svc_state sshd)"

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

# crowdsec-firewall-bouncer — programa reglas nftables desde decisiones LAPI
echo "  crowdsec-firewall-bouncer:"
echo "    systemctl: $(svc_active crowdsec-firewall-bouncer)"
if systemctl is-active --quiet crowdsec-firewall-bouncer 2>/dev/null; then
  echo "    funcional: OK"
else
  echo "    funcional: FAIL"
fi

echo "======================================================="