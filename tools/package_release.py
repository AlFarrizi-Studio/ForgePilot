"""Build a checksummed source/release archive after tests and Rojo builds."""
import argparse
import hashlib
import json
import pathlib
import zipfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
EXCLUDED_DIRS = {'.git', 'node_modules', '__pycache__', 'AgentWorkspace', 'ForgePilotWorkspace', '.forgepilot-backups', 'releases'}
EXCLUDED_FILES = {'SHA256SUMS.txt', 'runtime-harness.luau', 'runtime-result.txt', '.DS_Store', 'Thumbs.db'}
def package_files():
    return sorted(p for p in ROOT.rglob('*') if p.is_file()
        and not (set(p.relative_to(ROOT).parts) & EXCLUDED_DIRS)
        and p.name not in EXCLUDED_FILES
        and not p.name.startswith('.env')
        and p.suffix not in {'.log', '.zip', '.pyc'})

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=pathlib.Path)
    args = parser.parse_args()
    version = json.loads((ROOT / 'package.json').read_text())['version']
    for name in ['plugin/ForgePilot.rbxm', 'plugin/ForgePilot.rbxmx']:
        if not (ROOT / name).is_file(): raise SystemExit('Build missing: ' + name)
    files = package_files()
    checksums = ROOT / 'SHA256SUMS.txt'
    checksums.write_text(''.join(hashlib.sha256(p.read_bytes()).hexdigest() + '  ' + p.relative_to(ROOT).as_posix() + '\n' for p in files))
    output = (args.output or ROOT / 'releases' / ('ForgePilot-' + version + '.zip')).resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(output, 'w', zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for p in sorted(files + [checksums]):
            archive.write(p, 'ForgePilot/' + p.relative_to(ROOT).as_posix())
    with zipfile.ZipFile(output) as archive:
        if archive.testzip() is not None: raise SystemExit('ZIP verification failed.')
        for p in files + [checksums]:
            if archive.read('ForgePilot/' + p.relative_to(ROOT).as_posix()) != p.read_bytes(): raise SystemExit('ZIP byte mismatch: ' + str(p))
    print(json.dumps({'file': str(output), 'files': len(files) + 1, 'bytes': output.stat().st_size, 'sha256': hashlib.sha256(output.read_bytes()).hexdigest()}))
if __name__ == '__main__': main()
