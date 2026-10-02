package service

import "path/filepath"

// This UI-only response may contain a filename. Keep it out of upload_summary,
// which is also used by exported diagnostics. Caller holds e.mu.
type uploadActivityItem struct {
	ID          string `json:"id"`
	Name        string `json:"name"`
	State       string `json:"state"`
	Uploaded    int64  `json:"uploaded"`
	Total       int64  `json:"total"`
	Measurement string `json:"measurement"`
	LivePhoto   bool   `json:"livePhoto"`
}

func (e *Engine) uploadActivity(preferred string) map[string]any {
	var selected *Job
	best := 0
	for _, j := range e.state.Jobs {
		if j.CancelRequested || len(j.Resources) == 0 {
			continue
		}
		rank := 0
		if e.active[j.ID] != nil {
			switch j.State {
			case "uploading":
				rank = 4
			case "importing":
				if j.Streaming {
					rank = 4
				}
			case "committing":
				rank = 3
			case "preparing":
				rank = 2
			}
		} else if j.Streaming && j.State == "importing" {
			// Keep the same stream visible between acknowledged chunks, including
			// retry backoff and waiting for more original bytes from PhotoKit.
			if _, producing := e.streamVerified[j.ID]; producing {
				rank = 1
			}
		} else if j.ID == preferred && j.State == "pending" && j.Attempts > 0 {
			rank = 1
		}
		if rank > best || (rank > 0 && rank == best && j.ID == preferred) {
			selected, best = j, rank
		}
	}
	result := e.uploadSummary()
	if selected == nil {
		return result
	}
	item := &uploadActivityItem{
		ID: selected.ID, Name: filepath.Base(selected.Resources[0].Name),
		State: selected.State, Uploaded: max(0, selected.Uploaded),
		Total: max(0, selected.Total), Measurement: "sent", LivePhoto: len(selected.Resources) == 2,
	}
	if selected.Streaming && selected.State == "importing" {
		// Total is only the staged prefix until seal. It must never be used as
		// the denominator of the original file's upload percentage.
		item.Uploaded = max(0, selected.StreamUploaded)
		item.Total = max(0, selected.StreamSourceSize)
		item.Measurement = "acknowledged"
		item.State = "uploading"
		if e.active[selected.ID] == nil {
			item.State = "waiting_source"
			if selected.StreamError != "" {
				item.State = "retrying"
			}
		}
	} else if selected.State == "pending" {
		item.State = "retrying"
	}
	if item.Total > 0 {
		item.Uploaded = min(item.Uploaded, item.Total)
	}
	result["currentUpload"] = item
	return result
}
