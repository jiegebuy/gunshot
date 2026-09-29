package main

import (
	"app/backend"
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"time"
)

// Developer opt-in: the marker must be placed in this app's private container.
// Normal launches make no probe requests. No credentials or session URLs are
// exported, and no probe submits media to the library.
func streamingProbeIfRequested(root string) {
	marker := filepath.Join(root, "streaming-probe.request")
	if info, err := os.Stat(marker); err != nil || !info.Mode().IsRegular() {
		return
	}
	if os.Rename(marker, marker+".running") != nil {
		return
	}
	defer os.Remove(marker + ".running")
	time.Sleep(5 * time.Second)
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()
	account := (&backend.ConfigManager{}).GetAccounts().Selected
	results, err := backend.GunshotProbeStreaming(ctx, account)
	result := map[string]any{"results": results, "finished": time.Now().Unix(), "synthetic": true, "libraryCommits": 0}
	if err != nil {
		result["error"] = "probe_unavailable"
	}
	data, _ := json.Marshal(result)
	target := filepath.Join(root, "streaming-probe-result.json")
	if os.WriteFile(target+".tmp", data, 0600) == nil {
		_ = os.Rename(target+".tmp", target)
	}
}
