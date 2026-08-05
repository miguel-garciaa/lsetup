package main

import (
	"bufio"
	"flag"
	"fmt"
	"log/slog"
	"os"
	"strings"
)

// main es el dispatcher de subcomandos.
// Comportamiento:
//   - Sin args  → ejecuta setup (genera ./lsetup.conf o lo lee si existe).
//   - Flag directo (--config=...) → ejecuta setup con ese flag.
//   - "setup" explícito → igual que sin args (向后 compat).
//   - "-h"/"--help"/"help" → muestra ayuda.
//
// setup es el subcomando por defecto para reducir fricción CLI.
// Futuro: añadir "panel"/"secure" al switch cuando se migren esos scripts.
func main() {
	args := os.Args[1:]
	if len(args) == 0 {
		cmdSetup(args)
		return
	}
	if strings.HasPrefix(args[0], "-") {
		cmdSetup(args)
		return
	}
	switch args[0] {
	case "setup":
		cmdSetup(args[1:])
	case "-h", "--help", "help":
		printHelp()
	default:
		fmt.Fprintf(os.Stderr, "Subcomando desconocido: %s\n", args[0])
		printHelp()
		os.Exit(2)
	}
}

// printHelp muestra ayuda con ejemplos concretos de uso.
func printHelp() {
	fmt.Println("lsetup — Instalador Laravel 13 + PHP 8.4 + PostgreSQL 18 + Redis 8 + Octane/FrankenPHP + Nginx")
	fmt.Println()
	fmt.Println("USO:")
	fmt.Println("  ./lsetup                              1ª vez: genera ./lsetup.conf y sale")
	fmt.Println("  ./lsetup --config=lsetup.conf         Lee config y ejecuta setup")
	fmt.Println("  ./lsetup setup                        Igual que ./lsetup (subcomando explícito)")
	fmt.Println("  ./lsetup setup --config=/ruta/xx      Igual que arriba con config explícito")
	fmt.Println("  ./lsetup --help                       Muestra esta ayuda")
	fmt.Println()
	fmt.Println("CONFIG FILE (./lsetup.conf):")
	fmt.Println("  project=laravel1            # dir /var/www/<project>")
	fmt.Println("  db_name=midb                # solo [A-Za-z_][A-Za-z0-9_]*")
	fmt.Println("  db_user=miusuario           # misma regex")
	fmt.Println("  db_pass=secreto             # texto plano")
	fmt.Println("  # O bien:")
	fmt.Println("  db_pass_file=/ruta/archivo  # externo, chmod 600 (gana sobre db_pass)")
	fmt.Println()
	fmt.Println("FLUJO:")
	fmt.Println("  1. ./lsetup                 → genera ./lsetup.conf")
	fmt.Println("  2. nano ./lsetup.conf       → rellena db_name, db_user, db_pass")
	fmt.Println("  3. ./lsetup                 → lee config y ejecuta")
}

// cmdSetup implementa: ./lsetup setup [--config=./lsetup.conf]
//   - Si config no existe → crea template + exit 0.
//   - Si config existe → parsea, valida, detecta hardware/IP, ejecuta setup.
func cmdSetup(args []string) {
	fs := flag.NewFlagSet("setup", flag.ExitOnError)
	cfgPath := fs.String("config", "./lsetup.conf", "Ruta config file")
	fs.Parse(args)

	if !fileExists(*cfgPath) {
		if err := writeRootFile(*cfgPath, tplLsetupConf, 0600); err != nil {
			fmt.Fprintln(os.Stderr, "Error creando config:", err)
			os.Exit(1)
		}
		fmt.Printf("Config generado: %s\n", *cfgPath)
		fmt.Printf("Rellena y vuelve a ejecutar:\n  lsetup setup --config=%s\n", *cfgPath)
		os.Exit(0)
	}

	cfg, err := parseConfig(*cfgPath)
	if err != nil {
		fmt.Fprintln(os.Stderr, "Error parse config:", err)
		os.Exit(1)
	}
	if err := validateConfig(cfg); err != nil {
		fmt.Fprintln(os.Stderr, "Error validación config:", err)
		os.Exit(1)
	}

	// Logger slog JSON stdout (estándar del SKILL.md golang).
	log := slog.New(slog.NewJSONHandler(os.Stdout, nil))

	// Detección de hardware (nproc + /proc/meminfo).
	t, err := detectHardware()
	if err != nil {
		log.Error("detección hardware falló", "error", err)
		os.Exit(1)
	}

	// Detección IP (hostname -I o fallback 127.0.0.1).
	ip, err := detectServerIP()
	if err != nil {
		log.Warn("detección IP falló (usando 127.0.0.1)", "error", err)
		ip = "127.0.0.1"
	}

	// Banner inicial (réplica de setup.sh:62-66 + 103-108).
	fmt.Println("==========================================================================")
	fmt.Printf(" IPv4: %s\n", ip)
	fmt.Printf(" Proyecto:     %s\n", cfg.ProyectoDir)
	fmt.Println("==========================================================================")
	fmt.Println("==========================================================================")
	fmt.Printf(" Hardware: %d núcleos / %d MB RAM\n", t.CPU, t.RAM)
	fmt.Printf(" Octane:   workers=%d (FrankenPHP)\n", t.OctaneWorkers)
	fmt.Printf(" PG18:     shared_buffers=%dMB cache=%dMB work_mem=%dMB\n",
		t.PGSharedBuffers, t.PGEffectiveCacheSize, t.PGWorkMem)
	fmt.Printf(" Redis:    maxmemory=%dmb io-threads=%d\n", t.RedisMaxMemory, t.RedisIOThreads)
	fmt.Println("==========================================================================")

	app := newApp(cfg, t, ip)
	app.runSetup()
}

// parseConfig lee archivo key=value, ignora líneas vacías y comentarios (#).
// Equivalente a leer el heredoc del script. Solo 5 claves soportadas.
func parseConfig(path string) (*Config, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()

	cfg := &Config{}
	scan := bufio.NewScanner(f)
	for scan.Scan() {
		line := strings.TrimSpace(scan.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		idx := strings.IndexByte(line, '=')
		if idx == -1 {
			continue
		}
		key := strings.TrimSpace(line[:idx])
		val := strings.TrimSpace(line[idx+1:])
		switch key {
		case "project":
			cfg.Project = val
		case "db_name":
			cfg.DBName = val
		case "db_user":
			cfg.DBUser = val
		case "db_pass":
			cfg.DBPass = val
		case "db_pass_file":
			cfg.DBPassFile = val
		}
	}
	if err := scan.Err(); err != nil {
		return nil, err
	}
	return cfg, nil
}

// detectServerIP replica `hostname -I | awk '{print $1}'` con fallback 127.0.0.1.
// Equivalente a setup.sh:56-59.
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
