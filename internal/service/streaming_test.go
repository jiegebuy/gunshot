package service

import (
	"bytes"
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func beginStreamTest(t *testing.T, e *Engine, source string) *Job {
	t.Helper()
	v, err := e.begin(Request{Account: "a@example.com", Quality: "original", SourceID: source, Streaming: true, Resources: []Resource{{Name: "original.mov"}}}, "googlephotos")
	if err != nil {
		t.Fatal(err)
	}
	return e.find(v.(map[string]any)["id"].(string))
}
func appendStreamTest(t *testing.T, e *Engine, j *Job, offset int64, data []byte) {
	t.Helper()
	if !e.AppendEmbedded(j.ID, 0, offset, data) {
		t.Fatal("stream append failed")
	}
}
func TestStreamingAcknowledgesWhileProducerIsStillOpen(t *testing.T) {
	e := newEngine(t, nil)
	defer e.Close()
	e.online, e.wifi = true, true
	data := bytes.Repeat([]byte{7}, 768<<10)
	j := beginStreamTest(t, e, "cloud-original")
	e.preuploader = func(ctx context.Context, path, account, quality string, available int64) (int64, error) {
		b, err := os.ReadFile(path)
		if err != nil || !bytes.Equal(b, data) || available != int64(len(data)) {
			t.Error("preuploader saw wrong original prefix")
		}
		return 512 << 10, nil
	}
	appendStreamTest(t, e, j, 0, data)
	e.Tick()
	waitIdle(t, e)
	if j.State != "importing" || j.StreamUploaded != 512<<10 || j.StreamFirstAck == 0 {
		t.Fatal("no upload during import", j)
	}
	appendStreamTest(t, e, j, int64(len(data)), []byte("end"))
	if _, err := e.seal(j); err != nil {
		t.Fatal(err)
	}
	if j.Streaming || j.State != "pending" || j.StreamBeforeSeal != 512<<10 {
		t.Fatal("stream not sealed correctly")
	}
	s := e.uploadSummary()["streaming"].(map[string]int64)
	if s["jobsWithOverlap"] != 1 || s["bytesAcknowledgedBeforeSeal"] != 512<<10 {
		t.Fatal("missing overlap evidence")
	}
}
func TestStreamingRestartRequiresMatchingReplay(t *testing.T) {
	e := newEngine(t, nil)
	j := beginStreamTest(t, e, "same-cloud-original")
	data := bytes.Repeat([]byte{9}, 768<<10)
	appendStreamTest(t, e, j, 0, data)
	if err := e.suspendStream(j); err != nil {
		t.Fatal(err)
	}
	e.Close()
	next, err := Open(e.root, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer next.Close()
	j2 := beginStreamTest(t, next, "same-cloud-original")
	if j2.ID != j.ID || j2.Total != int64(len(data)) {
		t.Fatal("discarded resumable import")
	}
	if next.AppendEmbedded(j2.ID, 0, 0, []byte("changed")) {
		t.Fatal("mixed different original contents")
	}
	if next.AppendEmbedded(j2.ID, 0, int64(len(data)), []byte("skip")) {
		t.Fatal("skipped prefix verification")
	}
	if _, err := next.seal(j2); err == nil {
		t.Fatal("sealed before producer replayed")
	}
	appendStreamTest(t, next, j2, 0, data[:500000])
	appendStreamTest(t, next, j2, 500000, append(append([]byte{}, data[500000:]...), []byte("tail")...))
	if _, err := next.seal(j2); err != nil {
		t.Fatal(err)
	}
	b, err := os.ReadFile(filepath.Join(next.jobDir(j2.ID), "original.mov"))
	if err != nil || !bytes.Equal(b, append(data, []byte("tail")...)) {
		t.Fatal("replay duplicated or lost bytes")
	}
}
func TestStreamSealWaitsForPreuploadWorker(t *testing.T) {
	started, release, runner := make(chan struct{}), make(chan struct{}), make(chan struct{}, 1)
	e := newEngine(t, func(context.Context, []string, string, string, func(Progress)) (string, error) {
		runner <- struct{}{}
		return "remote", nil
	})
	defer e.Close()
	e.online, e.wifi = true, true
	e.preuploader = func(ctx context.Context, _ string, _ string, _ string, _ int64) (int64, error) {
		close(started)
		<-ctx.Done()
		<-release
		return 256 << 10, ctx.Err()
	}
	j := beginStreamTest(t, e, "slow-network")
	appendStreamTest(t, e, j, 0, bytes.Repeat([]byte{3}, 512<<10))
	e.Tick()
	select {
	case <-started:
	case <-time.After(time.Second):
		t.Fatal("preupload not scheduled")
	}
	e.mu.Lock()
	_, err := e.seal(j)
	e.mu.Unlock()
	if err != nil {
		t.Fatal(err)
	}
	e.Tick()
	select {
	case <-runner:
		t.Fatal("two workers used same checkpoint")
	default:
	}
	close(release)
	waitIdle(t, e)
	e.Tick()
	waitIdle(t, e)
	if j.State != "completed" {
		t.Fatal("sealed job did not resume")
	}
}
func TestStreamSuspensionAndPauseDoNotScheduleUploads(t *testing.T) {
	e := newEngine(t, nil)
	defer e.Close()
	e.online, e.wifi = true, true
	e.preuploader = func(context.Context, string, string, string, int64) (int64, error) {
		t.Error("unexpected preupload")
		return 0, nil
	}
	j := beginStreamTest(t, e, "suspend")
	appendStreamTest(t, e, j, 0, bytes.Repeat([]byte{3}, 512<<10))
	e.state.Options.Paused = true
	e.Tick()
	waitIdle(t, e)
	if err := e.suspendStream(j); err != nil {
		t.Fatal(err)
	}
	e.state.Options.Paused = false
	e.Tick()
	waitIdle(t, e)
	if retryableFailure(j) {
		t.Fatal("ordinary retry could finalize incomplete original")
	}
	if roleAllowed("settings", "stream_suspend") || !roleAllowed("googlephotos", "stream_suspend") {
		t.Fatal("wrong stream operation owner")
	}
}
