"""Add the companion visual activity bundles to an unsigned host IPA.

Run before signing the IPA. No app group or network access is needed: ActivityKit
transports the bounded content state directly from the host to WidgetKit.
"""
import argparse
from pathlib import Path
import plistlib
import zipfile


def bundle_entries(assets, host):
    assets = Path(assets)
    for folder, destination in [('GoToHPActivity.framework', 'Frameworks'), ('GoToHPUploadProgress.appex', 'PlugIns')]:
        bundle = assets / folder
        assert bundle.is_dir(), f'Missing Live Activity bundle: {folder}'
        info = plistlib.loads((bundle / 'Info.plist').read_bytes())
        assert (bundle / info['CFBundleExecutable']).is_file()
        for path in sorted(bundle.rglob('*')):
            if path.is_file():
                yield f'{host}/{destination}/{folder}/{path.relative_to(bundle).as_posix()}', path.read_bytes()


def inject(source, destination, assets):
    assert Path(source).resolve() != Path(destination).resolve()
    with zipfile.ZipFile(source) as archive, zipfile.ZipFile(destination, 'x', zipfile.ZIP_DEFLATED, compresslevel=6) as output:
        hosts = [n[:-len('/Info.plist')] for n in archive.namelist() if n.startswith('Payload/') and n.endswith('.app/Info.plist') and n.count('/') == 2]
        assert len(hosts) == 1
        host = hosts[0]
        additions = dict(bundle_entries(assets, host))
        for entry in archive.infolist():
            if entry.filename in additions:
                raise ValueError('Input already contains this Live Activity bundle')
            content = archive.read(entry)
            if entry.filename == host + '/Info.plist':
                info = plistlib.loads(content)
                info['NSSupportsLiveActivities'] = True
                info['NSSupportsLiveActivitiesFrequentUpdates'] = True
                content = plistlib.dumps(info, fmt=plistlib.FMT_BINARY)
            output.writestr(entry, content)
        for name, content in additions.items():
            entry = zipfile.ZipInfo(name)
            entry.create_system = 3
            entry.compress_type = zipfile.ZIP_DEFLATED
            entry.external_attr = (0o100755 if content[:4] == bytes.fromhex('cffaedfe') else 0o100644) << 16
            output.writestr(entry, content)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source')
    parser.add_argument('destination')
    parser.add_argument('assets')
    args = parser.parse_args()
    inject(args.source, args.destination, args.assets)
