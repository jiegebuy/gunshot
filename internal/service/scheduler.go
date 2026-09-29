package service

// Caller holds e.mu. Reserve half the slots for sustained large transfers;
// small photos use the remainder. Every ninth preference selects the oldest, so
// continuously arriving small photos cannot starve an older video.
func (e *Engine) nextPendingUpload(now int64) *Job {
	var oldest, smallest, large *Job
	largeActive := 0
	for _, j := range e.state.Jobs {
		if _, running := e.active[j.ID]; running && (j.State == "preparing" || j.State == "uploading") && j.Total >= 32<<20 {
			largeActive++
		}
		if j.State != "pending" || j.Next > now || e.nativeAuthorization(j.Account) == "waiting" {
			continue
		}
		if oldest == nil || j.Created < oldest.Created {
			oldest = j
		}
		if j.Total >= 32<<20 && (large == nil || j.Created < large.Created) {
			large = j
		}
		if smallest == nil || j.Total < smallest.Total || (j.Total == smallest.Total && j.Created < smallest.Created) {
			smallest = j
		}
	}
	if oldest == nil {
		return nil
	}
	if large != nil && largeActive < max(1, e.state.Options.Concurrent/2) {
		return large
	}
	if e.smallJobBurst >= 8 || smallest == oldest {
		e.smallJobBurst = 0
		return oldest
	}
	e.smallJobBurst++
	return smallest
}
