#!/usr/bin/env python3
"""Upload immutable GameNight builds using only Python's standard library."""
import argparse
import hashlib
import http.client
import json
import os
from pathlib import Path
import shutil
import sys
import tempfile
import urllib.parse
import urllib.request
import zipfile

MAX_BYTES = 512 * 1024 * 1024

def origin(value):
    u = urllib.parse.urlsplit(value)
    if (u.scheme != 'https' and not (u.scheme == 'http' and u.hostname in {'127.0.0.1', 'localhost', '::1'})) or not u.hostname or u.username or u.password or u.query or u.fragment or u.path not in {'', '/'}:
        raise ValueError('Use an HTTPS server origin (HTTP is allowed only for loopback tests)')
    return value.rstrip('/')

class Client:
    def __init__(self, base, token):
        self.base = origin(base)
        self.token = token
        if not token.startswith('gn_pub_'):
            raise ValueError('Set GAMENIGHT_API_TOKEN to a publishing key from the portal')

    def request(self, method, path, body=None, file=None):
        u = urllib.parse.urlsplit(self.base)
        connection = (http.client.HTTPSConnection if u.scheme == 'https' else http.client.HTTPConnection)(u.hostname, u.port, timeout=180)
        headers = {'Authorization': 'Bearer ' + self.token}
        if file:
            headers.update({'Content-Length': str(file.stat().st_size), 'Content-Type': 'application/octet-stream'})
        elif body is not None:
            body = json.dumps(body).encode()
            headers.update({'Content-Type': 'application/json', 'Content-Length': str(len(body))})
        try:
            if file:
                with file.open('rb') as stream:
                    connection.request(method, path, stream, headers)
            else:
                connection.request(method, path, body, headers)
            response = connection.getresponse()
            raw = response.read(1024 * 1024)
            try:
                result = json.loads(raw)
            except ValueError:
                result = {}
            if not 200 <= response.status < 300:
                raise ValueError(result.get('error', f'GameNight returned HTTP {response.status}'))
            return result
        finally:
            connection.close()

    def download(self, url, destination, authenticated=True):
        u = urllib.parse.urlsplit(url)
        if authenticated and urllib.parse.urlunsplit((u.scheme, u.netloc, '', '', '')).rstrip('/') != self.base:
            raise ValueError('Refusing to send publishing credentials to another server')
        if not authenticated and (u.scheme != 'https' or u.username or u.password):
            raise ValueError('Runtime downloads require HTTPS without account credentials')
        request = urllib.request.Request(url, headers={'Authorization': 'Bearer ' + self.token} if authenticated else {})
        class NoRedirect(urllib.request.HTTPRedirectHandler):
            def redirect_request(self, *args):
                raise ValueError('Authenticated artifact downloads must not redirect')
        opener = urllib.request.build_opener(NoRedirect) if authenticated else urllib.request.build_opener()
        with opener.open(request, timeout=180) as response, destination.open('wb') as target:
            size = 0
            while chunk := response.read(1024 * 1024):
                size += len(chunk)
                if size > MAX_BYTES:
                    raise ValueError('Artifact exceeds 512 MiB')
                target.write(chunk)

def sha256(path):
    with path.open('rb') as file:
        return hashlib.file_digest(file, 'sha256').hexdigest()

def unpack(artifact, destination):
    with zipfile.ZipFile(artifact) as archive:
        total, names = 0, set()
        if len(archive.infolist()) > 10000:
            raise ValueError('Archive has too many entries')
        for item in archive.infolist():
            name = item.filename.rstrip('/')
            folded = name.casefold()
            if '\\' in name or ':' in name or name.startswith('/') or any(p in {'', '.', '..'} for p in name.split('/')) or (item.external_attr >> 16) & 0o170000 == 0o120000 or folded in names:
                raise ValueError('Unsafe archive')
            names.add(folded)
            total += item.file_size
            if total > 2 * 1024 * 1024 * 1024:
                raise ValueError('Archive exceeds extracted size limit')
        archive.extractall(destination)

def push(client, args):
    path = args.file.resolve()
    if not path.is_file() or path.stat().st_size > MAX_BYTES:
        raise ValueError('Provide a package no larger than 512 MiB')
    game = urllib.parse.quote(args.game, safe='')
    data = {'version': args.version, 'platform': args.platform, 'filename': path.name,
            'entrypoint': args.entrypoint, 'sha256': sha256(path),
            'changelog': args.changelog_file.read_text() if args.changelog_file else args.changelog}
    build = client.request('POST', f'/v1/developer/games/{game}/builds', data)
    if build['state'] != 'ready':
        build = client.request('PUT', f"/v1/developer/builds/{build['id']}/content", file=path)
    release = client.request('POST', f'/v1/developer/games/{game}/releases', {'build': build['id'], 'channel': args.channel})
    result = {'build_id': build['id'], 'sha256': build['sha256'], 'state': release['state'],
              'portal_url': client.base + '/developers/publishing#' + game}
    print(json.dumps(result, indent=2))
    if os.environ.get('GITHUB_OUTPUT'):
        with open(os.environ['GITHUB_OUTPUT'], 'a') as output:
            for name, value in result.items():
                output.write(f'{name}={value}\n')
    if os.environ.get('GITHUB_STEP_SUMMARY'):
        with open(os.environ['GITHUB_STEP_SUMMARY'], 'a') as summary:
            summary.write(f"GameNight build `{build['id']}`: **{release['state']}**. [Open publishing portal]({result['portal_url']})\n")

def preview(client, args):
    feed = client.request('GET', f'/v1/developer/games/{urllib.parse.quote(args.game, safe="")}/preview-catalog')
    platform = args.platform or {'win32': 'windows', 'darwin': 'mac', 'linux': 'linux'}[sys.platform]
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    shelf = []
    for entry in feed['games']:
        if platform not in entry.get('downloads', {}):
            continue
        download = entry['downloads'][platform]
        folder = output / entry['id'] / download['sha256']
        if not folder.exists():
            with tempfile.TemporaryDirectory(dir=output) as temp:
                temp = Path(temp)
                artifact = temp / 'artifact'
                client.download(download['url'], artifact)
                if sha256(artifact) != download['sha256']:
                    raise ValueError('Preview checksum mismatch')
                stage = temp / 'game'
                stage.mkdir()
                if download['url'].endswith('.zip'):
                    unpack(artifact, stage)
                else:
                    shutil.copyfile(artifact, stage / download['entrypoint'])
                executable = stage / download['entrypoint']
                if not executable.is_file():
                    raise ValueError('Missing preview executable')
                if platform != 'windows':
                    executable.chmod(executable.stat().st_mode | 0o111)
                folder.parent.mkdir(parents=True, exist_ok=True)
                stage.rename(folder)
        executable = folder / download['entrypoint']
        command, arguments = executable, []
        if runtime := download.get('runtime'):
            runtime_folder = output / '.runtimes' / runtime['sha256']
            if not runtime_folder.exists():
                with tempfile.TemporaryDirectory(dir=output) as temp:
                    temp = Path(temp)
                    artifact = temp / 'runtime.zip'
                    client.download(runtime['url'], artifact, authenticated=False)
                    if sha256(artifact) != runtime['sha256']:
                        raise ValueError('Runtime checksum mismatch')
                    stage = temp / 'runtime'
                    stage.mkdir()
                    unpack(artifact, stage)
                    binary = stage / runtime['entrypoint']
                    if not binary.is_file():
                        raise ValueError('Missing runtime executable')
                    if platform != 'windows':
                        binary.chmod(binary.stat().st_mode | 0o111)
                    runtime_folder.parent.mkdir(parents=True, exist_ok=True)
                    stage.rename(runtime_folder)
            command = runtime_folder / runtime['entrypoint']
            arguments = [str(executable if runtime.get('argument') == 'entry_point' else executable.parent)]
        shelf.append({'id': entry['id'], 'title': entry['title'], 'min_players': entry['players']['min'],
                      'max_players': entry['players']['max'], 'launch': {'command': str(command),
                      'args': arguments, 'cwd': str(executable.parent), 'env': {}}})
    if not shelf:
        raise ValueError('No preview is available for this platform')
    path = output / 'shelf.json'
    path.write_text(json.dumps(shelf, indent=2) + '\n')
    print('Preview downloaded and verified. Set GAMENIGHT_LIBRARY=' + str(path))

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--server', default='https://gamenight.ontola.io')
    commands = parser.add_subparsers(dest='command', required=True)
    p = commands.add_parser('push')
    p.add_argument('--game', required=True)
    p.add_argument('--file', type=Path, required=True)
    p.add_argument('--platform', choices=['windows', 'mac', 'linux'], required=True)
    p.add_argument('--entrypoint', required=True)
    p.add_argument('--version', required=True)
    p.add_argument('--channel', choices=['preview', 'stable'], default='preview')
    notes = p.add_mutually_exclusive_group()
    notes.add_argument('--changelog', default='')
    notes.add_argument('--changelog-file', type=Path)
    p = commands.add_parser('preview')
    p.add_argument('--game', required=True)
    p.add_argument('--platform', choices=['windows', 'mac', 'linux'])
    p.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    client = Client(args.server, os.environ.get('GAMENIGHT_API_TOKEN', ''))
    (push if args.command == 'push' else preview)(client, args)

if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, http.client.HTTPException) as error:
        print('GameNight publishing failed: ' + str(error), file=sys.stderr)
        sys.exit(1)
