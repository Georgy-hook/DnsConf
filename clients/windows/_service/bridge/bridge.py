"""Local-only DNS -> authenticated NextDNS DoH; no hosts rewriting or DNS cache."""
import argparse
import concurrent.futures
import ctypes
import datetime as dt
import json
import os
from pathlib import Path
import re
import socket
import ssl
import struct
import sys
import threading
import time

SERVERS = ('45.90.28.0', '45.90.30.0')
HOST = 'dns.nextdns.io'

class DoH:
    def __init__(self, profile):
        if not re.fullmatch(r'[a-fA-F0-9]{6}', profile):
            raise ValueError('Invalid NextDNS profile ID')
        self.profile = profile.lower()
        self.context = ssl.create_default_context()
        self.context.minimum_version = ssl.TLSVersion.TLSv1_3
        self.context.maximum_version = ssl.TLSVersion.TLSv1_3
        self.preferred = 0
        self.lock = threading.Lock()
        self.active = set()

    def close(self):
        with self.lock:
            for sock in list(self.active):
                try:
                    sock.shutdown(socket.SHUT_RDWR)
                    sock.close()
                except OSError:
                    pass

    def query(self, query):
        with self.lock:
            first = self.preferred
        last_error = None
        for attempt in range(len(SERVERS)):
            index = (first + attempt) % len(SERVERS)
            try:
                reply = self.request(query, SERVERS[index])
                if len(reply) < 12 or reply[:2] != query[:2] or not reply[2] & 128:
                    raise ValueError('DoH reply does not match DNS request')
                with self.lock:
                    self.preferred = index
                return reply
            except (OSError, EOFError, ValueError, ssl.SSLError) as exc:
                last_error = exc
        raise OSError('NextDNS: ' + type(last_error).__name__)

    def request(self, query, server):
        deadline = time.monotonic() + 5
        raw = socket.create_connection((server, 443), 2.0)
        raw.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        with self.lock:
            self.active.add(raw)
        incoming, outgoing = ssl.MemoryBIO(), ssl.MemoryBIO()
        tls = self.context.wrap_bio(incoming, outgoing, server_side=False, server_hostname=HOST)
        def receive():
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError('DoH deadline')
            raw.settimeout(remaining)
            data = raw.recv(65536)
            if not data:
                raise EOFError('DoH peer closed')
            incoming.write(data)
        def flush(first=False):
            data = outgoing.read()
            if not data:
                return
            if first:
                data = split_hello(data)
                # Send two valid records; TLS handshake bytes remain identical.
                length = 5 + int.from_bytes(data[3:5], 'big')
                raw.sendall(data[:length])
                time.sleep(.08)
                raw.sendall(data[length:])
            else:
                raw.sendall(data)
        try:
            first = True
            while True:
                try:
                    tls.do_handshake()
                    break
                except ssl.SSLWantReadError:
                    flush(first)
                    first = False
                    receive()
            flush()
            header = (f'POST /{self.profile} HTTP/1.1\r\nHost: {HOST}\r\n'
                      'Accept: application/dns-message\r\nContent-Type: application/dns-message\r\n'
                      f'Content-Length: {len(query)}\r\nConnection: close\r\n\r\n').encode('ascii')
            tls.write(header + query)
            flush()
            response = bytearray()
            def read_more():
                while True:
                    try:
                        part = tls.read(65536)
                        if not part:
                            raise EOFError('DoH body truncated')
                        return part
                    except ssl.SSLWantReadError:
                        flush()
                        receive()
            while b'\r\n\r\n' not in response:
                response += read_more()
                if len(response) > 81920:
                    raise ValueError('DoH response too large')
            head, body = bytes(response).split(b'\r\n\r\n', 1)
            lines = head.split(b'\r\n')
            if not lines[0].startswith(b'HTTP/1.1 200 '):
                raise ValueError('DoH HTTP status not 200')
            fields = dict(line.split(b':', 1) for line in lines[1:] if b':' in line)
            fields = {k.lower(): v.strip().lower() for k, v in fields.items()}
            if fields.get(b'content-type', b'').split(b';')[0] != b'application/dns-message':
                raise ValueError('Unexpected DoH content type')
            if b'content-length' in fields:
                length = int(fields[b'content-length'])
                if not 12 <= length <= 65535:
                    raise ValueError('DoH body length')
                while len(body) < length:
                    body += read_more()
                return body[:length]
            if fields.get(b'transfer-encoding') == b'chunked':
                output = bytearray()
                while True:
                    while b'\r\n' not in body:
                        body += read_more()
                    line, body = body.split(b'\r\n', 1)
                    if len(line) > 80:
                        raise ValueError('DoH chunk header')
                    length = int(line.split(b';')[0], 16)
                    if length == 0:
                        return bytes(output)
                    if length < 0 or len(output) + length > 65535:
                        raise ValueError('DoH chunks too large')
                    while len(body) < length + 2:
                        body += read_more()
                    if body[length:length+2] != b'\r\n':
                        raise ValueError('DoH chunk framing')
                    output += body[:length]
                    body = body[length+2:]
            raise ValueError('Unbounded DoH response')
        finally:
            raw.close()
            with self.lock:
                self.active.discard(raw)

def split_hello(data):
    if len(data) < 5 or data[0] != 22 or data[1] != 3:
        raise ValueError('Expected TLS ClientHello')
    length = int.from_bytes(data[3:5], 'big')
    if length < 1 or len(data) < length + 5:
        raise ValueError('Incomplete TLS record')
    payload = data[5:5+length]
    index = payload.find(HOST.encode('ascii'))
    if index < 0:
        raise ValueError('Unexpected TLS destination')
    split = index + 5
    a, b = payload[:split], payload[split:]
    return (data[:3] + struct.pack('!H', len(a)) + a +
            data[:3] + struct.pack('!H', len(b)) + b + data[5+length:])

def failure(query):
    data = bytearray(query)
    if len(data) >= 12:
        data[2] = (data[2] & 0x79) | 0x80
        data[3] = (data[3] & 0x10) | 0x82
        data[6:10] = b'\0' * 4
    return bytes(data)

class Bridge:
    def __init__(self, profile, port, data_root):
        self.doh = DoH(profile)
        self.port = port
        self.root = Path(data_root)
        self.stop = threading.Event()
        self.pool = concurrent.futures.ThreadPoolExecutor(max_workers=64)
        self.slots = threading.BoundedSemaphore(64)
        self.sockets = []
        self.lock = threading.RLock()
        self.stats = dict(version=1, startedAt=self.now(), at=self.now(), lastSuccessAt=None,
                          successCount=0, failureCount=0, upstream=SERVERS[0], lastError='', running=True)
        ticks = ctypes.windll.kernel32.GetTickCount64
        ticks.restype = ctypes.c_uint64
        self.boot_at = (dt.datetime.now(dt.timezone.utc) - dt.timedelta(milliseconds=ticks())).isoformat()
        self.stats['bootAt'] = self.boot_at

    def boot_probe(self):
        """Check the Windows resolver after service start; retain actual boot proof separately."""
        try:
            route_path = Path(__file__).with_name('routes.json')
            if not route_path.exists():
                route_path = Path(__file__).parent.parent / 'connection-routes.json'
            routes = json.loads(route_path.read_text(encoding='utf-8-sig'))['routes']
            uptime = (dt.datetime.now(dt.timezone.utc) - dt.datetime.fromisoformat(self.boot_at)).total_seconds()
            report = dict(bootAt=self.boot_at, serviceStartedAt=self.stats['startedAt'],
                          afterReboot=uptime < 600, status='checking', checks=[])
            def save():
                with self.lock:
                    self.root.mkdir(parents=True, exist_ok=True)
                    report['at'] = self.now()
                    temporary = self.root / 'boot-check.json.tmp'
                    temporary.write_text(json.dumps(report), encoding='utf-8')
                    os.replace(temporary, self.root / 'boot-check.json')
                    if report['status'] == 'ok' and report['afterReboot']:
                        temporary = self.root / 'boot-verified.json.tmp'
                        temporary.write_text(json.dumps(report), encoding='utf-8')
                        os.replace(temporary, self.root / 'boot-verified.json')
            save()
            for attempt in range(4):
                if self.stop.is_set():
                    return
                nonce = 'boot-' + os.urandom(6).hex()
                checks = []
                for route in routes:
                    try:
                        answers = sorted({item[4][0] for item in socket.getaddrinfo(
                            nonce + '.' + route['domain'], None, socket.AF_UNSPEC, socket.SOCK_STREAM)})
                        good = bool(answers) and set(answers).issubset(route['addresses'])
                    except OSError:
                        answers, good = [], False
                    checks.append(dict(domain=route['domain'], addresses=answers, ok=good))
                report.update(checks=checks, attempt=attempt + 1,
                              status='ok' if checks and all(item['ok'] for item in checks) else 'waiting')
                save()
                if report['status'] == 'ok':
                    return
                if self.stop.wait(10):
                    return
            report['status'] = 'error'
            save()
        except Exception:
            # DNS service remains available even when its optional startup report cannot be written.
            return

    @staticmethod
    def now():
        return dt.datetime.now(dt.timezone.utc).isoformat()

    def write_status(self):
        with self.lock:
            try:
                self.root.mkdir(parents=True, exist_ok=True)
                self.stats['at'] = self.now()
                temporary = self.root / 'status.json.tmp'
                temporary.write_text(json.dumps(self.stats), encoding='utf-8')
                os.replace(temporary, self.root / 'status.json')
            except OSError:
                pass

    def resolve(self, query):
        try:
            answer = self.doh.query(query)
            with self.lock:
                self.stats.update(lastSuccessAt=self.now(), lastError='', upstream=SERVERS[self.doh.preferred])
                self.stats['successCount'] += 1
            return answer
        except Exception as exc:
            with self.lock:
                self.stats['failureCount'] += 1
                self.stats['lastError'] = type(exc).__name__ + ': ' + str(exc)[:160]
            return failure(query)
        finally:
            self.write_status()

    def start(self):
        try:
            for family, ip in ((socket.AF_INET, '127.0.0.1'), (socket.AF_INET6, '::1')):
                for kind in (socket.SOCK_DGRAM, socket.SOCK_STREAM):
                    sock = socket.socket(family, kind)
                    sock.setsockopt(socket.SOL_SOCKET, socket.SO_EXCLUSIVEADDRUSE, 1)
                    sock.bind((ip, self.port))
                    self.sockets.append(sock)
                    if kind == socket.SOCK_DGRAM:
                        action = self.udp
                    else:
                        sock.listen(64)
                        action = self.tcp
                    threading.Thread(target=action, args=(sock,), daemon=True).start()
            self.write_status()
            print('READY', flush=True)
            threading.Thread(target=self.boot_probe, daemon=True).start()
            while not self.stop.wait(30):
                self.write_status()
        finally:
            self.close()

    def submit(self, action, *args):
        if not self.slots.acquire(False):
            return False
        def run():
            try:
                action(*args)
            finally:
                self.slots.release()
        self.pool.submit(run)
        return True

    def udp(self, sock):
        while not self.stop.is_set():
            try:
                query, peer = sock.recvfrom(65535)
                if len(query) >= 12 and not query[2] & 128:
                    def answer(q, p):
                        try:
                            sock.sendto(self.resolve(q), p)
                        except OSError:
                            pass
                    if not self.submit(answer, query, peer):
                        sock.sendto(failure(query), peer)
            except OSError:
                if not self.stop.is_set():
                    time.sleep(.1)

    @staticmethod
    def exact(sock, length):
        parts = bytearray()
        while len(parts) < length:
            data = sock.recv(length - len(parts))
            if not data:
                raise EOFError('DNS TCP closed')
            parts += data
        return bytes(parts)

    def tcp(self, listener):
        while not self.stop.is_set():
            try:
                sock, _ = listener.accept()
                if not self.submit(self.tcp_client, sock):
                    sock.close()
            except OSError:
                if not self.stop.is_set():
                    time.sleep(.1)

    def tcp_client(self, sock):
        with sock:
            sock.settimeout(12)
            try:
                for _ in range(16):
                    length = int.from_bytes(self.exact(sock, 2), 'big')
                    if length < 12:
                        return
                    response = self.resolve(self.exact(sock, length))
                    sock.sendall(struct.pack('!H', len(response)) + response)
            except (OSError, EOFError):
                pass

    def close(self):
        self.stop.set()
        for sock in self.sockets:
            sock.close()
        self.doh.close()
        self.pool.shutdown(wait=False, cancel_futures=True)
        with self.lock:
            self.stats['running'] = False
        self.write_status()

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--profile-file', required=True)
    parser.add_argument('--port', type=int, default=53)
    parser.add_argument('--data-dir', required=True)
    args = parser.parse_args()
    profile = Path(args.profile_file).read_text(encoding='utf-8-sig').strip()
    bridge = Bridge(profile, args.port, args.data_dir)
    def control():
        for line in sys.stdin:
            if line.strip() == 'STOP':
                bridge.stop.set()
                return
    threading.Thread(target=control, daemon=True).start()
    bridge.start()

if __name__ == '__main__':
    main()
