"""Harness Social: separate account/content service. Run only behind HTTPS outside localhost."""
import argparse
import hashlib
import hmac
import json
import re
import secrets
import sqlite3
import threading
import time
from collections import defaultdict, deque
from contextlib import contextmanager
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

MAX_BODY = 8192
SESSION_SECONDS = 30 * 24 * 60 * 60
PASSWORD_ITERATIONS = 600_000


class APIError(Exception):
    def __init__(self, status, message):
        self.status, self.message = status, message


def digest(value):
    return hashlib.sha256(value.encode()).hexdigest()


def required_text(data, key, minimum=1, maximum=500, trim=True):
    value = data.get(key)
    if not isinstance(value, str): raise APIError(400, f'{key} is required.')
    value = value.strip() if trim else value
    if not minimum <= len(value) <= maximum: raise APIError(400, f'{key} must contain {minimum}–{maximum} characters.')
    return value


class Store:
    def __init__(self, path):
        self.path = str(path)
        Path(path).parent.mkdir(parents=True, exist_ok=True)
        with self.connect() as conn:
            conn.executescript('''
            PRAGMA journal_mode=WAL;
            CREATE TABLE IF NOT EXISTS users (
              id TEXT PRIMARY KEY, handle TEXT UNIQUE NOT NULL, display_name TEXT NOT NULL,
              salt TEXT NOT NULL, password_hash TEXT NOT NULL, created REAL NOT NULL);
            CREATE TABLE IF NOT EXISTS sessions (
              token_hash TEXT PRIMARY KEY, user_id TEXT NOT NULL REFERENCES users(id), expires REAL NOT NULL);
            CREATE TABLE IF NOT EXISTS posts (
              id TEXT PRIMARY KEY, author_id TEXT NOT NULL REFERENCES users(id), text TEXT NOT NULL,
              parent_id TEXT REFERENCES posts(id), created REAL NOT NULL, deleted INTEGER NOT NULL DEFAULT 0);
            CREATE TABLE IF NOT EXISTS publishes (
              user_id TEXT NOT NULL REFERENCES users(id), key TEXT NOT NULL, payload_hash TEXT NOT NULL,
              post_id TEXT NOT NULL REFERENCES posts(id), PRIMARY KEY(user_id, key));
            CREATE TABLE IF NOT EXISTS follows (
              follower_id TEXT NOT NULL REFERENCES users(id), followed_id TEXT NOT NULL REFERENCES users(id),
              PRIMARY KEY(follower_id, followed_id));
            CREATE TABLE IF NOT EXISTS mutes (
              user_id TEXT NOT NULL REFERENCES users(id), muted_id TEXT NOT NULL REFERENCES users(id),
              PRIMARY KEY(user_id, muted_id));
            CREATE TABLE IF NOT EXISTS likes (
              user_id TEXT NOT NULL REFERENCES users(id), post_id TEXT NOT NULL REFERENCES posts(id),
              PRIMARY KEY(user_id, post_id));
            CREATE TABLE IF NOT EXISTS activities (
              sequence INTEGER PRIMARY KEY AUTOINCREMENT, actor_id TEXT NOT NULL REFERENCES users(id),
              post_id TEXT NOT NULL REFERENCES posts(id), kind TEXT NOT NULL, created REAL NOT NULL,
              UNIQUE(actor_id, post_id, kind));
            CREATE INDEX IF NOT EXISTS posts_parent ON posts(parent_id, created);
            CREATE INDEX IF NOT EXISTS activities_post ON activities(post_id, kind);
            CREATE INDEX IF NOT EXISTS sessions_expiry ON sessions(expires);
            ''')
        Path(path).chmod(0o600)
        self.auth_attempts = defaultdict(deque)
        self.rate_lock = threading.Lock()
        # Use the same work factor when an account is missing to reduce account timing leakage.
        self.dummy_salt = secrets.token_hex(16)

    @contextmanager
    def connect(self):
        conn = sqlite3.connect(self.path, timeout=10)
        conn.row_factory = sqlite3.Row
        conn.execute('PRAGMA foreign_keys=ON')
        try:
            with conn: yield conn
        finally: conn.close()

    def auth_limit(self, address):
        now = time.monotonic()
        with self.rate_lock:
            attempts = self.auth_attempts[address]
            while attempts and attempts[0] < now - 60: attempts.popleft()
            if len(attempts) >= 10: raise APIError(429, 'Too many account attempts. Try again in one minute.')
            attempts.append(now)
            # Bound process memory even when deployed behind a proxy with many client IPs.
            if len(self.auth_attempts) > 10000:
                for key in list(self.auth_attempts):
                    if self.auth_attempts[key][-1] < now - 60: del self.auth_attempts[key]

    def password_hash(self, password, salt):
        return hashlib.pbkdf2_hmac('sha256', password.encode(), bytes.fromhex(salt), PASSWORD_ITERATIONS).hex()

    def profile(self, conn, user_id, viewer):
        row = conn.execute('SELECT * FROM users WHERE id=?', (user_id,)).fetchone()
        if row is None: raise APIError(404, 'Account not found.')
        return {'id': row['id'], 'handle': row['handle'], 'displayName': row['display_name'],
                'followerCount': conn.execute('SELECT COUNT(*) FROM follows WHERE followed_id=?', (user_id,)).fetchone()[0],
                'followingCount': conn.execute('SELECT COUNT(*) FROM follows WHERE follower_id=?', (user_id,)).fetchone()[0],
                'muted': bool(conn.execute('SELECT 1 FROM mutes WHERE user_id=? AND muted_id=?', (viewer, user_id)).fetchone()),
                'following': bool(conn.execute('SELECT 1 FROM follows WHERE follower_id=? AND followed_id=?', (viewer, user_id)).fetchone())}

    def post(self, conn, post_id, viewer):
        row = conn.execute('SELECT * FROM posts WHERE id=?', (post_id,)).fetchone()
        if row is None: raise APIError(404, 'Post not found.')
        return {'id': row['id'], 'author': self.profile(conn, row['author_id'], viewer),
                'text': '' if row['deleted'] else row['text'], 'parentID': row['parent_id'], 'createdAt': row['created'],
                'deleted': bool(row['deleted']),
                'replyCount': conn.execute('SELECT COUNT(*) FROM posts WHERE parent_id=? AND deleted=0', (post_id,)).fetchone()[0],
                'likeCount': conn.execute('SELECT COUNT(*) FROM likes WHERE post_id=?', (post_id,)).fetchone()[0],
                'repostCount': conn.execute("SELECT COUNT(*) FROM activities WHERE post_id=? AND kind='repost'", (post_id,)).fetchone()[0],
                'liked': bool(conn.execute('SELECT 1 FROM likes WHERE user_id=? AND post_id=?', (viewer, post_id)).fetchone()),
                'reposted': bool(conn.execute("SELECT 1 FROM activities WHERE actor_id=? AND post_id=? AND kind='repost'", (viewer, post_id)).fetchone())}

    def authenticate(self, conn, authorization):
        if not authorization.startswith('Bearer ') or len(authorization) > 256: raise APIError(401, 'Sign in to Social.')
        token_hash = digest(authorization[7:])
        row = conn.execute('SELECT user_id FROM sessions WHERE token_hash=? AND expires>?', (token_hash, time.time())).fetchone()
        if row is None: raise APIError(401, 'Your Social session expired. Sign in again.')
        return row['user_id']

    def request(self, method, path, query, body, authorization, key, address):
        with self.connect() as conn:
            # Serialize mutations, so retries and toggles are atomic even with concurrent clients.
            if method != 'GET': conn.execute('BEGIN IMMEDIATE')
            if path in ('/v1/register', '/v1/login') and method == 'POST':
                self.auth_limit(address)
                handle = required_text(body, 'handle', 1, 24).lower()
                password = required_text(body, 'password', 1, 128, trim=False)
                if not re.fullmatch(r'[a-z0-9_]{1,24}', handle): raise APIError(400, 'Use letters, numbers, or underscores for your handle.')
                if path == '/v1/register':
                    if len(password) < 12: raise APIError(400, 'Use at least 12 characters for your password.')
                    name = required_text(body, 'displayName', 1, 60)
                    salt, uid = secrets.token_hex(16), secrets.token_hex(16)
                    try: conn.execute('INSERT INTO users VALUES (?,?,?,?,?,?)', (uid, handle, name, salt, self.password_hash(password, salt), time.time()))
                    except sqlite3.IntegrityError: raise APIError(409, 'That handle is already in use.')
                else:
                    row = conn.execute('SELECT * FROM users WHERE handle=?', (handle,)).fetchone()
                    hashed = self.password_hash(password, row['salt'] if row else self.dummy_salt)
                    if row is None or not hmac.compare_digest(hashed, row['password_hash']): raise APIError(401, 'The handle or password is incorrect.')
                    uid = row['id']
                token, expiry = secrets.token_urlsafe(32), time.time() + SESSION_SECONDS
                conn.execute('DELETE FROM sessions WHERE expires<=?', (time.time(),))
                conn.execute('INSERT INTO sessions VALUES (?,?,?)', (digest(token), uid, expiry))
                return (201 if path.endswith('register') else 200), {'token': token, 'expiresAt': expiry, 'profile': self.profile(conn, uid, uid)}

            uid = self.authenticate(conn, authorization)
            if path == '/v1/me' and method == 'GET': return 200, self.profile(conn, uid, uid)
            if path == '/v1/logout' and method == 'POST':
                conn.execute('DELETE FROM sessions WHERE token_hash=?', (digest(authorization[7:]),))
                return 200, {'ok': True}
            if path == '/v1/posts' and method == 'POST':
                text = required_text(body, 'text')
                parent = body.get('parentID')
                if parent is not None and (not isinstance(parent, str) or not re.fullmatch('[a-f0-9]{32}', parent)):
                    raise APIError(400, 'Invalid reply target.')
                if not re.fullmatch(r'[A-Za-z0-9_-]{1,100}', key): raise APIError(400, 'A valid Idempotency-Key is required.')
                payload_hash = digest(json.dumps([text, parent], ensure_ascii=False))
                existing = conn.execute('SELECT * FROM publishes WHERE user_id=? AND key=?', (uid, key)).fetchone()
                if existing:
                    if existing['payload_hash'] != payload_hash: raise APIError(409, 'This publish key already belongs to another draft.')
                    return 200, self.post(conn, existing['post_id'], uid)
                if parent is not None:
                    target = self.post(conn, parent, uid)
                    if target['deleted']: raise APIError(409, 'This post was deleted. Your draft is still yours.')
                post_id, created = secrets.token_hex(16), time.time()
                conn.execute('INSERT INTO posts(id,author_id,text,parent_id,created) VALUES (?,?,?,?,?)', (post_id, uid, text, parent, created))
                conn.execute('INSERT INTO publishes VALUES (?,?,?,?)', (uid, key, payload_hash, post_id))
                if parent is None: conn.execute('INSERT INTO activities(actor_id,post_id,kind,created) VALUES (?,?,?,?)', (uid, post_id, 'post', created))
                return 201, self.post(conn, post_id, uid)
            if path == '/v1/feed' and method == 'GET':
                mode = query.get('mode', ['all'])[0]
                if mode not in ('all', 'following'): raise APIError(400, 'Choose all or following.')
                try:
                    limit = min(50, max(1, int(query.get('limit', ['30'])[0])))
                    before = int(query.get('before', [str(2**63 - 1)])[0])
                    if before < 0 or before > 2**63 - 1: raise ValueError()
                except ValueError: raise APIError(400, 'Invalid page cursor.')
                args = [before, uid, uid]
                where = 'a.sequence<? AND p.deleted=0 AND a.actor_id NOT IN (SELECT muted_id FROM mutes WHERE user_id=?) AND p.author_id NOT IN (SELECT muted_id FROM mutes WHERE user_id=?)'
                if mode == 'following':
                    where += ' AND (a.actor_id=? OR a.actor_id IN (SELECT followed_id FROM follows WHERE follower_id=?))'
                    args += [uid, uid]
                rows = conn.execute(f'SELECT a.* FROM activities a JOIN posts p ON p.id=a.post_id WHERE {where} ORDER BY a.sequence DESC LIMIT ?', (*args, limit + 1)).fetchall()
                return 200, {'items': [{'id': str(r['sequence']), 'sequence': r['sequence'], 'post': self.post(conn, r['post_id'], uid), 'repostedBy': self.profile(conn, r['actor_id'], uid) if r['kind'] == 'repost' else None} for r in rows[:limit]], 'nextCursor': rows[limit - 1]['sequence'] if len(rows) > limit else None}
            match = re.fullmatch(r'/v1/posts/([a-f0-9]{32})(?:/(thread|like|repost))?', path)
            if match:
                post_id, action = match.groups()
                post = self.post(conn, post_id, uid)
                if action == 'thread' and method == 'GET':
                    try:
                        before = int(query.get('after', ['0'])[0])
                        if before < 0 or before > 2**63 - 1: raise ValueError()
                    except ValueError: raise APIError(400, 'Invalid reply cursor.')
                    rows = conn.execute('SELECT id,rowid AS cursor FROM posts WHERE parent_id=? AND rowid>? ORDER BY rowid LIMIT 51', (post_id, before)).fetchall()
                    return 200, {'post': post, 'replies': [self.post(conn, r['id'], uid) for r in rows[:50]], 'nextCursor': rows[49]['cursor'] if len(rows) > 50 else None}
                if action is None and method == 'DELETE':
                    if post['author']['id'] != uid: raise APIError(403, 'You can delete your own posts.')
                    conn.execute("UPDATE posts SET deleted=1,text='' WHERE id=?", (post_id,))
                    return 200, self.post(conn, post_id, uid)
                if action in ('like', 'repost') and method in ('PUT', 'DELETE'):
                    if post['deleted']: raise APIError(409, 'This post was deleted.')
                    if action == 'like':
                        if method == 'PUT': conn.execute('INSERT OR IGNORE INTO likes VALUES (?,?)', (uid, post_id))
                        else: conn.execute('DELETE FROM likes WHERE user_id=? AND post_id=?', (uid, post_id))
                    elif method == 'PUT': conn.execute("INSERT OR IGNORE INTO activities(actor_id,post_id,kind,created) VALUES (?,?,'repost',?)", (uid, post_id, time.time()))
                    else: conn.execute("DELETE FROM activities WHERE actor_id=? AND post_id=? AND kind='repost'", (uid, post_id))
                    return 200, self.post(conn, post_id, uid)
            match = re.fullmatch(r'/v1/profiles/([a-z0-9_]{1,24})(?:/(follow|mute))?', path)
            if match:
                handle, action = match.groups()
                user = conn.execute('SELECT id FROM users WHERE handle=?', (handle,)).fetchone()
                if user is None: raise APIError(404, 'Account not found.')
                target = user['id']
                if action is None and method == 'GET':
                    rows = conn.execute('SELECT id FROM posts WHERE author_id=? AND parent_id IS NULL AND deleted=0 ORDER BY created DESC LIMIT 50', (target,)).fetchall()
                    return 200, {'profile': self.profile(conn, target, uid), 'posts': [self.post(conn, r['id'], uid) for r in rows]}
                if action == 'mute' and method in ('PUT', 'DELETE'):
                    if target == uid: raise APIError(400, 'You cannot mute your own account.')
                    if method == 'PUT': conn.execute('INSERT OR IGNORE INTO mutes VALUES (?,?)', (uid, target))
                    else: conn.execute('DELETE FROM mutes WHERE user_id=? AND muted_id=?', (uid, target))
                    return 200, self.profile(conn, target, uid)
                if action == 'follow' and method in ('PUT', 'DELETE'):
                    if target == uid: raise APIError(400, 'Your posts already appear in Following.')
                    if method == 'PUT': conn.execute('INSERT OR IGNORE INTO follows VALUES (?,?)', (uid, target))
                    else: conn.execute('DELETE FROM follows WHERE follower_id=? AND followed_id=?', (uid, target))
                    return 200, self.profile(conn, target, uid)
            raise APIError(404, 'That Social route does not exist.')


class Handler(BaseHTTPRequestHandler):
    server_version = 'HarnessSocial/1'

    def log_message(self, format, *args):
        pass  # Never log passwords, tokens, query strings or content.

    def setup(self):
        super().setup()
        self.connection.settimeout(15)

    def respond(self, status, data):
        payload = json.dumps(data, ensure_ascii=False, allow_nan=False).encode()
        self.send_response(status)
        self.send_header('Content-Type', 'application/json; charset=utf-8')
        self.send_header('Content-Length', str(len(payload)))
        self.send_header('Cache-Control', 'no-store')
        self.send_header('X-Content-Type-Options', 'nosniff')
        self.send_header('Connection', 'close')
        if status == 429: self.send_header('Retry-After', '60')
        self.end_headers()
        self.wfile.write(payload)
        self.close_connection = True

    def route(self):
        try:
            if self.headers.get('Transfer-Encoding'): raise APIError(400, 'Chunked request bodies are unsupported.')
            lengths = self.headers.get_all('Content-Length', [])
            if len(lengths) > 1: raise APIError(400, 'Use one Content-Length.')
            try: length = int(self.headers.get('Content-Length', '0'))
            except ValueError: raise APIError(400, 'Invalid Content-Length.')
            if length < 0: raise APIError(400, 'Invalid Content-Length.')
            if length > MAX_BODY: raise APIError(413, 'Request is too large.')
            body = {}
            if length:
                if self.headers.get_content_type() != 'application/json': raise APIError(415, 'Use application/json.')
                try: body = json.loads(self.rfile.read(length))
                except (ValueError, UnicodeError): raise APIError(400, 'Invalid JSON.')
                if not isinstance(body, dict): raise APIError(400, 'JSON must be an object.')
            parts = urlsplit(self.path)
            status, data = self.server.store.request(self.command, parts.path, parse_qs(parts.query), body,
                self.headers.get('Authorization', ''), self.headers.get('Idempotency-Key', ''), self.client_address[0])
            self.respond(status, data)
        except APIError as error: self.respond(error.status, {'error': error.message})
        except (TimeoutError, ConnectionError): self.close_connection = True
        except sqlite3.Error: self.respond(503, {'error': 'Social storage is temporarily busy. Retry with the same draft.'})

    do_GET = do_POST = do_PUT = do_DELETE = route


def make_server(path, port=8790):
    server = ThreadingHTTPServer(('127.0.0.1', port), Handler)
    server.daemon_threads = True
    server.store = Store(path)
    return server


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--database', default=str(Path.home() / '.harness-social' / 'social.sqlite'))
    parser.add_argument('--port', type=int, default=8790)
    args = parser.parse_args()
    server = make_server(Path(args.database), args.port)
    print(f'Harness Social listening on http://127.0.0.1:{server.server_port}. Use an HTTPS reverse proxy for devices.')
    try: server.serve_forever()
    except KeyboardInterrupt: pass
    finally: server.server_close()


if __name__ == '__main__': main()
