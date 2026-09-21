package service

import (
	"encoding/json"
	"errors"
	"os"
)

// Native code supplies identity from the kernel audit trailer, never JSON.
func roleAllowed(role, op string) bool {
	if role == "daemon" {
		return op == "conditions"
	}
	common := op == "import_capacity" || op == "upload_summary" || op == "job" || op == "ping" || op == "list" || op == "accounts" || op == "options" || op == "retry" || op == "cancel" || op == "clear_completed" || op == "retry_failed"
	if (role == "photos" || role == "googlephotos") && op == "source_lookup" {
		return true
	}
	if role == "settings" || role == "googlephotos" {
		return common || (role == "googlephotos" && (op == "begin" || op == "append" || op == "seal" || op == "account_native" || op == "native_bearer" || op == "native_bearer_clear")) || op == "configure" || op == "account_add" || op == "account_remove" || op == "account_select"
	}
	if role == "photos" {
		return common || op == "begin" || op == "append" || op == "seal"
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
	e.mu.Lock()
	defer e.mu.Unlock()
	if e.fault {
		return response(nil, errors.New("storage error; restart after checking free space"))
	}
	data, err := e.handle(r, role)
	return response(data, err)
}
func response(data any, err error) []byte {
	var v any
	if err != nil {
		v = map[string]any{"ok": false, "error": "operation_failed"}
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
		return map[string]any{"version": 1}, nil
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
			return map[string]any{"found": true, "id": j.ID, "state": j.State, "retryable": retryableFailure(j)}, nil
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
			if j.State == "completed" || j.State == "cancelled" {
				// Completed rows are removable only after the durable dedup evidence
				// needed for their generation exists. Source-backed rows retain the
				// early PhotoKit lookup; legacy rows retain their content fingerprint.
				if j.State == "completed" {
					if j.SourceKey != "" {
						if _, ok := e.sourceReceipts[j.SourceKey]; !ok {
							next = append(next, j)
							continue
						}
					} else if _, ok := e.fingerprintReceipts[j.Fingerprint]; !ok {
						next = append(next, j)
						continue
					}
				}
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
	if (r.Op == "append" || r.Op == "seal") && j.Owner != role {
		return nil, errRequest
	}
	switch r.Op {
	case "job":
		return j, nil
	case "append":
		return nil, e.appendChunk(j, r)
	case "seal":
		return e.seal(j)
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
