package main

import (
	"fmt"
	"os"
	"regexp"
	"strings"
)

// Config agrupa todos los parámetros leídos de lsetup.conf.
// Se rellena en parseConfig y valida en validateConfig antes de runSetup.
type Config struct {
	Project    string // /var/www/<project>
	DBName     string // identificador PostgreSQL
	DBUser     string // identificador PostgreSQL
	DBPass     string // contraseña (texto plano)
	DBPassFile string // ruta a archivo externo (opcional, gana sobre DBPass)

	// Derivados (no van en el config file)
	ProyectosDir string // /var/www
	ProyectoDir  string // /var/www/<project>
	LaravelUser  string // "laravel"
	LaravelHome  string // /var/lib/laravel
}

// identPG valida identificadores PostgreSQL: [A-Za-z_][A-Za-z0-9_]*
// Anti-inyección SQL/psql. Equivalente a `[[ $v =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]` en setup.sh:45.
var identPG = regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_]*$`)

// validIdent devuelve true si s cumple la regex de identificador PG.
func validIdent(s string) bool {
	return identPG.MatchString(s)
}

// escapeSQLSingleQuote duplica comillas simples: ' -> ”
// Necesario al interpolar DB_PASS en SQL de CREATE USER. Equivalente a setup.sh:226.
func escapeSQLSingleQuote(s string) string {
	return strings.ReplaceAll(s, "'", "''")
}

// readPassFile lee contraseña de archivo externo. Valida:
//   - archivo existe
//   - permisos grupo/other sin acceso (chmod 600/400)
//   - contenido no vacío
func readPassFile(path string) (string, error) {
	info, err := os.Stat(path)
	if err != nil {
		return "", fmt.Errorf("--db-pass-file inaccesible (%q): %w", path, err)
	}
	// Perm 077 mask: si group u other tienen R/W/X, rechazar.
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

// validateConfig aplica todas las validaciones del bloque setup.sh:43-49 más
// las reglas de password embebido/archivo. Devuelve error si algo falla.
func validateConfig(cfg *Config) error {
	if cfg.Project == "" {
		cfg.Project = "laravel1"
	}
	if cfg.DBName == "" {
		return fmt.Errorf("db_name vacío en config")
	}
	if cfg.DBUser == "" {
		return fmt.Errorf("db_user vacío en config")
	}
	if !validIdent(cfg.DBName) {
		return fmt.Errorf("db_name=%q inválido (solo [A-Za-z_][A-Za-z0-9_]*)", cfg.DBName)
	}
	if !validIdent(cfg.DBUser) {
		return fmt.Errorf("db_user=%q inválido (solo [A-Za-z_][A-Za-z0-9_]*)", cfg.DBUser)
	}

	// Password: db_pass_file gana sobre db_pass si ambos presentes.
	switch {
	case cfg.DBPassFile != "":
		p, err := readPassFile(cfg.DBPassFile)
		if err != nil {
			return err
		}
		cfg.DBPass = p
	case cfg.DBPass != "":
		//.getPasswordDB embebido ok (texto plano). No extra sanitization.
	default:
		return fmt.Errorf("falta password: indique db_pass o db_pass_file en config")
	}

	// Rellenar derivados.
	cfg.ProyectosDir = "/var/www"
	cfg.ProyectoDir = "/var/www/" + cfg.Project
	cfg.LaravelUser = "laravel"
	cfg.LaravelHome = "/var/lib/laravel"
	return nil
}
