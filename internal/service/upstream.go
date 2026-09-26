package service

import (
	"app/backend"
	"context"
	"errors"
	"path/filepath"
)

var errRemoteComponentExists = backend.ErrGunshotRemoteComponentExists

func Initialize(root string) (*Engine, error) {
	e, err := Open(root, upload)
	if err != nil {
		return nil, err
	}
	e.reconciler = backend.GunshotFindUploadedHash
	if err = backend.LoadConfig(filepath.Join(root, "credentials.json")); err != nil {
		return nil, err
	}
	return e, nil
}
func accountExists(email string) bool {
	for _, a := range (&backend.ConfigManager{}).GetAccounts().Accounts {
		if a.Email == email {
			return true
		}
	}
	return false
}
func (e *Engine) accounts(r Request) (any, error) {
	g := &backend.ConfigManager{}
	switch r.Op {
	case "accounts":
		a := g.GetAccounts()
		return map[string]any{"accounts": a.Accounts, "selected": a.Selected, "nativeAuthorization": e.nativeAuthorization(a.Selected)}, nil
	case "account_native":
		if e.nativeRelay != nil {
			if err := e.nativeRelay.put(r.NativeID, r.Secret); err != nil {
				return nil, err
			}
		}
		err := g.AddNativeAccount(r.Account, r.NativeID)
		if err != nil && e.nativeRelay != nil {
			e.nativeRelay.clear()
		}
		return nil, err
	case "native_bearer":
		if e.nativeRelay == nil || backend.GunshotNativeAccountID(r.Account) != r.NativeID || r.NativeID == "" {
			return nil, errRequest
		}
		return nil, e.nativeRelay.put(r.NativeID, r.Secret)
	case "native_bearer_clear":
		if e.nativeRelay == nil {
			return nil, errRequest
		}
		e.nativeRelay.clear()
		return nil, nil
	case "account_add":
		if len(r.Secret) == 0 || len(r.Secret) > 32768 {
			return nil, errRequest
		}
		var err error
		if backend.LooksLikeAuthString(r.Secret) {
			err = g.AddCredentials(r.Secret)
		} else {
			_, err = g.AddGoogleAccountWithProxy(r.Secret, "")
		}
		return nil, err
	case "account_select":
		return nil, g.SelectAccount(r.Account)
	case "account_remove":
		for _, j := range e.state.Jobs {
			if j.Account == r.Account && j.State != "completed" && j.State != "cancelled" {
				return nil, errors.New("cancel account jobs first")
			}
		}
		err := g.RemoveCredentials(r.Account)
		if err == nil && e.nativeRelay != nil {
			e.nativeRelay.clear()
		}
		return nil, err
	}
	return nil, errRequest
}

type reporter struct {
	backend.NopReporter
	callback func(Progress)
	uploaded int64
}

func (r *reporter) ThreadStatus(s backend.ThreadStatus) {
	phase := "preparing"
	switch s.Status {
	case "uploading":
		phase = "uploading"
	case "finalizing":
		phase = "committing"
	}
	// One reporter serves one work item. Upstream already aggregates Live Photo
	// components; phase-only notifications omit bytes and must preserve progress.
	if s.BytesTotal > 0 {
		r.uploaded = s.BytesUploaded
	}
	r.callback(Progress{State: phase, Uploaded: r.uploaded})
}
func upload(ctx context.Context, paths []string, account, quality string, cb func(Progress)) (string, error) {
	opts := backend.UploadOptions{Api: backend.ApiOptions{Account: account, Saver: quality == "saver", UseQuota: quality == "quota"}, Threads: 1, ForceUpload: quality == "original", PairLivePhotos: len(paths) == 2, SkipIncompleteLivePhotos: true}
	return backend.GunshotUpload(ctx, paths, opts, &reporter{callback: cb})
}
