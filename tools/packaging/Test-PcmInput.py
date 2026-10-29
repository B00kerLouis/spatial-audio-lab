"""Exercise the real native float PCM pipe and default speaker mapping without an audio device."""
from pathlib import Path
import argparse
import json
import math
import struct
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument('--engine', type=Path, required=True)
parser.add_argument('--profile', type=Path, required=True)
args = parser.parse_args()
samples = [0.01 * (channel + 1) for _ in range(64) for channel in range(12)]
result = subprocess.run([str(args.engine), 'validate-pcm-stdin', str(args.profile)],
                        input=struct.pack('<%df' % len(samples), *samples), capture_output=True, check=True)
messages = [json.loads(line) for line in result.stdout.decode('utf-8').splitlines() if line.startswith('{')]
last = messages[-1]
assert last['event'] == 'done' and last['submittedFrames'] == 64
expected = [.01, .02, .03, .04, .07, .08, .05, .06, .09, .10, .11, .12]
assert all(math.isclose(a, b, abs_tol=1e-6) for a, b in zip(last['peaks'], expected)), last
bad = subprocess.run([str(args.engine), 'validate-pcm-stdin', str(args.profile)], input=b'123', capture_output=True)
assert bad.returncode != 0, 'Truncated PCM frame was accepted'
print('Native Cinema float pipe passed: 7.1.4 mapping, 64 frames, truncated-frame rejection')
