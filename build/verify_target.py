"""Fail packaging if Go target or executable architecture is wrong."""
import os
from pathlib import Path
import struct
import subprocess
import sys

binary = Path(sys.argv[1])
goos, goarch = os.environ['GOOS'], os.environ['GOARCH']
info = subprocess.check_output(['go', 'version', '-m', str(binary)], text=True)
for key, expected in [('GOOS', goos), ('GOARCH', goarch), ('CGO_ENABLED', '1')]:
    assert f'{key}={expected}' in info, f'{key} target mismatch'
header = binary.read_bytes()[:32]
if goos == 'darwin':
    magic, cpu = struct.unpack('<II', header[:8])
    assert magic == 0xFEEDFACF and cpu == {'amd64': 0x01000007, 'arm64': 0x0100000C}[goarch]
else:
    assert header[:5] == b'\x7fELF\x02'
    assert struct.unpack('<H', header[18:20])[0] == {'amd64': 62, 'arm64': 183}[goarch]
print(f'Validated {goos}/{goarch} executable with cgo')
