"""Check distribution layout, runtime hashes and accidental local state."""
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import sys
import zipfile


def check(path):
    with zipfile.ZipFile(path) as archive:
        assert archive.testzip() is None
        names = archive.namelist()
        assert len(names) == len(set(names))
        required = ['NextDNS/NextDNS.exe', 'NextDNS/NextDNS.exe.config',
                    'NextDNS/_service/bridge/NextDNSBridge.exe',
                    'NextDNS/_service/bridge/python/python.exe',
                    'NextDNS/_service/bridge/python/LICENSE.txt']
        assert all(name in names for name in required)
        for name in names:
            parts = PurePosixPath(name).parts
            assert parts and parts[0] == 'NextDNS' and '..' not in parts and '\\' not in name, name
            assert not any(part.lower() in {'backups', 'run-results', '__pycache__', 'bin'} for part in parts), name
            assert not name.lower().endswith(('.log', '.lock', '-state.json', '.pyc')), name
            assert parts[-1].lower() not in {'profile.txt', 'enabled.txt', 'gui-settings.json', 'status.json', 'boot-check.json', 'boot-verified.json'}, name
            if name.endswith('.ps1'):
                assert archive.read(name).startswith(b'\xef\xbb\xbf'), name
            if PurePosixPath(name).suffix.lower() in {'.ps1', '.py', '.cs', '.json', '.txt', '.xaml', '.hosts', '.config'}:
                text = archive.read(name).decode('utf-8-sig')
                assert not re.search(r'[A-Za-z]:[/\\]Users[/\\]|S-1-5-21-\d', text), name
                assert not re.search(r'https://(?:[a-z0-9.-]+\.)?dns\.nextdns\.io/[a-f0-9]{6}\b', text), name
        hashes = json.loads(archive.read('NextDNS/_service/bridge/runtime-hashes.json'))
        runtime_prefix = 'NextDNS/_service/bridge/python/'
        runtime_names = {name[len(runtime_prefix):] for name in names if name.startswith(runtime_prefix) and not name.endswith('/')}
        assert runtime_names == set(hashes)
        for name, expected in hashes.items():
            assert hashlib.sha256(archive.read(runtime_prefix + name)).hexdigest() == expected.lower(), name
    print(json.dumps({'archive': Path(path).name, 'files': len(names), 'runtime_files': len(hashes), 'checks': 'passed'}))


if __name__ == '__main__':
    check(sys.argv[1])
