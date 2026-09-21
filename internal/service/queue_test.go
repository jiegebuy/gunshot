package service

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func newEngine(t *testing.T, r Runner) *Engine {
	t.Helper()
	e, err := Open(t.TempDir(), r)
	if err != nil {
		t.Fatal(err)
	}
	return e
}
func importTest(t *testing.T, e *Engine, quality string) *Job {
	t.Helper()
	r := Request{Account: "a@example.com", Quality: quality, Resources: []Resource{{Name: "photo.jpg", Size: 3}}}
	v, err := e.begin(r, "photos")
	if err != nil {
		t.Fatal(err)
	}
	j := e.find(v.(map[string]any)["id"].(string))
	if err = e.appendChunk(j, Request{Index: 0, Offset: 0, Data: []byte("abc")}); err != nil {
		t.Fatal(err)
	}
	if _, err = e.seal(j); err != nil {
		t.Fatal(err)
	}
	return j
}
func waitIdle(t *testing.T, e *Engine) {
	t.Helper()
	done := make(chan struct{})
	go func() { e.wg.Wait(); close(done) }()
	select {
	case <-done:
	case <-time.After(3 * time.Second):
		t.Fatal("worker stuck")
	}
}
func TestImportBoundsAndDuplicate(t *testing.T) {
	e := newEngine(t, nil)
	for _, name := range []string{"../x", "a/b", "..", "a\\b", "a\x00b"} {
		if _, err := e.begin(Request{Account: "a", Quality: "original", Resources: []Resource{{name, 3}}}, "photos"); err == nil {
			t.Fatalf("accepted %q", name)
		}
	}
	a := importTest(t, e, "original")
	b := importTest(t, e, "original")
	c := importTest(t, e, "quota")
	if a.State != "pending" || b.State != "cancelled" || c.State != "pending" {
		t.Fatalf("wrong dedup states: %s/%s/%s", a.State, b.State, c.State)
	}
	st, _ := os.Stat(filepath.Join(e.root, "state.json"))
	if st.Mode().Perm() != 0600 {
		t.Fatal("state not private")
	}
}
func TestSourceIdentityDeduplicatesBeforeStaging(t *testing.T) {
	e := newEngine(t, nil)
	r := Request{Account: "a@example.com", Quality: "original", SourceID: "asset-local-id-secret", Resources: []Resource{{Name: "photo.jpg", Size: 3}}}
	first, err := e.begin(r, "googlephotos")
	if err != nil {
		t.Fatal(err)
	}
	second, err := e.begin(r, "googlephotos")
	if err != nil {
		t.Fatal(err)
	}
	a := first.(map[string]any)
	b := second.(map[string]any)
	if a["id"] != b["id"] || b["duplicate"] != true || len(e.state.Jobs) != 1 {
		t.Fatalf("source duplicate was staged twice: first=%v second=%v jobs=%d", a, b, len(e.state.Jobs))
	}
	if e.state.Jobs[0].SourceKey == "" || e.state.Jobs[0].SourceKey == r.SourceID {
		t.Fatal("source identity was not hashed")
	}
	if err := e.save(); err != nil {
		t.Fatal(err)
	}
	state, err := os.ReadFile(filepath.Join(e.root, "state.json"))
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(state), r.SourceID) {
		t.Fatal("raw PhotoKit identifier persisted")
	}
	if _, err := e.begin(Request{Account: r.Account, Quality: "quota", SourceID: r.SourceID, Resources: r.Resources}, "googlephotos"); err != nil {
		t.Fatal(err)
	}
	if len(e.state.Jobs) != 2 {
		t.Fatal("quality profile incorrectly shared source identity")
	}
}
func TestSourceReceiptSurvivesHistoryCleanupAndRestart(t *testing.T) {
	e := newEngine(t, nil)
	r := Request{Account: "a@example.com", Quality: "original", SourceID: "stable-photo-id", Resources: []Resource{{Name: "photo.jpg", Size: 3}}}
	value, err := e.begin(r, "googlephotos")
	if err != nil {
		t.Fatal(err)
	}
	j := e.find(value.(map[string]any)["id"].(string))
	j.State, j.MediaKey, j.OriginalPolicy = "completed", "remote-media-key", 1
	if err := e.recordSourceReceipt(j); err != nil {
		t.Fatal(err)
	}
	if err := e.save(); err != nil {
		t.Fatal(err)
	}
	if _, err := e.handle(Request{Op: "clear_completed"}, "photos"); err != nil {
		t.Fatal(err)
	}
	if len(e.state.Jobs) != 0 {
		t.Fatal("completed history was not cleared")
	}
	duplicate, err := e.begin(r, "googlephotos")
	if err != nil {
		t.Fatal(err)
	}
	if duplicate.(map[string]any)["id"] != j.ID || duplicate.(map[string]any)["duplicate"] != true || len(e.state.Jobs) != 0 {
		t.Fatal("receipt did not deduplicate after history cleanup")
	}
	reopened, err := Open(e.root, nil)
	if err != nil {
		t.Fatal(err)
	}
	duplicate, err = reopened.begin(r, "googlephotos")
	if err != nil || duplicate.(map[string]any)["id"] != j.ID || len(reopened.state.Jobs) != 0 {
		t.Fatalf("receipt did not survive restart: %v %v", duplicate, err)
	}
	state, err := reopened.handle(Request{Op: "job", ID: j.ID}, "photos")
	if err != nil {
		t.Fatal(err)
	}
	completed := state.(map[string]any)
	if completed["state"] != "completed" || completed["mediaKey"] != "remote-media-key" {
		t.Fatalf("receipt did not synthesize completed job state: %v", completed)
	}
}
func TestLegacyFingerprintReceiptSurvivesCleanupAndBindsSource(t *testing.T) {
	root := t.TempDir()
	e, err := Open(root, nil)
	if err != nil {
		t.Fatal(err)
	}
	legacy := importTest(t, e, "original")
	legacy.State = "completed"
	legacy.MediaKey = "legacy-remote-media-key"
	legacy.OriginalPolicy = 1
	if err := e.save(); err != nil {
		t.Fatal(err)
	}

	reopened, err := Open(root, nil)
	if err != nil {
		t.Fatal(err)
	}
	if receipt, ok := reopened.fingerprintReceipts[legacy.Fingerprint]; !ok || receipt.ID != legacy.ID {
		t.Fatalf("legacy completion was not migrated to fingerprint receipt: %v %v", receipt, ok)
	}
	if _, err := reopened.handle(Request{Op: "clear_completed"}, "photos"); err != nil {
		t.Fatal(err)
	}
	if len(reopened.state.Jobs) != 0 {
		t.Fatal("legacy completed history was not removable after fingerprint migration")
	}

	r := Request{Account: "a@example.com", Quality: "original", SourceID: "post-upgrade-photo-id", Resources: []Resource{{Name: "photo.jpg", Size: 3}}}
	value, err := reopened.begin(r, "googlephotos")
	if err != nil {
		t.Fatal(err)
	}
	staged := reopened.find(value.(map[string]any)["id"].(string))
	if err := reopened.appendChunk(staged, Request{Index: 0, Offset: 0, Data: []byte("abc")}); err != nil {
		t.Fatal(err)
	}
	sealed, err := reopened.seal(staged)
	if err != nil {
		t.Fatal(err)
	}
	result := sealed.(map[string]any)
	if result["id"] != legacy.ID || result["duplicate"] != true || staged.State != "cancelled" {
		t.Fatalf("legacy fingerprint did not block re-upload: %v state=%s", result, staged.State)
	}
	receipt, err := reopened.findSourceReceipt(r.Account, r.Quality, r.SourceID)
	if err != nil || receipt == nil || receipt.ID != legacy.ID {
		t.Fatalf("first post-upgrade scan did not bind source identity: %v %v", receipt, err)
	}
	jobsBefore := len(reopened.state.Jobs)
	duplicate, err := reopened.begin(r, "googlephotos")
	if err != nil {
		t.Fatal(err)
	}
	if duplicate.(map[string]any)["id"] != legacy.ID || duplicate.(map[string]any)["duplicate"] != true || len(reopened.state.Jobs) != jobsBefore {
		t.Fatal("bound legacy source was staged again")
	}
	state, err := reopened.handle(Request{Op: "job", ID: legacy.ID}, "photos")
	if err != nil || state.(map[string]any)["mediaKey"] != "legacy-remote-media-key" {
		t.Fatalf("fingerprint receipt did not preserve completed job lookup: %v %v", state, err)
	}
}
func TestUnverifiedLegacyOriginalIsNotMigrated(t *testing.T) {
	root := t.TempDir()
	e, err := Open(root, nil)
	if err != nil {
		t.Fatal(err)
	}
	legacy := importTest(t, e, "original")
	legacy.State = "completed"
	legacy.MediaKey = "legacy-unverified-key"
	legacy.OriginalPolicy = 0
	if err := e.save(); err != nil {
		t.Fatal(err)
	}
	reopened, err := Open(root, nil)
	if err != nil {
		t.Fatal(err)
	}
	if _, ok := reopened.fingerprintReceipts[legacy.Fingerprint]; ok {
		t.Fatal("unverified legacy original was promoted to durable dedup proof")
	}
	if _, err := reopened.handle(Request{Op: "clear_completed"}, "photos"); err != nil {
		t.Fatal(err)
	}
	if len(reopened.state.Jobs) != 1 || reopened.state.Jobs[0].ID != legacy.ID {
		t.Fatal("unverified legacy original was cleared without safe dedup evidence")
	}
}
func TestPartialImportNeverQueues(t *testing.T) {
	e := newEngine(t, nil)
	v, err := e.begin(Request{Account: "a", Quality: "original", Resources: []Resource{{"a.jpg", 3}}}, "photos")
	if err != nil {
		t.Fatal(err)
	}
	j := e.find(v.(map[string]any)["id"].(string))
	if err = e.appendChunk(j, Request{Offset: 1, Data: []byte("a")}); err == nil {
		t.Fatal("accepted invalid offset")
	}
	if _, err = e.seal(j); err == nil {
		t.Fatal("accepted incomplete file")
	}
	reopened, err := Open(e.root, nil)
	if err != nil {
		t.Fatal(err)
	}
	if reopened.find(j.ID).State != "cancelled" {
		t.Fatal("interrupted import not cancelled")
	}
	if _, err = os.Stat(e.jobDir(j.ID)); !os.IsNotExist(err) {
		t.Fatal("interrupted staging not removed")
	}
}
func TestRestartCommitIsUncertain(t *testing.T) {
	e := newEngine(t, nil)
	j := importTest(t, e, "original")
	j.State = "committing"
	if err := e.save(); err != nil {
		t.Fatal(err)
	}
	next, err := Open(e.root, nil)
	if err != nil {
		t.Fatal(err)
	}
	got := next.find(j.ID)
	if got.State != "failed" || got.Error != "commit_outcome_unknown" {
		t.Fatalf("unsafe recovery: %+v", got)
	}
	if _, err := next.handle(Request{Op: "retry", ID: got.ID}, "photos"); err == nil {
		t.Fatal("uncertain commit accepted explicit retry")
	}
	if _, err := next.handle(Request{Op: "retry_failed"}, "photos"); err != nil {
		t.Fatal(err)
	}
	if got.State != "failed" || got.Error != "commit_outcome_unknown" {
		t.Fatal("bulk retry changed uncertain commit")
	}
}
func TestRestrictionsRetryAndSanitizedError(t *testing.T) {
	called := 0
	e := newEngine(t, func(context.Context, []string, string, string, func(Progress)) (string, error) {
		called++
		return "", errors.New("secret=TOKEN_DONT_LEAK")
	})
	j := importTest(t, e, "original")
	e.Tick()
	if called != 0 {
		t.Fatal("started while offline")
	}
	e.online = true
	e.Tick()
	if called != 0 {
		t.Fatal("started without wifi")
	}
	e.wifi = true
	e.Tick()
	waitIdle(t, e)
	if j.State != "pending" || j.Next <= time.Now().Unix() {
		t.Fatal("missing backoff")
	}
	b, _ := os.ReadFile(filepath.Join(e.root, "state.json"))
	if strings.Contains(string(b), "TOKEN_DONT_LEAK") {
		t.Fatal("leaked error")
	}
	e.state.Options.Retries = 0
	j.Next = 0
	e.Tick()
	waitIdle(t, e)
	if j.State != "failed" {
		t.Fatal("retry limit ignored")
	}
}
func TestCancelAndCommitRace(t *testing.T) {
	started := make(chan struct{})
	e := newEngine(t, func(ctx context.Context, _ []string, _ string, _ string, cb func(Progress)) (string, error) {
		cb(Progress{State: "committing"})
		close(started)
		<-ctx.Done()
		return "remote-key", nil
	})
	j := importTest(t, e, "original")
	e.online = true
	e.wifi = true
	e.Tick()
	<-started
	e.mu.Lock()
	_, err := e.handle(Request{Op: "cancel", ID: j.ID}, "photos")
	e.mu.Unlock()
	if err != nil {
		t.Fatal(err)
	}
	waitIdle(t, e)
	if j.State != "completed" {
		t.Fatal("successful commit incorrectly labelled cancelled")
	}
}
func TestUncertainCommitDoesNotAutoRetry(t *testing.T) {
	e := newEngine(t, func(ctx context.Context, _ []string, _ string, _ string, cb func(Progress)) (string, error) {
		cb(Progress{State: "committing"})
		return "", errors.New("disconnect")
	})
	j := importTest(t, e, "original")
	e.online = true
	e.wifi = true
	e.Tick()
	waitIdle(t, e)
	if j.State != "failed" || j.Error != "commit_outcome_unknown" {
		t.Fatal("uncertain commit scheduled for automatic retry")
	}
}
func TestRoleCannotBeSpoofedInJSON(t *testing.T) {
	e := newEngine(t, nil)
	for _, r := range []struct{ role, body string }{{"unknown", `{"op":"ping","role":"settings"}`}, {"photos", `{"op":"account_add","secret":"foo"}`}, {"photos", `{"op":"configure"}`}, {"settings", `{"op":"conditions","online":true}`}} {
		var reply struct{ OK bool }
		if err := json.Unmarshal(e.HandleJSON([]byte(r.body), r.role), &reply); err != nil || reply.OK {
			t.Fatalf("unauthorized request accepted: %v", r)
		}
	}
}
func TestStorageFailureStopsScheduling(t *testing.T) {
	e := newEngine(t, func(context.Context, []string, string, string, func(Progress)) (string, error) {
		t.Error("must not start without durable state")
		return "", nil
	})
	importTest(t, e, "original")
	p := filepath.Join(e.root, "state.json")
	if err := os.Remove(p); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(p, 0700); err != nil {
		t.Fatal(err)
	}
	e.online = true
	e.wifi = true
	e.Tick()
	if !e.fault || len(e.active) != 0 {
		t.Fatal("failed-open on write error")
	}
}
func TestCorruptStateDoesNotReset(t *testing.T) {
	d := t.TempDir()
	os.WriteFile(filepath.Join(d, "state.json"), []byte("{"), 0600)
	if _, err := Open(d, nil); err == nil {
		t.Fatal("corrupt state silently reset")
	}
}

func TestRemoteLivePhotoComponentIsNotRetried(t *testing.T) {
	e := newEngine(t, func(context.Context, []string, string, string, func(Progress)) (string, error) {
		return "", errRemoteComponentExists
	})
	j := importTest(t, e, "original")
	e.online = true
	e.wifi = true
	e.Tick()
	waitIdle(t, e)
	if j.State != "failed" || j.Error != "remote_live_photo_component_exists" || j.Attempts != 1 {
		t.Fatal("duplicate component outcome lost")
	}
	if _, err := e.handle(Request{Op: "retry", ID: j.ID}, "photos"); err == nil {
		t.Fatal("remote component duplicate accepted explicit retry")
	}
	if _, err := e.handle(Request{Op: "retry_failed"}, "photos"); err != nil {
		t.Fatal(err)
	}
	if j.State != "failed" {
		t.Fatal("bulk retry re-queued remote component duplicate")
	}
}

func TestStructurallyCorruptStateRejected(t *testing.T) {
	for _, mutate := range []func(*State){
		func(s *State) { s.Jobs = append(s.Jobs, nil) },
		func(s *State) { s.Jobs[0].ID = "../credentials.json" },
		func(s *State) { s.Jobs[0].Resources[0].Name = "../credentials.json" },
		func(s *State) { s.Jobs[0].State = "unknown" },
		func(s *State) { s.Jobs = append(s.Jobs, s.Jobs[0]) },
	} {
		e := newEngine(t, nil)
		importTest(t, e, "original")
		mutate(&e.state)
		if err := e.save(); err != nil {
			t.Fatal(err)
		}
		if _, err := Open(e.root, nil); err == nil {
			t.Fatal("accepted invalid persisted job")
		}
	}
}

func TestEmbeddedBackgroundPauseAndReopen(t *testing.T) {
	started := make(chan struct{})
	e := newEngine(t, func(ctx context.Context, _ []string, _ string, _ string, cb func(Progress)) (string, error) {
		cb(Progress{State: "uploading"})
		close(started)
		<-ctx.Done()
		return "", ctx.Err()
	})
	j := importTest(t, e, "original")
	e.HandleJSON([]byte(`{"op":"conditions","online":true,"wifi":true}`), "daemon")
	e.Tick()
	select {
	case <-started:
	case <-time.After(3 * time.Second):
		t.Fatal("upload did not start")
	}
	e.HandleJSON([]byte(`{"op":"conditions","online":false,"wifi":true}`), "daemon")
	waitIdle(t, e)
	if j.State != "pending" || j.Attempts != 0 {
		t.Fatalf("background pause lost queue/retry budget: %+v", j)
	}
	e.Tick()
	waitIdle(t, e) // Would panic by re-closing started if scheduling ignored suspension.
	e.Close()
	next, err := Open(e.root, func(context.Context, []string, string, string, func(Progress)) (string, error) {
		return "committed", nil
	})
	if err != nil {
		t.Fatal(err)
	}
	defer next.Close()
	next.Tick()
	waitIdle(t, next)
	if next.find(j.ID).State != "pending" {
		t.Fatal("reopened queue must await foreground/network conditions")
	}
	next.HandleJSON([]byte(`{"op":"conditions","online":true,"wifi":true}`), "daemon")
	next.Tick()
	waitIdle(t, next)
	if next.find(j.ID).State != "completed" {
		t.Fatal("foreground reopen did not finish queued upload")
	}
}

func TestGooglePhotosSettingsRole(t *testing.T) {
	for _, op := range []string{"configure", "account_add", "account_native", "account_remove", "account_select", "source_lookup", "begin", "append", "seal"} {
		if !roleAllowed("googlephotos", op) {
			t.Fatalf("in-app settings/import denied: %s", op)
		}
	}
	if roleAllowed("googlephotos", "conditions") || roleAllowed("photos", "account_add") || !roleAllowed("photos", "source_lookup") || roleAllowed("settings", "source_lookup") {
		t.Fatal("expanded role crossed native boundary")
	}
}

func TestOriginalDoesNotReuseLegacyUnverifiedCompletion(t *testing.T) {
	e := newEngine(t, nil)
	old := importTest(t, e, "original")
	old.State = "completed"
	old.MediaKey = "legacy-saver-match"
	fresh := importTest(t, e, "original")
	if fresh.State != "pending" {
		t.Fatal("legacy completion prevented sending original bytes")
	}
	fresh.State = "completed"
	fresh.OriginalPolicy = 1
	fresh.MediaKey = "original-key"
	duplicate := importTest(t, e, "original")
	if duplicate.State != "cancelled" {
		t.Fatal("current original completion was not deduplicated")
	}
}
