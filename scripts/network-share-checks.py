#!/usr/bin/env python3
"""Synthetic WebDAV, connection and navigation checks; never accesses saved share configuration."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import base64
import subprocess
import threading
import os

ROOT = Path(__file__).resolve().parent.parent
SIZE = 32 * 1024 * 1024

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def authenticate(self):
        if self.headers.get('Authorization') == 'Basic ' + base64.b64encode(b'fixture:fixture').decode():
            return True
        self.send_response(401)
        self.send_header('WWW-Authenticate', 'Basic realm="fixture"')
        self.send_header('Content-Length', '0')
        self.end_headers()
        return False

    def do_PROPFIND(self):
        if not self.authenticate():
            return
        if self.headers.get('Depth') != '1':
            self.send_error(400)
            return
        data = ('<d:multistatus xmlns:d="DAV:">' + ''.join(
            '<d:response><d:href>/dav/' + name + '</d:href><d:propstat><d:prop><d:getcontentlength>' + str(SIZE) + '</d:getcontentlength></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>'
            for name in ['Video.mp4', 'NoRanges.mp4']) + '</d:multistatus>').encode()
        self.send_response(207)
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if not self.authenticate():
            return
        start, end = 0, SIZE - 1
        ranged = self.headers.get('Range') and 'NoRanges' not in self.path
        if ranged:
            value = self.headers['Range'].removeprefix('bytes=')
            a, b = value.split('-')
            start, end = int(a), int(b) if b else SIZE - 1
        self.send_response(206 if ranged else 200)
        self.send_header('Content-Type', 'video/mp4')
        self.send_header('Content-Length', str(end - start + 1))
        self.send_header('Accept-Ranges', 'bytes')
        if ranged:
            self.send_header('Content-Range', f'bytes {start}-{end}/{SIZE}')
        self.end_headers()
        remaining = end - start + 1
        try:
            while remaining:
                count = min(remaining, 256 * 1024)
                self.wfile.write(b'*' * count)
                remaining -= count
        except (BrokenPipeError, ConnectionResetError):
            pass

if __name__ == '__main__':
    build = ROOT / 'build/network-share-checks'
    build.mkdir(parents=True, exist_ok=True)
    binary = build / 'NetworkShareChecks'
    subprocess.run(['swiftc', '-swift-version', '6', '-parse-as-library', '-I', str(ROOT / 'Sources/CSQLite'),
                    '-module-cache-path', str(build / 'ModuleCache'),
                    *map(str, sorted((ROOT / 'Sources/AirThrowCore').glob('*.swift'))),
                    str(ROOT / 'Sources/AirThrowApp/NetworkLibraryModel.swift'),
                    str(ROOT / 'Tests/NetworkShareChecks/main.swift'), '-o', str(binary)], cwd=ROOT, check=True, timeout=240)
    server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        subprocess.run([str(binary), f'http://127.0.0.1:{server.server_port}/dav/'], check=True, timeout=120)
    finally:
        server.shutdown()
        server.server_close()
