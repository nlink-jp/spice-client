#!/usr/bin/env python3
"""Loopback-only TLS portal and small SPICE wire peer. No VM or credentials needed.

The peer implements bootstrap, a primary surface, input reception and negative
paths; it does not pretend to validate real guest audio/codecs/interoperability.
Wire fixtures are informed by SwiftSpice's pinned protocol tests (MIT).
"""
import gzip
import http.server
import json
import os
from pathlib import Path
import signal
import socket
import ssl
import struct
import subprocess
import tempfile
import threading

ROOT = Path(__file__).resolve().parent.parent
STOP = threading.Event()
LOCK = threading.Lock()
COUNTS = {"connections": 0, "closed": 0, "input_packets": 0, "public_cookie_leaks": 0}


def u32(*values):
    return struct.pack('<' + 'I' * len(values), *values)


def mini(kind, body=b''):
    return struct.pack('<HI', kind, len(body)) + body


def exact(conn, count):
    data = bytearray()
    while len(data) < count and not STOP.is_set():
        try:
            part = conn.recv(count - len(data))
        except socket.timeout:
            continue
        if not part:
            raise EOFError()
        data.extend(part)
    if len(data) != count:
        raise EOFError()
    return bytes(data)


def start_peer(public_key, mode='normal'):
    listener = socket.socket()
    listener.bind(('127.0.0.1', 0))
    listener.listen(8)
    listener.settimeout(0.2)
    port = listener.getsockname()[1]

    def client(conn):
        with conn:
            conn.settimeout(0.2)
            with LOCK:
                COUNTS['connections'] += 1
            try:
                header = exact(conn, 16)
                magic, major, minor, size = struct.unpack('<4sIII', header)
                assert magic == b'REDQ' and major == 2 and size <= 4096
                body = exact(conn, size)
                channel = body[4]
                if mode == 'stalled':
                    while not STOP.wait(0.1):
                        try:
                            if not conn.recv(1):
                                break
                        except socket.timeout:
                            continue
                    return
                if mode == 'malformed':
                    conn.sendall(b'NOPE' + u32(2, 2, 0))
                    return
                reply = u32(0) + public_key + u32(1, 0, 178) + u32(0b1011)
                conn.sendall(b'REDQ' + u32(2, 2, len(reply)) + reply)
                assert exact(conn, 4) == u32(1)
                exact(conn, 128)  # encrypted synthetic ticket; never recorded
                conn.sendall(u32(5 if mode == 'authentication' else 0))
                if mode == 'authentication':
                    return
                if channel == 1:
                    conn.sendall(mini(103, u32(77, 1, 3, 2, 0, 0, 0, 0)))
                    conn.sendall(mini(104, u32(2) + bytes([2, 0, 3, 0])))
                elif channel == 2:
                    conn.sendall(mini(314, u32(0, 128, 96, 32, 1)))
                elif channel == 3:
                    conn.sendall(mini(101, struct.pack('<H', 0)))
                while not STOP.is_set():
                    message, size = struct.unpack('<HI', exact(conn, 6))
                    assert size <= 1 << 20
                    exact(conn, size)
                    if channel == 3:
                        with LOCK:
                            COUNTS['input_packets'] += 1
            except (OSError, EOFError, AssertionError, struct.error):
                pass
            finally:
                with LOCK:
                    COUNTS['closed'] += 1

    def serve():
        while not STOP.is_set():
            try:
                conn, _ = listener.accept()
                threading.Thread(target=client, args=(conn,), daemon=True).start()
            except socket.timeout:
                pass
            except OSError:
                return
    threading.Thread(target=serve, daemon=True).start()
    return listener, port


def main():
    with tempfile.TemporaryDirectory(prefix='spice-client-simulation-') as work:
        work = Path(work)
        config = work/'openssl.cnf'
        config.write_text('[req]\ndistinguished_name=dn\nx509_extensions=extensions\nprompt=no\n[dn]\nCN=localhost\n[extensions]\nsubjectAltName=DNS:localhost,IP:127.0.0.1\nbasicConstraints=critical,CA:TRUE\nkeyUsage=critical,digitalSignature,keyEncipherment,keyCertSign\nextendedKeyUsage=serverAuth\n')
        subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1',
                        '-config', str(config), '-keyout', str(work/'key.pem'), '-out', str(work/'cert.pem')],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        subprocess.run(['openssl', 'x509', '-in', str(work/'cert.pem'), '-outform', 'DER', '-out', str(work/'cert.der')], check=True)
        subprocess.run(['openssl', 'genrsa', '-out', str(work/'ticket.pem'), '1024'], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        public_key = subprocess.check_output(['openssl', 'pkey', '-in', str(work/'ticket.pem'), '-pubout', '-outform', 'DER'])
        assert len(public_key) == 162
        peers = {mode: start_peer(public_key, mode) for mode in ('normal', 'authentication', 'malformed', 'stalled')}
        ports = {mode: pair[1] for mode, pair in peers.items()}

        class Portal(http.server.BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_POST(self):
                self.rfile.read(min(int(self.headers.get('Content-Length', 0)), 4096))
                self.do_GET()

            def do_GET(self):
                if self.path == '/receipt':
                    with LOCK:
                        body = json.dumps(COUNTS).encode()
                    kind = 'application/json'
                elif self.path in ('/auto.html', '/form.html'):
                    script = "location.href='/session.vv'" if self.path == '/auto.html' else "document.forms[0].submit()"
                    body = ("<html><body><form method='post' action='/session.vv'></form><script>" + script + '</script></body></html>').encode()
                    kind = 'text/html'
                elif self.path in ('/private/start.vv', '/cross-origin.vv'):
                    self.send_response(302)
                    self.send_header('Location', '/public/final.vv' if self.path.startswith('/private') else 'https://127.0.0.1:1/forbidden.vv')
                    self.end_headers()
                    return
                else:
                    if self.path == '/public/final.vv' and 'scoped=' in self.headers.get('Cookie', ''):
                        with LOCK:
                            COUNTS['public_cookie_leaks'] += 1
                    body = f'[virt-viewer]\ntype=spice\nhost=127.0.0.1\nport={ports["normal"]}\npassword=synthetic\n'.encode()
                    if self.path == '/oversized.vv':
                        body += b'x' * (1 << 20)
                    if self.path == '/invalid-utf8.vv':
                        body = bytes([255])
                    kind = 'application/x-virt-viewer'
                if self.path == '/gzip.vv':
                    body = gzip.compress(body)
                self.send_response(200)
                if self.path == '/gzip.vv':
                    self.send_header('Content-Encoding', 'gzip')
                self.send_header('Content-Type', kind)
                self.send_header('Content-Length', str(len(body) + (20 if self.path == '/truncated.vv' else 0)))
                self.end_headers()
                try:
                    self.wfile.write(body)
                except OSError:
                    pass

        server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Portal)
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(work/'cert.pem', work/'key.pem')
        server.socket = context.wrap_socket(server.socket, server_side=True)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        env = dict(os.environ, SPICE_CLIENT_SIMULATION_URL=f'https://localhost:{server.server_port}',
                   SPICE_CLIENT_SIMULATION_CA=str(work/'cert.der'), SPICE_CLIENT_SIMULATION_PORTS=json.dumps(ports))
        process = subprocess.Popen(['swift', 'test', '--disable-sandbox', '-Xswiftc', '-warnings-as-errors'], cwd=ROOT, env=env, start_new_session=True)
        try:
            code = process.wait(timeout=180)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGTERM)
            process.wait(timeout=10)
            code = 1
            print('Simulation timed out.', flush=True)
        finally:
            STOP.set()
            server.shutdown()
            server.server_close()
            for listener, _ in peers.values():
                listener.close()
        print('Simulation counters:', json.dumps(COUNTS, sort_keys=True), flush=True)
        if COUNTS['public_cookie_leaks'] or not COUNTS['input_packets']:
            code = 1
        return code


if __name__ == '__main__':
    raise SystemExit(main())
