package main

import (
	"bytes"
	_ "embed"
	"flag"
	"fmt"
	"log/slog"
	"os"
)

// ===== Embeds de scripts bash originales =====
//
// Cada script se embebe vía go:embed y se ejecuta con stdin/stdout/stderr
// heredados (preserva prompts interactivos). Antes de ejecutar, cmdUp exporta
// las claves de la sección correspondiente como env vars (UPPERCASE) — los
// scripts parcheados, si la var ya existe, omiten el prompt interactivo.

//go:embed secure.sh
var shSecure []byte

//go:embed waf.sh
var shWaf []byte

//go:embed harden.sh
var shHarden []byte

//go:embed dominio.sh
var shDominio []byte

//go:embed backup-install.sh
var shBackupInstall []byte

//go:embed backup.sh
var shBackup []byte

//go:embed backup-verify.sh
var shBackupVerify []byte

//go:embed restore.sh
var shRestore []byte

//go:embed 2fa.sh
var sh2fa []byte

// ===== Helpers comunes =====

// runEmbedded ejecuta un script bash embebido (pasado como []byte) en un
// tmpfile. Preserva stdin/stdout/stderr del proceso (interactividad).
// scriptArgs son argv extras para el script (ej: ["--off"] para 2fa.sh).
// Devuelve exit code (0 OK, ≠0 fallo).
//
// Normaliza CRLF→LF: scripts editados en Windows con \r\n rompen bash en Linux
// ("set: -\r: opción inválida", "$'\r': orden no encontrada"). Stripping CR
// aquí garantiza ejecución correcta sin importar line endings del source.
func runEmbedded(script []byte, scriptArgs []string) int {
	clean := bytes.ReplaceAll(script, []byte("\r\n"), []byte("\n"))
	clean = bytes.ReplaceAll(clean, []byte("\r"), []byte("\n"))

	tmp, err := os.CreateTemp("", "lsetup-*.sh")
	if err != nil {
		fmt.Fprintln(os.Stderr, "Error creando tmpfile:", err)
		return 1
	}
	tmpPath := tmp.Name()
	defer os.Remove(tmpPath)
	if _, err := tmp.Write(clean); err != nil {
		tmp.Close()
		fmt.Fprintln(os.Stderr, "Error escribiendo tmpfile:", err)
		return 1
	}
	tmp.Close()

	args := append([]string{tmpPath}, scriptArgs...)
	return runBashWith(args)
}

// runBashWith ejecuta `bash <args>...` conectando stdin/stdout/stderr del
// proceso actual al del bash. Devuelve exit code.
func runBashWith(bashArgs []string) int {
	return runCmdPassthrough(append([]string{"bash"}, bashArgs...))
}

// sectionNonEmpty devuelve true si la sección existe y tiene al menos una
// clave con valor non-empty.
func sectionNonEmpty(cf *ConfigFile, section string) bool {
	for _, v := range cf.Section(section) {
		if v != "" {
			return true
		}
	}
	return false
}

// deployAliasSelf copia el binario actual (lsetup) a /usr/local/bin/<name>.
// Crea el alias para invocación sin prefijo (sudo <name>).
func deployAliasSelf(name string) {
	self, err := os.Executable()
	if err != nil {
		fmt.Fprintln(os.Stderr, "Aviso: no se pudo detectar binario actual:", err)
		return
	}
	src, err := os.ReadFile(self)
	if err != nil {
		fmt.Fprintln(os.Stderr, "Aviso: no se pudo leer binario:", err)
		return
	}
	dst := "/usr/local/bin/" + name
	if err := os.WriteFile(dst, src, 0755); err != nil {
		fmt.Fprintln(os.Stderr, "Aviso: no se pudo desplegar alias", name, ":", err)
		return
	}
	fmt.Printf("Alias desplegado: %s\n", dst)
}

// containsStr helper mínimo (stdlib no tiene para []string).
func containsStr(s []string, v string) bool {
	for _, x := range s {
		if x == v {
			return true
		}
	}
	return false
}

// toUpperASCII convierte ASCII a mayúsculas sin unicode (suficiente para claves
// alfanuméricas del config INI).
func toUpperASCII(s string) string {
	b := []byte(s)
	for i := range b {
		if b[i] >= 'a' && b[i] <= 'z' {
			b[i] -= 32
		}
	}
	return string(b)
}

// subcmdHelpFlagSet construye un flag.FlagSet estándar para subcomandos
// operacionales (backup, backup-verify, restore). Devuelve (cfgPath, install, help).
func subcmdHelpFlagSet(name string, args []string) (cfgPath string, install bool, help bool) {
	fs := flag.NewFlagSet(name, flag.ContinueOnError)
	fs.SetOutput(os.Stderr)
	cfg := fs.String("config", "./lsetup.conf", "Ruta config file")
	inst := fs.Bool("install", false, "Despliega alias en /usr/local/bin/"+name)
	h := fs.Bool("h", false, "Muestra ayuda")
	fs.BoolVar(h, "help", false, "Muestra ayuda")
	_ = fs.Parse(args)
	return *cfg, *inst, *h
}

// ===== cmdUp — pipeline completo =====

// cmdUp ejecuta el pipeline de instalación completo en orden AGENTS.md:
//  1. setup       (REQUIRED — aborta si [setup] vacío y proyecto no instalado)
//  2. dominio     (opcional — skip si [dominio] vacío)
//  3. waf         (siempre)
//  4. harden      (siempre)
//  5. secure       (opcional — skip si [secure] vacío; LAST hardening)
//  6. backup-install (opcional — skip si [backup-install] vacío)
//
// Tras pipeline OK, instala aliases en /usr/local/bin:
//
//	status, backup, backup-verify, restore.
func cmdUp(args []string) {
	fs := flag.NewFlagSet("up", flag.ExitOnError)
	fs.SetOutput(os.Stderr)
	cfgPath := fs.String("config", "./lsetup.conf", "Ruta config file")
	help := fs.Bool("h", false, "Muestra ayuda")
	fs.BoolVar(help, "help", false, "Muestra ayuda")
	_ = fs.Parse(args)

	if *help {
		fmt.Println("Uso: lsetup up [--config=path]")
		fmt.Println("  Ejecuta pipeline completo en orden AGENTS.md:")
		fmt.Println("    1. setup             (REQUIRED — aborta si [setup] vacío y proyecto no instalado)")
		fmt.Println("    2. dominio           (opcional — skip si [dominio] vacío)")
		fmt.Println("    3. waf               (siempre)")
		fmt.Println("    4. harden            (siempre)")
		fmt.Println("    5. secure            (opcional — skip si [secure] vacío; LAST hardening)")
		fmt.Println("    6. backup-install    (opcional — skip si [backup-install] vacío)")
		fmt.Println("  Tras pipeline OK, instala aliases en /usr/local/bin/status, backup, backup-verify, restore.")
		return
	}

	if !fileExists(*cfgPath) {
		fmt.Fprintln(os.Stderr, "Config no existe. Ejecuta primero: lsetup init")
		os.Exit(1)
	}
	cf, err := loadConfig(*cfgPath)
	if err != nil {
		fmt.Fprintln(os.Stderr, "Error leyendo config:", err)
		os.Exit(1)
	}

	log := slog.New(slog.NewJSONHandler(os.Stdout, nil))

	// --- Paso 1: setup (REQUIRED) ---
	fmt.Println("\n>>> [1/6] setup")
	if !sectionNonEmpty(cf, "setup") {
		// Idempotencia: si proyecto ya tiene vendor, asumimos setup hecho.
		projName := cf.Section("setup")["project"]
		if projName == "" {
			projName = "laravel1"
		}
		if fileExists("/var/www/" + projName + "/vendor") {
			log.Warn("[setup] vacío pero vendor/ encontrado — asumiendo setup ya ejecutado, saltando")
		} else {
			fmt.Fprintln(os.Stderr, "[setup] vacío o incompleto en", *cfgPath)
			fmt.Fprintln(os.Stderr, "Rellena la sección [setup] (project, db_name, db_user, db_pass o db_pass_file) y re-ejecuta lsetup up.")
			os.Exit(1)
		}
	} else {
		if rc := runSetupStep(cf, *cfgPath, log); rc != 0 {
			fmt.Fprintf(os.Stderr, "Paso setup falló (exit %d). Pipeline abortado.\n", rc)
			os.Exit(rc)
		}
		// Auto-shred [setup] tras éxito.
		cf.RemoveSection("setup")
		if err := cf.save(); err != nil {
			log.Warn("auto-shred [setup] falló", "error", err)
		} else {
			log.Info("sección [setup] borrada del config (auto-shred)")
		}
	}

	// --- Paso 2: dominio (opcional) ---
	fmt.Println("\n>>> [2/6] dominio")
	if !sectionNonEmpty(cf, "dominio") {
		log.Warn("[dominio] vacío — saltando configuración de dominio + cert Cloudflare")
	} else {
		cf.exportEnvFiltered("dominio", []string{"domain_name", "proyecto_dir", "cloudflare_cert", "cloudflare_key"})
		if rc := runEmbedded(shDominio, nil); rc != 0 {
			fmt.Fprintf(os.Stderr, "Paso dominio falló (exit %d). Pipeline abortado.\n", rc)
			os.Exit(rc)
		}
		cf.RemoveSection("dominio")
		if err := cf.save(); err != nil {
			log.Warn("auto-shred [dominio] falló", "error", err)
		}
	}

	// --- Paso 3: waf (siempre) ---
	fmt.Println("\n>>> [3/6] waf")
	// Pre-exportar creds GitHub si [github] presente (waf.sh las usa para
	// clonar libmodsecurity + connector sin rate-limit anónimo).
	if sectionNonEmpty(cf, "github") {
		cf.exportEnvFiltered("github", []string{"github_user", "github_token"})
	}
	if rc := runEmbedded(shWaf, nil); rc != 0 {
		fmt.Fprintf(os.Stderr, "Paso waf falló (exit %d). Pipeline abortado.\n", rc)
		os.Exit(rc)
	}

	// --- Paso 4: harden (siempre) ---
	fmt.Println("\n>>> [4/6] harden")
	if rc := runEmbedded(shHarden, nil); rc != 0 {
		fmt.Fprintf(os.Stderr, "Paso harden falló (exit %d). Pipeline abortado.\n", rc)
		os.Exit(rc)
	}

	// --- Paso 5: secure (opcional — LAST hardening según AGENTS.md) ---
	fmt.Println("\n>>> [5/6] secure")
	if !sectionNonEmpty(cf, "secure") {
		log.Warn("[secure] vacío — saltando hardening SSH/firewalld/f2b/CrowdSec/AIDE/ClamAV")
	} else {
		cf.exportEnvFiltered("secure", nil) // exporta todas las claves
		if rc := runEmbedded(shSecure, nil); rc != 0 {
			fmt.Fprintf(os.Stderr, "Paso secure falló (exit %d). Pipeline abortado.\n", rc)
			os.Exit(rc)
		}
		cf.RemoveSection("secure")
		if err := cf.save(); err != nil {
			log.Warn("auto-shred [secure] falló", "error", err)
		}
	}

	// --- Paso 6: backup-install (opcional) ---
	fmt.Println("\n>>> [6/6] backup-install")
	if !sectionNonEmpty(cf, "backup-install") {
		log.Warn("[backup-install] vacío — saltando instalación del sistema de backups")
	} else {
		cf.exportEnvFiltered("backup-install", nil)
		if rc := runEmbedded(shBackupInstall, nil); rc != 0 {
			fmt.Fprintf(os.Stderr, "Paso backup-install falló (exit %d). Pipeline abortado.\n", rc)
			os.Exit(rc)
		}
		cf.RemoveSection("backup-install")
		if err := cf.save(); err != nil {
			log.Warn("auto-shred [backup-install] falló", "error", err)
		}
	}

	// --- Final: instalar aliases en /usr/local/bin ---
	fmt.Println("\n>>> Instalando aliases en /usr/local/bin...")
	deployAliasSelf("status")
	deployAliasSelf("backup")
	deployAliasSelf("backup-verify")
	deployAliasSelf("restore")

	fmt.Println("\n==========================================================================")
	fmt.Println(" lsetup up COMPLETADO")
	fmt.Println("==========================================================================")
	fmt.Println(" Aliases activos:")
	fmt.Println("   sudo status         — panel de auditoría")
	fmt.Println("   sudo backup          — snapshots (uso cron)")
	fmt.Println("   sudo backup-verify   — verificación semanal (uso cron)")
	fmt.Println("   sudo restore         — restauración interactiva")
	fmt.Println()
	fmt.Println(" Opcional: ./lsetup 2fa --on  para activar 2FA SSH")
	fmt.Println("==========================================================================")
}

// runSetupStep ejecuta el paso setup (idéntico al viejo cmdSetup) en el contexto
// de cmdUp. Devuelve exit code. posiblemente exitosa trae auto-shred via caller.
func runSetupStep(cf *ConfigFile, cfgPath string, log *slog.Logger) int {
	cfg, err := loadSetupConfig(cf)
	if err != nil {
		fmt.Fprintln(os.Stderr, "Error validación [setup]:", err)
		return 1
	}

	t, err := detectHardware()
	if err != nil {
		log.Error("detección hardware falló", "error", err)
		return 1
	}

	ip, err := detectServerIP()
	if err != nil {
		log.Warn("detección IP falló (usando 127.0.0.1)", "error", err)
		ip = "127.0.0.1"
	}

	fmt.Println("==========================================================================")
	fmt.Printf(" IPv4: %s\n", ip)
	fmt.Printf(" Proyecto:     %s\n", cfg.ProyectoDir)
	fmt.Println("==========================================================================")
	fmt.Printf(" Hardware: %d núcleos / %d MB RAM\n", t.CPU, t.RAM)
	fmt.Printf(" Octane:   workers=%d (FrankenPHP)\n", t.OctaneWorkers)
	fmt.Printf(" PG18:     shared_buffers=%dMB cache=%dMB work_mem=%dMB\n",
		t.PGSharedBuffers, t.PGEffectiveCacheSize, t.PGWorkMem)
	fmt.Printf(" Redis:    maxmemory=%dmb io-threads=%d\n", t.RedisMaxMemory, t.RedisIOThreads)
	fmt.Println("==========================================================================")

	app := newApp(cfg, t, ip)
	app.runSetup()
	return 0
}

// exportEnvFiltered exporta solo las claves listadas (si nil, exporta todas).
func (cf *ConfigFile) exportEnvFiltered(section string, allowed []string) {
	for k, v := range cf.Section(section) {
		if v == "" {
			continue
		}
		if allowed != nil && !containsStr(allowed, k) {
			continue
		}
		_ = os.Setenv(toUpperASCII(k), v)
	}
}

// ===== cmd2fa — flags --on / --off (requerido) =====

// cmd2fa requiere --on o --off. Sin flag → usage error + exit 2.
//
//	--on   ejecuta 2fa.sh con usuario de [secure].ssh_user si aún en config, o prompt interactivo.
//	--off  ejecuta 2fa.sh --off (argv ["--off"]).
//	--install  despliega alias en /usr/local/bin/2fa (opcional, no automatico).
func cmd2fa(args []string) {
	fs := flag.NewFlagSet("2fa", flag.ContinueOnError)
	fs.SetOutput(os.Stderr)
	cfgPath := fs.String("config", "./lsetup.conf", "Ruta config file")
	on := fs.Bool("on", false, "Activa 2FA SSH (genera/reusa secreto TOTP)")
	off := fs.Bool("off", false, "Desactiva 2FA SSH (vuelve a pubkey-only)")
	install := fs.Bool("install", false, "Despliega alias en /usr/local/bin/2fa")
	help := fs.Bool("h", false, "Muestra ayuda")
	fs.BoolVar(help, "help", false, "Muestra ayuda")
	_ = fs.Parse(args)

	if *help {
		fmt.Println("Uso: lsetup 2fa --on | --off")
		fmt.Println("  --on   Activa 2FA SSH con Google Authenticator PAM (genera/reusa secreto TOTP).")
		fmt.Println("  --off  Desactiva 2FA SSH (vuelve a pubkey-only).")
		fmt.Println("  Requiere --on o --off explicito (default OFF protege contra activaciones accidentales).")
		fmt.Println("  Usuario objetivo: [secure].ssh_user del config (si no auto-shreddado) o prompt interactivo.")
		return
	}

	if *install {
		deployAliasSelf("2fa")
		return
	}

	if !*on && !*off {
		fmt.Fprintln(os.Stderr, "Error: 2fa requiere un flag explicito: --on o --off")
		fmt.Fprintln(os.Stderr, "Default es OFF (protege contra activacion accidental de 2FA SSH).")
		fmt.Fprintln(os.Stderr, "Usa: lsetup 2fa --on   o   lsetup 2fa --off")
		os.Exit(2)
	}
	if *on && *off {
		fmt.Fprintln(os.Stderr, "Error: --on y --off son mutuamente excluyentes")
		os.Exit(2)
	}

	// Para --on: pre-exportar ssh_user si está en [secure] (config aún no shreddado)
	// o en env (override manual).
	if *on {
		cf, err := loadConfig(*cfgPath)
		if err == nil {
			if v := cf.Section("secure")["ssh_user"]; v != "" {
				_ = os.Setenv("SSH_USER", v)
			}
		}
		// 2fa.sh lee $SSH_USER si pre-set; si vacío, prompt interactivo.
		if rc := runEmbedded(sh2fa, nil); rc != 0 {
			os.Exit(rc)
		}
		return
	}

	// --off
	if rc := runEmbedded(sh2fa, []string{"--off"}); rc != 0 {
		os.Exit(rc)
	}
}

// ===== Subcomandos operacionales (backup, backup-verify, restore) =====
//
// Mantienen存在 para uso:
//   - cron (invoca `sudo /usr/local/bin/backup` o `sudo backup`)
//   - restauración manual (restore)

func cmdBackup(args []string) {
	cfgPath, install, help := subcmdHelpFlagSet("backup", args)
	if help {
		fmt.Println("Uso: lsetup backup [--install]")
		fmt.Println("  Ejecuta 3 snapshots (db/dat/keyring) — tarea cron.")
		fmt.Println("  --install: despliega alias en /usr/local/bin/backup.")
		return
	}
	if install {
		deployAliasSelf("backup")
		return
	}
	_ = cfgPath // backup.sh no lee config INI; lee /etc/backup.conf propio.
	os.Exit(runEmbedded(shBackup, nil))
}

func cmdBackupVerify(args []string) {
	cfgPath, install, help := subcmdHelpFlagSet("backup-verify", args)
	if help {
		fmt.Println("Uso: lsetup backup-verify [--install]")
		fmt.Println("  Verifica integridad snapshots (gzip -t, tar -tzf, decrypt prueba).")
		fmt.Println("  --install: despliega alias en /usr/local/bin/backup-verify.")
		return
	}
	if install {
		deployAliasSelf("backup-verify")
		return
	}
	_ = cfgPath
	os.Exit(runEmbedded(shBackupVerify, nil))
}

func cmdRestore(args []string) {
	cfgPath, install, help := subcmdHelpFlagSet("restore", args)
	if help {
		fmt.Println("Uso: lsetup restore [--install]")
		fmt.Println("  Restauración interactiva de backups (DB/FILES/SECRETS/TODO).")
		fmt.Println("  --install: despliega alias en /usr/local/bin/restore.")
		return
	}
	if install {
		deployAliasSelf("restore")
		return
	}
	_ = cfgPath
	os.Exit(runEmbedded(shRestore, nil))
}
