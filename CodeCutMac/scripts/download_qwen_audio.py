"""Download the pinned MLX Qwen2-Audio weights with verified HTTP ranges and SHA256."""
import concurrent.futures
import hashlib
import os
from pathlib import Path
import shutil
import tempfile
import time
import urllib.request

ROOT = Path.home() / 'Library/Application Support/CodeCut/Runtime/Qwen2-Audio-7B-Instruct-4bit'
URL = 'https://huggingface.co/mlx-community/Qwen2-Audio-7B-Instruct-4bit/resolve/c65570002626f41b4dc08b7b54f42f99f3e82e7f/weights.safetensors'
SIZE = 6562540479
SHA = '0967cde270ad62aa4824f0bbce283d0a2a6da2825ccf587640753c527d4174da'

def main():
    ROOT.mkdir(parents=True, exist_ok=True)
    destination = ROOT / 'weights.safetensors'
    prefix = destination.stat().st_size if destination.exists() else 0
    if prefix > SIZE:
        raise RuntimeError('Unexpected existing model size')
    with tempfile.TemporaryDirectory(prefix='qwen-download-', dir=ROOT.parent) as scratch:
        staging = Path(scratch)
        ranges = [(start, min(SIZE - 1, start + 64 * 1024**2 - 1)) for start in range(prefix, SIZE, 64 * 1024**2)]
        def fetch(bounds):
            start, end = bounds
            target = staging / str(start)
            for attempt in range(5):
                try:
                    request = urllib.request.Request(URL + '?range_start=' + str(start), headers={'Range': f'bytes={start}-{end}'})
                    with urllib.request.urlopen(request, timeout=60) as response:
                        expected = f'bytes {start}-{end}/{SIZE}'
                        if response.status != 206 or response.headers.get('Content-Range') != expected:
                            raise RuntimeError('Server did not honor requested range')
                        with target.open('wb') as output:
                            shutil.copyfileobj(response, output, 1024**2)
                    if target.stat().st_size != end - start + 1:
                        raise RuntimeError('Incomplete range')
                    return target
                except Exception:
                    if attempt == 4:
                        raise
                    time.sleep(2 * (attempt + 1))
        completed = prefix
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
            futures = [pool.submit(fetch, bounds) for bounds in ranges]
            for future in concurrent.futures.as_completed(futures):
                completed += future.result().stat().st_size
                print(f'Download {completed / SIZE:.1%} ({completed / 1e9:.2f} GB)', flush=True)
        combined = staging / 'verified.safetensors'
        with combined.open('wb') as output:
            if prefix:
                with destination.open('rb') as source:
                    shutil.copyfileobj(source, output, 1024**2)
            for start, _ in ranges:
                with (staging / str(start)).open('rb') as source:
                    shutil.copyfileobj(source, output, 1024**2)
        with combined.open('rb') as source:
            digest = hashlib.file_digest(source, 'sha256').hexdigest()
        if digest != SHA:
            raise RuntimeError('Model SHA256 mismatch; original download retained')
        os.replace(combined, destination)
        print('Model SHA256 verified. Ready.', flush=True)

if __name__ == '__main__':
    main()
