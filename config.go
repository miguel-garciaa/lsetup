package main

import (
	"bufio"
	"fmt"
	"os"
	"strings"
)

// ConfigFile es un INI multi-sección simple. Sección: [name]. Claves: key=val.
// Comentarios: #. Línea vacía ignorada. Parser intencionalmente minimal: no
// soporta comillas, escapes ni continuaciones — suficiente para lsetup.conf.
type ConfigFile struct {
	path     string
	sections map[string]map[string]string // sección -> clave -> valor
	order    []string                     // orden de secciones (estable en escritura)
}

// loadConfig carga el archivo. Secciones/claves no presentes → vacíos.
// Si el archivo no existe, devuelve ConfigFile vacío (sin error).
//
// Sintaxis multi-línea heredoc inline:
//
//	cloudflare_cert<<EOF
//	-----BEGIN CERTIFICATE-----
//	MIIDI...
//	-----END CERTIFICATE-----
//	EOF
//
// El delimitador (EOF en este caso) es una línea que contiene SOLO ese token.
// La clave se rellena con el contenido entre `<<DELIM` y la línea `DELIM`.
// Útil para embeber bloques PEM (certificates, private keys) en el config INI.
func loadConfig(path string) (*ConfigFile, error) {
	cf := &ConfigFile{
		path:     path,
		sections: map[string]map[string]string{},
	}
	f, err := os.Open(path)
	if err != nil {
		if os.IsNotExist(err) {
			return cf, nil
		}
		return nil, err
	}
	defer f.Close()

	cur := "" // sección activa; "" = pre-sección (solo comentarios)
	scan := bufio.NewScanner(f)
	// Buffer amplio: certificados PEM pueden ser grandes pero caben en 1MB.
	scan.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	for scan.Scan() {
		line := scan.Text()
		trimmed := strings.TrimSpace(line)
		if trimmed == "" || strings.HasPrefix(trimmed, "#") {
			continue
		}
		if strings.HasPrefix(trimmed, "[") && strings.HasSuffix(trimmed, "]") {
			cur = trimmed[1 : len(trimmed)-1]
			if _, ok := cf.sections[cur]; !ok {
				cf.sections[cur] = map[string]string{}
				cf.order = append(cf.order, cur)
			}
			continue
		}
		if cur == "" {
			continue
		}

		// Detectar heredoc: "key<<DELIM"
		if heredocStart(trimmed) {
			key, delim := parseHeredocHeader(trimmed)
			// Leer líneas hasta encontrar delim en línea propia.
			var block strings.Builder
			for scan.Scan() {
				hl := scan.Text()
				if strings.TrimSpace(hl) == delim {
					break
				}
				if block.Len() > 0 {
					block.WriteString("\n")
				}
				block.WriteString(hl)
			}
			cf.sections[cur][key] = block.String()
			continue
		}

		// Asignación normal: "key=val"
		idx := strings.IndexByte(trimmed, '=')
		if idx == -1 {
			continue
		}
		key := strings.TrimSpace(trimmed[:idx])
		val := strings.TrimSpace(trimmed[idx+1:])
		cf.sections[cur][key] = val
	}
	return cf, scan.Err()
}

// heredocStart devuelve true si la línea tiene forma "key<<DELIM".
// DELIM es cualquier token sin espacios (típicamente EOF o PEM).
func heredocStart(line string) bool {
	idx := strings.Index(line, "<<")
	if idx <= 0 {
		return false
	}
	delim := strings.TrimSpace(line[idx+2:])
	return delim != "" && !strings.ContainsAny(delim, " \t")
}

// parseHeredocHeader extrae (key, delim) de una línea "key<<DELIM".
// Req: heredocStart(line) == true.
func parseHeredocHeader(line string) (string, string) {
	idx := strings.Index(line, "<<")
	key := strings.TrimSpace(line[:idx])
	delim := strings.TrimSpace(line[idx+2:])
	return key, delim
}

// Section devuelve el mapa clave->valor de la sección pedida (vacía si no existe).
func (cf *ConfigFile) Section(name string) map[string]string {
	s, ok := cf.sections[name]
	if !ok {
		return map[string]string{}
	}
	return s
}

// SectionExists devuelve true si la sección existe y tiene al menos una clave.
func (cf *ConfigFile) SectionExists(name string) bool {
	s, ok := cf.sections[name]
	return ok && len(s) > 0
}

// RemoveSection elimina la sección del config. Si era la última, saveConfig
// acaba borrando el archivo (WriteFile con 0 bytes — caller decide).
func (cf *ConfigFile) RemoveSection(name string) {
	delete(cf.sections, name)
	newOrder := cf.order[:0]
	for _, n := range cf.order {
		if n != name {
			newOrder = append(newOrder, n)
		}
	}
	cf.order = newOrder
}

// save escribe el config a disco SI hay secciones; si no hay ninguna,
// elimina el archivo físico (auto-borrado final).
//
// Valores con `\n` se serializan como heredoc inline:
//
//	cloudflare_cert<<__LSH__
//	-----BEGIN CERTIFICATE-----
//	...
//	-----END CERTIFICATE-----
//	__LSH__
//
// Asi save+load es idempotente: PEM multiline se preserva al reescribir.
func (cf *ConfigFile) save() error {
	if len(cf.sections) == 0 {
		return os.Remove(cf.path)
	}
	var b strings.Builder
	for _, name := range cf.order {
		fmt.Fprintf(&b, "[%s]\n", name)
		for k, v := range cf.sections[name] {
			if strings.Contains(v, "\n") {
				// Multi-línea: heredoc inline con delimitador fijo __LSH__.
				fmt.Fprintf(&b, "%s<<__LSH__\n%s\n__LSH__\n", k, v)
			} else {
				fmt.Fprintf(&b, "%s=%s\n", k, v)
			}
		}
		b.WriteString("\n")
	}
	return os.WriteFile(cf.path, []byte(b.String()), 0600)
}

// exportEnv toma una sección y exporta sus claves como variables de entorno
// (UPPERCASE key, valor). Los scripts bash embebidos las leen si están set.
// Solo se exportan claves con valor non-empty.
func (cf *ConfigFile) exportEnv(section string) {
	for k, v := range cf.Section(section) {
		if v == "" {
			continue
		}
		// Setenv pisa cualquier valor previo del entorno del proceso.
		_ = os.Setenv(strings.ToUpper(k), v)
	}
}

// fillInteractive escribe el template de secciones vacías de un subcomando si
// no ya presentes. Devuelve true si hubo cambio (para save()). Las secciones
// nuevas se añaden al final del orden de escritura.
func (cf *ConfigFile) fillInteractive(sections ...string) bool {
	changed := false
	for _, name := range sections {
		if _, ok := cf.sections[name]; !ok {
			cf.sections[name] = map[string]string{}
			cf.order = append(cf.order, name)
			changed = true
		}
	}
	return changed
}
