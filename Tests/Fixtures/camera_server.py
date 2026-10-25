#!/usr/bin/env python3
"""Loopback-only synthetic blue camera, for repeatable video integration tests.
No printer captures or external connections. Run with --directory for ports and receipts.
"""
import argparse, base64, http.server, json, pathlib, socketserver, ssl, struct, subprocess, threading, time

# Generated from a 160x90 solid-blue image with libx264, not a printer recording.
NALS = [base64.b64decode(n) for n in ['Z0LACtoKN+TARAAAAwAEAAADAAo8SJqA', 'aM4PyA==', 'ZYiEOhGKAAIxccAAQ8o4AAgFycnJycnJycnJ111111111111111111111111111111111111111111111111114=']]
JPEG = base64.b64decode('/9j/4AAQSkZJRgABAgAAAQABAAD//gAPTGF2YzYzLjEuMTAyAP/bAEMACAQEBAQEBQUFBQUFBgYGBgYGBgYGBgYGBgcHBwgICAcHBwYGBwcICAgICQkJCAgICAkJCgoKDAwLCw4ODhERFP/EAE0AAQEAAAAAAAAAAAAAAAAAAAAHAQEBAQAAAAAAAAAAAAAAAAAABQcQAQAAAAAAAAAAAAAAAAAAAAARAQAAAAAAAAAAAAAAAAAAAAD/wAARCABaAKADASIAAhEAAxEA/9oADAMBAAIRAxEAPwCOAN/SgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAH/2Q==')
parser = argparse.ArgumentParser()
parser.add_argument('--directory', required=True)
args = parser.parse_args()
directory = pathlib.Path(args.directory)
directory.mkdir(parents=True, exist_ok=True)
receipts = directory / 'receipts.jsonl'
receipt_lock = threading.Lock()
def record(event):
    with receipt_lock:
        with receipts.open('a') as f:
            f.write(json.dumps({'event': event}) + '\n')

class HTTP(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_): pass
    def do_GET(self):
        if self.path == '/server/webcams/list':
            body = json.dumps({'result': {'webcams': [{'enabled': True, 'uid': 'fixture-primary', 'name': 'Front camera', 'stream_url': '/camera'}, {'enabled': True, 'uid': 'fixture-secondary', 'name': 'Side camera', 'stream_url': '/camera-secondary', 'rotation': 90, 'flip_horizontal': True}]}}).encode()
            self.send_response(200); self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(body))); self.end_headers(); self.wfile.write(body)
            return
        if self.path == '/denied':
            self.send_response(401); self.end_headers(); return
        if self.path == '/redirect':
            self.send_response(302); self.send_header('Location', '/camera'); self.end_headers(); return
        if self.path not in ['/camera', '/camera-secondary']:
            self.send_response(404); self.end_headers(); return
        record('http-open')
        self.send_response(200)
        self.send_header('Content-Type', 'multipart/x-mixed-replace; boundary=frame'); self.end_headers()
        try:
            for _ in range(600):
                header = b'--frame\r\nContent-Type: image/jpeg\r\nContent-Length: ' + str(len(JPEG)).encode() + b'\r\n\r\n'
                for part in [header, JPEG[:7], JPEG[7:], b'\r\n']:
                    self.wfile.write(part); self.wfile.flush()
                time.sleep(.1)
        except (BrokenPipeError, ConnectionResetError): pass
        finally: record('http-closed')

class RTSP(socketserver.BaseRequestHandler):
    def handle(self):
        try:
            self.request = tls.wrap_socket(self.request, server_side=True)
            self.request.settimeout(4)
            record('rtsp-open')
            pending = b''
            while True:
                while b'\r\n\r\n' not in pending:
                    part = self.request.recv(4096)
                    if not part: return
                    pending += part
                raw, pending = pending.split(b'\r\n\r\n', 1)
                lines = raw.decode().split('\r\n')
                method, uri, _ = lines[0].split(' ')
                headers = dict((k.lower(), v.strip()) for k,v in (l.split(':',1) for l in lines[1:]))
                seq = headers['cseq']
                if 'authorization' not in headers:
                    self.reply(seq, 401, {'WWW-Authenticate': 'Digest realm="camera", nonce="fixture-nonce"'})
                    continue
                # Verify the Digest response, including the fixture password.
                import hashlib, re
                fields = dict(re.findall(r'(\w+)="([^"]*)"', headers['authorization']))
                md5 = lambda s: hashlib.md5(s.encode()).hexdigest()
                expected = md5(md5('bblp:camera:fixture-password') + ':fixture-nonce:' + md5(method+':'+uri))
                if fields.get('response') != expected:
                    self.reply(seq, 403); continue
                record(method.lower())
                if method == 'DESCRIBE':
                    body = ('v=0\r\nm=video 0 RTP/AVP 96\r\na=rtpmap:96 H264/90000\r\n'
                            'a=fmtp:96 packetization-mode=1;sprop-parameter-sets=' + ','.join(base64.b64encode(n).decode() for n in NALS[:2]) + '\r\na=control:trackID=0\r\n').encode()
                    self.reply(seq, 200, {'Content-Type': 'application/sdp', 'Content-Base': uri+'/'}, body)
                elif method == 'SETUP':
                    self.reply(seq, 200, {'Session': 'fixture-session;timeout=60', 'Transport': 'RTP/AVP/TCP;unicast;interleaved=0-1'})
                elif method == 'PLAY':
                    self.reply(seq, 200, {'Session': 'fixture-session'})
                    for i in range(300):
                        # STAP-A with SPS/PPS and the synthetic IDR access unit.
                        payload = b'\x78' + b''.join(struct.pack('!H',len(n))+n for n in NALS)
                        packet = struct.pack('!BBHII',0x80,0x80|96,i,i*9000,1234)+payload
                        wire = b'$\x00'+struct.pack('!H',len(packet))+packet
                        self.request.sendall(wire[:3]); self.request.sendall(wire[3:])
                        time.sleep(.1)
                else: self.reply(seq, 200)
        except (OSError, ssl.SSLError): pass
        finally: record('rtsp-closed')
    def reply(self, seq, status, headers=None, body=b''):
        fields = {'CSeq':seq,'Content-Length':str(len(body)), **(headers or {})}
        wire = f'RTSP/1.0 {status} Fixture\r\n'+''.join(f'{k}: {v}\r\n' for k,v in fields.items())+'\r\n'
        self.request.sendall(wire.encode()+body)

subprocess.run(['openssl','req','-x509','-newkey','rsa:2048','-nodes','-keyout',str(directory/'key.pem'),'-out',str(directory/'cert.pem'),'-days','1','-subj','/CN=localhost'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True)
tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
tls.load_cert_chain(directory/'cert.pem', directory/'key.pem')
class LoopbackHTTPServer(http.server.ThreadingHTTPServer):
    def server_bind(self):
        # Skip reverse DNS on a loopback-only fixture.
        socketserver.TCPServer.server_bind(self)
        self.server_name = 'localhost'
        self.server_port = self.server_address[1]
http = LoopbackHTTPServer(('127.0.0.1',0),HTTP)
class Threaded(socketserver.ThreadingTCPServer):
    daemon_threads=True
    allow_reuse_address=True
rtsp = Threaded(('127.0.0.1',0),RTSP)
for server in (http,rtsp): threading.Thread(target=server.serve_forever,daemon=True).start()
ready = directory / 'ready.json'
pending = directory / 'ready.json.tmp'
pending.write_text(json.dumps({'http': http.server_port, 'rtsp': rtsp.server_address[1]}))
pending.replace(ready)
try:
    while True: time.sleep(1)
except KeyboardInterrupt: pass
