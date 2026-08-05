package main

import (
	"fmt"
	"net/http"
	"os"
	"os/exec"
	"regexp"
	"time"

	"log/slog"
)

// App integra logger, configuración, tuning y helpers de ejecución.
// Todas las secciones (sections.go) son métodos sobre App.
type App struct {
	log      *slog.Logger
	cfg      *SetupConfig
	tuning   *Tuning
	serverIP string
}

// newApp construye App con logger JSON stdout (estándar del SKILL.md golang).
func newApp(cfg *SetupConfig, t *Tuning, serverIP string) *App {
	return &App{
		log:      slog.New(slog.NewJSONHandler(os.Stdout, nil)),
		cfg:      cfg,
		tuning:   t,
		serverIP: serverIP,
	}
}

// runStrict ejecuta un comando y aborta (os.Exit 1) si falla.
// Equivalente a `set -e` del script bash: cualquier error detiene el instalador.
// Output hereda stdout/stderr del proceso padre para ver progreso en vivo.
func (a *App) runStrict(name string, args ...string) {
	cmd := exec.Command(name, args...)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	if err := cmd.Run(); err != nil {
		a.log.Error("comando falló (fatal)", "cmd", name, "args", args, "error", err)
		os.Exit(1)
	}
}

// runIgnore ejecuta un comando y solo logea warning si falla. No aborta.
// Equivalente al patrón `cmd || true` del script (líneas 130-148, 157-159 p.ej).
func (a *App) runIgnore(name string, args ...string) {
	cmd := exec.Command(name, args...)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	if err := cmd.Run(); err != nil {
		a.log.Warn("comando falló (ignorado)", "cmd", name, "args", args, "error", err)
	}
}

// asLaravelIn ejecuta un comando como usuario laravel dentro de `dir`.
// Replica exacta del helper as_laravel() de setup.sh:114-116:
//
//	sudo -u laravel env HOME=$LARAVEL_HOME COMPOSER_HOME=$LARAVEL_HOME/.composer \
//	    bash -lc "cd 'dir' && cmdline"
//
// HOME apunta al hogar real (no al proyecto) para que la caché de Composer
// viva en ~/.composer y no dentro del proyecto (regla AGENTS.md).
func (a *App) asLaravelIn(dir, cmdline string) error {
	full := "cd '" + dir + "' && " + cmdline
	cmd := exec.Command("sudo", "-u", a.cfg.LaravelUser,
		"env",
		"HOME="+a.cfg.LaravelHome,
		"COMPOSER_HOME="+a.cfg.LaravelHome+"/.composer",
		"bash", "-lc", full,
	)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	return cmd.Run()
}

// asLaravel llama a asLaravelIn usando el directorio del proyecto por defecto.
func (a *App) asLaravel(cmdline string) error {
	return a.asLaravelIn(a.cfg.ProyectoDir, cmdline)
}

// asLaravelStrict igual que asLaravel pero aborta si falla.
func (a *App) asLaravelStrict(cmdline string) {
	if err := a.asLaravel(cmdline); err != nil {
		a.log.Error("as_laravel falló (fatal)", "cmd", cmdline, "error", err)
		os.Exit(1)
	}
}

// syncClockHTTP sincroniza el reloj via HTTP HEAD Date header.
// Replica de setup.sh:130-134 y 195-199 (preflight VBox/PGDG).
// Razón histórica: PGDG firma repomd.xml con timestamp "not before" ligeramente
// futuro; en VMs VirtualBox el reloj va atrasado y GPG rechaza con
// "signature is not alive yet". NTP UDP 123 no pasa VBox NAT, pero TCP 443 sí.
// Formato RFC 7231 que `date -s` acepta ("Wed, 29 Jul 2026 12:34:56 GMT").
func (a *App) syncClockHTTP() {
	client := &http.Client{Timeout: 5 * time.Second}
	resp, err := client.Head("https://www.cloudflare.com/")
	if err != nil {
		a.log.Warn("syncClockHTTP: HEAD falló", "error", err)
		return
	}
	defer resp.Body.Close()
	dateStr := resp.Header.Get("Date")
	if dateStr == "" {
		a.log.Warn("syncClockHTTP: header Date vacío")
		return
	}
	a.runIgnore("sudo", "date", "-s", dateStr)
}

// fileExists devuelve true si path existe (cualquier tipo).
func fileExists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}

// replaceInFile aplica regex sobre el contenido de un archivo y lo reescribe.
// Equivalente a `sed -i -E 'pattern/repl/g' file`.
// Usado para pg_hba.conf y .repo PGDG (líneas 140, 206, 220-221 del script).
func replaceInFile(path string, re *regexp.Regexp, repl string) error {
	b, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	out := re.ReplaceAll(b, []byte(repl))
	return os.WriteFile(path, out, 0644)
}

// writeRootFile escribe un archivo con permisos indicados.
// El binario corre como root en el server, os.WriteFile directo (sin sudo).
func writeRootFile(path, content string, perm os.FileMode) error {
	return os.WriteFile(path, []byte(content), perm)
}

// appendFile añade content al final de path (crea si no existe).
// Equivalente a `cat << EOF >> path` de setup.sh (líneas 162-170, 304-313).
func appendFile(path, content string) error {
	f, err := os.OpenFile(path, os.O_APPEND|os.O_WRONLY|os.O_CREATE, 0644)
	if err != nil {
		return err
	}
	defer f.Close()
	_, err = f.WriteString(content)
	return err
}

// cmdOutput ejecuta comando y devuelve stdout (sin streaming).
// Útil para `hostname -I` (detección IP) y nc de un solo valor.
func cmdOutput(name string, args ...string) (string, error) {
	out, err := exec.Command(name, args...).Output()
	return string(out), err
}

// runCmdPassthrough ejecuta el comando args[0] con args[1:] conectando
// stdin/stdout/stderr del proceso actual (passthrough puro — preserva
// interactividad y colores). Devuelve exit code numérico.
// Útil para ejecutar scripts bash embebidos con herencia de terminal.
func runCmdPassthrough(argv []string) int {
	if len(argv) == 0 {
		return 1
	}
	cmd := exec.Command(argv[0], argv[1:]...)
	cmd.Stdin = os.Stdin
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	if err := cmd.Run(); err != nil {
		if exitErr, ok := err.(*exec.ExitError); ok {
			return exitErr.ExitCode()
		}
		fmt.Fprintln(os.Stderr, "Error ejecutando:", argv, "→", err)
		return 1
	}
	return 0
}
