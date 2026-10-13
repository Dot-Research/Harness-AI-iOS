"""Run Swift client tests against an isolated live Social service; requires Swift/Xcode."""
import argparse
import os
import subprocess
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from social_service.server import Handler, Store


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--scratch-path', default='/private/tmp/harness-social-swift-build')
    args = parser.parse_args()
    captured = []

    class CaptureHandler(BaseHTTPRequestHandler):
        def log_message(self, *args): pass
        def do_GET(self):
            captured.append(self.headers.get('Authorization'))
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b'{}')

    capture = ThreadingHTTPServer(('127.0.0.1', 0), CaptureHandler)

    class FixtureHandler(Handler):
        def do_GET(self):
            if self.headers.get('Authorization') == 'Bearer redirect-probe':
                self.send_response(302)
                self.send_header('Location', f'http://127.0.0.1:{capture.server_port}/captured')
                self.end_headers()
            else: self.route()

    with tempfile.TemporaryDirectory(prefix='harness-social-client-') as directory:
        server = ThreadingHTTPServer(('127.0.0.1', 0), FixtureHandler)
        server.store = Store(Path(directory) / 'social.sqlite')
        threads = [threading.Thread(target=item.serve_forever, daemon=True) for item in (server, capture)]
        for thread in threads: thread.start()
        try:
            environment = dict(os.environ, HARNESS_SOCIAL_TEST_URL=f'http://127.0.0.1:{server.server_port}')
            result = subprocess.run(['swift', 'test', '--scratch-path', args.scratch_path, '--filter', 'SocialClientIntegrationTests'], env=environment)
            if captured: raise AssertionError('The Swift client followed a credentialed redirect.')
            return result.returncode
        finally:
            for item in (server, capture): item.shutdown(); item.server_close()
            for thread in threads: thread.join()


if __name__ == '__main__': raise SystemExit(main())
