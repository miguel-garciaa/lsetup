package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
)

// Regex precompiladas para sed-i equivalentes (reemplazos in-file).
var (
	reRepoGPG = regexp.MustCompile(`(?m)^\s*repo_gpgcheck\s*=\s*1`)
	rePgHbaV4 = regexp.MustCompile(`(?m)^host\s+all\s+all\s+127\.0\.0\.1/32.*`)
	rePgHbaV6 = regexp.MustCompile(`(?m)^host\s+all\s+all\s+::1/128.*`)
)

// header imprime el banner de sección (equivalente a `echo "=== N. ... ==="`).
func (a *App) header(msg string) {
	fmt.Printf("\n=== %s ===\n", msg)
}

// ============================================================
// Sección 1: Preparación del sistema y repos
// Equivalente a setup.sh:145-170.
// ============================================================
func (a *App) s1_repos() {
	a.header("1. PREPARACIÓN DEL SISTEMA Y REPOS")

	// Preflight reloj (defensa VBox/PGDG).
	a.syncClockHTTP()

	a.runStrict("sudo", "dnf", "install", "-y", "epel-release", "dnf-plugins-core")
	a.runIgnore("sudo", "dnf", "config-manager", "--set-enabled", "crb")
	a.runIgnore("sudo", "dnf", "install", "-y", "--nogpgcheck",
		"https://rpms.remirepo.net/enterprise/remi-release-10.rpm")
	// Pipe bash clásico (curl | sudo bash -): stdlib sin io.Pipe.
	a.runStrict("bash", "-c",
		"curl -fsSL https://rpm.nodesource.com/setup_22.x | sudo bash -")
	a.runStrict("sudo", "dnf", "install", "-y", "nodejs", "npm")
	a.runStrict("sudo", "dnf", "install", "-y", "git")

	// chrony: sincronización horaria robusta (certificados PGDG en el futuro).
	a.runIgnore("sudo", "dnf", "install", "-y", "chrony")
	a.runIgnore("sudo", "systemctl", "enable", "--now", "chronyd")
	a.runIgnore("sudo", "chronyc", "-a", "makestep")

	// Límites del sistema (append idempotente del bloque).
	if err := appendFile("/etc/security/limits.conf", tplLimitsAppend); err != nil {
		a.log.Warn("limits.conf append falló", "error", err)
	}
	if err := appendFile("/etc/sysctl.conf", tplSysctlAppend); err != nil {
		a.log.Warn("sysctl.conf append falló", "error", err)
	}
	a.runIgnore("sudo", "sysctl", "-p")
}

// ============================================================
// Sección 2: Firewall
// Equivalente a setup.sh:172-179.
// ============================================================
func (a *App) s2_firewall() {
	a.header("2. FIREWALL")
	a.runStrict("sudo", "dnf", "install", "-y", "firewalld")
	a.runStrict("sudo", "systemctl", "enable", "--now", "firewalld")
	a.runStrict("sudo", "firewall-cmd", "--permanent", "--add-service", "http")
	a.runStrict("sudo", "firewall-cmd", "--permanent", "--add-service", "ssh")
	a.runStrict("sudo", "firewall-cmd", "--reload")
}

// ============================================================
// Sección 3: PostgreSQL 18
// Equivalente a setup.sh:181-248.
// ============================================================
func (a *App) s3_postgres() {
	a.header("3. POSTGRESQL 18")

	// Re-sincronizar reloj justo antes de tocar PGDG (defensa VBox).
	a.syncClockURLHTTP()

	a.runIgnore("sudo", "dnf", "install", "-y", "--nogpgcheck",
		"https://download.postgresql.org/pub/repos/yum/reporpms/EL-10-x86_64/pgdg-redhat-repo-latest.noarch.rpm")

	// Desactivar repo_gpgcheck=1 en todos los .repo de PGDG (belt-and-suspenders).
	if files, err := filepath.Glob("/etc/yum.repos.d/pgdg*.repo"); err == nil {
		for _, f := range files {
			if err := replaceInFile(f, reRepoGPG, "repo_gpgcheck=0"); err != nil {
				a.log.Warn("repo_gpgcheck rewrite falló", "file", f, "error", err)
			}
		}
	}

	a.runStrict("sudo", "dnf", "clean", "all")
	a.runIgnore("sudo", "dnf", "-qy", "module", "disable", "postgresql")
	a.runStrict("sudo", "dnf", "install", "-y",
		"--setopt=pgdg-*.repo_gpgcheck=0", "--nogpgcheck", "postgresql18-server")

	// initdb idempotente (PG_VERSION marca si ya inicializado).
	if !fileExists("/var/lib/pgsql/18/data/PG_VERSION") {
		a.runStrict("sudo", "/usr/pgsql-18/bin/postgresql-18-setup", "initdb")
	}

	// Autenticación scram-sha-256 para conexiones locales TCP.
	pgHBA := "/var/lib/pgsql/18/data/pg_hba.conf"
	if err := replaceInFile(pgHBA, rePgHbaV4,
		"host    all    all    127.0.0.1/32    scram-sha-256"); err != nil {
		a.log.Warn("pg_hba rewrite IPv4 falló", "error", err)
	}
	if err := replaceInFile(pgHBA, rePgHbaV6,
		"host    all    all    ::1/128         scram-sha-256"); err != nil {
		a.log.Warn("pg_hba rewrite IPv6 falló", "error", err)
	}

	a.runStrict("sudo", "systemctl", "enable", "--now", "postgresql-18")

	// CREATE USER / DATABASE / GRANT — anti-inyección vía validIdent + escapeSingleQuote.
	dbPassSQL := escapeSQLSingleQuote(a.cfg.DBPass)
	a.runIgnore("sudo", "-u", "postgres", "psql", "-c",
		fmt.Sprintf("CREATE USER %s WITH PASSWORD '%s';", a.cfg.DBUser, dbPassSQL))
	a.runIgnore("sudo", "-u", "postgres", "psql", "-c",
		fmt.Sprintf("CREATE DATABASE %s OWNER %s;", a.cfg.DBName, a.cfg.DBUser))
	a.runIgnore("sudo", "-u", "postgres", "psql", "-c",
		fmt.Sprintf("GRANT ALL PRIVILEGES ON DATABASE %s TO %s;", a.cfg.DBName, a.cfg.DBUser))

	// ALTER SYSTEM tuning con psql heredoc (stdin).
	t := a.tuning
	alterSQL := fmt.Sprintf(`ALTER SYSTEM SET shared_buffers = '%dMB';
ALTER SYSTEM SET effective_cache_size = '%dMB';
ALTER SYSTEM SET work_mem = '%dMB';
ALTER SYSTEM SET maintenance_work_mem = '%dMB';
ALTER SYSTEM SET wal_buffers = '%dMB';
ALTER SYSTEM SET max_connections = %d;
ALTER SYSTEM SET max_worker_processes = %d;
ALTER SYSTEM SET max_parallel_workers = %d;
ALTER SYSTEM SET max_parallel_workers_per_gather = %d;
ALTER SYSTEM SET checkpoint_completion_target = %.1f;
ALTER SYSTEM SET random_page_cost = %.1f;
ALTER SYSTEM SET effective_io_concurrency = %d;
`,
		t.PGSharedBuffers, t.PGEffectiveCacheSize, t.PGWorkMem,
		t.PGMaintenanceWorkMem, t.PGWalBuffers, t.PGMaxConnections,
		t.PGMaxWorkerProcesses, t.PGMaxParallelWorkers, t.PGParallelPerGather,
		t.PGCheckpointTarget, t.PGRandomPageCost, t.PGEffectiveIOConcurrency)

	cmd := exec.Command("sudo", "-u", "postgres", "psql", "-v", "ON_ERROR_STOP=1")
	cmd.Stdin = strings.NewReader(alterSQL)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	if err := cmd.Run(); err != nil {
		a.log.Error("ALTER SYSTEM tuning falló (fatal)", "error", err)
		os.Exit(1)
	}

	a.runStrict("sudo", "systemctl", "restart", "postgresql-18")
}

// syncClockURLHTTP es alias de syncClockHTTP (sección 3 llama de nuevo).
func (a *App) syncClockURLHTTP() { a.syncClockHTTP() }

// ============================================================
// Sección 4: Usuario Laravel (no-root)
// Equivalente a setup.sh:250-277.
// ============================================================
func (a *App) s4_user_laravel() {
	a.header("4. USUARIO LARAVEL (no-root)")

	lu := a.cfg.LaravelUser
	lh := a.cfg.LaravelHome

	a.runIgnore("sudo", "useradd", "-m", "-s", "/bin/bash", "-d", lh, lu)
	a.runStrict("sudo", "mkdir", "-p", lh)
	a.runStrict("sudo", "chown", "-R", lu+":"+lu, lh)

	// Password puente "laravel:laravel" vía chpasswd (stdin pipe).
	cmd := exec.Command("sudo", "chpasswd")
	cmd.Stdin = strings.NewReader("laravel:laravel")
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	if err := cmd.Run(); err != nil {
		a.log.Error("chpasswd laravel falló (fatal)", "error", err)
		os.Exit(1)
	}

	// .ssh listo para subir clave pública (ver ssh.txt).
	sshDir := lh + "/.ssh"
	authKeys := sshDir + "/authorized_keys"
	a.runStrict("sudo", "-u", lu, "mkdir", "-p", sshDir)
	a.runStrict("sudo", "-u", lu, "touch", authKeys)
	a.runStrict("sudo", "chmod", "700", sshDir)
	a.runStrict("sudo", "chmod", "600", authKeys)
	a.runStrict("sudo", "chown", "-R", lu+":"+lu, sshDir)

	// Grupo wheel = sudoers en RHEL/AlmaLinux.
	a.runStrict("sudo", "usermod", "-aG", "wheel", lu)

	// Git config como laravel (HOME real → /var/lib/laravel/.gitconfig).
	// Hardcode miguel / miguel2006ngl@gmail.com (confirmado por usuario).
	gitEnv := func(args ...string) {
		full := append([]string{"-u", lu, "env", "HOME=" + lh, "git", "config", "--global"}, args...)
		cmd := exec.Command("sudo", full...)
		cmd.Stdout = os.Stdout
		cmd.Stderr = os.Stderr
		if err := cmd.Run(); err != nil {
			a.log.Error("git config falló (fatal)", "error", err)
			os.Exit(1)
		}
	}
	gitEnv("user.name", "miguel")
	gitEnv("user.email", "miguel2006ngl@gmail.com")
	gitEnv("init.defaultBranch", "main")

	a.runStrict("sudo", "mkdir", "-p", "/var/www")
	a.runStrict("sudo", "chown", lu+":"+lu, "/var/www")
}

// ============================================================
// Sección 5: PHP 8.4 + Composer
// Equivalente a setup.sh:279-294.
// ============================================================
func (a *App) s5_php_composer() {
	a.header("5. PHP 8.4 + COMPOSER")

	a.runIgnore("sudo", "dnf", "module", "reset", "php", "-y")
	a.runIgnore("sudo", "dnf", "module", "enable", "php:remi-8.4", "-y")

	phpPkgs := []string{
		"php", "php-cli", "php-fpm", "php-pgsql", "php-zip", "php-xml",
		"php-curl", "php-intl", "php-bcmath", "php-mbstring", "php-posix",
		"php-pcntl", "php-gd", "php-opcache", "php-pecl-redis",
	}
	args := append([]string{"dnf", "install", "-y"}, phpPkgs...)
	a.runStrict("sudo", args...)

	// Composer global si no existe.
	if !fileExists("/usr/local/bin/composer") {
		a.runStrict("bash", "-c",
			"curl -sS https://getcomposer.org/installer | sudo php -- --install-dir=/usr/local/bin --filename=composer")
		a.runStrict("sudo", "chmod", "+x", "/usr/local/bin/composer")
	}
	a.runIgnore("sudo", "ln", "-sf", "/usr/local/bin/composer", "/usr/bin/composer")
}

// ============================================================
// Sección 6: Redis
// Equivalente a setup.sh:296-315.
// ============================================================
func (a *App) s6_redis() {
	a.header("6. REDIS (phpredis)")

	a.runIgnore("sudo", "dnf", "module", "reset", "redis", "-y")
	a.runIgnore("sudo", "dnf", "module", "enable", "redis:remi-8.0", "-y")
	a.runStrict("sudo", "dnf", "install", "-y", "redis")
	a.runStrict("sudo", "systemctl", "enable", "--now", "redis")

	// Tuning idempotente: solo añadir si no existe `maxmemory` ya configurado.
	conf := "/etc/redis/redis.conf"
	needAppend := true
	if b, err := os.ReadFile(conf); err == nil && strings.Contains(string(b), "\nmaxmemory ") {
		needAppend = false
	}
	if needAppend {
		tuning := fmt.Sprintf(tplRedisAppend, a.tuning.RedisMaxMemory, a.tuning.RedisIOThreads)
		if err := appendFile(conf, tuning); err != nil {
			a.log.Error("redis.conf tuning append falló (fatal)", "error", err)
			os.Exit(1)
		}
	}
	a.runStrict("sudo", "systemctl", "restart", "redis")
}

// ============================================================
// Sección 7: Creación del proyecto Laravel 13
// Equivalente a setup.sh:317-330.
// ============================================================
func (a *App) s7_laravel_project() {
	a.header("7. CREACIÓN DEL PROYECTO LARAVEL 13")

	pDir := a.cfg.ProyectoDir
	vendorDir := pDir + "/vendor"

	// Limpiar restos incompletos (sin vendor) — evita "mkdir Permission denied".
	if fileExists(pDir) && !fileExists(vendorDir) {
		a.runStrict("sudo", "rm", "-rf", pDir)
	}
	a.runStrict("sudo", "chown", a.cfg.LaravelUser+":"+a.cfg.LaravelUser, "/var/www")

	// composer create-project idempotente.
	if !fileExists(vendorDir) {
		cmdline := fmt.Sprintf("composer create-project laravel/laravel %s --prefer-dist --no-interaction",
			a.cfg.Project)
		if err := a.asLaravelIn("/var/www", cmdline); err != nil {
			a.log.Error("create-project falló (fatal)", "error", err)
			os.Exit(1)
		}
	}
	a.runStrict("sudo", "chown", "-R", a.cfg.LaravelUser+":"+a.cfg.LaravelUser, pDir)
}

// ============================================================
// Sección 8: Generación del .env
// Equivalente a setup.sh:332-413.
// ============================================================
func (a *App) s8_env_file() {
	a.header("8. GENERACIÓN DE .env (con IP expandida)")

	// tplEnv: %s en orden = SERVER_IP, DB_NAME, DB_USER, DB_PASS.
	// ${APP_NAME} queda literal (Laravel).
	content := fmt.Sprintf(tplEnv, a.serverIP, a.cfg.DBName, a.cfg.DBUser, a.cfg.DBPass)

	envPath := a.cfg.ProyectoDir + "/.env"
	if err := writeRootFile(envPath, content, 0644); err != nil {
		a.log.Error("escritura .env falló (fatal)", "path", envPath, "error", err)
		os.Exit(1)
	}
	a.runStrict("sudo", "chown", a.cfg.LaravelUser+":"+a.cfg.LaravelUser, envPath)

	a.asLaravelStrict("php artisan key:generate --force")
	a.asLaravelStrict("php artisan migrate --force")
}

// ============================================================
// Sección 9: Octane + FrankenPHP + systemd
// Equivalente a setup.sh:415-440.
// ============================================================
func (a *App) s9_octane_systemd() {
	a.header("9. OCTANE + FRANKENPHP + SERVICIO SYSTEMD")

	a.asLaravelStrict("composer require laravel/octane --no-interaction")
	a.asLaravelStrict("php artisan octane:install --server=frankenphp --no-interaction")

	// tplOctaneService: %s,%s,%s,%d = User, Group, WorkingDir, Workers.
	content := fmt.Sprintf(tplOctaneService,
		a.cfg.LaravelUser, a.cfg.LaravelUser,
		a.cfg.ProyectoDir, a.tuning.OctaneWorkers)

	svc := "/etc/systemd/system/octane.service"
	if err := writeRootFile(svc, content, 0644); err != nil {
		a.log.Error("octane.service write falló (fatal)", "error", err)
		os.Exit(1)
	}
	a.runStrict("sudo", "chown", "root:root", svc)
	a.runStrict("sudo", "systemctl", "daemon-reload")
	a.runStrict("sudo", "systemctl", "enable", "octane")
}

// ============================================================
// Sección 10: Nginx + SELinux + permisos
// Equivalente a setup.sh:442-534.
// ============================================================
func (a *App) s10_nginx_selinux() {
	a.header("10. NGINX + SELINUX + PERMISOS")

	a.runStrict("sudo", "dnf", "install", "-y",
		"nginx", "httpd-tools", "policycoreutils-python-utils")

	pDir := a.cfg.ProyectoDir
	a.runStrict("sudo", "chown", "-R", a.cfg.LaravelUser+":"+a.cfg.LaravelUser, pDir)
	a.runStrict("sudo", "chmod", "-R", "775",
		pDir+"/storage", pDir+"/bootstrap/cache")

	// SELinux booleans.
	a.runIgnore("sudo", "setsebool", "-P", "httpd_can_network_connect", "1")
	a.runIgnore("sudo", "setsebool", "-P", "httpd_can_network_connect_db", "1")
	a.runIgnore("sudo", "setsebool", "-P", "httpd_can_network_connect_redis", "1")
	a.runIgnore("sudo", "setsebool", "-P", "httpd_unified", "1")

	// Permitir a Octane (vía nginx/fpm) escribir en storage y bootstrap/cache.
	a.runIgnore("sudo", "semanage", "fcontext", "-a", "-t", "httpd_sys_rw_content_t",
		pDir+"/storage(/.*)?")
	a.runIgnore("sudo", "semanage", "fcontext", "-a", "-t", "httpd_sys_rw_content_t",
		pDir+"/bootstrap/cache(/.*)?")
	a.runIgnore("sudo", "restorecon", "-R", pDir)

	// Backup nginx.conf (idempotente).
	if fileExists("/etc/nginx/nginx.conf") && !fileExists("/etc/nginx/nginx.conf.bak") {
		a.runStrict("sudo", "cp", "/etc/nginx/nginx.conf", "/etc/nginx/nginx.conf.bak")
	}

	// nginx.conf crudo (tplNginxConf, sin expansiones).
	if err := writeRootFile("/etc/nginx/nginx.conf", tplNginxConf, 0644); err != nil {
		a.log.Error("nginx.conf write falló (fatal)", "error", err)
		os.Exit(1)
	}

	// laravel.conf reverse proxy (tplLaravelVhost, expande solo PROYECTO_DIR).
	vhost := fmt.Sprintf(tplLaravelVhost, pDir)
	if err := writeRootFile("/etc/nginx/conf.d/laravel.conf", vhost, 0644); err != nil {
		a.log.Error("laravel.conf write falló (fatal)", "error", err)
		os.Exit(1)
	}
}

// ============================================================
// Sección 11: Arranque final
// Equivalente a setup.sh:536-552.
// ============================================================
func (a *App) s11_arranque() {
	a.header("11. ARRANQUE FINAL")

	a.asLaravelStrict("php artisan optimize:clear")
	a.asLaravelStrict("php artisan config:cache")
	a.asLaravelStrict("php artisan route:cache")

	a.runStrict("sudo", "systemctl", "restart", "octane")
	a.runStrict("sudo", "systemctl", "enable", "--now", "nginx")
	a.runStrict("sudo", "systemctl", "restart", "nginx")

	fmt.Println("\n==========================================================================")
	fmt.Println(" INSTALACIÓN COMPLETADA")
	fmt.Println("==========================================================================")
	fmt.Printf(" App:     http://%s\n", a.serverIP)
	fmt.Printf(" BD:      PostgreSQL 18  (db=%s user=%s)\n", a.cfg.DBName, a.cfg.DBUser)
	fmt.Println(" Cache:   Redis (phpredis)")
	fmt.Println(" Server:  Octane/FrankenPHP + Nginx reverse proxy")
	fmt.Println("==========================================================================")
}

// runSetup ejecuta las 11 secciones en orden.
func (a *App) runSetup() {
	a.s1_repos()
	a.s2_firewall()
	a.s3_postgres()
	a.s4_user_laravel()
	a.s5_php_composer()
	a.s6_redis()
	a.s7_laravel_project()
	a.s8_env_file()
	a.s9_octane_systemd()
	a.s10_nginx_selinux()
	a.s11_arranque()
}
