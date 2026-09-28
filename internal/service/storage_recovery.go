package service

import (
	"errors"
	"os"
	"syscall"
	"time"
)

var errStorageFault = errors.New("queue persistence unavailable")

// Called with mu held. Never start network work until the complete state has
// been made durable again. Active runners first settle cancellation/commit.
func (e *Engine) recoverStorage(now time.Time) bool {
	if len(e.active) != 0 || now.Before(e.storageRetry) {
		return false
	}
	e.storageRetry = now.Add(5 * time.Second)
	for _, j := range e.state.Jobs {
		switch j.State {
		case "importing":
			// The importer received an error; its partial file cannot be uploaded.
			j.State, j.Error = "cancelled", "import_interrupted"
			delete(e.importHashes, j.ID)
		case "preparing", "uploading":
			j.State, j.Error = "pending", "storage_recovered"
		case "committing":
			// Preserve remote uncertainty: recovery must not duplicate a commit.
			j.State, j.Error = "failed", "commit_outcome_unknown"
		}
	}
	if e.save() != nil {
		return false
	}
	e.fault = false
	return true
}

func storageErrorCode(err error) string {
	switch {
	case err == nil:
		return "none"
	case errors.Is(err, syscall.ENOSPC):
		return "storage_full"
	case errors.Is(err, os.ErrPermission):
		return "storage_permission"
	case errors.Is(err, os.ErrNotExist):
		return "storage_missing"
	case errors.Is(err, syscall.EIO):
		return "storage_io"
	case errors.Is(err, syscall.EINTR):
		return "storage_interrupted"
	default:
		return "storage_write_failed"
	}
}
