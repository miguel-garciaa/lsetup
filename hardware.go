package main

import (
	"bufio"
	"fmt"
	"os"
	"runtime"
	"strconv"
	"strings"
)

// Tuning agrupa los parámetros de rendimiento derivados del hardware.
// Cálculos 1:1 con setup.sh líneas 67-101.
type Tuning struct {
	CPU int // nº de núcleos
	RAM int // MB totales

	// Octane (FrankenPHP): workers ≈ núcleos, cap 8, min 2.
	OctaneWorkers int

	// PostgreSQL 18.
	PGSharedBuffers          int // MB ~25% RAM
	PGEffectiveCacheSize     int // MB ~75% RAM
	PGWorkMem                int // MB
	PGMaintenanceWorkMem     int // MB ~6% RAM
	PGWalBuffers             int // MB cap 16
	PGMaxConnections         int
	PGMaxWorkerProcesses     int
	PGMaxParallelWorkers     int
	PGParallelPerGather      int
	PGCheckpointTarget       float64
	PGRandomPageCost         float64
	PGEffectiveIOConcurrency int

	// Redis: maxmemory ~25% RAM (cap 4 GB), io-threads 1-4.
	RedisMaxMemory int // MB
	RedisIOThreads int
}

// memTotalKB lee /proc/meminfo y devuelve MemTotal en KB.
// Equivalente a `grep -m1 MemTotal /proc/meminfo | awk '{print $2}'`.
func memTotalKB() (int, error) {
	f, err := os.Open("/proc/meminfo")
	if err != nil {
		return 0, fmt.Errorf("lectura /proc/meminfo: %w", err)
	}
	defer f.Close()

	scan := bufio.NewScanner(f)
	for scan.Scan() {
		line := scan.Text()
		if strings.HasPrefix(line, "MemTotal:") {
			fields := strings.Fields(line)
			if len(fields) >= 2 {
				return strconv.Atoi(fields[1])
			}
		}
	}
	return 0, fmt.Errorf("MemTotal no encontrado en /proc/meminfo")
}

// detectHardware rellena Tuning con los cálculos del script bash.
// Preserva los mismos floors/caps que setup.sh.
func detectHardware() (*Tuning, error) {
	cpu := runtime.NumCPU()
	if cpu < 1 {
		cpu = 1
	}

	ramKB, err := memTotalKB()
	if err != nil {
		return nil, err
	}
	ramMB := ramKB / 1024
	if ramMB < 256 {
		ramMB = 256 // suelo razonable
	}

	t := &Tuning{CPU: cpu, RAM: ramMB}

	// Octane (FrankenPHP): workers ≈ núcleos, cap 8, min 2.
	t.OctaneWorkers = cpu
	if t.OctaneWorkers > 8 {
		t.OctaneWorkers = 8
	}
	if t.OctaneWorkers < 2 {
		t.OctaneWorkers = 2
	}

	// PostgreSQL 18.
	t.PGSharedBuffers = ramMB / 4
	t.PGEffectiveCacheSize = ramMB * 3 / 4
	t.PGWorkMem = (ramMB - t.PGSharedBuffers) / 300
	if t.PGWorkMem < 4 {
		t.PGWorkMem = 4
	}
	t.PGMaintenanceWorkMem = ramMB / 16
	if t.PGMaintenanceWorkMem < 64 {
		t.PGMaintenanceWorkMem = 64
	}
	t.PGWalBuffers = t.PGSharedBuffers / 32
	if t.PGWalBuffers > 16 {
		t.PGWalBuffers = 16
	}
	if t.PGWalBuffers < 4 {
		t.PGWalBuffers = 4
	}
	t.PGMaxConnections = 100
	t.PGMaxWorkerProcesses = cpu
	t.PGMaxParallelWorkers = cpu
	t.PGParallelPerGather = cpu / 2
	if t.PGParallelPerGather < 1 {
		t.PGParallelPerGather = 1
	}
	t.PGCheckpointTarget = 0.9
	t.PGRandomPageCost = 1.1
	t.PGEffectiveIOConcurrency = 200

	// Redis: maxmemory ~25% RAM (cap 4 GB), io-threads 1-4.
	t.RedisMaxMemory = ramMB / 4
	if t.RedisMaxMemory < 64 {
		t.RedisMaxMemory = 64
	}
	if t.RedisMaxMemory > 4096 {
		t.RedisMaxMemory = 4096
	}
	t.RedisIOThreads = cpu
	if t.RedisIOThreads > 4 {
		t.RedisIOThreads = 4
	}
	if t.RedisIOThreads < 1 {
		t.RedisIOThreads = 1
	}

	return t, nil
}
