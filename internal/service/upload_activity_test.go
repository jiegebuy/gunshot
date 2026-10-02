package service

import (
	"encoding/json"
	"strings"
	"testing"
)

func readActivity(t *testing.T, e *Engine, preferred string) *uploadActivityItem {
	t.Helper()
	request, _ := json.Marshal(Request{Op: "upload_activity", ID: preferred})
	var reply struct {
		OK   bool
		Data struct{ CurrentUpload *uploadActivityItem }
	}
	raw := e.HandleJSON(request, "googlephotos")
	if err := json.Unmarshal(raw, &reply); err != nil || !reply.OK {
		t.Fatalf("activity failed: %s", raw)
	}
	return reply.Data.CurrentUpload
}

func TestUploadActivityUsesOneStableFileAndRealRetryBytes(t *testing.T) {
	e := newEngine(t, nil)
	a := &Job{ID: "a", State: "uploading", Quality: "original", Uploaded: 80, Total: 100, Resources: []Resource{{Name: "first.mov", Size: 100}}}
	b := &Job{ID: "b", State: "uploading", Quality: "original", Uploaded: 30, Total: 200, Resources: []Resource{{Name: "second.mov", Size: 200}}}
	e.state.Jobs = []*Job{a, b}
	e.active[a.ID], e.active[b.ID] = func() {}, func() {}
	got := readActivity(t, e, "b")
	if got == nil || got.ID != "b" || got.Name != "second.mov" || got.Uploaded != 30 || got.Total != 200 {
		t.Fatalf("mixed concurrent files: %+v", got)
	}
	b.Uploaded = 0 // The actual callback resets after a failed attempt.
	if got = readActivity(t, e, "b"); got.Uploaded != 0 {
		t.Fatalf("fabricated monotonic file progress: %+v", got)
	}
	b.State = "completed"
	delete(e.active, b.ID)
	if got = readActivity(t, e, "b"); got.ID != "a" || got.Uploaded != 80 {
		t.Fatalf("did not switch completed file: %+v", got)
	}
	a.State = "committing"
	a.Uploaded = 100
	if got = readActivity(t, e, "a"); got.State != "committing" {
		t.Fatalf("upload bytes mistaken for cloud completion: %+v", got)
	}
	a.CancelRequested = true
	if got = readActivity(t, e, "a"); got != nil {
		t.Fatalf("cancelled file remained visible: %+v", got)
	}
}

func TestUploadActivityStreamingUsesOriginalSizeAndAcknowledgements(t *testing.T) {
	e := newEngine(t, nil)
	j := &Job{ID: "stream", State: "importing", Quality: "original", Streaming: true,
		Uploaded: 90, StreamUploaded: 40, Total: 100, StreamSourceSize: 1000,
		Resources: []Resource{{Name: "original.mov", Size: 100}}}
	e.state.Jobs = []*Job{j}
	e.streamVerified[j.ID] = 100
	e.active[j.ID] = func() {}
	got := readActivity(t, e, "")
	if got == nil || got.Uploaded != 40 || got.Total != 1000 || got.Measurement != "acknowledged" {
		t.Fatalf("staging treated as upload: %+v", got)
	}
	j.Total, j.Resources[0].Size = 500, 500 // More iCloud data is not more uploaded data.
	if got = readActivity(t, e, "stream"); got.Uploaded != 40 || got.Total != 1000 {
		t.Fatalf("preparation advanced file upload: %+v", got)
	}
	j.StreamSourceSize = 0
	if got = readActivity(t, e, "stream"); got.Total != 0 || got.Uploaded != 40 {
		t.Fatalf("invented unknown file size: %+v", got)
	}
	delete(e.active, j.ID)
	if got = readActivity(t, e, "stream"); got.State != "waiting_source" {
		t.Fatalf("waiting source reported as sending: %+v", got)
	}
	j.StreamError = "preupload_retry"
	if got = readActivity(t, e, "stream"); got.State != "retrying" || got.Uploaded != 40 {
		t.Fatalf("retry lost last acknowledgement: %+v", got)
	}
}

func TestUploadActivityLivePhotoPrivacyAndAccess(t *testing.T) {
	e := newEngine(t, nil)
	j := &Job{ID: "pair", State: "uploading", Quality: "original", Account: "private-account",
		Uploaded: 50, Total: 100, MediaKey: "private-key", ContentSHA1: "private-hash",
		Resources: []Resource{{Name: "private-name.heic", Size: 10}, {Name: "private-name.mov", Size: 90}}}
	e.state.Jobs = []*Job{j}
	e.active[j.ID] = func() {}
	e.fault = true // Diagnostic reads must remain available after a storage fault.
	got := readActivity(t, e, "pair")
	if got == nil || !got.LivePhoto || got.Uploaded != 50 || got.Total != 100 {
		t.Fatalf("pair bytes not preserved: %+v", got)
	}
	raw := string(e.HandleJSON([]byte(`{"op":"upload_activity"}`), "googlephotos"))
	for _, secret := range []string{"private-account", "private-key", "private-hash"} {
		if strings.Contains(raw, secret) {
			t.Fatalf("unneeded private field in activity: %s", secret)
		}
	}
	if strings.Contains(string(e.HandleJSON([]byte(`{"op":"upload_summary"}`), "googlephotos")), "private-name") {
		t.Fatal("filename leaked into exportable diagnostics")
	}
	if strings.Contains(string(e.HandleJSON([]byte(`{"op":"upload_activity"}`), "untrusted")), `"ok":true`) {
		t.Fatal("unauthorized activity request allowed")
	}
	delete(e.active, j.ID)
	if got = readActivity(t, e, "pair"); got != nil {
		t.Fatal("stale persisted uploading state treated as active")
	}
}
