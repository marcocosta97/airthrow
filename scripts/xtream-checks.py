#!/usr/bin/env python3
"""Xtream API and controller checks against a deterministic local provider."""
from pathlib import Path
import argparse
import base64
import http.server
import gzip
import json
import os
import plistlib
import shutil
import subprocess
import threading
import time
import urllib.parse

ROOT = Path(__file__).resolve().parent.parent
BUILD = ROOT / 'build/xtream-api-checks'
BUILD.mkdir(parents=True, exist_ok=True)
parser = argparse.ArgumentParser()
parser.add_argument('--serve-only', action='store_true')
args = parser.parse_args()
USER, PASSWORD = 'fixture+user', 'fixture&pass=/word'
LARGE = json.dumps([{'stream_id': n, 'series_id': n, 'name': f'Large title {n}', 'category_id': '1', 'padding': 'x' * 750} for n in range(1, 12001)]).encode()
COUNTS = {}
COUNTS_LOCK = threading.Lock()
class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_GET(self):
        parsed = urllib.parse.urlsplit(self.path)
        query = urllib.parse.parse_qs(parsed.query)
        user, password = query.get('username', [''])[0], query.get('password', [''])[0]
        action = query.get('action', [''])[0]
        prefix = parsed.path.split('/')[1]
        if parsed.path == '/cache/stats':
            with COUNTS_LOCK: counts = dict(COUNTS)
            self.reply(counts); return
        if prefix == 'cache' and action:
            key = action + ':' + query.get('category_id', ['all'])[0]
            with COUNTS_LOCK: COUNTS[key] = COUNTS.get(key, 0) + 1
        if prefix == 'slow': time.sleep(0.7)
        if prefix == 'redirect':
            self.send_response(302); self.send_header('Location', f'http://localhost:{self.server.server_port}/player_api.php?' + parsed.query); self.end_headers(); return
        if prefix == 'oversize':
            self.send_response(200); self.send_header('Content-Length', '70000000'); self.end_headers()
            try:
                self.wfile.write(b'x' * 8192); self.wfile.flush(); time.sleep(0.3)
            except (BrokenPipeError, ConnectionResetError): pass
            return
        if prefix in ('chunked', 'compressed'):
            self.send_response(200)
            if prefix == 'compressed':
                compressed = gzip.compress(b' ' * (65 * 1024 * 1024))
                self.send_header('Content-Encoding', 'gzip')
                self.send_header('Content-Length', str(len(compressed))); self.end_headers()
                try: self.wfile.write(compressed)
                except (BrokenPipeError, ConnectionResetError): pass
            else:
                self.send_header('Transfer-Encoding', 'chunked'); self.end_headers()
                try:
                    for _ in range(1040):
                        self.wfile.write(b'10000\r\n' + b' ' * 65536 + b'\r\n')
                    self.wfile.write(b'0\r\n\r\n')
                except (BrokenPipeError, ConnectionResetError): pass
            return
        if prefix == 'bad': self.reply(b'<html>password=secret</html>', raw=True); return
        if user != USER or password != PASSWORD:
            self.reply({'user_info': {'auth': 0}}); return
        if not action:
            self.reply({'user_info': {'auth': '1', 'status': 'Expired' if prefix == 'expired' else 'Active',
                       'exp_date': '2000000000', 'active_cons': '1', 'max_connections': 2,
                       'allowed_output_formats': ['ts']}, 'server_info': {'timezone': 'Europe/Rome'}}); return
        if prefix == 'scroll' and action in ('get_live_streams', 'get_vod_streams', 'get_series'):
            key = 'series_id' if action == 'get_series' else 'stream_id'
            self.reply([{key: str(n), 'name': f'Title {n:03d}', 'category_id': '1'} for n in range(1, 121)]); return
        if prefix == 'wide' and action.endswith('_categories'):
            self.reply([{'category_id': '1', 'category_name': 'Categoria molto lunga ' * 40},
                        {'category_id': '2', 'category_name': 'ABCDEFGHIJKLMNOPQRSTUVWXYZ' * 40}]); return
        if prefix == 'wide' and action in ('get_live_streams', 'get_vod_streams', 'get_series'):
            key = 'series_id' if action == 'get_series' else 'stream_id'
            self.reply([{key: '11', 'name': 'Titolo molto lungo con spazi ' * 60, 'category_id': '1'},
                        {key: '12', 'name': 'ABCDEFGHIJKLMNOPQRSTUVWXYZ' * 60, 'category_id': '2'}]); return
        if action.endswith('_categories'):
            self.reply([{'category_id': 1, 'category_name': 'News'}, {'category_id': '2', 'category_name': 'Sport'}]); return
        if action in ('get_live_streams', 'get_vod_streams', 'get_series'):
            category = query.get('category_id', [''])[0]
            if prefix == 'large': self.reply(LARGE, raw=True); return
            if prefix == 'filtered' and not category:
                self.send_response(200); self.send_header('Content-Length', '70000000'); self.end_headers()
                try:
                    self.wfile.write(b'x' * 8192); self.wfile.flush(); time.sleep(0.3)
                except (BrokenPipeError, ConnectionResetError): pass
                return
            if category == '2': self.reply({}); return
            if category == '3': time.sleep(0.6)
            key = 'series_id' if action == 'get_series' else 'stream_id'
            self.reply([{key: 11, 'name': 'First title', 'category_id': '1', 'container_extension': 'mp4', 'plot': 'A story', 'year': '2026'},
                        {key: '12', 'name': 'Second title', 'category_id': 1},
                        {key: '12', 'name': 'Duplicate'}, {key: '../bad', 'name': 'Invalid ID'}, {key: 99}]); return
        if action == 'get_vod_info':
            if query.get('vod_id') != ['11']: self.reply({'error': 'Not found'}, status=404); return
            self.reply({'info': {'plot': 'Film plot', 'genre': 'Drama', 'cast': 'Actor', 'director': 'Director', 'duration': '01:02:03', 'rating': '8.4'}, 'movie_data': {'stream_id': 11}}); return
        if action == 'get_series_info' and prefix == 'array':
            self.reply({'info': [], 'episodes': [
                [{'id': 301, 'episode_num': 1, 'title': 'Pilot', 'container_extension': 'mp4', 'info': {'plot': 'Opens'}}],
                [{'id': 302, 'season': 2, 'episode_num': 1, 'title': 'Later'}]
            ]}); return
        if action == 'get_series_info':
            self.reply({'info': {'plot': 'Series plot'}, 'episodes': {
                '2': [{'id': 202, 'season': '2', 'episode_num': 2, 'title': 'Second season', 'container_extension': 'mkv'}],
                '1': [{'id': '102', 'season': 1, 'episode_num': '2', 'title': 'Episode two'},
                      {'id': 101, 'episode_num': 1, 'title': 'Episode one', 'info': {'plot': 'Episode plot', 'duration': '00:30:00'}},
                      {'id': 101, 'episode_num': 9}, {'id': '../escape', 'episode_num': 3}]}}); return
        if action == 'get_simple_data_table' and query.get('stream_id') == ['12']:
            self.reply({'error': 'Not supported'}, status=404); return
        if action in ('get_simple_data_table', 'get_short_epg'):
            self.reply({'epg_listings': [
                {'title': base64.b64encode('Notizie italiane'.encode()).decode(), 'description': base64.b64encode('La guida'.encode()).decode(), 'start_timestamp': '1000000000' if prefix == 'past' else '2000000000', 'stop_timestamp': 1000003600 if prefix == 'past' else 2000003600},
                {'title': 'Legacy schedule', 'start': '2001-09-09 06:33:20' if prefix == 'past' else '2033-05-18 06:33:20', 'end': '2001-09-09 07:33:20' if prefix == 'past' else '2033-05-18 07:33:20'},
                {'title': 'Invalid interval', 'start_timestamp': 20, 'stop_timestamp': 10}]}); return
        self.reply({'error': 'Unknown action'}, status=400)
    def reply(self, value, status=200, raw=False):
        data = value if raw else json.dumps(value).encode()
        self.send_response(status); self.send_header('Content-Length', str(len(data))); self.end_headers()
        try: self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError): pass

server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
try:
    if args.serve_only:
        print(f'http://127.0.0.1:{server.server_port}', flush=True)
        threading.Event().wait()
    binary = BUILD / 'XtreamChecks'
    env = dict(os.environ, CLANG_MODULE_CACHE_PATH=str(BUILD / 'ModuleCache'))
    subprocess.run(['swiftc', '-swift-version', '6', '-parse-as-library', '-module-cache-path', str(BUILD / 'ModuleCache'),
        *map(str, sorted((ROOT / 'Sources/AirThrowCore').glob('*.swift'))),
        *[str(ROOT / ('Sources/AirThrowApp/' + name)) for name in ['MediaDiagnostics.swift', 'PlaybackController.swift', 'ReceiverWaitingScreen.swift', 'XtreamLibrary.swift']],
        str(ROOT / 'Tests/XtreamChecks/main.swift'), '-o', str(binary)], cwd=ROOT, env=env, check=True, timeout=180)
    app = BUILD / 'XtreamChecks.app'
    target = app / 'Contents/MacOS/XtreamChecks'
    target.parent.mkdir(parents=True, exist_ok=True); shutil.copy2(binary, target)
    info = plistlib.loads((ROOT / 'Resources/Info.plist').read_bytes())
    info.update(CFBundleIdentifier='app.airthrow.xtream-checks', CFBundleExecutable='XtreamChecks')
    (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
    subprocess.run([str(target), f'http://127.0.0.1:{server.server_port}'], check=True, timeout=90)
finally:
    server.shutdown(); server.server_close()
