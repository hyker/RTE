package main

import (
	"log"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// MaxTOEAge is the maximum age of TOE files before they are considered stale
// and cleaned up by the background sweeper. Adjust as needed.
const MaxTOEAge = 30 * 24 * time.Hour // 1 month
const sweepInterval = 1 * time.Hour

var toeExtensions = []string{".input", ".suite", ".output", ".failed", ".running"}

// cleanupTOE removes all files associated with a TOE job.
// If leaveExpired is true, a small .expired marker is left so the /result
// endpoint can distinguish "cleaned up" from "never existed".
func cleanupTOE(basePath string, leaveExpired bool) {
	for _, ext := range toeExtensions {
		os.Remove(basePath + ext)
	}
	if leaveExpired {
		writeToFile(basePath+".expired", []byte{})
	}
}

// startSweeper launches a background goroutine that periodically removes
// stale TOE files and old .expired markers from toeDir.
func startSweeper(toeDir string) {
	go func() {
		for {
			time.Sleep(sweepInterval)
			sweepStaleTOEs(toeDir)
		}
	}()
	log.Printf("TOE cleanup sweeper started (max age: %v, interval: %v)", MaxTOEAge, sweepInterval)
}

func sweepStaleTOEs(toeDir string) {
	entries, err := os.ReadDir(toeDir)
	if err != nil {
		log.Printf("sweeper: failed to read %s: %v", toeDir, err)
		return
	}

	staleJobs := make(map[string]bool)

	for _, entry := range entries {
		if entry.IsDir() {
			continue
		}
		name := entry.Name()
		ext := filepath.Ext(name)
		jobID := strings.TrimSuffix(name, ext)

		// Clean up old .expired markers after double the max age
		if ext == ".expired" {
			info, err := entry.Info()
			if err != nil {
				continue
			}
			if time.Since(info.ModTime()) > MaxTOEAge*2 {
				os.Remove(filepath.Join(toeDir, name))
			}
			continue
		}

		isTOEFile := false
		for _, toeExt := range toeExtensions {
			if ext == toeExt {
				isTOEFile = true
				break
			}
		}
		if !isTOEFile {
			continue
		}

		info, err := entry.Info()
		if err != nil {
			continue
		}
		if time.Since(info.ModTime()) > MaxTOEAge {
			staleJobs[jobID] = true
		}
	}

	for jobID := range staleJobs {
		basePath := filepath.Join(toeDir, jobID)
		log.Printf("sweeper: cleaning up stale TOE %s", jobID)
		cleanupTOE(basePath, true)
	}
}
