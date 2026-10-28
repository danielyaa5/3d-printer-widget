#!/usr/bin/env python3
"""Optional, on-demand Bambu Studio -> loopback MJPEG relay.

Requires an existing ffmpeg installation and Studio's authenticated Go Live export.
No printer credentials, recordings, app automation, or external listening socket.
"""
import argparse
import concurrent.futures
import ctypes
from datetime import datetime, timezone
import http.server
import json
import os
from pathlib import Path
import re
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
from urllib.parse import quote


class FtJobResult(ctypes.Structure):
    _fields_ = [
        ('err', ctypes.c_int32),
        ('code', ctypes.c_int32),
        ('msg', ctypes.c_char_p),
        ('data', ctypes.POINTER(ctypes.c_uint8)),
        ('data_len', ctypes.c_uint32),
        ('pad', ctypes.c_uint32),
    ]


def find_bambu_ips():
    prioritized = []
    candidates = []
    seen = set()
    try:
        netstat = subprocess.check_output(['/usr/sbin/netstat', '-an', '-p', 'tcp'], text=True, stderr=subprocess.DEVNULL, timeout=2)
        for ip in re.findall(r'\b(\d{1,3}(?:\.\d{1,3}){3})\.(?:8883|6000)\b', netstat):
            if ip not in seen and not ip.startswith(('127.', '0.')):
                seen.add(ip)
                prioritized.append(ip)
    except Exception:
        pass
    for ip in prioritized:
        try:
            with socket.create_connection((ip, 6000), timeout=0.4):
                return [ip]
        except OSError:
            pass
    try:
        arp = subprocess.check_output(['/usr/sbin/arp', '-an'], text=True, stderr=subprocess.DEVNULL, timeout=2)
        for ip in re.findall(r'\((\d{1,3}(?:\.\d{1,3}){3})\)', arp):
            if ip not in seen and not ip.startswith(('127.', '0.', '224.', '239.', '255.')) and not ip.endswith('.255'):
                seen.add(ip)
                candidates.append(ip)
    except Exception:
        pass

    def probe(ip):
        try:
            with socket.create_connection((ip, 6000), timeout=0.8):
                return ip
        except OSError:
            return None

    if not candidates:
        return prioritized
    with concurrent.futures.ThreadPoolExecutor(max_workers=min(16, len(candidates))) as pool:
        found = [ip for ip in pool.map(probe, candidates) if ip]
    return found or prioritized


def run_ft_producer(studio_root, ffmpeg):
    out_fd = os.dup(1)
    devnull = os.open(os.devnull, os.O_WRONLY)
    os.dup2(devnull, 1)
    os.dup2(devnull, 2)
    os.close(devnull)
    out_stream = os.fdopen(out_fd, 'wb', buffering=0)
    stopping = False
    producer = decoder = None

    def handle_stop(*_):
        nonlocal stopping
        stopping = True
        for child in (decoder, producer):
            if child is not None and child.poll() is None:
                try:
                    child.terminate()
                except OSError:
                    pass
        os._exit(0)

    signal.signal(signal.SIGTERM, handle_stop)
    signal.signal(signal.SIGINT, handle_stop)

    try:
        conf = json.loads((studio_root / 'BambuStudio.conf').read_text())
    except Exception:
        os._exit(1)

    access_codes = []
    for key in ('access_code', 'user_access_code'):
        mapping = conf.get(key)
        if isinstance(mapping, dict):
            for code in mapping.values():
                if isinstance(code, str) and code and code not in access_codes:
                    access_codes.append(code)

    dylib_path = studio_root / 'plugins/libbambu_networking.dylib'
    real_exe = str(Path(sys.executable).resolve())
    emitted = False
    if 'CommandLineTools' not in real_exe and 'Xcode.app' not in real_exe and access_codes and dylib_path.is_file():
        ips = find_bambu_ips()
        if ips:
            try:
                lib = ctypes.CDLL(str(dylib_path))
                lib.bambu_network_create_agent.argtypes = [ctypes.c_char_p]
                lib.bambu_network_create_agent.restype = ctypes.c_void_p
                lib.ft_tunnel_create.argtypes = [ctypes.c_char_p, ctypes.POINTER(ctypes.c_void_p)]
                lib.ft_tunnel_create.restype = ctypes.c_int
                lib.ft_tunnel_sync_connect.argtypes = [ctypes.c_void_p]
                lib.ft_tunnel_sync_connect.restype = ctypes.c_int
                lib.ft_job_create.argtypes = [ctypes.c_char_p, ctypes.POINTER(ctypes.c_void_p)]
                lib.ft_job_create.restype = ctypes.c_int
                lib.ft_tunnel_start_job.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
                lib.ft_tunnel_start_job.restype = ctypes.c_int
                lib.ft_job_get_result.argtypes = [ctypes.c_void_p, ctypes.c_uint32, ctypes.POINTER(FtJobResult)]
                lib.ft_job_get_result.restype = ctypes.c_int
                lib.ft_job_result_destroy.argtypes = [ctypes.POINTER(FtJobResult)]
                lib.ft_job_release.argtypes = [ctypes.c_void_p]
                lib.ft_tunnel_shutdown.argtypes = [ctypes.c_void_p]
                lib.ft_tunnel_release.argtypes = [ctypes.c_void_p]

                os.chdir(tempfile.gettempdir())
                sso_tmp = ctypes.create_string_buffer(b'/tmp' + b'\x00' * 19 + b'\x04', 24)
                lib.bambu_network_create_agent(sso_tmp)
                job_json = json.dumps({
                    'cmd_type': 4,
                    'is_mem_file': True,
                    'path': 'mem:/26',
                    'target_path': '',
                }).encode()

                for ip in ips:
                    for code in access_codes:
                        if stopping:
                            break
                        url = f'bambu:///local/{ip}?port=6000&user=bblp&passwd={code}'.encode()
                        tunnel = ctypes.c_void_p()
                        if lib.ft_tunnel_create(url, ctypes.byref(tunnel)) != 0 or not tunnel.value:
                            continue
                        try:
                            if lib.ft_tunnel_sync_connect(tunnel) != 0:
                                continue
                            while not stopping:
                                t0 = time.monotonic()
                                job = ctypes.c_void_p()
                                if lib.ft_job_create(job_json, ctypes.byref(job)) != 0 or not job.value:
                                    break
                                raw = None
                                try:
                                    if lib.ft_tunnel_start_job(tunnel, job) == 0:
                                        res = FtJobResult()
                                        rc = lib.ft_job_get_result(job, 6000, ctypes.byref(res))
                                        try:
                                            if rc == 0 and res.err == 0 and res.data and res.data_len > 0:
                                                raw = ctypes.string_at(res.data, res.data_len)
                                        finally:
                                            lib.ft_job_result_destroy(ctypes.byref(res))
                                finally:
                                    lib.ft_job_release(job)
                                if not raw or not (raw.startswith(b'\xff\xd8') and raw.endswith(b'\xff\xd9')):
                                    break
                                out_stream.write(raw)
                                out_stream.flush()
                                emitted = True
                                elapsed = time.monotonic() - t0
                                if elapsed < 0.5:
                                    time.sleep(0.5 - elapsed)
                        except (BrokenPipeError, OSError):
                            stopping = True
                        finally:
                            lib.ft_tunnel_shutdown(tunnel)
                            lib.ft_tunnel_release(tunnel)
                        if emitted or stopping:
                            break
                    if emitted or stopping:
                        break
            except Exception:
                pass

    # Fallback to bambu_source + url.txt if DeviceImageFlow was not used.
    tools = studio_root / 'cameratools'
    url_file = tools / 'url.txt'
    bambu_source = tools / 'bambu_source'
    if not emitted and not stopping and bambu_source.is_file() and url_file.is_file():
        try:
            if url_file.read_bytes()[:65536].strip():
                producer = subprocess.Popen(
                    [str(bambu_source), 'bambu:///camera/' + quote(str(url_file))],
                    cwd=str(studio_root / 'plugins'),
                    stdout=subprocess.PIPE,
                    stderr=subprocess.DEVNULL,
                )
                decoder = subprocess.Popen(
                    [ffmpeg, '-nostdin', '-hide_banner', '-loglevel', 'error',
                     '-flags', 'low_delay', '-probesize', '3200', '-analyzeduration', '1',
                     '-f', 'h264', '-i', 'pipe:0',
                     '-an', '-vf', 'fps=2,scale=640:-2', '-c:v', 'mjpeg', '-q:v', '5',
                     '-f', 'image2pipe', 'pipe:1'],
                    stdin=producer.stdout,
                    stdout=out_fd,
                    stderr=subprocess.DEVNULL,
                )
                producer.stdout.close()
                decoder.wait()
                producer.terminate()
        except Exception:
            pass

    os._exit(0 if emitted else 1)


class Frames:
    def __init__(self, command, source=None, producer=None, producer_cwd=None, idle_seconds=2):
        self.command = command
        self.source = source
        self.producer_command = producer
        self.producer_cwd = producer_cwd
        self.idle_seconds = idle_seconds
        self.condition = threading.Condition()
        self.stopping = threading.Event()
        self.clients = 0
        self.released = time.monotonic()
        self.image = None
        self.sequence = 0
        self.captured = None
        self.monotonic = 0
        self.process = None
        self.producer = None
        self.started = 0
        self.source_version = None
        self.consecutive_failures = 0
        self.last_error = None
        self.worker = threading.Thread(target=self.ingest, daemon=True)
        self.watchdog = threading.Thread(target=self.watch, daemon=True)

    def version(self):
        try:
            return self.source.stat().st_mtime_ns if self.source else None
        except OSError:
            return None

    def source_ready(self):
        if self.source and self.source.name == 'BambuStudio.conf':
            try:
                conf = json.loads(self.source.read_text())
                return bool(conf.get('access_code') or conf.get('user_access_code'))
            except Exception:
                return False
        if not self.producer_command:
            return True
        try:
            # Studio creates an empty file before Go Live is enabled. Its
            # helper renders a setup card for that file, not a camera picture.
            with self.source.open("rb") as source:
                return bool(source.read(65536).strip())
        except OSError:
            return False

    def watch(self):
        while not self.stopping.is_set():
            with self.condition:
                self.condition.wait_for(lambda: self.process is not None or self.stopping.is_set())
                if self.stopping.is_set():
                    return
                process = self.process
                if process and process.poll() is None:
                    stale = time.monotonic() - max(self.started, self.monotonic) > 20
                    changed = self.version() != self.source_version
                    idle = not self.clients and time.monotonic() - self.released >= self.idle_seconds
                    if stale or changed or idle:
                        self.image = None
                        self.terminate(process)
                        self.terminate(self.producer)
            self.stopping.wait(.25)

    @staticmethod
    def terminate(process):
        if process and process.poll() is None:
            try:
                os.killpg(process.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            except OSError:
                try:
                    process.terminate()
                except ProcessLookupError:
                    pass

    def acquire(self):
        with self.condition:
            self.clients += 1
            self.condition.notify_all()

    def release(self):
        with self.condition:
            self.clients -= 1
            if not self.clients:
                self.released = time.monotonic()
            self.condition.notify_all()

    def status(self):
        with self.condition:
            processes = sum(p is not None and p.poll() is None for p in (self.process, self.producer))
            available = self.available()
            state = 'streaming' if available else 'backing_off' if (self.consecutive_failures > 0 and self.clients) else 'starting' if self.clients else 'idle'
            return {'available': available,
                    'state': state,
                    'clients': self.clients, 'videoProcesses': processes, 'frames': self.sequence,
                    'consecutiveFailures': self.consecutive_failures,
                    'lastError': self.last_error,
                    'latestCapture': self.captured, 'loopbackOnly': True}

    def ingest(self):
        while not self.stopping.is_set():
            with self.condition:
                self.condition.wait_for(lambda: self.clients or self.stopping.is_set())
                if self.stopping.is_set():
                    break
                if not self.source_ready():
                    self.condition.wait(timeout=.5)
                    continue
            process = producer = None
            start_sequence = self.sequence
            try:
                if self.producer_command:
                    producer = subprocess.Popen(self.producer_command, cwd=self.producer_cwd,
                                                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                                start_new_session=True)
                process = subprocess.Popen(self.command, stdin=producer.stdout if producer else subprocess.DEVNULL, stdout=subprocess.PIPE,
                                           stderr=subprocess.DEVNULL, start_new_session=True)
                if producer:
                    producer.stdout.close()
                with self.condition:
                    self.started = time.monotonic()
                    self.source_version = self.version()
                    self.process = process
                    self.producer = producer
                    self.image = None
                    self.condition.notify_all()
                buffer = bytearray()
                while not self.stopping.is_set():
                    part = process.stdout.read1(65536)
                    if not part:
                        break
                    buffer.extend(part)
                    if len(buffer) > 8 * 1024 * 1024:
                        raise ValueError('Oversized camera frame')
                    while True:
                        start = buffer.find(b'\xff\xd8')
                        if start < 0:
                            break
                        end = buffer.find(b'\xff\xd9', start + 2)
                        if end < 0:
                            if start:
                                del buffer[:start]
                            break
                        image = bytes(buffer[start:end + 2])
                        del buffer[:end + 2]
                        with self.condition:
                            if not self.source_ready() or self.version() != self.source_version:
                                continue
                            self.image = image
                            self.sequence += 1
                            self.captured = datetime.now(timezone.utc).isoformat()
                            self.monotonic = time.monotonic()
                            self.condition.notify_all()
            except (OSError, ValueError):
                pass
            finally:
                for child in (process, producer):
                    if child is None:
                        continue
                    self.terminate(child)
                    try:
                        child.wait(timeout=3)
                    except subprocess.TimeoutExpired:
                        try:
                            os.killpg(child.pid, signal.SIGKILL)
                        except OSError:
                            child.kill()
                        child.wait()
                    if child.stdout:
                        child.stdout.close()
                with self.condition:
                    self.process = self.producer = None
                    self.image = None
                    if self.sequence > start_sequence:
                        self.consecutive_failures = 0
                        self.last_error = None
                    else:
                        self.consecutive_failures += 1
                        if self.last_error is None:
                            self.last_error = 'Timeout waiting for camera frames'
                    self.condition.notify_all()
                    if self.clients and not self.stopping.is_set():
                        if self.consecutive_failures > 0:
                            backoff = min(30.0, 1.0 * (2 ** min(self.consecutive_failures - 1, 5)))
                            self.condition.wait(timeout=backoff)
                        else:
                            self.condition.wait(timeout=.5)

    def available(self):
        return self.source_ready() and self.version() == self.source_version and self.image is not None and self.process is not None and self.process.poll() is None and time.monotonic() - self.monotonic < 10

    def stop(self):
        self.stopping.set()
        with self.condition:
            self.condition.notify_all()
            self.terminate(self.process)
            self.terminate(self.producer)
        self.worker.join(timeout=8)
        self.watchdog.join(timeout=3)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--sdp', type=Path, help='Receive an independently managed RTP/SDP source instead of owning the official helper.')
    parser.add_argument('--port', type=int, default=8898)
    parser.add_argument('--ffmpeg', default=shutil.which('ffmpeg') or '/opt/homebrew/bin/ffmpeg')
    parser.add_argument('--hwaccel', choices=('none', 'videotoolbox'), default='none',
                        help='Optional hardware video decoder; use videotoolbox on a supported Mac.')
    parser.add_argument('--studio-tools', type=Path, help='Own the official Studio helper on demand instead of receiving an existing SDP export.')
    parser.add_argument('--idle-seconds', type=float, default=2, help='Stop video processes this long after the last viewer leaves (default: 2).')
    parser.add_argument('--test-pattern', action='store_true', help='Use a generated blue image for isolated checks only.')
    parser.add_argument('--ft-producer', type=Path, help=argparse.SUPPRESS)
    args = parser.parse_args()
    if args.ft_producer is not None:
        run_ft_producer(args.ft_producer, args.ffmpeg)
        return
    if not args.test_pattern and args.studio_tools is None and args.sdp is None:
        args.studio_tools = Path.home() / 'Library/Application Support/BambuStudio/cameratools'
    if not 0 <= args.port <= 65535:
        parser.error('Port must be between 0 and 65535.')
    if not 0 <= args.idle_seconds <= 10:
        parser.error('Idle grace must be between 0 and 10 seconds.')
    if not Path(args.ffmpeg).is_file():
        parser.error('Install ffmpeg separately, or pass its executable using --ffmpeg.')
    if sum((args.test_pattern, args.studio_tools is not None, args.sdp is not None)) > 1:
        parser.error('Choose a generated test source or the official Studio source, not both.')
    ft_ready = (
        args.studio_tools is not None
        and (args.studio_tools.parent / 'plugins/libbambu_networking.dylib').is_file()
        and (args.studio_tools.parent / 'BambuStudio.conf').is_file()
    )
    if args.studio_tools and not ft_ready and not all((args.studio_tools / name).is_file() for name in ('bambu_source', 'url.txt')):
        parser.error('Official Studio helper or its source file is missing. Enable Go Live in Studio first.')
    if not args.test_pattern and not args.studio_tools and not args.sdp.is_file():
        parser.error('Studio camera export is missing. Start its camera and enable Go Live first.')
    command = [args.ffmpeg, '-nostdin', '-hide_banner', '-loglevel', 'error']
    if args.hwaccel != 'none':
        command += ['-hwaccel', args.hwaccel]
    producer = producer_cwd = source = None
    if args.test_pattern:
        command += ['-re', '-f', 'lavfi', '-i', 'color=c=blue:s=160x90:r=2']
        command += ['-an', '-vf', 'fps=2,scale=640:-2', '-c:v', 'mjpeg', '-q:v', '5', '-f', 'image2pipe', 'pipe:1']
    elif args.studio_tools and ft_ready:
        source = args.studio_tools.parent / 'BambuStudio.conf'
        ft_python = next((p for p in (
            '/Library/Frameworks/Python.framework/Versions/3.13/bin/python3',
            '/opt/homebrew/bin/python3',
            '/usr/local/bin/python3',
            sys.executable,
        ) if Path(p).is_file()), sys.executable)
        command = [ft_python, str(Path(__file__).resolve()), '--ft-producer', str(args.studio_tools.parent), '--ffmpeg', args.ffmpeg]
    elif args.studio_tools:
        source = args.studio_tools / 'url.txt'
        producer = [str(args.studio_tools / 'bambu_source'), 'bambu:///camera/' + quote(str(source))]
        producer_cwd = args.studio_tools.parent / 'plugins'
        # Keep the first H.264 keyframe collected during stream probing.
        # nobuffer discards it, delaying startup until another keyframe arrives.
        command += ['-flags', 'low_delay', '-probesize', '3200', '-analyzeduration', '1', '-f', 'h264', '-i', 'pipe:0']
        command += ['-an', '-vf', 'fps=2,scale=640:-2', '-c:v', 'mjpeg', '-q:v', '5', '-f', 'image2pipe', 'pipe:1']
    else:
        source = args.sdp
        command += ['-protocol_whitelist', 'file,rtp,udp', '-localaddr', '127.0.0.1', '-i', str(args.sdp)]
        command += ['-an', '-vf', 'fps=2,scale=640:-2', '-c:v', 'mjpeg', '-q:v', '5', '-f', 'image2pipe', 'pipe:1']
    frames = Frames(command, source, producer, producer_cwd, args.idle_seconds)

    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_GET(self):
            if self.path == '/health':
                status = frames.status()
                status['source'] = 'test-pattern' if args.test_pattern else 'studio-export'
                body = json.dumps(status).encode()
                self.send_response(200 if status['available'] else 503)
                self.send_header('Content-Type', 'application/json')
                self.send_header('Content-Length', str(len(body)))
                self.send_header('Cache-Control', 'no-store')
                self.end_headers()
                self.wfile.write(body)
                return
            if self.path not in ('/camera.mjpg', '/snapshot.jpg'):
                self.send_error(404)
                return
            if not frames.source_ready():
                self.send_error(503, "Camera source is missing; enable Go Live in Bambu Studio.")
                return
            frames.acquire()
            try:
                wait_seconds = 4 if frames.consecutive_failures >= 3 else 12
                deadline = time.monotonic() + wait_seconds
                with frames.condition:
                    initial = frames.sequence
                    while (not frames.available() or (self.path == '/snapshot.jpg' and frames.sequence == initial)) and time.monotonic() < deadline and not frames.stopping.is_set():
                        frames.condition.wait(timeout=.1)
                    if not frames.available() or frames.stopping.is_set() or (self.path == '/snapshot.jpg' and frames.sequence == initial):
                        self.send_error(503, 'Camera export unavailable; start Bambu Studio camera and Go Live.')
                        return
                    image = frames.image
                self.connection.settimeout(5)
                self.send_response(200)
                self.send_header('Cache-Control', 'no-store')
                if self.path == '/snapshot.jpg':
                    self.send_header('Content-Type', 'image/jpeg')
                    self.send_header('Content-Length', str(len(image)))
                    self.end_headers()
                    self.wfile.write(image)
                    return
                self.send_header('Content-Type', 'multipart/x-mixed-replace; boundary=frame')
                self.end_headers()
                sequence = -1
                while not frames.stopping.is_set():
                    with frames.condition:
                        frames.condition.wait_for(lambda: frames.sequence != sequence or frames.stopping.is_set(), timeout=2)
                        if not frames.available():
                            break
                        if sequence == frames.sequence:
                            continue
                        sequence = frames.sequence
                        image = frames.image
                    self.wfile.write(b'--frame\r\nContent-Type: image/jpeg\r\nContent-Length: ' + str(len(image)).encode() + b'\r\n\r\n' + image + b'\r\n')
                    self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError, TimeoutError):
                pass
            finally:
                frames.release()

    server = http.server.ThreadingHTTPServer(('127.0.0.1', args.port), Handler)
    server.daemon_threads = True

    def shutdown(*_):
        threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, shutdown)
    signal.signal(signal.SIGINT, shutdown)
    frames.worker.start()
    frames.watchdog.start()
    print(json.dumps({'port': server.server_port, 'loopbackOnly': True}), flush=True)
    try:
        server.serve_forever(poll_interval=.25)
    finally:
        server.server_close()
        frames.stop()


if __name__ == '__main__':
    main()
