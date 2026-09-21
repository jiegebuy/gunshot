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
	return validQuality(o.Quality) && o.Concurrent >= 1 && o.Concurrent <= 4 && o.Retries >= 0 && o.Retries <= 10
}
func validQuality(q string) bool { return q == "original" || q == "saver" || q == "quota" }

type Job struct {
	OriginalPolicy  int        `json:"originalPolicy,omitempty"` // 1: original bytes sent without legacy remote-hash shortcut.
	ID              string     `json:"id"`
	Account         string     `json:"account"`
	Quality         string     `json:"quality"`
	State           string     `json:"state"`
	Resources       []Resource `json:"resources"`
	Created         int64      `json:"created"`
	Timestamp       int64      `json:"timestamp"`
	Fingerprint     string     `json:"fingerprint,omitempty"`
	SourceKey       string     `json:"sourceKey,omitempty"` // Hashed account/quality/source identity; raw PhotoKit ID is never persisted.
	Attempts        int        `json:"attempts"`
	Next            int64      `json:"next,omitempty"`
	Uploaded        int64      `json:"uploaded"`
	Total           int64      `json:"total"`
	Error           string     `json:"error,omitempty"`
	MediaKey        string     `json:"mediaKey,omitempty"`
	CancelRequested bool       `json:"cancelRequested,omitempty"`
	Owner           string     `json:"owner"`
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
	NativeID  string     `json:"nativeID,omitempty"`
	SourceID  string     `json:"sourceID,omitempty"`
	Op        string     `json:"op"`
	ID        string     `json:"id,omitempty"`
	Account   string     `json:"account,omitempty"`
	Secret    string     `json:"secret,omitempty"`
	Quality   string     `json:"quality,omitempty"`
	Resources []Resource `json:"resources,omitempty"`
	Index     int        `json:"index,omitempty"`
	Offset    int64      `json:"offset,omitempty"`
	Data      []byte     `json:"data,omitempty"`
	Timestamp int64      `json:"timestamp,omitempty"`
	Options   *Options   `json:"options,omitempty"`
	Cursor    int        `json:"cursor,omitempty"`
	Online    bool       `json:"online,omitempty"`
	WiFi      bool       `json:"wifi,omitempty"`
	Charging  bool       `json:"charging,omitempty"`
}
type Progress struct {
	State           string
	Uploaded, Total int64
}
type Runner func(context.Context, []string, string, string, func(Progress)) (string, error)
type Engine struct {
	nativeRelay             *nativeRelay
	importHashes            map[string][]hash.Hash
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
	online, wifi, charging  bool
	stopped                 bool
	wg                      sync.WaitGroup
	fault                   bool
}

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
	en := &Engine{root: root, state: s, jobsByID: make(map[string]*Job, len(s.Jobs)), sourceReceipts: receipts, receiptsByID: receiptsByID, fingerprintReceipts: fingerprintReceipts, fingerprintReceiptsByID: fingerprintReceiptsByID, active: map[string]context.CancelFunc{}, importHashes: map[string][]hash.Hash{}, runner: runner}
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
			j.Error = "import_interrupted"
		}
		if j.CancelRequested && j.State == "pending" {
			j.State = "cancelled"
		}
		if j.State == "cancelled" || j.State == "completed" {
			_ = os.RemoveAll(en.jobDir(j.ID))
		}
	}
	if e = en.save(); e != nil {
		return nil, e
	}
	return en, nil
}
func (e *Engine) save() error {
	err := atomicJSON(filepath.Join(e.root, "state.json"), e.state)
	if err != nil {
		e.fault = true
	}
	return err
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
		}
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
		seen[j.ID] = true
		names := map[string]bool{}
		var total int64
		for _, r := range j.Resources {
			if !safeName(r.Name) || names[r.Name] || r.Size <= 0 || r.Size > 100<<30 {
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
