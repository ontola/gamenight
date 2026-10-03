"""Exercise native lobby authentication, transcript submission, results and credit review.

Uses a loopback fixture; never records a microphone or calls a paid provider.
"""
import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import subprocess
import threading
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--godot', required=True)
    parser.add_argument('--check-windows-speech', action='store_true', help='Transcribe generated speech; does not record or play audio')
    args = parser.parse_args()
    submissions = []
    quotes = []

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_args):
            pass

        def reply(self, code, data, headers=None):
            body = json.dumps(data).encode()
            self.send_response(code)
            for key, value in (headers or {}).items(): self.send_header(key, value)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            if self.path == '/start/test':
                self.reply(303, {}, {'Set-Cookie': 'gn_session=fixture; HttpOnly; Path=/', 'Location': '/agent'})
                return
            if self.headers.get('Cookie') != 'gn_session=fixture':
                self.reply(401, {})
                return
            if self.path == '/auth/session':
                self.reply(200, {'csrf': 'test-csrf'})
            elif self.path == '/v1/rooms/agent':
                self.reply(200, {'provider_configured': True, 'local_model': not submissions,
                                'requests': [{'id': req['request_id'], 'state': 'complete',
                                              'result': 'The host confirmed the game is queued.'}
                                             for req in submissions]})
            else:
                self.reply(404, {})

        def do_POST(self):
            if (self.headers.get('Cookie') != 'gn_session=fixture'
                or self.headers.get('x-gamenight-csrf') != 'test-csrf'
                or self.headers.get('Origin') != f'http://127.0.0.1:{self.server.server_port}'):
                self.reply(403, {})
                return
            data = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
            if self.path == '/v1/rooms/agent/quote':
                quotes.append(data)
                self.reply(200, {'maximum_credits': 3})
            elif self.path == '/v1/rooms/agent':
                submissions.append(data)
                self.reply(202, {'request_id': data['request_id']})
            else:
                self.reply(404, {})

    with ThreadingHTTPServer(('127.0.0.1', 0), Handler) as server:
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        env = {**os.environ, 'GAMENIGHT_ASSISTANT_TEST_URL': f'http://127.0.0.1:{server.server_port}/start/test'}
        with tempfile.TemporaryDirectory(prefix='lobby-speech-test-') as temp:
            if args.check_windows_speech:
                env['GAMENIGHT_ASSISTANT_TEST_WAV'] = str(Path(temp)/'generated.wav')
                subprocess.run(['powershell.exe', '-NoProfile', '-NonInteractive', '-Command', '''
Add-Type -AssemblyName System.Speech
$speaker = [System.Speech.Synthesis.SpeechSynthesizer]::new()
$format = [System.Speech.AudioFormat.SpeechAudioFormatInfo]::new(48000,[System.Speech.AudioFormat.AudioBitsPerSample]::Sixteen,[System.Speech.AudioFormat.AudioChannel]::Stereo)
$speaker.SetOutputToWaveFile($env:GAMENIGHT_ASSISTANT_TEST_WAV,$format)
$speaker.Speak('Please add a short game to the queue')
$speaker.Dispose()
'''], env=env, check=True, capture_output=True, timeout=15)
            result = subprocess.run([args.godot, '--headless', '--path', str(ROOT/'sdk/godot'), '--script',
                                     'res://lobby/tests/assistant.gd'], env=env, capture_output=True,
                                    text=True, encoding='utf-8', timeout=40)
        server.shutdown()
    assert result.returncode == 0 and 'ASSISTANT_TEST_PASS' in result.stdout, result.stdout + result.stderr
    assert 'SCRIPT ERROR' not in result.stderr, result.stderr
    assert [item['text'] for item in submissions] == ['Queue a short game', 'Paid request']
    assert [item['max_credits'] for item in submissions] == [0, 3]
    assert len(quotes) == 1 and quotes[0]['request_id'] == submissions[1]['request_id']
    print('PASS native assistant: session, CSRF, local request, paid confirmation, response, silence')


if __name__ == '__main__':
    main()
