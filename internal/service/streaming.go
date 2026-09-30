package service

import (
	"app/backend"
	"bytes"
	"context"
	"crypto/sha256"
	"encoding"
	"errors"
	"hash"
	"io"
	"os"
	"path/filepath"
	"time"
)

type streamPrefix struct {
	offset int64
	digest []byte
}

func (e *Engine) streamWindow(j *Job) (any, error) {
	verified, producing := e.streamVerified[j.ID]
	if !j.Streaming || j.State != "importing" || !producing || j.CancelRequested {
		return nil, errRequest
	}
	remaining := int64(MaxEmbeddedChunk)
	if j.StreamBounded {
		// Replaying retained data allocates nothing and must not deadlock on a
		// full window left by a previous producer.
		remaining = max(j.Total-verified, backend.GunshotStreamWindow-(j.Total-j.StreamReclaimed))
	}
	return map[string]any{"availableBytes": max(0, remaining), "paused": e.state.Options.Paused}, nil
}

// PhotoKit restarts at byte zero. Compare its replay with the retained prefix
// before reusing the private server session; never mix two versions of an asset.
func (e *Engine) resumeStream(j *Job) (any, error) {
	if e.active[j.ID] != nil {
		return nil, errRequest
	}
	st, err := os.Stat(filepath.Join(e.jobDir(j.ID), j.Resources[0].Name))
	if err != nil {
		return nil, err
	}
	if st.Size() < j.Total || st.Size() > 100<<30 {
		return nil, errRequest
	}
	floor, digest, err := backend.GunshotStreamPrefix(filepath.Join(e.jobDir(j.ID), j.Resources[0].Name))
	if err != nil {
		return nil, err
	}
	e.streamPrefixes[j.ID] = streamPrefix{floor, digest}
	j.Total, j.Resources[0].Size = st.Size(), st.Size()
	j.State, j.Error, j.Next, j.CancelRequested = "importing", "", 0, false
	e.streamVerified[j.ID] = 0
	e.importHashes[j.ID] = []hash.Hash{sha256.New()}
	if err := e.save(); err != nil {
		return nil, err
	}
	return map[string]any{"id": j.ID, "resumed": true, "retainedBytes": j.Total - j.StreamReclaimed, "streamBounded": j.StreamBounded}, nil
}

func (e *Engine) appendStream(j *Job, r Request, limit int) error {
	verified, producing := e.streamVerified[j.ID]
	if !producing || j.State != "importing" || j.CancelRequested || r.Index != 0 || r.Offset != verified || len(r.Data) == 0 || len(r.Data) > limit || r.Offset+int64(len(r.Data)) > 100<<30 {
		return errRequest
	}
	end := r.Offset + int64(len(r.Data))
	if j.StreamSourceSize > 0 && end > j.StreamSourceSize {
		return errRequest
	}
	if j.StreamBounded && end > j.Total && end-j.StreamReclaimed > backend.GunshotStreamWindow {
		return errors.New("stream window full")
	}
	prefix := e.streamPrefixes[j.ID]
	if r.Offset < prefix.offset && end >= prefix.offset {
		state, _ := e.importHashes[j.ID][0].(encoding.BinaryMarshaler).MarshalBinary()
		h := sha256.New()
		if err := h.(encoding.BinaryUnmarshaler).UnmarshalBinary(state); err != nil {
			return err
		}
		h.Write(r.Data[:prefix.offset-r.Offset])
		if !bytes.Equal(h.Sum(nil), prefix.digest) {
			return errors.New("stream original changed")
		}
	}
	f, err := os.OpenFile(filepath.Join(e.jobDir(j.ID), j.Resources[0].Name), os.O_RDWR, 0600)
	if err != nil {
		return err
	}
	defer f.Close()
	st, err := f.Stat()
	if err != nil {
		return err
	}
	if st.Size() != j.Total {
		return errRequest
	}
	replayed := min(int64(len(r.Data)), j.Total-r.Offset)
	compareStart := min(replayed, max(0, prefix.offset-r.Offset))
	if replayed > compareStart {
		old := make([]byte, replayed-compareStart)
		if _, err = f.ReadAt(old, r.Offset+compareStart); err != nil {
			return err
		}
		if !bytes.Equal(old, r.Data[compareStart:replayed]) {
			return errors.New("stream original changed")
		}
	}
	if replayed < int64(len(r.Data)) {
		n, err := f.WriteAt(r.Data[replayed:], r.Offset+replayed)
		if err != nil {
			return err
		}
		if n != len(r.Data)-int(replayed) {
			return io.ErrShortWrite
		}
	}
	e.importHashes[j.ID][0].Write(r.Data)
	e.streamVerified[j.ID] += int64(len(r.Data))
	j.Total = max(j.Total, e.streamVerified[j.ID])
	j.Resources[0].Size = j.Total
	// A range source may discard its window as soon as append succeeds. Make
	// both bytes and their hash checkpoint durable before acknowledging it.
	if j.StreamSourceVersion != "" && e.streamVerified[j.ID] == j.Total {
		if err := f.Sync(); err != nil {
			j.State, j.Error = "failed", "import_interrupted"
			delete(e.streamVerified, j.ID)
			return err
		}
		if err := e.checkpointRangeStream(j); err != nil {
			j.State, j.Error = "failed", "import_interrupted"
			delete(e.streamVerified, j.ID)
			return err
		}
	}
	e.signalWork()
	return nil
}

func (e *Engine) suspendStream(j *Job) error {
	if !j.Streaming || j.State != "importing" {
		return errRequest
	}
	if cancel := e.active[j.ID]; cancel != nil {
		cancel()
	}
	j.State, j.Error = "failed", "import_interrupted"
	delete(e.streamVerified, j.ID)
	delete(e.streamPrefixes, j.ID)
	delete(e.importHashes, j.ID)
	f, err := os.OpenFile(filepath.Join(e.jobDir(j.ID), j.Resources[0].Name), os.O_RDWR, 0600)
	if err != nil {
		return err
	}
	err = f.Sync()
	f.Close()
	if err != nil {
		return err
	}
	return e.save()
}

// Reserve a bounded share of the ordinary upload slots so a ready-file queue
// cannot starve a growing video. Waiting for PhotoKit never holds a network slot.
func (e *Engine) tickStreams(now int64) {
	if e.preuploader == nil {
		return
	}
	limit, active := max(1, min(4, e.state.Options.Concurrent/2)), 0
	for id := range e.active {
		if j := e.find(id); j != nil && j.Streaming {
			active++
		}
	}
	for _, j := range e.state.Jobs {
		if active >= limit || len(e.active) >= e.state.Options.Concurrent {
			return
		}
		if !j.Streaming || j.State != "importing" || j.CancelRequested || e.active[j.ID] != nil || j.Next > now || e.nativeAuthorization(j.Account) == "waiting" || e.streamVerified[j.ID] != j.Total || j.Total-j.StreamUploaded <= 256<<10 {
			continue
		}
		// The backend fsyncs the prefix before any network write. Persist its size
		// before starting it so restart can account for every retained byte.
		if e.save() != nil {
			return
		}
		ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
		e.active[j.ID] = cancel
		active++
		e.wg.Add(1)
		go e.preupload(ctx, *j, cancel)
	}
}

func (e *Engine) preupload(ctx context.Context, snapshot Job, cancel context.CancelFunc) {
	defer e.wg.Done()
	defer cancel()
	defer e.signalWork()
	ack, err := e.preuploader(ctx, filepath.Join(e.jobDir(snapshot.ID), snapshot.Resources[0].Name), snapshot.Account, snapshot.Quality, snapshot.Total)
	e.mu.Lock()
	defer e.mu.Unlock()
	delete(e.active, snapshot.ID)
	j := e.find(snapshot.ID)
	if j == nil {
		return
	}
	if ack >= 0 && ack <= snapshot.Total && ack > j.StreamUploaded {
		j.StreamUploaded = ack
		if j.StreamFirstAck == 0 {
			j.StreamFirstAck = time.Now().UnixMilli()
		}
		j.Uploaded = max(j.Uploaded, ack)
	}
	if j.StreamBounded && j.Streaming && j.State == "importing" && !j.CancelRequested && ack > j.StreamReclaimed {
		reclaimed, reclaimErr := backend.GunshotReclaimStream(filepath.Join(e.jobDir(j.ID), j.Resources[0].Name), ack)
		j.StreamReclaimed = max(j.StreamReclaimed, reclaimed)
		if reclaimErr != nil {
			// Leave the checkpoint intact; do not drain more source bytes into a
			// window whose physical storage cannot be reclaimed.
			j.State, j.Error = "failed", "stream_storage_failed"
			delete(e.streamVerified, j.ID)
			delete(e.streamPrefixes, j.ID)
			delete(e.importHashes, j.ID)
		}
	}
	if errors.Is(err, backend.ErrGunshotStreamLost) && j.Streaming && j.State == "importing" {
		j.State, j.Error = "failed", "stream_reimport_required"
		delete(e.streamVerified, j.ID)
		delete(e.streamPrefixes, j.ID)
		delete(e.importHashes, j.ID)
	}
	if j.CancelRequested {
		j.State = "cancelled"
		delete(e.streamVerified, j.ID)
		delete(e.streamPrefixes, j.ID)
		delete(e.importHashes, j.ID)
	} else if j.Streaming && j.State == "importing" {
		j.StreamError = ""
		j.Next = time.Now().Unix() + 1
		if err != nil && ctx.Err() == nil {
			j.StreamError = "preupload_retry"
			j.Next += 14
		} else if err == nil && ack > snapshot.StreamUploaded {
			j.Next = 0
		}
	}
	if e.save() == nil && j.State == "cancelled" {
		_ = os.RemoveAll(e.jobDir(j.ID))
	}
}
