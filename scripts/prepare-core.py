#!/usr/bin/env python3
"""Project pinned upstream into a disposable build tree. Never modify the submodule."""
from pathlib import Path
import shutil
import subprocess
r = Path(__file__).resolve().parents[1]
u = r / 'GotohpCore/upstream'
rev = (r / 'GotohpCore/UPSTREAM_REVISION').read_text().strip()
assert subprocess.check_output(['git', '-C', str(u), 'rev-parse', 'HEAD'], text=True).strip() == rev, 'upstream revision mismatch'
d = r / '.build/upstream'
if d.exists(): shutil.rmtree(d)
d.mkdir(parents=True)
for name in ['backend', 'generated']:
    shutil.copytree(u / name, d / name)
shutil.copy2(u / 'LICENSE', d / 'LICENSE')
for path in (d / 'backend').glob('wails*.go'): path.unlink()
# Replace desktop configuration/ADB with the small iOS store adapter.
s = (u / 'backend/configmanager.go').read_text()
prefs = s[s.index('type Preferences struct {'):s.index('// Config is the on-disk')]
(d / 'backend/configmanager.go').write_text((r / 'GotohpCore/config_ios.go.txt').read_text().replace('// UPSTREAM_PREFERENCES', prefs).replace('// UPSTREAM_SETTERS', s[s.index('func (g *ConfigManager) SetProxy'):s.index('func (g *ConfigManager) AddCredentials')]))
(d / 'backend/config_migration_test.go').unlink()
# Upstream dereferences a nil TLSClientConfig on an ordinary Go transport.
# Exact replacement fails closed when upstream changes this section.
p = d / 'backend/httpclient.go'
s = p.read_text()
old = 'transport.TLSClientConfig.InsecureSkipVerify = false'
assert s.count(old) == 1, 'review upstream HTTP transport changes'
s = s.replace('"compress/gzip"', '"compress/gzip"\n "crypto/tls"')
s = s.replace(old, 'if transport.TLSClientConfig == nil { transport.TLSClientConfig = &tls.Config{MinVersion: tls.VersionTLS12} }\n\t' + old)
s = s.replace('transport.TLSClientConfig.InsecureSkipVerify = true', 'transport.TLSClientConfig.InsecureSkipVerify = false')
s = s.replace('Timeout:   0,', 'Timeout:   6 * time.Hour,')
p.write_text(s)
(d / 'go.mod').write_text('module app\n\ngo 1.26.0\n\nrequire (\n github.com/tink-crypto/tink-go/v2 v2.8.0\n google.golang.org/protobuf v1.36.12\n)\n')
shutil.copy2(u / 'go.sum', d / 'go.sum')
shutil.copy2(r / 'GotohpCore/facade.go.txt', d / 'backend/gunshot_facade.go')
# A failed remote hash lookup must not silently cause a duplicate after restart.
p = d / 'backend/upload.go'
s = p.read_text()
start = s.index('\t\tif err != nil {\n\t\t\t// Non-fatal:')
end = s.index('\n\t\tif len(mediakey)', start)
s = s[:start] + '\t\tif err != nil { return "", fmt.Errorf("remote duplicate check failed: %w", err) }' + s[end:]
p.write_text(s)

# Same persistence assertions, using the iOS JSON store rather than desktop YAML.
p = d / 'backend/googleauth_test.go'
s = p.read_text().replace('"proxy: %s"', '`"proxy":"%s"`').replace('"upload_threads: %d"', '`"uploadThreads":%d`')
p.write_text(s)

# iOS session tokens stay in the host. Refresh is delegated to its SSO authorizer.
shutil.copy2(r / 'GotohpCore/native_auth.go.txt', d / 'backend/gunshot_native_auth.go')
shutil.copy2(r / 'tests/native_auth_test.go.txt', d / 'backend/gunshot_native_auth_test.go')
p = d / 'backend/api.go'
s = p.read_text()
needle = 'func (a *Api) BearerToken() (string, error) {'
assert s.count(needle) == 1, 'review upstream bearer-token entry point'
s = s.replace(needle, needle + '\n if token, native, err := gunshotNativeBearer(a.authData); native { return token, err }')
start = s.index('func (a *Api) commitSerialized(')
end = s.index('func (a *Api) doCommitRequest(', start)
commit = s[start:end]
assert commit.count('time.Sleep(delay)') == 1
commit = commit.replace('time.Sleep(delay)', 'if err := gunshotCommitWait(a, delay); err != nil { return "", err }')
commit = commit.replace('for attempt := 0; attempt <= retryConfig.MaxRetries; attempt++ {', 'for attempt := 0; attempt <= retryConfig.MaxRetries; attempt++ {\n if err := gunshotCommitWait(a, 0); err != nil { return "", err }')
s = s[:start] + commit + s[end:]
p.write_text(s)
shutil.copy2(r / 'tests/quality_wire_test.go.txt', d / 'backend/gunshot_quality_wire_test.go')

shutil.copy2(r / 'tests/context_transport_test.go.txt', d / 'backend/gunshot_context_transport_test.go')

shutil.copy2(r / 'GotohpCore/resumable_upload.go.txt', d / 'backend/gunshot_resumable_upload.go')
shutil.copy2(r / 'tests/resumable_upload_test.go.txt', d / 'backend/gunshot_resumable_upload_test.go')
p = d / 'backend/api.go'
s = p.read_text()
needle = 'func (a *Api) UploadFileWithProgress('
assert s.count(needle) == 1
s = s.replace(needle, 'func (a *Api) gunshotUploadFileLegacy(')
p.write_text(s)
p = d / 'backend/upload.go'
s = p.read_text()
needle = 'api.GetUploadToken(sha1_hash_b64, fileSize)'
assert s.count(needle) == 1
s = s.replace(needle, 'api.gunshotGetUploadTokenForFile(ctx, filePath, sha1_hash_b64, fileSize)')
p.write_text(s)
