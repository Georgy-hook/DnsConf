"""Bundle an installed Windows CPython; never download or copy site-packages."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import struct
import sys
import zipfile


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--destination', required=True, type=Path)
    args = parser.parse_args()
    if sys.platform != 'win32' or struct.calcsize('P') != 8 or sys.version_info[:2] != (3, 14):
        parser.error('Use an installed Windows CPython 3.14 x64.')
    source = Path(sys.base_prefix)
    if not (source / 'Lib/ssl.py').is_file():
        parser.error('A full Python installation with Lib/ is required.')
    dest = args.destination.resolve()
    dest.mkdir(parents=True, exist_ok=False)
    for name in ('python.exe', 'python3.dll', 'python314.dll', 'vcruntime140.dll', 'vcruntime140_1.dll', 'LICENSE.txt'):
        shutil.copyfile(source / name, dest / name)
    shutil.copytree(source / 'DLLs', dest / 'DLLs', ignore=shutil.ignore_patterns('*.pdb'))
    excluded = {'site-packages', 'test', 'tests', 'idlelib', 'tkinter', 'turtledemo', 'ensurepip', 'venv', '__pycache__'}
    with zipfile.ZipFile(dest / 'python314.zip', 'w', zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
        for path in sorted((source / 'Lib').rglob('*.py')):
            rel = path.relative_to(source / 'Lib')
            if not set(rel.parts) & excluded:
                archive.write(path, rel.as_posix())
    (dest / 'python314._pth').write_text('python314.zip\n.\nDLLs\n', encoding='ascii')
    hashes = {p.relative_to(dest).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest()
              for p in sorted(dest.rglob('*')) if p.is_file()}
    (dest.parent / 'runtime-hashes.json').write_text(json.dumps(hashes, indent=2) + '\n', encoding='utf-8')
    print(json.dumps({'version': sys.version.split()[0], 'files': len(hashes)}))


if __name__ == '__main__':
    main()
