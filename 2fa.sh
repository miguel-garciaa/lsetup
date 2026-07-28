#!/bin/bash
set -e

# ==============================================================================
# SCRIPT DE ACTIVACIÓN/DESACTIVACIÓN DE 2FA SSH (GOOGLE AUTHENTICATOR PAM)
# Requisito previo: secure.sh ya ejecutado (existe 00-hardening.conf).
# Uso:
#   sudo bash 2fa.sh         → activar 2FA (genera o reusa secreto TOTP)
#   sudo bash 2fa.sh --off   → desactivar 2FA (vuelve a pubkey-only)
# ==============================================================================

if [ "$EUID" -ne 0 ]; then
    echo "⚠️ Ejecuta este script como root o con sudo."
    exit 1
fi

SSHD_DROPIN=/etc/ssh/sshd_config.d/00-hardening.conf

echo "=========================================================================="
if [ "$1" = "--off" ]; then
    echo " 🛡️  DESACTIVANDO 2FA SSH"
else
    echo " 🛡️  ACTIVANDO 2FA SSH (GOOGLE AUTHENTICATOR)"
fi
echo "=========================================================================="

# Requisito: secure.sh debe haber creado el drop-in de hardening.
if [ ! -f "$SSHD_DROPIN" ]; then
    echo "ERROR: no existe $SSHD_DROPIN."
    echo "       Ejecuta primero secure.sh (bastionado SSH base)."
    exit 1
fi

# Instalar paquete google-authenticator si falta (EPEL).
if ! rpm -q google-authenticator &>/dev/null; then
    dnf install -y epel-release
    dnf install -y google-authenticator
fi

# ------------------------------------------------------------------------------
# DESACTIVAR 2FA (--off)
# ------------------------------------------------------------------------------
if [ "$1" = "--off" ]; then
    TS=$(date +%s)
    PAM_BAK=/etc/pam.d/sshd.bak.$TS
    DROPIN_BAK="$SSHD_DROPIN.bak.$TS"
    cp -a /etc/pam.d/sshd "$PAM_BAK"
    cp -a "$SSHD_DROPIN" "$DROPIN_BAK"

    # PAM: borrar pam_google_authenticator y restaurar password-auth.
    sed -i '/pam_google_authenticator/d' /etc/pam.d/sshd 2>/dev/null || true
    sed -i -E 's/^#\s*(auth\s+substack\s+password-auth)/\1/' /etc/pam.d/sshd 2>/dev/null || true

    # Drop-in: kbd-int a no, quitar AuthenticationMethods.
    sed -i -E 's/^\s*KbdInteractiveAuthentication.*/KbdInteractiveAuthentication no/I' "$SSHD_DROPIN"
    sed -i '/^AuthenticationMethods/d' "$SSHD_DROPIN"

    if ! sshd -t 2>/tmp/sshd_err; then
        echo "ERROR: sshd -t falló. NO se reinicia sshd. Detalle:"
        cat /tmp/sshd_err
        echo "Restaurando backups..."
        cp -a "$PAM_BAK" /etc/pam.d/sshd
        cp -a "$DROPIN_BAK" "$SSHD_DROPIN"
        exit 1
    fi
    systemctl restart sshd
    echo ">> 2FA DESACTIVADA. SSH vuelve a pubkey-only."
    echo "   El archivo ~/.google_authenticator del usuario NO se borra;"
    echo "   vuelve a activar con: sudo bash 2fa.sh"
    exit 0
fi

# ------------------------------------------------------------------------------
# ACTIVAR 2FA
# ------------------------------------------------------------------------------

# Usuario objetivo (prompt con default miguel).
DEFAULT_USER="miguel"
read -rp "1. Usuario para 2FA [default: $DEFAULT_USER]: " SSH_USER
SSH_USER="${SSH_USER:-$DEFAULT_USER}"
if ! id "$SSH_USER" &>/dev/null; then
    echo "Error: el usuario '$SSH_USER' no existe."
    exit 1
fi
USER_HOME=$(eval echo "~$SSH_USER")
if [ ! -f "$USER_HOME/.ssh/authorized_keys" ] || [ ! -s "$USER_HOME/.ssh/authorized_keys" ]; then
    echo "⚠️ ALERTA: '$SSH_USER' no tiene claves en authorized_keys."
    echo "   Sin clave pública te quedarás fuera al activar 2FA."
    exit 1
fi

# TOTP requiere reloj sincronizado.
timedatectl set-ntp true 2>/dev/null || true

# ¿Generar secreto nuevo o usar existente?
GEN_NEW="s"
if [ -f "$USER_HOME/.google_authenticator" ]; then
    read -rp "   Ya existe secreto para '$SSH_USER'. ¿Generar nuevo? [s/N]: " GEN_NEW
    GEN_NEW="${GEN_NEW:-N}"
    GEN_NEW="${GEN_NEW,,}"
else
    GEN_NEW="s"
fi

if [[ "$GEN_NEW" == "s" || "$GEN_NEW" == "si" || "$GEN_NEW" == "sí" ]]; then
    echo "   >> Generando secreto TOTP y scratch codes para '$SSH_USER'..."
    # -t: TOTP time-based | -d: disallow reuse | -f: force overwrite
    # -r 3 -R 30: rate-limit 3 intentos / 30s | -W: sin QR (texto)
    # -e 10: 10 scratch codes de emergencia
    # Ejecutar como root con HOME del usuario: NO abre sesión PAM → no dispara
    # maxlogins (limits.d/99-ssh-max.conf). Luego chown del archivo al usuario.
    if ! HOME="$USER_HOME" google-authenticator -t -d -f -r 3 -R 30 -W -e 10; then
        echo "ERROR: no se pudo generar el secreto TOTP. Abortando (no se toca sshd)."
        exit 1
    fi
    chown "$SSH_USER:$SSH_USER" "$USER_HOME/.google_authenticator"
    chmod 600 "$USER_HOME/.google_authenticator"
    echo ""
    echo "   ================================================================"
    echo "   🔑 GUARDA AHORA EL SECRETO Y LOS SCRATCH CODES (arriba)."
    echo "      - Introduce el 'secret key' en tu app TOTP (Authy/1Password)."
    echo "      - Los scratch codes son accesos de emergencia únicos."
    echo "      - Si pierdes el móvil Y los scratch codes, QUEDAS FUERA."
    echo "   ================================================================"
    echo ""
else
    echo "   >> Usando secreto existente en $USER_HOME/.google_authenticator"
fi

# Backup antes de tocar PAM y drop-in.
TS=$(date +%s)
PAM_BAK=/etc/pam.d/sshd.bak.$TS
DROPIN_BAK="$SSHD_DROPIN.bak.$TS"
cp -a /etc/pam.d/sshd "$PAM_BAK"
cp -a "$SSHD_DROPIN" "$DROPIN_BAK"

# PAM: kbd-int SOLO pedirá TOTP (la clave pública ya se validó en capa SSH).
# Comentar 'auth substack password-auth' para que no pida password además.
# Idempotente: limpia líneas previas y restaura password-auth antes de tocar.
sed -i '/pam_google_authenticator/d' /etc/pam.d/sshd 2>/dev/null || true
sed -i -E 's/^#\s*(auth\s+substack\s+password-auth)/\1/' /etc/pam.d/sshd 2>/dev/null || true
sed -i -E 's/^(auth\s+substack\s+password-auth)/#\1/' /etc/pam.d/sshd 2>/dev/null || true
if ! grep -Eq '^#\s*auth\s+substack\s+password-auth' /etc/pam.d/sshd; then
    echo "   ⚠️  AVISO: no se encontró 'auth substack password-auth' en /etc/pam.d/sshd."
    echo "      Es posible que kbd-int pida password además de TOTP. Revisa el archivo."
fi
echo "auth required pam_google_authenticator.so" >> /etc/pam.d/sshd

# Drop-in: habilitar kbd-int y forzar cadena publickey + kbd-int (TOTP).
sed -i -E 's/^\s*KbdInteractiveAuthentication.*/KbdInteractiveAuthentication yes/I' "$SSHD_DROPIN"
# Reescribir AuthenticationMethods (idempotente).
sed -i '/^AuthenticationMethods/d' "$SSHD_DROPIN"
echo "AuthenticationMethods publickey,keyboard-interactive:pam" >> "$SSHD_DROPIN"

# Validar antes de reiniciar: si falla, restaura backup y aborta.
if ! sshd -t 2>/tmp/sshd_err; then
    echo "ERROR: sshd -t falló. NO se reinicia sshd. Detalle:"
    cat /tmp/sshd_err
    echo "Restaurando backups de pam.d/sshd y drop-in..."
    cp -a "$PAM_BAK" /etc/pam.d/sshd
    cp -a "$DROPIN_BAK" "$SSHD_DROPIN"
    exit 1
fi
systemctl restart sshd

echo "=========================================================================="
echo " 🚀 2FA SSH ACTIVADA para '$SSH_USER'"
echo "=========================================================================="
echo " - Próxima conexión SSH pedirá: clave pública + código TOTP del móvil."
echo " - Comando de prueba desde tu PC:"
echo "     ssh -p <PUERTO> $SSH_USER@<SERVER>"
echo " - Para desactivar 2FA: sudo bash 2fa.sh --off"
echo "=========================================================================="
