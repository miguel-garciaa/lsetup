package main

import (
	"bytes"
	_ "embed"
	"flag"
	"fmt"
	"os"
	"os/exec"
)

// statusSh es el script bash embebido en compilación.
// go:embed incrusta status.sh (repo root) como []byte en el binario.
// Así el binario Go se despliega standalone, sin llevar status.sh aparte.
//
//go:embed status.sh
var statusSh []byte

// cmdStatus implementa: ./lsetup status [--install]
//   - Sin flags: ejecuta el script embebido vía bash (panel completo en vivo).
//   - --install: escribe el script a /usr/local/bin/status (chmod 0755) para
//     activar el alias `sudo status` sin esperar a que migre secure.sh.
//   - -h/--help: muestra ayuda del subcomando.
//
// El script delega en /usr/local/bin/sec-logs si existe (instalado por secure.sh)
// y siempre añade la sección SERVICIOS LSETUP al final.
func cmdStatus(args []string) {
	fs := flag.NewFlagSet("status", flag.ExitOnError)
	install := fs.Bool("install", false, "Despliega el script a /usr/local/bin/status (activa alias 'sudo status')")
	help := fs.Bool("h", false, "Muestra ayuda")
	fs.BoolVar(help, "help", false, "Muestra ayuda")
	fs.Parse(args)

	if *help {
		fmt.Println("Uso: lsetup status [--install]")
		fmt.Println("  Sin flags: ejecuta el panel de auditoría embebido (sec-logs + SERVICIOS LSETUP).")
		fmt.Println("  --install: despliega el script a /usr/local/bin/status (chmod 0755).")
		fmt.Println("             Activa alias 'sudo status' sin esperar a migrar secure.sh.")
		fmt.Println("             Requiere /usr/local/bin en sudoers secure_path (secure.sh lo añade).")
		return
	}

	if *install {
		if err := os.WriteFile("/usr/local/bin/status", statusSh, 0755); err != nil {
			fmt.Fprintln(os.Stderr, "Error desplegando /usr/local/bin/status:", err)
			os.Exit(1)
		}
		fmt.Println("/usr/local/bin/status desplegado (chmod 0755).")
		fmt.Println("Alias activado: sudo status  (equivalente a  sudo lsetup status)")
		fmt.Println("Nota: si 'sudo status' no se encuentra, usa ruta absoluta: sudo /usr/local/bin/status")
		return
	}

	// Ejecutar script embebido vía `bash -s` (lee de stdin). Sin tmpfiles.
	cmd := exec.Command("bash", "-s")
	cmd.Stdin = bytes.NewReader(statusSh)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	_ = cmd.Run()
}
