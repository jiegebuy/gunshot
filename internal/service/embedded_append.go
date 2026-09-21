package service

const MaxEmbeddedChunk = 1 << 20

// AppendEmbedded is reachable only through the in-process host ABI. Keep the
// same owner, offset, size, state and durability checks as JSON imports.
func (e *Engine) AppendEmbedded(id string, index int, offset int64, data []byte) bool {
	e.mu.Lock()
	defer e.mu.Unlock()
	if e.fault || e.stopped || !validID(id) {
		return false
	}
	j := e.find(id)
	if j == nil || j.Owner != "googlephotos" {
		return false
	}
	return e.appendChunkLimit(j, Request{Index: index, Offset: offset, Data: data}, MaxEmbeddedChunk) == nil
}
