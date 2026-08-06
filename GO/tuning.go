package main

import (
	"fmt"
	"os"
	"runtime"
	"strconv"
	"strings"
)

// Tuning agrupa los valores derivados de CPU/RAM para setup.
// Replica las formulas de SH/setup.sh para mantener paridad entre el instalador
// historico Bash y la reescritura nativa Go.
type Tuning struct {
	CPU int
	RAM int

	OctaneWorkers int

	PGSharedBuffers          int
	PGEffectiveCacheSize     int
	PGWorkMem                int
	PGMaintenanceWorkMem     int
	PGWalBuffers             int
	PGMaxConnections         int
	PGMaxWorkerProcesses     int
	PGMaxParallelWorkers     int
	PGParallelPerGather      int
	PGCheckpointTarget       float64
	PGRandomPageCost         float64
	PGEffectiveIOConcurrency int

	RedisMaxMemory int
	RedisIOThreads int
}

func detectHardware() (*Tuning, error) {
	cpu := runtime.NumCPU()
	if cpu < 1 {
		cpu = 1
	}

	ram, err := detectRAMMB()
	if err != nil {
		return nil, err
	}
	if ram < 256 {
		ram = 256
	}

	octaneWorkers := clamp(cpu, 2, 8)

	pgSharedBuffers := ram / 4
	pgEffectiveCacheSize := ram * 3 / 4
	pgWorkMem := (ram - pgSharedBuffers) / 300
	if pgWorkMem < 4 {
		pgWorkMem = 4
	}
	pgMaintenanceWorkMem := ram / 16
	if pgMaintenanceWorkMem < 64 {
		pgMaintenanceWorkMem = 64
	}
	pgWalBuffers := pgSharedBuffers / 32
	pgWalBuffers = clamp(pgWalBuffers, 4, 16)
	pgParallelPerGather := cpu / 2
	if pgParallelPerGather < 1 {
		pgParallelPerGather = 1
	}

	redisMaxMemory := ram / 4
	redisMaxMemory = clamp(redisMaxMemory, 64, 4096)
	redisIOThreads := clamp(cpu, 1, 4)

	return &Tuning{
		CPU:                      cpu,
		RAM:                      ram,
		OctaneWorkers:            octaneWorkers,
		PGSharedBuffers:          pgSharedBuffers,
		PGEffectiveCacheSize:     pgEffectiveCacheSize,
		PGWorkMem:                pgWorkMem,
		PGMaintenanceWorkMem:     pgMaintenanceWorkMem,
		PGWalBuffers:             pgWalBuffers,
		PGMaxConnections:         100,
		PGMaxWorkerProcesses:     cpu,
		PGMaxParallelWorkers:     cpu,
		PGParallelPerGather:      pgParallelPerGather,
		PGCheckpointTarget:       0.9,
		PGRandomPageCost:         1.1,
		PGEffectiveIOConcurrency: 200,
		RedisMaxMemory:           redisMaxMemory,
		RedisIOThreads:           redisIOThreads,
	}, nil
}

func detectRAMMB() (int, error) {
	b, err := os.ReadFile("/proc/meminfo")
	if err != nil {
		// Permite compilar y ejecutar ayuda en entornos no Linux; el binario real
		// corre en AlmaLinux/RHEL, donde /proc/meminfo existe.
		if runtime.GOOS != "linux" {
			return 256, nil
		}
		return 0, fmt.Errorf("lectura /proc/meminfo fallo: %w", err)
	}
	for _, line := range strings.Split(string(b), "\n") {
		if !strings.HasPrefix(line, "MemTotal:") {
			continue
		}
		fields := strings.Fields(line)
		if len(fields) < 2 {
			break
		}
		kb, err := strconv.Atoi(fields[1])
		if err != nil {
			return 0, fmt.Errorf("MemTotal invalido: %w", err)
		}
		return kb / 1024, nil
	}
	return 0, fmt.Errorf("MemTotal no encontrado en /proc/meminfo")
}

func clamp(v, min, max int) int {
	if v < min {
		return min
	}
	if v > max {
		return max
	}
	return v
}
