package service

// Caller holds e.mu. Keep a long upload moving while shorter files fill the
// other slots. Every ninth preference goes to the oldest eligible item, so
// continuously arriving small photos cannot starve an older video.
func (e *Engine) nextPendingUpload(now int64) *Job {
	var oldest, smallest *Job
	largeActive := false
	for _, j := range e.state.Jobs {
		if _, running := e.active[j.ID]; running && j.State != "failed" && j.Total >= 32<<20 {
			largeActive = true
		}
		if j.State != "pending" || j.Next > now || e.nativeAuthorization(j.Account) == "waiting" {
			continue
		}
		if oldest == nil || j.Created < oldest.Created {
			oldest = j
		}
		if smallest == nil || j.Total < smallest.Total || (j.Total == smallest.Total && j.Created < smallest.Created) {
			smallest = j
		}
	}
	if oldest == nil {
		return nil
	}
	if !largeActive || e.smallJobBurst >= 8 || smallest == oldest {
		e.smallJobBurst = 0
		return oldest
	}
	e.smallJobBurst++
	return smallest
}
