package service

import "time"

type uploadRateSample struct {
	at    time.Time
	bytes int64
}
type uploadRateWindow struct {
	samples     []uploadRateSample
	measurement string
	attempt     int
}

// A trailing 12-second window uses observed byte deltas and monotonic elapsed
// time. It is never based on file size, preparation work, or an estimated ETA.
// ACK-based streams therefore show their recent confirmed throughput rather
// than falsely claiming the whole acknowledged chunk was sent in one poll.
func (w *uploadRateWindow) sample(now time.Time, bytes int64, measurement, state string, attempt int) *int64 {
	n := len(w.samples)
	reset := n == 0 || w.measurement != measurement || w.attempt != attempt
	if n > 0 && (bytes < w.samples[n-1].bytes || now.Before(w.samples[n-1].at)) {
		reset = true
	}
	if reset {
		w.samples = nil
	}
	w.measurement, w.attempt = measurement, attempt
	if state == "retrying" || state == "preparing" || state == "committing" {
		w.samples = []uploadRateSample{{now, bytes}}
		zero := int64(0)
		return &zero
	}
	if len(w.samples) == 0 || now.Sub(w.samples[len(w.samples)-1].at) >= time.Second {
		w.samples = append(w.samples, uploadRateSample{now, bytes})
	}
	cutoff := now.Add(-12 * time.Second)
	for len(w.samples) > 1 && !w.samples[1].at.After(cutoff) {
		w.samples = w.samples[1:]
	}
	if len(w.samples) < 2 {
		return nil
	}
	first, last := w.samples[0], w.samples[len(w.samples)-1]
	seconds := last.at.Sub(first.at).Seconds()
	if seconds < 1 {
		return nil
	}
	rate := int64(float64(max(0, last.bytes-first.bytes)) / seconds)
	return &rate
}
