package service

import "time"

const MaxEmbeddedChunk = 8 << 20

// AppendEmbedded is reachable only through the in-process host ABI. Keep the
// same owner, offset, size, state and durability checks as JSON imports.
func (e *Engine) AppendEmbedded(id string, index int, offset int64, data []byte) bool {
	started := time.Now()
	e.mu.Lock()
	defer e.mu.Unlock()
	waited := time.Since(started)
	if e.fault || e.stopped || !validID(id) {
		return false
	}
	j := e.find(id)
	if j == nil || j.Owner != "googlephotos" {
		return false
	}
	started = time.Now()
	accepted := e.appendChunkLimit(j, Request{Index: index, Offset: offset, Data: data}, MaxEmbeddedChunk) == nil
	if j.Streaming {
		j.StreamAppendCalls++
		j.StreamAppendWaitNanos += waited.Nanoseconds()
		j.StreamAppendWorkNanos += time.Since(started).Nanoseconds()
		if accepted {
			j.StreamAppendBytes += int64(len(data))
		}
	}
	return accepted
}
