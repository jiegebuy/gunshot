package service

import (
	"context"
	"testing"
	"time"
)

func TestSchedulerKeepsLargeLaneAndPrioritizesSmallPhotos(t *testing.T) {
	e := newEngine(t, nil)
	e.state.Options.Concurrent = 2
	oldest := &Job{ID: "old", State: "pending", Total: 100 << 20, Created: 1}
	newer := &Job{ID: "new", State: "pending", Total: 80 << 20, Created: 2}
	small := &Job{ID: "small", State: "pending", Total: 1 << 20, Created: 3}
	delayed := &Job{ID: "delay", State: "pending", Total: 1, Created: 0, Next: 200}
	e.state.Jobs = []*Job{oldest, newer, small, delayed}
	if e.nextPendingUpload(100) != oldest {
		t.Fatal("oldest large item did not get first lane")
	}
	oldest.State = "uploading"
	e.active[oldest.ID] = func() {}
	if e.nextPendingUpload(100) != small {
		t.Fatal("small photo blocked behind second video")
	}
	for i := 0; i < 7; i++ {
		if e.nextPendingUpload(100) != small {
			t.Fatal("unexpected small-file preference")
		}
	}
	if e.nextPendingUpload(100) != newer {
		t.Fatal("large file starved beyond fairness bound")
	}
}

func TestSchedulerReservesSustainedTransfersWithoutStarvingPhotos(t *testing.T) {
	e := newEngine(t, nil)
	e.state.Options.Concurrent = 8
	for i := 0; i < 6; i++ {
		e.state.Jobs = append(e.state.Jobs, &Job{ID: string(rune('a' + i)), State: "pending", Total: 64 << 20, Created: int64(i + 1)})
	}
	small := &Job{ID: "photo", State: "pending", Total: 1 << 20, Created: 10}
	e.state.Jobs = append(e.state.Jobs, small)
	for i := 0; i < 4; i++ {
		j := e.nextPendingUpload(100)
		if j == nil || j == small {
			t.Fatal("large transfer lane not filled")
		}
		j.State = "uploading"
		e.active[j.ID] = func() {}
	}
	if e.nextPendingUpload(100) != small {
		t.Fatal("photos lost their slots")
	}
	e.state.Jobs[0].State = "committing"
	if j := e.nextPendingUpload(100); j == nil || j == small {
		t.Fatal("commit incorrectly counted as sustained transfer")
	}
	for _, j := range e.state.Jobs {
		if j.Total >= 32<<20 && j.State == "pending" {
			j.Next = 200
		}
	}
	if e.nextPendingUpload(100) != small {
		t.Fatal("delayed large transfers blocked runnable photo")
	}
}

func TestSchedulerSingleSlotRetainsOldestFirst(t *testing.T) {
	e := newEngine(t, nil)
	e.state.Options.Concurrent = 1
	small := &Job{ID: "old-photo", State: "pending", Total: 1 << 20, Created: 1}
	e.state.Jobs = []*Job{small, {ID: "video", State: "pending", Total: 64 << 20, Created: 2}}
	if e.nextPendingUpload(100) != small {
		t.Fatal("single-slot queue starved an older photo")
	}
}
func TestSchedulerFillsConfiguredSlotsAndHonorsPause(t *testing.T) {
	started := make(chan struct{}, 8)
	e := newEngine(t, func(ctx context.Context, _ []string, _, _ string, _ func(Progress)) (string, error) {
		started <- struct{}{}
		<-ctx.Done()
		return "", ctx.Err()
	})
	for i := 0; i < 6; i++ {
		value, err := e.begin(Request{Account: "a@example.com", Quality: "original", Resources: []Resource{{Name: "photo.jpg", Size: 3}}}, "photos")
		if err != nil {
			t.Fatal(err)
		}
		e.find(value.(map[string]any)["id"].(string)).State = "pending"
	}
	e.state.Options.Concurrent = 6
	e.online = true
	e.wifi = true
	e.Tick()
	for i := 0; i < 6; i++ {
		select {
		case <-started:
		case <-time.After(time.Second):
			t.Fatal("parallel slots were not filled")
		}
	}
	e.mu.Lock()
	if len(e.active) != 6 {
		t.Fatal("wrong active count")
	}
	e.state.Options.Paused = true
	for _, cancel := range e.active {
		cancel()
	}
	e.mu.Unlock()
	waitIdle(t, e)
	e.Tick()
	if len(e.active) != 0 {
		t.Fatal("paused scheduler launched jobs")
	}
	o := defaults()
	o.Concurrent = 8
	if !o.valid() {
		t.Fatal("8 slots rejected")
	}
	o.Concurrent = 9
	if o.valid() {
		t.Fatal("unbounded concurrency")
	}
}

func TestSchedulerWakesOnSealAndCompletedUpload(t *testing.T) {
	e := newEngine(t, func(context.Context, []string, string, string, func(Progress)) (string, error) { return "media", nil })
	importTest(t, e, "original")
	select {
	case <-e.wake:
	default:
		t.Fatal("seal did not notify the scheduler")
	}
	e.online, e.wifi = true, true
	e.Tick()
	waitIdle(t, e)
	select {
	case <-e.wake:
	default:
		t.Fatal("completed upload did not notify the scheduler")
	}
}
