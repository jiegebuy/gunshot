package service

import (
	"context"
	"sync"
	"time"
)

// Progress here means bytes consumed by the HTTP transport, not server receipts.
// A silent socket must not occupy an upload slot for the six-hour total limit.
type uploadWatch struct {
	mu      sync.Mutex
	active  bool
	last    time.Time
	bytes   int64
	stalled bool
}

func (w *uploadWatch) update(p Progress) {
	w.mu.Lock()
	defer w.mu.Unlock()
	if p.State != "uploading" {
		w.active = false
		return
	}
	if !w.active || p.Uploaded != w.bytes {
		w.last = time.Now()
	}
	w.active = true
	w.bytes = p.Uploaded
}
func (w *uploadWatch) run(ctx context.Context, cancel context.CancelFunc, limit time.Duration) {
	tick := min(time.Second, limit/4)
	if tick <= 0 {
		tick = time.Millisecond
	}
	timer := time.NewTicker(tick)
	defer timer.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-timer.C:
			w.mu.Lock()
			expired := w.active && time.Since(w.last) >= limit
			if expired {
				w.stalled = true
			}
			w.mu.Unlock()
			if expired {
				cancel()
				return
			}
		}
	}
}
func (w *uploadWatch) didStall() bool { w.mu.Lock(); defer w.mu.Unlock(); return w.stalled }
