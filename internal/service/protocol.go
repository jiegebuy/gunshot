package service

import (
	"encoding/json"
	"errors"
	"os"
	"syscall"
	"time"
)

// recordLock accumulates engine-lock wait and hold time per IPC op. Ops are
// from roleAllowed's fixed set. Caller holds e.mu.
func (e *Engine) recordLock(op string, wait, hold time.Duration) {
	if e.lockStats == nil {
		e.lockStats = map[string]*lockStat{}
	}
	s := e.lockStats[op]
	if s == nil {
		s = &lockStat{}
		e.lockStats[op] = s
	}
	s.count++
	s.waitNs += int64(wait)
	s.holdNs += int64(hold)
}

// lockSnapshot reports lock contention and state persistence cost in ms.
// Caller holds e.mu.
func (e *Engine) lockSnapshot() map[string]any {
	ops := map[string]any{}
	for op, s := range e.lockStats {
		ops[op] = map[string]int64{"count": s.count, "waitMs": s.waitNs / 1e6, "holdMs": s.holdNs / 1e6}
	}
	var errno syscall.Errno
	errors.As(e.storageError, &errno)
	return map[string]any{"ops": ops, "saves": e.saveStat.count, "saveMs": e.saveStat.holdNs / 1e6, "jobs": len(e.state.Jobs), "storageFault": e.fault, "lastStorageError": storageErrorCode(e.storageError), "storageErrno": int(errno)}
}

// Native code supplies identity from the kernel audit trailer, never JSON.
func roleAllowed(role, op string) bool {
	if role == "daemon" {
		return op == "conditions"
	}
	common := op == "import_capacity" || op == "upload_summary" || op == "job" || op == "ping" || op == "list" || op == "accounts" || op == "options" || op == "retry" || op == "cancel" || op == "clear_completed" || op == "retry_failed"
	if (role == "photos" || role == "googlephotos") && (op == "source_lookup" || op == "stream_window") {
		return true
	}
	if role == "settings" || role == "googlephotos" {
		return common || (role == "googlephotos" && (op == "begin" || op == "append" || op == "seal" || op == "stream_suspend" || op == "account_native" || op == "native_bearer" || op == "native_bearer_clear")) || op == "configure" || op == "account_add" || op == "account_remove" || op == "account_select"
	}
	if role == "photos" {
		return common || op == "begin" || op == "append" || op == "seal" || op == "stream_suspend"
	}
	return false
}
func (e *Engine) HandleJSON(b []byte, role string) []byte {
	if len(b) > MaxMessage {
		return response(nil, errRequest)
	}
	var r Request
	if json.Unmarshal(b, &r) != nil || !roleAllowed(role, r.Op) {
		return response(nil, errors.New("unauthorized or invalid request"))
	}
	waited := time.Now()
	e.mu.Lock()
	defer e.mu.Unlock()
	held := time.Now()
	defer func() { e.recordLock(r.Op, held.Sub(waited), time.Since(held)) }()
	if e.fault && r.Op != "upload_summary" && r.Op != "list" && r.Op != "options" && r.Op != "ping" && r.Op != "conditions" && r.Op != "accounts" && r.Op != "source_lookup" && r.Op != "import_capacity" {
		return response(nil, errStorageFault)
	}
	data, err := e.handle(r, role)
	return response(data, err)
}
func response(data any, err error) []byte {
	var v any
	if err != nil {
		code := "operation_failed"
		switch {
		case errors.Is(err, errRequest):
			code = "invalid_request"
		case errors.Is(err, errStorageFault):
			code = "storage_fault"
		case errors.Is(err, syscall.ENOSPC):
			code = "storage_full"
		case errors.Is(err, os.ErrPermission):
			code = "storage_permission"
		case errors.Is(err, os.ErrNotExist):
			code = "storage_missing"
		}
		v = map[string]any{"ok": false, "error": code}
	} else {
		v = map[string]any{"ok": true, "data": data}
	}
	b, _ := json.Marshal(v)
	if len(b) > MaxMessage {
		return []byte(`{"ok":false,"error":"response_too_large"}`)
	}
	return b
}
func (e *Engine) handle(r Request, role string) (any, error) {
	switch r.Op {
	case "ping":
		return map[string]any{"version": 1, "streamingImport": e.preuploader != nil}, nil
	case "options":
		return e.state.Options, nil
	case "upload_summary":
		return e.uploadSummary(), nil
	case "import_capacity":
		return e.importCapacity(), nil
	case "conditions":
		e.online = r.Online
		e.wifi = r.WiFi
		e.charging = r.Charging
		if !e.online || (e.state.Options.WiFiOnly && !e.wifi) || (e.state.Options.ChargingOnly && !e.charging) {
			for _, c := range e.active {
				c()
			}
		}
		return nil, nil
	case "configure":
		if r.Options == nil || !r.Options.valid() {
			return nil, errRequest
		}
		changed := e.state.Options != *r.Options
		e.state.Options = *r.Options
		if r.Options.Paused || (r.Options.WiFiOnly && !e.wifi) || (r.Options.ChargingOnly && !e.charging) {
			for _, c := range e.active {
				c()
			}
		}
		if !changed {
			return nil, nil
		}
		return nil, e.save()
	case "list":
		start := r.Cursor
		if start < 0 || start > len(e.state.Jobs) {
			return nil, errRequest
		}
		end := min(start+25, len(e.state.Jobs))
		next := -1
		if end < len(e.state.Jobs) {
			next = end
		}
		return map[string]any{"jobs": e.state.Jobs[start:end], "next": next, "online": e.online, "wifi": e.wifi, "charging": e.charging}, nil
	case "accounts", "account_native", "native_bearer", "native_bearer_clear", "account_add", "account_remove", "account_select":
		return e.accounts(r)
	case "source_lookup":
		if !accountExists(r.Account) || !validQuality(r.Quality) {
			return nil, errRequest
		}
		j, err := e.findSource(r.Account, r.Quality, r.SourceID)
		if err != nil {
			return nil, err
		}
		if j != nil {
			return map[string]any{"found": true, "id": j.ID, "state": j.State, "retryable": retryableFailure(j), "resumeImport": j.State == "failed" && ((j.Streaming && j.Error == "import_interrupted") || j.Error == "stream_reimport_required")}, nil
		}
		receipt, err := e.findSourceReceipt(r.Account, r.Quality, r.SourceID)
		if err != nil {
			return nil, err
		}
		if receipt != nil {
			return map[string]any{"found": true, "id": receipt.ID, "state": "completed", "retryable": false, "receipt": true}, nil
		}
		return map[string]any{"found": false}, nil
	case "begin":
		if !accountExists(r.Account) {
			return nil, errRequest
		}
		return e.begin(r, role)
	case "clear_completed":
		next := e.state.Jobs[:0]
		for _, j := range e.state.Jobs {
			if e.historyRemovable(j) {
				delete(e.jobsByID, j.ID)
			} else {
				next = append(next, j)
			}
		}
		if len(next) == len(e.state.Jobs) {
			return nil, nil
		}
		clear(e.state.Jobs[len(next):]) // Release removed jobs held by the backing array.
		e.state.Jobs = next
		return nil, e.save()
	case "retry_failed":
		changed := false
		for _, j := range e.state.Jobs {
			// A lost commit response may already have created the remote item.
			// Bulk retrying that state is a duplicate-upload hazard.
			if retryableFailure(j) {
				j.resetRetry()
				changed = true
			}
		}
		if !changed {
			return nil, nil
		}
		return nil, e.save()
	}
	if !validID(r.ID) {
		return nil, errRequest
	}
	j := e.find(r.ID)
	if j == nil {
		if r.Op == "job" {
			if receipt, ok := e.receiptsByID[r.ID]; ok {
				return map[string]any{"id": receipt.ID, "state": "completed", "mediaKey": receipt.MediaKey, "uploaded": 0, "total": 0}, nil
			}
			if receipt, ok := e.fingerprintReceiptsByID[r.ID]; ok {
				return map[string]any{"id": receipt.ID, "state": "completed", "mediaKey": receipt.MediaKey, "uploaded": 0, "total": 0}, nil
			}
		}
		return nil, errRequest
	}
	if (r.Op == "append" || r.Op == "seal" || r.Op == "stream_suspend" || r.Op == "stream_window") && j.Owner != role {
		return nil, errRequest
	}
	switch r.Op {
	case "stream_window":
		return e.streamWindow(j)
	case "job":
		return j, nil
	case "append":
		return nil, e.appendChunk(j, r)
	case "seal":
		if j.Streaming && r.CloudAtFirstData != nil {
			if *r.CloudAtFirstData < 0 || *r.CloudAtFirstData > 1000 {
				return nil, errRequest
			}
			j.StreamCloudAtFirstData = r.CloudAtFirstData
		}
		return e.seal(j)
	case "stream_suspend":
		return nil, e.suspendStream(j)
	case "cancel":
		if j.State == "completed" || j.State == "cancelled" {
			return nil, errRequest
		}
		j.CancelRequested = true
		if c := e.active[j.ID]; c != nil {
			c()
		} else {
			j.State = "cancelled"
			delete(e.importHashes, j.ID)
			delete(e.streamVerified, j.ID)
			delete(e.streamPrefixes, j.ID)
		}
		err := e.save()
		if err == nil && j.State == "cancelled" {
			_ = os.RemoveAll(e.jobDir(j.ID))
		}
		return nil, err
	case "retry":
		if !retryableFailure(j) {
			return nil, errRequest
		}
		j.resetRetry()
		return nil, e.save()
	}
	return nil, errRequest
}
