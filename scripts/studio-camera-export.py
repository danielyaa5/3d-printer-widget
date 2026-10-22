#!/usr/bin/env python3
"""Keep Studio's official camera-tool pipeline running outside Print Progress.

Studio must issue and refresh its own Go Live source. No authentication is
implemented here; source URLs and vendor diagnostics are never printed.
"""
import argparse
from pathlib import Path
import signal
import subprocess
import threading
from urllib.parse import quote


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--tools', type=Path, default=Path.home() / 'Library/Application Support/BambuStudio/cameratools')
    parser.add_argument('--ffmpeg', type=Path, default=Path('/opt/homebrew/bin/ffmpeg'))
    args = parser.parse_args()
    base = args.tools
    if not all(path.is_file() for path in (base / 'bambu_source', base / 'ffmpeg.cfg', base / 'url.txt', args.ffmpeg)):
        parser.error('Install the official Studio camera tools, enable Go Live, and provide an existing FFmpeg executable.')
    configs = [line for line in (base / 'ffmpeg.cfg').read_text().splitlines() if line]
    stop = threading.Event()
    signal.signal(signal.SIGTERM, lambda *_: stop.set())
    signal.signal(signal.SIGINT, lambda *_: stop.set())
    while not stop.is_set():
        children = []
        try:
            source = subprocess.Popen([str(base / 'bambu_source'), 'bambu:///camera/' + quote(str(base / 'url.txt'))],
                                      cwd=base.parent / 'plugins', stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
            children.append(source)
            encoder = subprocess.Popen([str(args.ffmpeg), *configs], stdin=source.stdout,
                                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            children.append(encoder)
            source.stdout.close()
            while not stop.wait(.25) and all(child.poll() is None for child in children):
                pass
        except OSError:
            pass
        finally:
            for child in children:
                if child.poll() is None:
                    child.terminate()
                try:
                    child.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    child.kill()
                    child.wait()
            if children and children[0].stdout:
                children[0].stdout.close()
        stop.wait(2)


if __name__ == '__main__':
    main()
