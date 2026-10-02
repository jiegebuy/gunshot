package service

import (
	"testing"
	"time"
)

func TestUploadSpeedUsesElapsedBytesAndDecaysWhenStalled(t *testing.T) {
	w := &uploadRateWindow{}
	now := time.Unix(100, 0)
	if w.sample(now, 9000, "sent", "uploading", 1) != nil {
		t.Fatal("invented initial speed")
	}
	rate := w.sample(now.Add(2*time.Second), 11000, "sent", "uploading", 1)
	if rate == nil || *rate != 1000 {
		t.Fatal(rate)
	}
	for i := 4; i <= 16; i += 2 {
		rate = w.sample(now.Add(time.Duration(i)*time.Second), 11000, "sent", "uploading", 1)
	}
	if rate == nil || *rate != 0 {
		t.Fatal("stalled upload retained old speed", rate)
	}
}

func TestUploadSpeedDoesNotCountRetriesOrSwitchMeasurement(t *testing.T) {
	w := &uploadRateWindow{}
	now := time.Unix(100, 0)
	w.sample(now, 0, "sent", "uploading", 1)
	w.sample(now.Add(2*time.Second), 1000, "sent", "uploading", 1)
	if w.sample(now.Add(4*time.Second), 0, "sent", "uploading", 2) != nil {
		t.Fatal("retry kept previous speed")
	}
	if w.sample(now.Add(6*time.Second), 1000, "acknowledged", "uploading", 2) != nil {
		t.Fatal("mixed acknowledged and read bytes")
	}
	rate := w.sample(now.Add(8*time.Second), 2000, "acknowledged", "uploading", 2)
	if rate == nil || *rate != 500 {
		t.Fatal(rate)
	}
	rate = w.sample(now.Add(10*time.Second), 2000, "acknowledged", "retrying", 2)
	if rate == nil || *rate != 0 {
		t.Fatal("retry backoff claimed transfer", rate)
	}
}

func TestActivityContainsAllConcurrentUploads(t *testing.T) {
	e := newEngine(t, nil)
	for i := 0; i < 8; i++ {
		id := string(rune('a' + i))
		j := &Job{ID: id, State: "uploading", Quality: "original", Total: 10000, Resources: []Resource{{Name: id + ".mov", Size: 10000}}}
		e.state.Jobs = append(e.state.Jobs, j)
		e.active[id] = func() {}
	}
	now := time.Unix(100, 0)
	e.uploadActivityAt("a", now)
	for _, j := range e.state.Jobs {
		j.Uploaded = 2000
	}
	items := e.uploadActivityAt("a", now.Add(2*time.Second))["uploads"].([]*uploadActivityItem)
	if len(items) != 8 {
		t.Fatal("hidden concurrent uploads", len(items))
	}
	for _, item := range items {
		if item.Speed == nil || *item.Speed != 1000 {
			t.Fatalf("incorrect per-file speed: %+v", item)
		}
	}
	e.state.Jobs[0].State = "completed"
	delete(e.active, "a")
	e.uploadActivityAt("a", now.Add(4*time.Second))
	if e.activityRates["a"] != nil {
		t.Fatal("finished file leaked rate history")
	}
}
