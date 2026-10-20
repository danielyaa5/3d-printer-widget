"""Loopback-only, synthetic printer protocols for integration and manual UI tests.

Run with a temporary output directory. No printer, account, or LAN access is used.
The optional state.json in that directory changes the OctoPrint fixture's state.
"""
import argparse
import base64
import faulthandler
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

faulthandler.dump_traceback_later(10, repeat=True)
parser = argparse.ArgumentParser()
parser.add_argument("--directory", required=True)
args = parser.parse_args()
directory = pathlib.Path(args.directory)
directory.mkdir(parents=True, exist_ok=True)
requests, violations = [], []
done = threading.Event()
USER, PASSWORD, REALM, NONCE = "fixture-user", "fixture-password", "test", "test-nonce"


def digest_ok(header, method):
    if not header.startswith("Digest "):
        return False
    values = {k: quoted or plain.strip() for k, quoted, plain in
              re.findall(r'(\w+)=(?:"([^"]*)"|([^,]*))', header[7:])}
    md5 = lambda value: hashlib.md5(value.encode()).hexdigest()
    expected = md5(":".join([md5(f"{USER}:{REALM}:{PASSWORD}"), NONCE,
                           values.get("nc", ""), values.get("cnonce", ""),
                           values.get("qop", ""), md5(f'{method}:{values.get("uri")}')]))
    return values.get("username") == USER and values.get("response") == expected


class HTTP(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_POST(self):
        violations.append("Unexpected HTTP mutation")
        self.send_error(405)

    do_PUT = do_DELETE = do_POST

    def do_GET(self):
        path = urlsplit(self.path).path
        requests.append({"method": "GET", "path": path})
        code, body = 200, {}
        if path == "/metrics":
            body = {"requests": requests, "violations": violations}
        elif path.startswith("/redirect/"):
            self.send_response(302)
            self.send_header("Location", f"http://127.0.0.1:{trap.server_address[1]}/trap")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        elif path.startswith("/auth/"):
            code = 401
        elif path.startswith("/forbidden/"):
            code = 403
        elif path.startswith("/unavailable/"):
            code = 503
        elif path.startswith("/bad/"):
            body = "malformed"
        elif path.startswith("/oversized/"):
            body = " " * (2 * 1024 * 1024 + 1)
        elif path.startswith("/slow/"):
            done.wait(2)
            body = {"state": "Operational"}
        elif path.startswith("/budget/"):
            done.wait(.35)
            body = {"result": {"objects": []}} if path.endswith("/list") else {
                "result": {"status": {"print_stats": {"state": "standby"}}}}
        elif path.startswith("/moonraker/"):
            if path.endswith("/list"):
                body = {"result": {"objects": ["print_stats", "heater_generic chamber",
                                               "temperature_fan chamber_fan"]}}
            else:
                body = {"result": {"status": {"print_stats": {"state": "printing", "print_duration": 600},
                        "display_status": {"progress": .5}, "extruder": {"temperature": 210},
                        "heater_bed": {"temperature": 60}, "heater_generic chamber": {
                            "temperature": 35, "target": 40}}}}
        elif path.startswith("/prusa/"):
            if not digest_ok(self.headers.get("Authorization", ""), "GET"):
                self.send_response(401)
                self.send_header("WWW-Authenticate",
                                 f'Digest realm="{REALM}", nonce="{NONCE}", algorithm=MD5, qop="auth"')
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            if path.endswith("/status"):
                body = {"printer": {"state": "PRINTING", "temp_nozzle": 215, "temp_bed": 60},
                        "job": {"progress": 50, "time_remaining": 600}}
            else:
                body = {"file": {"display_name": "Fixture planter.gcode"}}
        elif path.startswith("/octo/"):
            state_file = directory / "state.json"
            state = json.loads(state_file.read_text()) if state_file.exists() else {}
            if state.get("http"):
                code = state["http"]
            elif path.endswith("/job"):
                body = {"state": state.get("state", "Printing"),
                        "job": {"file": {"name": "Fixture planter.gcode"}},
                        "progress": {"completion": state.get("progress", 50),
                                     "printTime": 600, "printTimeLeft": 600}}
            else:
                body = {"temperature": {"tool0": {"actual": 210}, "bed": {"actual": 60},
                                        "chamber": {"actual": 35, "target": 40}}}
        elif path == "/duet/rr_connect":
            body = {"err": 0, "sessionKey": 42}
        elif path == "/sbc/rr_connect":
            code = 404
        elif path == "/sbc/machine/connect":
            body = {"sessionKey": "fixture-session"}
        elif path in ["/duet/rr_model", "/sbc/machine/model"]:
            if self.headers.get("X-Session-Key") not in ["42", "fixture-session"]:
                code = 403
            model = {"state": {"status": "processing"}, "job": {
                "file": {"fileName": "fixture.gcode", "size": 1000}, "filePosition": 500,
                "timesLeft": {"file": 600}}}
            body = {"result": model} if path.startswith("/duet/") else model
        elif path in ["/duet/rr_disconnect", "/sbc/machine/disconnect"]:
            body = {"err": 0}
        else:
            code = 404
        payload = body.encode() if isinstance(body, str) else json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        try:
            self.wfile.write(payload)
        except (BrokenPipeError, ConnectionResetError):
            pass  # Expected in cancellation and timeout tests.


class Trap(HTTP):
    def do_GET(self):
        violations.append("Cross-origin redirect followed")
        self.send_error(403)


def read(stream, count):
    result = b""
    while len(result) < count:
        chunk = stream.recv(count - len(result))
        if not chunk:
            raise EOFError()
        result += chunk
    return result


class WS(socketserver.BaseRequestHandler):
    def handle(self):
        stream = self.request
        stream.settimeout(3)
        try:
            raw = b""
            while not raw.endswith(b"\r\n\r\n"):
                raw += read(stream, 1)
            lines = raw.decode().split("\r\n")
            path = lines[0].split()[1]
            headers = {k.lower(): v.strip() for k, v in
                       (line.split(":", 1) for line in lines[1:] if ":" in line)}
            accept = base64.b64encode(hashlib.sha1(
                (headers["sec-websocket-key"] + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()).decode()
            stream.sendall(("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n"
                            f"Connection: Upgrade\r\nSec-WebSocket-Accept: {accept}\r\n\r\n").encode())

            def send(value):
                payload = json.dumps(value).encode()
                size = len(payload)
                length = bytes([size]) if size < 126 else bytes([126]) + struct.pack("!H", size)
                stream.sendall(b"\x81" + length + payload)

            if path == "/silent":
                done.wait(2)
                return
            if path == "/closed":
                return
            if path == "/creality":
                send(["ignore unrelated message"])
                send({"state": 1})
                send({"nozzleTemp": 210, "bedTemp0": 60, "boxTemp": 35,
                      "printProgress": 50, "printLeftTime": 600, "printFileName": "Fixture planter.gcode"})
            else:
                header = read(stream, 2)
                size = header[1] & 127
                if size == 126:
                    size = struct.unpack("!H", read(stream, 2))[0]
                elif size == 127:
                    size = struct.unpack("!Q", read(stream, 8))[0]
                mask = read(stream, 4) if header[1] & 128 else None
                payload = read(stream, size)
                if mask:
                    payload = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
                command = json.loads(payload)
                if command["Data"]["Cmd"] != 0:
                    violations.append("Non-status SDCP command")
                if command["Data"]["MainboardID"] != "FIXTURE-BOARD":
                    violations.append("Wrong fixture board")
                requests.append({"method": "WS", "path": path, "command": command["Data"]["Cmd"]})
                send({"Data": {"Cmd": 0}})  # Acknowledgement is not a status report.
                send({"Status": {"TempOfBox": 30, "PrintInfo": {
                    "Status": 3, "CurrentLayer": 50, "TotalLayer": 100,
                    "CurrentTicks": 600000, "TotalTicks": 1200000, "Filename": "Fixture.ctb"}}})
            done.wait(.1)
        except (EOFError, OSError):
            pass


class UDP(socketserver.BaseRequestHandler):
    def handle(self):
        payload, stream = self.request
        if payload != b"M99999":
            violations.append("Unexpected discovery command")
            return
        stream.sendto(json.dumps({"Id": "FIXTURE", "Data": {
            "MainboardID": "FIXTURE-BOARD"}}).encode(), self.client_address)


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
    size, encoded = len(body), bytearray([header])
    while True:
        digit, size = size % 128, size // 128
        encoded.append(digit | (128 if size else 0))
        if not size:
            return bytes(encoded) + body


def mqtt_string(value):
    data = value.encode()
    return struct.pack("!H", len(data)) + data


class MQTT(socketserver.BaseRequestHandler):
    def handle(self):
        try:
            stream = tls.wrap_socket(self.request, server_side=True)
            stream.settimeout(3)
            header, body = mqtt_frame(stream)
            if header != 0x10:
                violations.append("Missing MQTT connect")
                return
            if b"wrong-password" in body:
                stream.sendall(b"\x20\x02\x00\x05")
                return
            stream.sendall(b"\x20\x02\x00\x00")
            header, body = mqtt_frame(stream)
            if header != 0x82 or b"device/FIXTURE/report" not in body:
                violations.append("Unexpected MQTT subscription")
                return
            stream.sendall(b"\x90\x03\x00\x01\x00")
            header, body = mqtt_frame(stream)
            if header != 0x30 or b'"command":"pushall"' not in body:
                violations.append("Non-status MQTT command")
                return
            requests.append({"method": "MQTT", "command": "pushall"})
            messages = [
                mqtt_packet(0x30, mqtt_string("device/OTHER/report") +
                            b'{"print":{"gcode_state":"FINISH","mc_percent":100}}'),
                mqtt_packet(0x30, mqtt_string("device/FIXTURE/report") +
                            b'{"print":{"gcode_state":"RUNNING","nozzle_temper":210}}'),
                mqtt_packet(0x30, mqtt_string("device/FIXTURE/report") +
                            b'{"print":{"mc_percent":50,"mc_remaining_time":10}}'),
            ]
            # Exercise frames spanning reads and multiple frames within one read.
            packet = b"".join(messages)
            stream.sendall(packet[:7])
            done.wait(.02)
            stream.sendall(packet[7:])
            done.wait(.1)
            stream.close()
        except (EOFError, OSError):
            pass  # Includes the intentional certificate-pin rejection.


class TCP(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), HTTP)
trap = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Trap)
ws = TCP(("127.0.0.1", 0), WS)
servers = [server, trap, ws]
ports = {"http": server.server_address[1], "websocket": ws.server_address[1]}
try:
    udp = socketserver.ThreadingUDPServer(("127.0.0.1", 3000), UDP)
    udp.daemon_threads = True
    servers.append(udp)
    ports["sdcp"] = True
except OSError:
    ports["sdcp"] = False

subprocess.run(["/usr/bin/openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
                "-days", "1", "-subj", "/CN=localhost", "-keyout", str(directory / "key.pem"),
                "-out", str(directory / "certificate.pem")], check=True,
               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
tls.load_cert_chain(directory / "certificate.pem", directory / "key.pem")
try:
    mqtt = TCP(("127.0.0.1", 8883), MQTT)
    servers.append(mqtt)
    ports["mqtt"] = True
except OSError:
    ports["mqtt"] = False
for instance in servers:
    threading.Thread(target=instance.serve_forever, daemon=True).start()
(directory / "ready.json").write_text(json.dumps(ports))
faulthandler.cancel_dump_traceback_later()
signal.signal(signal.SIGTERM, lambda *_: done.set())
signal.signal(signal.SIGINT, lambda *_: done.set())
done.wait()
for instance in servers:
    instance.shutdown()
    instance.server_close()
(directory / "result.json").write_text(json.dumps({"requests": requests, "violations": violations}, indent=2))
