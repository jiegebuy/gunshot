package service

import (
	"path/filepath"
	"strings"
)

func diagnosticMediaType(resources []Resource) string {
	heic := false
	for _, resource := range resources {
		ext := strings.ToLower(filepath.Ext(resource.Name))
		heic = heic || ext == ".heic" || ext == ".heif"
	}
	if len(resources) == 2 {
		if heic {
			return "heic_live_photo"
		}
		return "live_photo"
	}
	if heic {
		return "heic"
	}
	if len(resources) == 1 {
		switch strings.ToLower(filepath.Ext(resources[0].Name)) {
		case ".jpg", ".jpeg":
			return "jpeg"
		case ".png":
			return "png"
		case ".mov", ".mp4", ".m4v":
			return "video"
		}
	}
	return "other"
}

// State files may come from older versions. Never copy arbitrary error strings
// or extensions into diagnostic output, even when a job has failed.
func diagnosticFailure(code string) string {
	switch code {
	case "remote_live_photo_component_exists", "commit_outcome_unknown", "commit_timeout_unknown",
		"upload_failed_retrying", "upload_failed_check_account_and_network",
		"waiting_for_native_auth", "paused", "import_interrupted", "upload_stalled":
		return code
	case "":
		return "unspecified"
	default:
		return "other"
	}
}

type mediaSummary struct {
	States       map[string]int `json:"states"`
	FailureCodes map[string]int `json:"failureCodes"`
}

// Caller holds e.mu. No account, asset, filename, hash, token or media key is
// exported. Profiles describe the immutable job policy, not verified cloud data.
func (e *Engine) uploadSummary() map[string]any {
	modes := map[string]any{}
	counts := map[string]map[string]int{}
	for _, mode := range []struct {
		name, model string
		policy      int
	}{{"original", "Pixel XL", 3}, {"saver", "Pixel 2", 1}, {"quota", "Pixel 8", 3}} {
		states := map[string]int{}
		counts[mode.name] = states
		modes[mode.name] = map[string]any{"model": mode.model, "storagePolicy": mode.policy, "uploadQuality": 1, "states": states}
	}
	media := map[string]*mediaSummary{}
	for _, job := range e.state.Jobs {
		if states := counts[job.Quality]; states != nil {
			states[job.State]++
		}
		kind := diagnosticMediaType(job.Resources)
		entry := media[kind]
		if entry == nil {
			entry = &mediaSummary{States: map[string]int{}, FailureCodes: map[string]int{}}
			media[kind] = entry
		}
		entry.States[job.State]++
		if job.Error != "" || job.State == "failed" {
			entry.FailureCodes[diagnosticFailure(job.Error)]++
		}
	}
	conditions := map[string]bool{"online": e.online, "wifi": e.wifi, "charging": e.charging, "paused": e.state.Options.Paused}
	return map[string]any{"completionRevision": e.state.CompletionRevision, "defaultQuality": e.state.Options.Quality, "profiles": modes, "mediaTypes": media, "conditions": conditions, "serverQualityVerified": false}
}
