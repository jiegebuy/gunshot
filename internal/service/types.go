package service

import (
	"context"
	"encoding/json"
	"errors"
	"hash"
	"os"
	"path/filepath"
	"sync"
	"time"
)

const MaxMessage = 60000
const MaxChunk = 32768
const MaxJobs = 10000

type Resource struct {
	Name string `json:"name"`
	Size int64  `json:"size"`
}
type Options struct {
	Quality      string `json:"quality"`
	Concurrent   int    `json:"concurrent"`
	Retries      int    `json:"retries"`
	WiFiOnly     bool   `json:"wifiOnly"`
	ChargingOnly bool   `json:"chargingOnly"`
	Paused       bool   `json:"paused"`
}

func defaults() Options {
	return Options{Quality: "original", Concurrent: 1, Retries: 3, WiFiOnly: true}
}
func (o Options) valid() bool {
	return validQuality(o.Quality) && o.Concurrent >= 1 && o.Concurrent <= 8 && o.Retries >= 0 && o.Retries <= 10
}
func validQuality(q string) bool { return q == "original" || q == "saver" || q == "quota" }

type Job struct {
	StreamSourceVersion    string     `json:"streamSourceVersion,omitempty"`
	StreamSourceSize       int64      `json:"streamSourceSize,omitempty"`
	StreamBounded          bool       `json:"streamBounded,omitempty"`
	StreamReclaimed        int64      `json:"streamReclaimed,omitempty"`
	StreamCloudAtFirstData *int       `json:"streamCloudAtFirstData,omitempty"`
	StreamUploaded         int64      `json:"streamUploaded,omitempty"`
	StreamBeforeSeal       int64      `json:"streamBeforeSeal,omitempty"`
	StreamFirstAck         int64      `json:"streamFirstAck,omitempty"`
	StreamAppendCalls      int64      `json:"streamAppendCalls,omitempty"`
	StreamAppendBytes      int64      `json:"streamAppendBytes,omitempty"`
	StreamAppendWaitNanos  int64      `json:"streamAppendWaitNanos,omitempty"`
	StreamAppendWorkNanos  int64      `json:"streamAppendWorkNanos,omitempty"`
	ImportFinished         int64      `json:"importFinished,omitempty"`
	StreamError            string     `json:"streamError,omitempty"`
	Streaming              bool       `json:"streaming,omitempty"`      // A single growing PhotoKit resource, not yet sealed.
	OriginalPolicy         int        `json:"originalPolicy,omitempty"` // 1: original bytes sent without legacy remote-hash shortcut.
	ID                     string     `json:"id"`
	Account                string     `json:"account"`
	Quality                string     `json:"quality"`
	State                  string     `json:"state"`
	CommitStarted          int64      `json:"commitStarted,omitempty"`
	ProgressUpdated        int64      `json:"progressUpdated,omitempty"`
	ContentSHA1            string     `json:"contentSHA1,omitempty"`
	Resources              []Resource `json:"resources"`
	Created                int64      `json:"created"`
	Timestamp              int64      `json:"timestamp"`
	Fingerprint            string     `json:"fingerprint,omitempty"`
	SourceKey              string     `json:"sourceKey,omitempty"` // Hashed account/quality/source identity; raw PhotoKit ID is never persisted.
	Attempts               int        `json:"attempts"`
	Next                   int64      `json:"next,omitempty"`
	Uploaded               int64      `json:"uploaded"`
	Total                  int64      `json:"total"`
	Error                  string     `json:"error,omitempty"`
	MediaKey               string     `json:"mediaKey,omitempty"`
	CancelRequested        bool       `json:"cancelRequested,omitempty"`
	Owner                  string     `json:"owner"`
}
type State struct {
	CompletionRevision uint64  `json:"completionRevision,omitempty"`
	Version            int     `json:"version"`
	Options            Options `json:"options"`
	Jobs               []*Job  `json:"jobs"`
}
type SourceReceipt struct {
	SourceKey      string `json:"sourceKey"`
	ID             string `json:"id"`
	MediaKey       string `json:"mediaKey"`
	OriginalPolicy int    `json:"originalPolicy,omitempty"`
	Completed      int64  `json:"completed"`
}
type FingerprintReceipt struct {
	Fingerprint    string `json:"fingerprint"`
	ID             string `json:"id"`
	MediaKey       string `json:"mediaKey"`
	OriginalPolicy int    `json:"originalPolicy,omitempty"`
	Completed      int64  `json:"completed"`
}
type Request struct {
	StreamSourceVersion string     `json:"streamSourceVersion,omitempty"`
	StreamSourceSize    int64      `json:"streamSourceSize,omitempty"`
	StreamBounded       bool       `json:"streamBounded,omitempty"`
	CloudAtFirstData    *int       `json:"cloudAtFirstData,omitempty"`
	Streaming           bool       `json:"streaming,omitempty"`
	NativeID            string     `json:"nativeID,omitempty"`
	SourceID            string     `json:"sourceID,omitempty"`
	Op                  string     `json:"op"`
	ID                  string     `json:"id,omitempty"`
	Account             string     `json:"account,omitempty"`
	Secret              string     `json:"secret,omitempty"`
	Quality             string     `json:"quality,omitempty"`
	Resources           []Resource `json:"resources,omitempty"`
	Index               int        `json:"index,omitempty"`
	Offset              int64      `json:"offset,omitempty"`
	Data                []byte     `json:"data,omitempty"`
	Timestamp           int64      `json:"timestamp,omitempty"`
	Options             *Options   `json:"options,omitempty"`
	Cursor              int        `json:"cursor,omitempty"`
	Online              bool       `json:"online,omitempty"`
	WiFi                bool       `json:"wifi,omitempty"`
	Charging            bool       `json:"charging,omitempty"`
}
type Progress struct {
	State           string
	Uploaded, Total int64
}
type Runner func(context.Context, []string, string, string, func(Progress)) (string, error)
type Engine struct {
	nativeRelay             *nativeRelay
	importHashes            map[string][]hash.Hash
	streamVerified          map[string]int64 // Bytes replayed/verified in this producer invocation.
	streamPrefixes          map[string]streamPrefix
	preuploader             func(context.Context, string, string, string, int64) (int64, error)
	mu                      sync.Mutex
	root                    string
	state                   State
	jobsByID                map[string]*Job // Derived index; guarded by mu, never persisted.
	sourceReceipts          map[string]SourceReceipt
	receiptsByID            map[string]SourceReceipt
	fingerprintReceipts     map[string]FingerprintReceipt
	fingerprintReceiptsByID map[string]FingerprintReceipt
	active                  map[string]context.CancelFunc
	runner                  Runner
	reconciler              func(context.Context, string, []byte) (string, error)
	online, wifi, charging  bool
	stopped                 bool
	wg                      sync.WaitGroup
	fault                   bool
	storageError            error
	storageRetry            time.Time
	commitTimeout           time.Duration // zero uses the production five-minute limit
	uploadIdleTimeout       time.Duration // zero uses two minutes without byte progress
	smallJobBurst           int
	wake                    chan struct{}
	terminalSwept           time.Time            // last sweep of terminal job directories
	lockStats               map[string]*lockStat // per-op engine lock wait/hold; guarded by mu
	saveStat                lockStat
}

type lockStat struct{ count, waitNs, holdNs, bytes int64 }

// Finished rows kept for the queue view. Older ones remain only as durable
// source/fingerprint receipts, which is all deduplication needs. Without a
// bound the state file grew by one row per photo (2 MB at 3,500 rows) and was
// rewritten with fsync on every job transition under the engine lock, and a
// large album would reach MaxJobs and reject new photos.
const terminalHistory = 300

var errRequest = errors.New("invalid request")

func atomicJSON(path string, v any) error {
	b, e := json.Marshal(v)
	if e != nil {
		return e
	}
	d := filepath.Dir(path)
	f, e := os.CreateTemp(d, ".write-*")
	if e != nil {
		return e
	}
	defer os.Remove(f.Name())
	if _, e = f.Write(b); e == nil {
		e = f.Sync()
	}
	ce := f.Close()
	if e != nil {
		return e
	}
	if ce != nil {
		return ce
	}
	if e = os.Rename(f.Name(), path); e != nil {
		return e
	}
	df, e := os.Open(d)
	if e != nil {
		return e
	}
	defer df.Close()
	return df.Sync()
}
func Open(root string, runner Runner) (*Engine, error) {
	if e := os.MkdirAll(filepath.Join(root, "media"), 0700); e != nil {
		return nil, e
	}
	if e := os.Chmod(root, 0700); e != nil {
		return nil, e
	}
	s := State{Version: 1, Options: defaults(), Jobs: []*Job{}}
	b, e := os.ReadFile(filepath.Join(root, "state.json"))
	if e == nil {
		// Defaults belong only to a new store, not a damaged persisted state.
		s = State{}
		if json.Unmarshal(b, &s) != nil || s.Version != 1 || !s.Options.valid() {
			return nil, errors.New("invalid state; restore backup")
		}
	} else if !os.IsNotExist(e) {
		return nil, e
	}
	if err := validateState(s); err != nil {
		return nil, err
	}
	receipts, receiptsByID, err := loadSourceReceipts(root)
	if err != nil {
		return nil, err
	}
	fingerprintReceipts, fingerprintReceiptsByID, err := loadFingerprintReceipts(root)
	if err != nil {
		return nil, err
	}
	if err := bootstrapFingerprintReceipts(root, fingerprintReceipts, fingerprintReceiptsByID, s.Jobs); err != nil {
		return nil, err
	}
	en := &Engine{root: root, state: s, jobsByID: make(map[string]*Job, len(s.Jobs)), sourceReceipts: receipts, receiptsByID: receiptsByID, fingerprintReceipts: fingerprintReceipts, fingerprintReceiptsByID: fingerprintReceiptsByID, active: map[string]context.CancelFunc{}, importHashes: map[string][]hash.Hash{}, runner: runner, wake: make(chan struct{}, 1)}
	en.streamVerified = make(map[string]int64)
	en.streamPrefixes = make(map[string]streamPrefix)
	for _, j := range s.Jobs {
		en.jobsByID[j.ID] = j
		switch j.State {
		case "uploading", "preparing":
			j.State = "pending"
		case "committing":
			j.State = "failed"
			j.Error = "commit_outcome_unknown"
		case "importing":
			j.State = "cancelled"
			if j.Streaming {
				j.State = "failed"
			}
			j.Error = "import_interrupted"
		case "failed":
			// Upgrade older stalled workers into resumable retries without
			// resetting the retry budget or replaying an uncertain commit.
			if j.Error == "upload_stalled" && j.Attempts <= s.Options.Retries && !j.CancelRequested {
				paths := make([]string, 0, len(j.Resources))
				for _, resource := range j.Resources {
					paths = append(paths, filepath.Join(en.jobDir(j.ID), resource.Name))
				}
				if resumablePaths(paths) {
					j.State = "pending"
					j.Error = "upload_resuming"
					j.Next = 0
				}
			}
		}
		if j.CancelRequested && j.State == "pending" {
			j.State = "cancelled"
		}
		if j.State == "cancelled" || j.State == "completed" {
			_ = os.RemoveAll(en.jobDir(j.ID))
		}
	}
	en.compactHistory()
	if e = en.save(); e != nil {
		return nil, e
	}
	return en, nil
}
func (e *Engine) save() error {
	started := time.Now()
	err := atomicJSON(filepath.Join(e.root, "state.json"), e.state)
	e.saveStat.count++
	e.saveStat.holdNs += int64(time.Since(started))
	if err != nil {
		if !e.fault {
			e.storageError = err
		}
		e.fault = true
		for _, cancel := range e.active {
			cancel()
		}
	}
	return err
}

// historyRemovable reports whether a finished row can leave the state file
// without losing deduplication evidence. Caller holds e.mu.
func (e *Engine) historyRemovable(j *Job) bool {
	if e.active[j.ID] != nil {
		return false
	}
	switch j.State {
	case "cancelled":
		return true
	case "completed":
		// Source-backed rows retain the early PhotoKit lookup; legacy rows
		// retain their content fingerprint.
		if j.SourceKey != "" {
			_, ok := e.sourceReceipts[j.SourceKey]
			return ok
		}
		_, ok := e.fingerprintReceipts[j.Fingerprint]
		return ok
	}
	return false
}

// compactHistory drops the oldest removable finished rows beyond
// terminalHistory. Caller holds e.mu and saves afterwards.
func (e *Engine) compactHistory() {
	terminal := 0
	for _, j := range e.state.Jobs {
		if j.State == "completed" || j.State == "cancelled" {
			terminal++
		}
	}
	excess := terminal - terminalHistory
	if excess <= 0 {
		return
	}
	next := e.state.Jobs[:0]
	for _, j := range e.state.Jobs { // Oldest first: rows are appended at begin.
		if excess > 0 && e.historyRemovable(j) {
			delete(e.jobsByID, j.ID)
			excess--
			continue
		}
		next = append(next, j)
	}
	clear(e.state.Jobs[len(next):]) // Release removed jobs held by the backing array.
	e.state.Jobs = next
}
func (e *Engine) jobDir(id string) string { return filepath.Join(e.root, "media", id) }
func (e *Engine) find(id string) *Job     { return e.jobsByID[id] }
func (e *Engine) Close() {
	e.mu.Lock()
	e.stopped = true
	for _, c := range e.active {
		c()
	}
	e.mu.Unlock()
	e.wg.Wait()
}
func (e *Engine) Run(ctx context.Context) {
	t := time.NewTicker(time.Second)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			e.Close()
			return
		case <-t.C:
			e.Tick()
		case <-e.wake:
			e.Tick()
		}
	}
}

// Coalesce queue changes. The timer remains for delayed retries, but a sealed
// photo or newly freed slot need not sit idle until the next one-second tick.
func (e *Engine) signalWork() {
	select {
	case e.wake <- struct{}{}:
	default:
	}
}

func validateState(s State) error {
	if len(s.Jobs) > MaxJobs {
		return errors.New("too many persisted jobs")
	}
	seen := map[string]bool{}
	states := map[string]bool{"importing": true, "pending": true, "preparing": true, "uploading": true, "committing": true, "completed": true, "failed": true, "cancelled": true}
	for _, j := range s.Jobs {
		if j == nil || !validID(j.ID) || seen[j.ID] || !states[j.State] || !validQuality(j.Quality) || j.Account == "" || len(j.Resources) < 1 || len(j.Resources) > 2 || j.Attempts < 0 || (j.SourceKey != "" && !validSHA256(j.SourceKey)) {
			return errors.New("invalid persisted job")
		}
		if j.Owner != "photos" && j.Owner != "googlephotos" {
			return errors.New("invalid job owner")
		}
		if (j.StreamSourceVersion == "" && j.StreamSourceSize != 0) || (j.StreamSourceVersion != "" && (!validSHA256(j.StreamSourceVersion) || j.StreamSourceSize <= 0 || j.StreamSourceSize > 8<<30 || j.Total > j.StreamSourceSize || !j.StreamBounded || len(j.Resources) != 1)) {
			return errors.New("invalid range source")
		}
		if j.Streaming && (len(j.Resources) != 1 || j.SourceKey == "" || (j.State != "importing" && j.State != "failed" && j.State != "cancelled")) {
			return errors.New("invalid streaming job")
		}
		if j.StreamReclaimed < 0 || j.StreamReclaimed > j.Total || (j.StreamReclaimed > 0 && (!j.StreamBounded || len(j.Resources) != 1)) {
			return errors.New("invalid stream window")
		}
		seen[j.ID] = true
		names := map[string]bool{}
		var total int64
		for _, r := range j.Resources {
			if !safeName(r.Name) || names[r.Name] || r.Size < 0 || (r.Size == 0 && !j.Streaming) || r.Size > 100<<30 {
				return errors.New("invalid persisted resource")
			}
			names[r.Name] = true
			total += r.Size
		}
		if j.Total != total {
			return errors.New("invalid persisted resource sizes")
		}
	}
	return nil
}
