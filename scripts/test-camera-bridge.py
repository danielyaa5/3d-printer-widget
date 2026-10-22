#!/usr/bin/env python3
"""Real ffmpeg/socket checks with generated imagery; no Studio or printer access."""
import concurrent.futures
import json
import os
from pathlib import Path
import subprocess
import sys
import time
import tempfile
import unittest
import urllib.error
import urllib.request


class CameraBridgeTests(unittest.TestCase):
    def testExportSupervisorStopsItsChildren(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            tools = root / 'cameratools'
            tools.mkdir()
            (root / 'plugins').mkdir()
            source = tools / 'bambu_source'
            source.write_text('#!' + sys.executable + '\nimport os,time\nfrom pathlib import Path\n'
                              'Path("source.pid").write_text(str(os.getpid()))\n'
                              'while True: time.sleep(.1)\n')
            source.chmod(0o700)
            encoder = root / 'encoder'
            marker = root / 'encoder.pid'
            encoder.write_text('#!' + sys.executable + '\nimport os,sys,time\nfrom pathlib import Path\n'
                               'Path(sys.argv[1]).write_text(str(os.getpid()))\n'
                               'while True: time.sleep(.1)\n')
            encoder.chmod(0o700)
            (tools / 'url.txt').write_text('fixture source, no credentials')
            (tools / 'ffmpeg.cfg').write_text(str(marker))
            process = subprocess.Popen([sys.executable, str(Path(__file__).with_name('studio-camera-export.py')),
                                        '--tools', str(tools), '--ffmpeg', str(encoder)])
            pids = []
            try:
                deadline = time.monotonic() + 5
                source_marker = root / 'plugins/source.pid'
                while time.monotonic() < deadline and not (source_marker.exists() and marker.exists()):
                    time.sleep(.05)
                pids = [int(source_marker.read_text()), int(marker.read_text())]
                for pid in pids:
                    os.kill(pid, 0)
            finally:
                process.terminate()
                process.wait(timeout=8)
            self.assertEqual(process.returncode, 0)
            for pid in pids:
                with self.assertRaises(ProcessLookupError):
                    os.kill(pid, 0)

    def start_bridge(self, *args):
        process = subprocess.Popen([sys.executable, str(Path(__file__).with_name('camera-bridge.py')),
                                    '--port', '0', '--idle-seconds', '.2', *args],
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.addCleanup(self.stop_bridge, process)
        ready = json.loads(process.stdout.readline())
        self.assertTrue(ready['loopbackOnly'])
        return f'http://127.0.0.1:{ready["port"]}'

    def stop_bridge(self, process):
        process.terminate()
        process.wait(timeout=10)
        errors = process.stderr.read()
        process.stdout.close()
        process.stderr.close()
        self.assertEqual(process.returncode, 0)
        self.assertEqual(errors, '')

    def health(self, base):
        try:
            response = urllib.request.urlopen(base + '/health', timeout=2)
        except urllib.error.HTTPError as response:
            return json.loads(response.read())
        with response:
            return json.load(response)

    def wait_for(self, base, predicate):
        deadline = time.monotonic() + 6
        status = None
        while time.monotonic() < deadline:
            status = self.health(base)
            if predicate(status):
                return status
            time.sleep(.05)
        self.fail(f'Bridge never reached expected state: {status}')

    def read_picture(self, response):
        self.assertEqual(response.readline().strip(), b'--frame')
        length = None
        while True:
            line = response.readline().strip()
            if not line:
                break
            if line.lower().startswith(b'content-length:'):
                length = int(line.split(b':')[1])
        image = response.read(length)
        self.assertTrue(image.startswith(b'\xff\xd8') and image.endswith(b'\xff\xd9'))
        self.assertLess(len(image), 128 * 1024)
        self.assertEqual(response.read(2), b'\r\n')
        return image

    def testLiveViewersShareDecoderUntilLastClosesThenRestart(self):
        base = self.start_bridge('--test-pattern')
        idle = self.health(base)
        self.assertEqual(idle['state'], 'idle')
        self.assertEqual(idle['videoProcesses'], 0)
        self.assertEqual(idle['frames'], 0)
        first = urllib.request.urlopen(base + '/camera.mjpg', timeout=15)
        second = None
        try:
            self.read_picture(first)
            second = urllib.request.urlopen(base + '/camera.mjpg', timeout=15)
            self.read_picture(second)
            active = self.wait_for(base, lambda h: h['clients'] == 2)
            self.assertEqual(active['videoProcesses'], 1)
            first.close()
            shared = self.wait_for(base, lambda h: h['clients'] == 1)
            self.assertEqual(shared['videoProcesses'], 1)
            self.read_picture(second)
            with urllib.request.urlopen(base + '/snapshot.jpg', timeout=15) as response:
                self.assertTrue(response.read().startswith(b'\xff\xd8'))
            self.assertTrue(self.health(base)['available'])
        finally:
            first.close()
            if second:
                second.close()
        idle = self.wait_for(base, lambda h: h['clients'] == 0 and h['videoProcesses'] == 0)
        old_sequence = idle['frames']
        self.assertFalse(idle['available'])
        time.sleep(.3)
        self.assertEqual(self.health(base)['frames'], old_sequence, 'Health requests must not wake the decoder')
        with urllib.request.urlopen(base + '/snapshot.jpg', timeout=15) as response:
            self.assertEqual(response.headers['Content-Type'], 'image/jpeg')
            self.assertTrue(response.read().startswith(b'\xff\xd8'))
        idle = self.wait_for(base, lambda h: h['videoProcesses'] == 0)
        self.assertGreater(idle['frames'], old_sequence)
        with self.assertRaises(urllib.error.HTTPError) as invalid:
            urllib.request.urlopen(base + '/unknown', timeout=2)
        self.assertEqual(invalid.exception.code, 404)
        self.assertEqual(self.health(base)['videoProcesses'], 0)

    def testConcurrentSnapshotsUseOneCapturePipelineAndReleaseIt(self):
        base = self.start_bridge('--test-pattern')
        def picture(_):
            with urllib.request.urlopen(base + '/snapshot.jpg', timeout=15) as response:
                return response.read()
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            pictures = list(pool.map(picture, range(2)))
        self.assertEqual(pictures[0], pictures[1])
        idle = self.wait_for(base, lambda h: h['videoProcesses'] == 0)
        self.assertEqual(idle['clients'], 0)
        self.assertLess(idle['frames'], 8)

    def testManagedStudioSourceRetainsFirstKeyframeAndStopsWhenIdle(self):
        import shutil
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            tools = root / 'cameratools'; tools.mkdir()
            (root / 'plugins').mkdir()
            source = tools / 'bambu_source'
            ffmpeg = shutil.which('ffmpeg') or '/opt/homebrew/bin/ffmpeg'
            source.write_text('#!' + sys.executable + '\nimport os\n'
                              + 'os.execv(' + repr(ffmpeg) + ', ' + repr([ffmpeg, '-hide_banner', '-loglevel', 'error',
                                  '-re', '-f', 'lavfi', '-i', 'color=c=blue:s=160x90:r=4', '-c:v', 'libx264',
                                  '-preset', 'ultrafast', '-tune', 'zerolatency', '-g', '40', '-keyint_min', '40',
                                  '-sc_threshold', '0', '-f', 'h264', 'pipe:1']) + ')\n')
            source.chmod(0o700)
            (tools / 'url.txt').write_text('fixture source')
            base = self.start_bridge('--studio-tools', str(tools))
            self.assertEqual(self.health(base)['videoProcesses'], 0)
            started = time.monotonic()
            with urllib.request.urlopen(base + '/camera.mjpg', timeout=15) as response:
                self.read_picture(response)
                # This fixture has ten seconds between keyframes. Startup must
                # retain the first one instead of waiting for the next GOP.
                self.assertLess(time.monotonic() - started, 5)
                self.assertEqual(self.health(base)['videoProcesses'], 2)
            self.wait_for(base, lambda h: h['videoProcesses'] == 0)
            started = time.monotonic()
            with urllib.request.urlopen(base + '/snapshot.jpg', timeout=15) as response:
                self.assertTrue(response.read().startswith(b'\xff\xd8'))
                self.assertLess(time.monotonic() - started, 5)
            self.wait_for(base, lambda h: h['videoProcesses'] == 0)


if __name__ == '__main__':
    unittest.main()
