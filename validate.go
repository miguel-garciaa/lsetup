package main

import (
	"fmt"
	"os"
	"regexp"
	"strings"
)

// SetupConfig reemplaza al viejo Config (solo la sección [setup]).
// Los demás subcomandos leen su sección del ConfigFile dinámicamente.
type SetupConfig struct {
	Project    string
	DBName     string
	DBUser     string
	DBPass     string
	DBPassFile string

	ProyectosDir string
	ProyectoDir  string
	LaravelUser  string
	LaravelHome  string
}

// identPG valida identificadores PostgreSQL: [A-Za-z_][A-Za-z0-9_]*
// Anti-inyección SQL/psql. Equivalente a `[[ $v =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]` en setup.sh:45.
var identPG = regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_]*$`)

func validIdent(s string) bool { return identPG.MatchString(s) }

// escapeSQLSingleQuote duplica comillas simples: ' -> ”
// Equivalente a setup.sh:226.
func escapeSQLSingleQuote(s string) string {
	return strings.ReplaceAll(s, "'", "''")
}

// readPassFile lee password de archivo externo. Valida existencia, permisos 600/400,
// no vacío. Equivalente al flag --db-pass-file del plan original.
func readPassFile(path string) (string, error) {
	info, err := os.Stat(path)
	if err != nil {
		return "", fmt.Errorf("--db-pass-file inaccesible (%q): %w", path, err)
	}
	if info.Mode().Perm()&0077 != 0 {
		return "", fmt.Errorf("--db-pass-file %q permisos inseguros (group/other con acceso; use chmod 600)", path)
	}
	b, err := os.ReadFile(path)
	if err != nil {
		return "", fmt.Errorf("lectura --db-pass-file falló: %w", err)
	}
	pass := strings.TrimSpace(string(b))
	if pass == "" {
		return "", fmt.Errorf("--db-pass-file %q vacío", path)
	}
	return pass, nil
}

// loadSetupConfig toma la sección [setup] del ConfigFile y devuelve *SetupConfig
// con todos los campos validados + derivados (ProyectoDir, LaravelUser...).
// Equivalente a validateConfig del diseño previo.
func loadSetupConfig(cf *ConfigFile) (*SetupConfig, error) {
	sec := cf.Section("setup")

	cfg := &SetupConfig{
		Project:    sec["project"],
		DBName:     sec["db_name"],
		DBUser:     sec["db_user"],
		DBPass:     sec["db_pass"],
		DBPassFile: sec["db_pass_file"],
	}

	if cfg.Project == "" {
		cfg.Project = "laravel1"
	}
	if cfg.DBName == "" {
		return nil, fmt.Errorf("[setup] db_name vacío")
	}
	if cfg.DBUser == "" {
		return nil, fmt.Errorf("[setup] db_user vacío")
	}
	if !validIdent(cfg.DBName) {
		return nil, fmt.Errorf("[setup] db_name=%q inválido (solo [A-Za-z_][A-Za-z0-9_]*)", cfg.DBName)
	}
	if !validIdent(cfg.DBUser) {
		return nil, fmt.Errorf("[setup] db_user=%q inválido (solo [A-Za-z_][A-Za-z0-9_]*)", cfg.DBUser)
	}

	switch {
	case cfg.DBPassFile != "":
		p, err := readPassFile(cfg.DBPassFile)
		if err != nil {
			return nil, err
		}
		cfg.DBPass = p
	case cfg.DBPass != "":
		// ok
	default:
		return nil, fmt.Errorf("[setup] falta password: indique db_pass o db_pass_file")
	}

	cfg.ProyectosDir = "/var/www"
	cfg.ProyectoDir = "/var/www/" + cfg.Project
	cfg.LaravelUser = "laravel"
	cfg.LaravelHome = "/var/lib/laravel"
	return cfg, nil
}
