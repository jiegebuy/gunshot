package service

import (
	"app/backend"
	"bytes"
	"encoding"
	"encoding/json"
	"errors"
	"hash"
	"os"
	"path/filepath"
)

// Opaque immutable resource signatures come from the owned CloudAssets reader,
// not filenames/PhotoKit UUIDs alone. Hash state stays in the private job folder.
type streamSourceCheckpoint struct {
	Version   int    `json:"version"`
	Source    string `json:"source"`
	SourceKey string `json:"sourceKey"`
	Name      string `json:"name"`
	Size      int64  `json:"size"`
	Received  int64  `json:"received"`
	SHA256    []byte `json:"sha256"`
}

func validStreamSource(r Request) bool {
	if r.StreamSourceVersion == "" {
		return r.StreamSourceSize == 0
	}
	return validSHA256(r.StreamSourceVersion) && r.Streaming && r.StreamBounded && r.StreamSourceSize > 0 && r.StreamSourceSize <= 8<<30
}

func (e *Engine) checkpointRangeStream(j *Job) error {
	state, err := e.importHashes[j.ID][0].(encoding.BinaryMarshaler).MarshalBinary()
	if err != nil {
		return err
	}
	c := streamSourceCheckpoint{1, j.StreamSourceVersion, j.SourceKey, j.Resources[0].Name, j.StreamSourceSize, e.streamVerified[j.ID], state}
	return atomicJSON(filepath.Join(e.jobDir(j.ID), ".source.json"), c)
}

func (e *Engine) resumeRangeStream(j *Job, r Request) (any, error) {
	if e.active[j.ID] != nil {
		return nil, errRequest
	}
	if r.StreamSourceVersion != j.StreamSourceVersion || r.StreamSourceSize != j.StreamSourceSize {
		return nil, errors.New("stream original changed")
	}
	b, err := os.ReadFile(filepath.Join(e.jobDir(j.ID), ".source.json"))
	if err != nil {
		return nil, err
	}
	var c streamSourceCheckpoint
	if len(b) > 4096 || json.Unmarshal(b, &c) != nil || c.Version != 1 || c.Source != j.StreamSourceVersion || c.SourceKey != j.SourceKey || c.Name != j.Resources[0].Name || c.Size != j.StreamSourceSize || c.Received < 0 || c.Received > c.Size {
		return nil, backend.ErrGunshotStreamLost
	}
	path := filepath.Join(e.jobDir(j.ID), c.Name)
	h, floor, err := backend.GunshotStreamImportHash(path, c.Received)
	if err != nil {
		return nil, err
	}
	state, err := h.(encoding.BinaryMarshaler).MarshalBinary()
	if err != nil || floor < j.StreamReclaimed || !bytes.Equal(state, c.SHA256) {
		return nil, backend.ErrGunshotStreamLost
	}
	// An interrupted write can extend the file beyond the last durable source
	// checkpoint. No preupload snapshot can include such unacknowledged bytes.
	f, err := os.OpenFile(path, os.O_RDWR, 0600)
	if err != nil {
		return nil, err
	}
	err = f.Truncate(c.Received)
	if err == nil {
		err = f.Sync()
	}
	f.Close()
	if err != nil {
		return nil, err
	}
	j.Total, j.Resources[0].Size, j.StreamReclaimed = c.Received, c.Received, floor
	j.State, j.Error, j.Next, j.CancelRequested = "importing", "", 0, false
	e.streamVerified[j.ID] = c.Received
	delete(e.streamPrefixes, j.ID)
	e.importHashes[j.ID] = []hash.Hash{h}
	if err := e.save(); err != nil {
		return nil, err
	}
	e.signalWork()
	return map[string]any{"id": j.ID, "resumed": true, "resumeOffset": c.Received, "streamBounded": j.StreamBounded}, nil
}
