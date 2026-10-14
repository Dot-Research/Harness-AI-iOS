import json
from contextlib import closing
import sqlite3
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
from pathlib import Path

from social_service.server import make_server


class SocialIntegrationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.db = Path(self.temp.name) / 'social.sqlite'
        self.server = make_server(self.db, port=0)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.base = f'http://127.0.0.1:{self.server.server_port}/v1'

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()
        self.temp.cleanup()

    def request(self, method, path, data=None, token=None, key=None):
        headers = {'Content-Type': 'application/json'}
        if token: headers['Authorization'] = 'Bearer ' + token
        if key: headers['Idempotency-Key'] = key
        req = urllib.request.Request(self.base + path, data=None if data is None else json.dumps(data).encode(), headers=headers, method=method)
        try:
            with urllib.request.urlopen(req) as response:
                return response.status, json.load(response)
        except urllib.error.HTTPError as error:
            with error: return error.code, json.load(error)

    def register(self, handle):
        status, data = self.request('POST', '/register', {'handle': handle, 'displayName': handle.title(), 'password': 'a long test password'})
        self.assertEqual(status, 201, data)
        return data['token']

    def post(self, token, text, key='unique-post', parent=None):
        data = {'text': text}
        if parent: data['parentID'] = parent
        status, result = self.request('POST', '/posts', data, token, key)
        self.assertIn(status, (200, 201), result)
        return result

    def test_authentication_persists_hashed_secrets_and_logout_revokes_token(self):
        token = self.register('alice')
        status, profile = self.request('GET', '/me', token=token)
        self.assertEqual((status, profile['handle']), (200, 'alice'))
        self.assertEqual(self.request('GET', '/me')[0], 401)
        self.assertEqual(self.request('POST', '/login', {'handle': 'alice', 'password': 'wrong'})[0], 401)
        status, login = self.request('POST', '/login', {'handle': 'ALICE', 'password': 'a long test password'})
        self.assertEqual(status, 200)
        with closing(sqlite3.connect(self.db)) as conn:
            dump = '\n'.join(conn.iterdump())
            self.assertNotIn('a long test password', dump)
            self.assertNotIn(token, dump)
        self.assertEqual(self.request('POST', '/logout', {}, login['token'])[0], 200)
        self.assertEqual(self.request('GET', '/me', token=login['token'])[0], 401)

    def test_publish_retry_is_idempotent_and_payload_change_is_rejected(self):
        token = self.register('alice')
        first = self.post(token, 'Hello, world.')
        retried = self.post(token, 'Hello, world.')
        self.assertEqual(first['id'], retried['id'])
        self.assertEqual(self.request('POST', '/posts', {'text': 'Changed'}, token, 'unique-post')[0], 409)
        self.assertEqual(len(self.request('GET', '/feed', token=token)[1]['items']), 1)
        self.assertEqual(self.request('POST', '/posts', {'text': ' '}, token, 'blank')[0], 400)
        self.assertEqual(self.request('POST', '/posts', {'text': 'x' * 501}, token, 'long')[0], 400)

    def test_following_feed_replies_likes_and_reposts_are_real_persisted_state(self):
        alice, bob, carol = [self.register(name) for name in ('alice', 'bob', 'carol')]
        original = self.post(bob, 'From Bob')
        self.post(carol, 'From Carol')
        self.assertEqual(self.request('GET', '/feed?mode=following', token=alice)[1]['items'], [])
        self.assertEqual(self.request('PUT', '/profiles/bob/follow', {}, alice)[0], 200)
        followed = self.request('GET', '/feed?mode=following', token=alice)[1]['items']
        self.assertEqual([item['post']['id'] for item in followed], [original['id']])
        reply = self.post(alice, 'A reply', key='reply', parent=original['id'])
        thread = self.request('GET', f"/posts/{original['id']}/thread", token=alice)[1]
        self.assertEqual(thread['replies'][0]['id'], reply['id'])
        self.assertEqual(thread['post']['replyCount'], 1)
        for _ in range(2): self.request('PUT', f"/posts/{original['id']}/like", {}, alice)
        liked = self.request('GET', f"/posts/{original['id']}/thread", token=alice)[1]['post']
        self.assertEqual((liked['likeCount'], liked['liked']), (1, True))
        self.request('PUT', f"/posts/{original['id']}/repost", {}, alice)
        feed = self.request('GET', '/feed', token=alice)[1]['items']
        self.assertEqual(feed[0]['repostedBy']['handle'], 'alice')
        self.assertEqual(feed[0]['post']['repostCount'], 1)
        self.request('DELETE', f"/posts/{original['id']}/like", token=alice)
        self.request('DELETE', f"/posts/{original['id']}/repost", token=alice)
        profile = self.request('GET', '/profiles/bob', token=alice)[1]
        self.assertEqual(profile['profile']['followerCount'], 1)
        # A second server instance reads the on-disk state, including sessions and relationships.
        other = make_server(self.db, port=0)
        try:
            with other.store.connect() as conn:
                self.assertEqual(conn.execute('SELECT COUNT(*) FROM posts').fetchone()[0], 3)
        finally: other.server_close()

    def test_mute_hides_author_and_reposts_without_deleting_their_content(self):
        alice, bob, carol = [self.register(name) for name in ('alice', 'bob', 'carol')]
        original = self.post(bob, 'Still here')
        self.request('PUT', f"/posts/{original['id']}/repost", {}, carol)
        self.assertEqual(len(self.request('GET', '/feed', token=alice)[1]['items']), 2)
        self.assertEqual(self.request('PUT', '/profiles/bob/mute', {}, alice)[0], 200)
        self.assertEqual(self.request('GET', '/feed', token=alice)[1]['items'], [])
        profile = self.request('GET', '/profiles/bob', token=alice)[1]
        self.assertTrue(profile['profile']['muted'])
        self.assertEqual(profile['posts'][0]['text'], 'Still here')
        self.request('DELETE', '/profiles/bob/mute', token=alice)
        self.assertEqual(len(self.request('GET', '/feed', token=alice)[1]['items']), 2)

    def test_pagination_is_stable_when_new_posts_arrive(self):
        token = self.register('alice')
        expected = [self.post(token, f'Post {i}', key=f'p{i}')['id'] for i in range(4)]
        first = self.request('GET', '/feed?limit=2', token=token)[1]
        self.post(token, 'Newer', key='newer')
        second = self.request('GET', '/feed?limit=2&before=' + str(first['nextCursor']), token=token)[1]
        self.assertEqual([item['post']['id'] for item in first['items'] + second['items']], list(reversed(expected)))

    def test_mutations_are_authorized_and_deleted_posts_preserve_threads(self):
        alice, bob = self.register('alice'), self.register('bob')
        post = self.post(alice, 'Original')
        self.post(bob, 'Reply survives', parent=post['id'])
        self.assertEqual(self.request('DELETE', f"/posts/{post['id']}", token=bob)[0], 403)
        self.assertEqual(self.request('PUT', f"/posts/{post['id']}/like", {})[0], 401)
        self.assertEqual(self.request('DELETE', f"/posts/{post['id']}", token=alice)[0], 200)
        detail = self.request('GET', f"/posts/{post['id']}/thread", token=bob)[1]
        self.assertTrue(detail['post']['deleted'])
        self.assertEqual(detail['post']['text'], '')
        self.assertEqual(detail['replies'][0]['text'], 'Reply survives')

    def test_body_limits_invalid_shapes_and_auth_rate_limit(self):
        self.assertEqual(self.request('POST', '/register', {'handle': 'x', 'password': 'x' * 20000})[0], 413)
        self.assertEqual(self.request('POST', '/register', [1, 2])[0], 400)
        self.assertEqual(self.request('POST', '/register', {'handle': 'bad name', 'password': 'a long test password'})[0], 400)
        statuses = [self.request('POST', '/login', {'handle': 'missing', 'password': 'wrong'})[0] for _ in range(15)]
        self.assertIn(429, statuses)


if __name__ == '__main__': unittest.main()
