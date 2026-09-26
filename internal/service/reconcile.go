package service

import (
	"context"
	"crypto/sha1"
	"encoding/hex"
	"io"
	"os"
	"path/filepath"
)

func uncertainCommit(j *Job) bool {
	return j.State == "failed" && (j.Error == "commit_outcome_unknown" || j.Error == "commit_timeout_unknown")
}

func (e *Engine) reconcileCommit(ctx context.Context, snapshot Job, cancel context.CancelFunc) {
	defer e.wg.Done()
	defer cancel()
	digest, err := hex.DecodeString(snapshot.ContentSHA1)
	if err != nil || len(digest) != sha1.Size {
		digest = nil
		f, openErr := os.Open(filepath.Join(e.jobDir(snapshot.ID), snapshot.Resources[0].Name))
		err = openErr
		if err == nil {
			h := sha1.New()
			buf := make([]byte, 1<<20)
			for {
				if err = ctx.Err(); err != nil {
					break
				}
				var n int
				n, err = f.Read(buf)
				if n > 0 {
					h.Write(buf[:n])
				}
				if err == io.EOF {
					err = nil
					digest = h.Sum(nil)
					break
				}
				if err != nil {
					break
				}
			}
			f.Close()
		}
	}
	key := ""
	if err == nil && len(digest) == sha1.Size {
		key, err = e.reconciler(ctx, snapshot.Account, digest)
	}
	e.mu.Lock()
	defer e.mu.Unlock()
	delete(e.active, snapshot.ID)
	j := e.find(snapshot.ID)
	if j == nil || !uncertainCommit(j) {
		return
	}
	if len(digest) == sha1.Size {
		j.ContentSHA1 = hex.EncodeToString(digest)
	}
	if j.CancelRequested {
		j.State = "cancelled"
		j.Error = ""
	} else if err == nil && key != "" {
		j.State = "completed"
		j.Error = ""
		j.MediaKey = key
		j.Uploaded = j.Total
		e.state.CompletionRevision++
		_ = e.recordSourceReceipt(j)
		_ = e.recordFingerprintReceipt(j)
	}
	if e.save() == nil && (j.State == "completed" || j.State == "cancelled") {
		_ = os.RemoveAll(e.jobDir(j.ID))
	}
}
