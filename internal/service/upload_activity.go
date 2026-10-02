package service

import (
	"path/filepath"
	"sort"
	"time"
)

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
	Speed       *int64 `json:"speed,omitempty"` // recent measured bytes/second; nil until sampled
}

func (e *Engine) uploadActivity(preferred string) map[string]any {
	return e.uploadActivityAt(preferred, time.Now())
}

func (e *Engine) uploadActivityAt(preferred string, now time.Time) map[string]any {
	var selected *Job
	type candidate struct {
		job  *Job
		rank int
	}
	var candidates []candidate
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
		if rank > 0 {
			candidates = append(candidates, candidate{j, rank})
		}
	}
	result := e.uploadSummary()
	if e.activityRates == nil {
		e.activityRates = map[string]*uploadRateWindow{}
	}
	seen := map[string]bool{}
	items := make([]*uploadActivityItem, 0, len(candidates))
	// Network slots are capped at eight. Put every active slot before waiting
	// producers so the 12-tile Live Activity always includes all active uploads.
	sort.SliceStable(candidates, func(i, j int) bool { return candidates[i].rank > candidates[j].rank })
	for _, c := range candidates {
		item := e.uploadActivityItem(c.job)
		seen[item.ID] = true
		window := e.activityRates[item.ID]
		if window == nil {
			window = &uploadRateWindow{}
			e.activityRates[item.ID] = window
		}
		item.Speed = window.sample(now, item.Uploaded, item.Measurement, item.State, c.job.Attempts)
		if len(items) < 12 {
			items = append(items, item)
		}
		if c.job == selected {
			result["currentUpload"] = item
		}
	}
	for id := range e.activityRates {
		if !seen[id] {
			delete(e.activityRates, id)
		}
	}
	result["uploads"] = items
	result["sampledAt"] = now.UnixMilli()
	return result
}

func (e *Engine) uploadActivityItem(selected *Job) *uploadActivityItem {
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
	return item
}
