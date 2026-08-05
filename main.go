package main

import (
	"crypto/rand"
	"encoding/hex"
	"flag"
	"fmt"
	"log/slog"
	"os"
	"path/filepath"
	"strings"
)

// main es el dispatcher de subcomandos.
// Surface CLI:
//
//	init              genera lsetup.conf template (aborta si existe, --force override)
//	up                ejecuta pipeline completo (setup→dominio→waf→harden→secure→backup-install)
//	2fa --on/--off    activa/desactiva 2FA SSH
//	status            panel auditoría (sec-logs + SERVICIOS LSETUP)
//	backup            snapshots (cron-driven)
//	backup-verify     verifica snapshots (cron semanal)
//	restore           restauración interactiva manual
//
// Alias por basename: si el binario se invoca como `status`/`backup`/`backup-verify`/
// `restore` (vía copia a /usr/local/bin/<name> hecha por `lsetup up` exitoso),
// ejecuta el subcomando correspondiente sin prefijo.
// setup es subcomando por defecto SOLO si no hay args (para mostrar ayuda).
func main() {
	// Diagnóstico: si esto no se imprime, el binario está corrupto (scp incompleto).
	fmt.Fprintln(os.Stderr, "[lsetup] init OK — arrancando dispatcher...")
	args := os.Args[1:]
	base := strings.TrimSuffix(filepath.Base(os.Args[0]), ".exe")

	// Alias por basename: invocar por nombre alternativo sin prefijo.
	if cmd, ok := aliasCmd(base, args); ok {
		cmd()
		return
	}

	if len(args) == 0 {
		printHelp()
		return
	}
	if strings.HasPrefix(args[0], "-") && args[0] != "-h" && args[0] != "--help" {
		fmt.Fprintf(os.Stderr, "Flag inesperado sin subcomando: %s\n", args[0])
		printHelp()
		os.Exit(2)
	}
	switch args[0] {
	case "init":
		cmdInit(args[1:])
	case "up":
		cmdUp(args[1:])
	case "2fa":
		cmd2fa(args[1:])
	case "status":
		cmdStatus(args[1:])
	case "backup":
		cmdBackup(args[1:])
	case "backup-verify":
		cmdBackupVerify(args[1:])
	case "restore":
		cmdRestore(args[1:])
	case "-h", "--help", "help":
		printHelp()
	default:
		fmt.Fprintf(os.Stderr, "Subcomando desconocido: %s\n", args[0])
		printHelp()
		os.Exit(2)
	}
}

// aliasCmd devuelve el comando a ejecutar si el binario fue invocado por un
// nombre alternativo (basename instalado por `lsetup up` en /usr/local/bin).
// Devuelve (nil, false) si el basename no es alias conocido.
type cmdFunc func()

func aliasCmd(base string, args []string) (cmdFunc, bool) {
	switch base {
	case "status":
		return func() { cmdStatus(args) }, true
	case "backup":
		return func() { cmdBackup(args) }, true
	case "backup-verify":
		return func() { cmdBackupVerify(args) }, true
	case "restore":
		return func() { cmdRestore(args) }, true
	}
	return nil, false
}

// printHelp muestra la ayuda completa con todos los subcomandos.
func printHelp() {
	fmt.Println("lsetup — Instalador y gestión de servidor Laravel/AlmaLinux 10")
	fmt.Println()
	fmt.Println("SUBCOMANDOS:")
	fmt.Println("  init              Genera ./lsetup.conf template (multi-sección)")
	fmt.Println("  up                Ejecuta pipeline completo (setup→dominio→waf→harden→secure→backup-install)")
	fmt.Println("  2fa --on          Activa 2FA SSH (Google Authenticator PAM)")
	fmt.Println("  2fa --off         Desactiva 2FA SSH")
	fmt.Println("  status            Panel de auditoría (sec-logs + SERVICIOS LSETUP DB+HTTP)")
	fmt.Println("  backup            Ejecuta 3 snapshots (db/dat/keyring) — tarea cron")
	fmt.Println("  backup-verify     Verifica integridad snapshots (gzip -t, tar -tzf, decrypt prueba)")
	fmt.Println("  restore           Restauración interactiva de backups (DB/FILES/SECRETS/TODO)")
	fmt.Println()
	fmt.Println("USO:")
	fmt.Println("  ./lsetup init [--force] [--config=path]   Genera config (aborta si existe, --force override)")
	fmt.Println("  ./lsetup up [--config=path]                Pipeline completo en orden AGENTS.md")
	fmt.Println("  ./lsetup 2fa --on|--off                    Toggle 2FA (flag requerido)")
	fmt.Println("  ./lsetup status                            Panel auditoría (read-only)")
	fmt.Println("  ./lsetup backup                            Snapshots (cron)")
	fmt.Println("  ./lsetup backup-verify                     Verifica snapshots (cron semanal)")
	fmt.Println("  ./lsetup restore                           Restauración manual interactiva")
	fmt.Println("  ./lsetup --help                            Esta ayuda")
	fmt.Println()
	fmt.Println("CONFIG FILE (./lsetup.conf) — multi-sección INI:")
	fmt.Println("  [setup]         OBLIGATORIA para up. Rellena project, db_name, db_user, db_pass[_file].")
	fmt.Println("  [dominio]       Opcional. domain_name, proyecto_dir, cloudflare_cert (PEM multi-línea),")
	fmt.Println("                  cloudflare_key  (PEM multi-línea). Vacía → up skip dominio.")
	fmt.Println("  [github]        Opcional. github_user, github_token (PAT). Waf.sh los usa para git clone")
	fmt.Println("                  de libmodsecurity sin rate-limit anónimo. Vacía → clone anónimo (puede fallar).")
	fmt.Println("  [secure]        Opcional. allowed_ip, ssh_port, ssh_user, redis_pass, report_email,")
	fmt.Println("                  grub_pass. Vacía → up skip hardening.")
	fmt.Println("  [backup-install] Opcional. cad_opt, bk_time, ret_days, etc. Vacía → up skip backups.")
	fmt.Println()
	fmt.Println("  Tras cada paso exitoso, `up` borra del config la sección consumida (auto-shred).")
	fmt.Println("  Si era la última sección, borra el archivo físico entero.")
	fmt.Println()
	fmt.Println("ALIAS (tras `lsetup up` exitoso):")
	fmt.Println("  sudo status         ==  sudo lsetup status")
	fmt.Println("  sudo backup         ==  sudo lsetup backup         (cron)")
	fmt.Println("  sudo backup-verify ==  sudo lsetup backup-verify  (cron semanal)")
	fmt.Println("  sudo restore        ==  sudo lsetup restore")
	fmt.Println()
	fmt.Println("FLUJO TÍPICO:")
	fmt.Println("  1. ./lsetup init                → genera ./lsetup.conf (multi-sección)")
	fmt.Println("  2. nano ./lsetup.conf            → rellena [setup] (obligatorio) + [secure]/[dominio]/[backup-install]")
	fmt.Println("  3. ./lsetup up                   → ejecuta pipeline completo en orden + instala aliases")
	fmt.Println("  4. ./lsetup 2fa --on             → (opcional) activa 2FA SSH")
	fmt.Println("  5. ./lsetup status               → panel de auditoría")
}

// cmdInit genera lsetup.conf template. Aborta si existe, --force para override.
// Autogen redis_pass con openssl hex 48 (placeholder __REDIS_PASS__ sustituido).
// Fallback a crypto/rand si openssl no disponible.
func cmdInit(args []string) {
	fs := flag.NewFlagSet("init", flag.ExitOnError)
	fs.SetOutput(os.Stderr)
	cfgPath := fs.String("config", "./lsetup.conf", "Ruta config file")
	force := fs.Bool("force", false, "Sobrescribe lsetup.conf existente")
	help := fs.Bool("h", false, "Muestra ayuda")
	fs.BoolVar(help, "help", false, "Muestra ayuda")
	_ = fs.Parse(args)

	if *help {
		fmt.Println("Uso: lsetup init [--force] [--config=path]")
		fmt.Println("  Genera ./lsetup.conf template (multi-sección INI).")
		fmt.Println("  Aborta si ya existe (usa --force para sobrescribir).")
		fmt.Println("  Autogenera redis_pass (hex 48) en [secure] con openssl.")
		return
	}

	if fileExists(*cfgPath) && !*force {
		fmt.Fprintf(os.Stderr, "Error: %s ya existe. Usa --force para sobrescribir.\n", *cfgPath)
		os.Exit(1)
	}

	// Generar Redis password (hex 48).
	pass := genRedisPassHex48()

	// Sustituir placeholder en template y escribir.
	content := strings.ReplaceAll(tplLsetupConf, "__REDIS_PASS__", pass)
	if err := writeRootFile(*cfgPath, content, 0600); err != nil {
		fmt.Fprintln(os.Stderr, "Error creando config:", err)
		os.Exit(1)
	}
	fmt.Printf("Config generado: %s\n", *cfgPath)
	fmt.Printf("redis_pass autogenerada en [secure] (hex 48): %s\n", pass)
	fmt.Println("Edita las secciones que necesites ([setup] obligatoria para `up`).")
	fmt.Println("Luego ejecuta: ./lsetup up")
}

// genRedisPassHex48 genera un password hexadecimal de 48 bytes (96 chars).
// Intenta primero `openssl rand -hex 48` (compatible server), fallback a
// crypto/rand si openssl no está en PATH.
func genRedisPassHex48() string {
	if out, err := cmdOutput("openssl", "rand", "-hex", "48"); err == nil {
		s := strings.TrimSpace(out)
		if len(s) > 0 {
			return s
		}
	}
	// Fallback: crypto/rand (stdlib).
	b := make([]byte, 48)
	for i := range b {
		b[i] = 0
	}
	if _, err := rand.Read(b); err != nil {
		// Último recurso: fallback determinista (no should happen en server).
		return "00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
	}
	return hex.EncodeToString(b)
}

// detectServerIP replica `hostname -I | awk '{print $1}'` con fallback 127.0.0.1.
func detectServerIP() (string, error) {
	out, err := cmdOutput("hostname", "-I")
	if err != nil {
		return "", err
	}
	fields := strings.Fields(strings.TrimSpace(out))
	if len(fields) == 0 {
		return "", fmt.Errorf("hostname -I vacío")
	}
	return fields[0], nil
}

// unusedLog evita "imported and not used" si slog solo se usa en otros archivos.
var _ = slog.New
