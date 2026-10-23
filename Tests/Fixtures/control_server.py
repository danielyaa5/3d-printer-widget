"""Explicit-control tests. Loopback only, fictional jobs, no physical printers."""
import argparse
import base64
import hashlib
import http.server
import json
import pathlib
import re
import signal
import socketserver
import ssl
import struct
import subprocess
import threading
import time
from urllib.parse import urlsplit

parser = argparse.ArgumentParser()
parser.add_argument('--directory', required=True)
directory = pathlib.Path(parser.parse_args().directory)
directory.mkdir(parents=True, exist_ok=True)
done = threading.Event()
lock = threading.Lock()
states, commands, violations = {}, [], []
USER, PASSWORD, REALM, NONCE = 'fixture-user', 'fixture-password', 'test', 'control-nonce'


def state(family):
    with lock:
        return states.get(family, 'printing')


def mutate(family, action):
    if action not in ('pause', 'resume', 'stop'):
        violations.append('Unexpected control command')
        return
    with lock:
        commands.append({'family': family, 'action': action})
        states[family] = {'pause': 'paused', 'resume': 'printing', 'stop': 'cancelled'}[action]


def digest_ok(header, method):
    values = {k: quoted or plain.strip() for k, quoted, plain in re.findall(r'(\w+)=(?:"([^"]*)"|([^,]*))', header[7:])}
    md5 = lambda value: hashlib.md5(value.encode()).hexdigest()
    expected = md5(':'.join([md5(f'{USER}:{REALM}:{PASSWORD}'), NONCE, values.get('nc', ''), values.get('cnonce', ''), values.get('qop', ''), md5(f'{method}:{values.get("uri")}')]))
    return header.startswith('Digest ') and values.get('username') == USER and values.get('response') == expected


class HTTP(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def respond(self, code, value=None, headers=None):
        data = json.dumps(value).encode() if value is not None else b''
        self.send_response(code)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(data)))
        for key, value in (headers or {}).items():
            self.send_header(key, value)
        self.end_headers()
        try:
            self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def authenticate(self, family):
        if family == 'prusa' and not digest_ok(self.headers.get('Authorization', ''), self.command):
            self.respond(401, headers={'WWW-Authenticate': f'Digest realm="{REALM}", nonce="{NONCE}", algorithm=MD5, qop="auth"'})
            return False
        return True

    def do_GET(self):
        path = urlsplit(self.path).path
        if path == '/metrics':
            self.respond(200, {'commands': commands, 'violations': violations})
            return
        family = path.split('/')[1]
        if not self.authenticate(family):
            return
        current = state(family)
        if family == 'moonraker':
            body = {'result': {'objects': []}} if path.endswith('/list') else {'result': {'status': {
                'print_stats': {'state': current, 'filename': 'fixture.gcode', 'print_duration': 600},
                'display_status': {'progress': .5}}}}
        elif family == 'prusa':
            body = {'printer': {'state': 'STOPPED' if current == 'cancelled' else current.upper()}, 'job': {'id': 42, 'progress': 50, 'time_printing': 600}} if path.endswith('/status') else {'id': 42, 'file': {'display_name': 'fixture.gcode'}}
        else:
            body = {'state': {'printing': 'Printing', 'paused': 'Paused', 'cancelled': 'Operational'}[current],
                    'job': {'file': {'name': 'fixture.gcode', 'path': 'fixture.gcode'}},
                    'progress': {'completion': 50, 'printTime': 600}} if path.endswith('/job') else {}
        self.respond(200, body)

    def do_POST(self):
        path = urlsplit(self.path).path
        body = self.rfile.read(int(self.headers.get('Content-Length', 0)))
        if path == '/reset':
            with lock:
                states.clear(); commands.clear(); violations.clear()
            self.respond(204)
            return
        family = path.split('/')[1]
        if not self.authenticate(family):
            return
        if family in ('redirect', 'cross-redirect'):
            origin = f'http://127.0.0.1:{trap.server_address[1]}' if family == 'cross-redirect' else ''
            self.respond(307, headers={'Location': origin + '/trap'})
            return
        if family == 'trap':
            violations.append('A control redirect was followed')
            self.respond(403)
            return
        if family == 'reject':
            self.respond(403)
            return
        if family == 'moonraker':
            action = path.rsplit('/', 1)[-1]
            action = 'stop' if action == 'cancel' else action
        elif family == 'prusa':
            if '/job/42' not in path:
                self.respond(409)
                return
            action = 'stop' if self.command == 'DELETE' else path.rsplit('/', 1)[-1]
        else:
            value = json.loads(body)
            action = 'stop' if value.get('command') == 'cancel' else value.get('action')
        mutate(family, action)
        if family == 'slow':
            done.wait(2)
        self.respond(200, {'result': 'ok'}) if family == 'moonraker' else self.respond(204)

    do_PUT = do_DELETE = do_POST


class TCP(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


class HTTPServer(http.server.ThreadingHTTPServer):
    def server_bind(self):
        socketserver.TCPServer.server_bind(self)
        self.server_name = 'localhost'
        self.server_port = self.server_address[1]


def read(stream, size):
    result = b''
    while len(result) < size:
        part = stream.recv(size - len(result))
        if not part:
            raise EOFError()
        result += part
    return result


def mqtt_frame(stream):
    header = read(stream, 1)[0]
    size, multiplier = 0, 1
    while True:
        digit = read(stream, 1)[0]
        size += (digit & 127) * multiplier
        if not digit & 128:
            break
        multiplier *= 128
    return header, read(stream, size)


def mqtt_packet(header, body):
    result = bytearray([header]); size = len(body)
    while True:
        digit, size = size % 128, size // 128
        result.append(digit | (128 if size else 0))
        if not size:
            return bytes(result) + body


def mqtt_string(value):
    data = value.encode()
    return struct.pack('!H', len(data)) + data


class MQTT(socketserver.BaseRequestHandler):
    def handle(self):
        try:
            with tls.wrap_socket(self.request, server_side=True) as stream:
                stream.settimeout(2)
                header, connect = mqtt_frame(stream)
                assert header == 0x10
                stream.sendall(b'\x20\x02\x00\x00')
                header, body = mqtt_frame(stream)
                assert header == 0x82 and b'device/FIXTURE/report' in body
                stream.sendall(b'\x90\x03\x00\x01\x00')
                header, body = mqtt_frame(stream)
                assert header == 0x30 and b'"command":"pushall"' in body

                def publish(value):
                    stream.sendall(mqtt_packet(0x30, mqtt_string('device/FIXTURE/report') + json.dumps(value).encode()))

                publish({'print': {'gcode_state': {'printing': 'RUNNING', 'paused': 'PAUSE', 'cancelled': 'FAILED'}[state('bambu')],
                                  'mc_percent': 50, 'subtask_name': 'fixture.gcode', 'task_id': 'fixture-task',
                                  'print_error': 0x0300400C if state('bambu') == 'cancelled' else 0}})
                _, body = mqtt_frame(stream)
                length = struct.unpack('!H', body[:2])[0]
                value = json.loads(body[2 + length:])['print']
                action, sequence = value['command'], value['sequence_id']
                if b'reject-control' not in connect:
                    mutate('bambu', action)
                publish({'print': {'command': action, 'sequence_id': 'unrelated', 'result': 'success'}})
                if b'wrong-ack' in connect or b'silent-control' in connect:
                    done.wait(1)
                    return
                reply = {'command': action, 'sequence_id': sequence,
                         'result': 'failed' if b'reject-control' in connect else 'success'}
                if b'reject-control-authorization' in connect:
                    reply['reason'] = 'mqtt message verify failed'
                publish({'print': reply})
        except (EOFError, OSError):
            pass
        except Exception as error:
            violations.append(type(error).__name__)


def ws_read(stream):
    header = read(stream, 2); size = header[1] & 127
    if size == 126: size = struct.unpack('!H', read(stream, 2))[0]
    if size == 127: size = struct.unpack('!Q', read(stream, 8))[0]
    mask = read(stream, 4) if header[1] & 128 else None
    data = read(stream, size)
    if mask: data = bytes(b ^ mask[i % 4] for i, b in enumerate(data))
    return json.loads(data)


class WS(socketserver.BaseRequestHandler):
    def handle(self):
        try:
            stream = self.request; stream.settimeout(2)
            raw = b''
            while not raw.endswith(b'\r\n\r\n'): raw += read(stream, 1)
            lines = raw.decode().split('\r\n'); path = lines[0].split()[1]
            headers = {k.lower(): v.strip() for k, v in (line.split(':', 1) for line in lines[1:] if ':' in line)}
            accept = base64.b64encode(hashlib.sha1((headers['sec-websocket-key'] + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest()).decode()
            stream.sendall(('HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ' + accept + '\r\n\r\n').encode())

            def send(value):
                data = json.dumps(value).encode(); size = len(data)
                stream.sendall(b'\x81' + (bytes([size]) if size < 126 else b'\x7e' + struct.pack('!H', size)) + data)

            if path == '/creality':
                def native_status():
                    return {'state': {'printing': 1, 'paused': 5, 'cancelled': 4}[state('creality')],
                            'nozzleTemp': 210, 'printProgress': 50, 'printFileName': 'fixture.gcode'}
                send(native_status())
                value = ws_read(stream)
                assert value['method'] == 'set'
                params = value['params']
                assert params in ({'pause': 1}, {'pause': 0}, {'stop': 1})
                mutate('creality', 'stop' if 'stop' in params else 'pause' if params['pause'] == 1 else 'resume')
                send(native_status())
                return
            query = ws_read(stream)
            assert query['Data']['Cmd'] == 0
            send({'Status': {'PrintInfo': {'Status': {'printing': 3, 'paused': 6, 'cancelled': 0}[state('sdcp')],
                  'CurrentLayer': 50, 'TotalLayer': 100, 'Filename': 'fixture.ctb', 'TaskId': 'fixture-task'}}})
            value = ws_read(stream)['Data']; number = value['Cmd']
            mutate('sdcp', {129: 'pause', 130: 'stop', 131: 'resume'}[number])
            reply = {'Topic': 'sdcp/response/FIXTURE-BOARD', 'Data': dict(value, Data={'Ack': 0})}
            reply['Data']['RequestID'] = 'unrelated'
            send(reply)
            if path == '/wrong-ack':
                done.wait(1)
                return
            reply['Data']['RequestID'] = value['RequestID']
            send(reply)
        except (EOFError, OSError, json.JSONDecodeError, UnicodeDecodeError):
            pass
        except Exception as error:
            violations.append(type(error).__name__)


class UDP(socketserver.BaseRequestHandler):
    def handle(self):
        payload, stream = self.request
        assert payload == b'M99999'
        stream.sendto(json.dumps({'Id': 'FIXTURE', 'Data': {'MainboardID': 'FIXTURE-BOARD'}}).encode(), self.client_address)


server = HTTPServer(('127.0.0.1', 0), HTTP)
trap = HTTPServer(('127.0.0.1', 0), HTTP)
ws = TCP(('127.0.0.1', 0), WS)
servers = [server, trap, ws]
ports = {'http': server.server_address[1], 'websocket': ws.server_address[1]}
subprocess.run(['/usr/bin/openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1', '-subj', '/CN=localhost', '-keyout', str(directory/'key.pem'), '-out', str(directory/'certificate.pem')], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
tls.load_cert_chain(directory/'certificate.pem', directory/'key.pem')
for name, constructor in [('mqtt', lambda: TCP(('127.0.0.1', 8883), MQTT)), ('sdcp', lambda: socketserver.ThreadingUDPServer(('127.0.0.1', 3000), UDP))]:
    try:
        instance = constructor(); servers.append(instance); ports[name] = True
    except OSError:
        ports[name] = False
for instance in servers: threading.Thread(target=instance.serve_forever, daemon=True).start()
(directory/'ready.json').write_text(json.dumps(ports))
signal.signal(signal.SIGTERM, lambda *_: done.set())
done.wait()
for instance in servers: instance.shutdown(); instance.server_close()
