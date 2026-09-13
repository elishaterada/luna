#!/usr/bin/env python3
"""Luna's tag-driven packaging and signed-feed pipeline. Standard library only."""
import argparse
import datetime
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import tempfile
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
SPARKLE = 'http://www.andymatuschak.org/xml-namespaces/sparkle'
REPO = 'elishaterada/luna'
ET.register_namespace('sparkle', SPARKLE)


def validate_version(version):
    if not re.fullmatch(r'(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)', version):
        raise ValueError('A stable X.Y.Z version is required')
    return version


def release_notes(version, changelog=None):
    validate_version(version)
    text = changelog if changelog is not None else (ROOT / 'CHANGELOG.md').read_text()
    match = re.search(r'^## ' + re.escape(version) + r'(?:\s[^\n]*)?\n(.*?)(?=^## |\Z)', text, re.M | re.S)
    if not match or not match.group(1).strip():
        raise ValueError('Missing human-readable changelog for ' + version)
    return match.group(1).strip()


def validate_release_order(version, releases):
    target = tuple(map(int, validate_version(version).split('.')))
    for item in releases:
        if item.get('isDraft') or item.get('isPrerelease'):
            continue
        tag = item['tagName']
        if re.fullmatch(r'v[0-9]+\.[0-9]+\.[0-9]+', tag):
            if tuple(map(int, tag[1:].split('.'))) >= target:
                raise ValueError('Release must be newer than published ' + tag)


def run(args, **kwargs):
    return subprocess.run([str(arg) for arg in args], check=True, cwd=ROOT, **kwargs)


def signing_args(tool):
    if os.environ.get('SPARKLE_ED_PRIVATE_KEY'):
        return [tool, '--ed-key-file', '-'], {'input': os.environ['SPARKLE_ED_PRIVATE_KEY'].encode()}
    return [tool, '--account', 'dev.luna.app'], {}


def make_feed(version, build, archive, signature, notes):
    root = ET.Element('rss', version='2.0')
    channel = ET.SubElement(root, 'channel')
    ET.SubElement(channel, 'title').text = 'Luna Updates'
    ET.SubElement(channel, 'link').text = f'https://github.com/{REPO}/releases'
    ET.SubElement(channel, 'description').text = 'Stable Luna updates'
    item = ET.SubElement(channel, 'item')
    ET.SubElement(item, 'title').text = f'Luna {version}'
    ET.SubElement(item, 'link').text = f'https://github.com/{REPO}/releases/tag/v{version}'
    ET.SubElement(item, 'pubDate').text = datetime.datetime.now(datetime.timezone.utc).strftime('%a, %d %b %Y %H:%M:%S +0000')
    ET.SubElement(item, '{%s}version' % SPARKLE).text = build
    ET.SubElement(item, '{%s}shortVersionString' % SPARKLE).text = version
    ET.SubElement(item, '{%s}minimumSystemVersion' % SPARKLE).text = '14.0'
    ET.SubElement(item, 'description', {'{%s}format' % SPARKLE: 'markdown'}).text = notes
    ET.SubElement(item, 'enclosure', {
        'url': f'https://github.com/{REPO}/releases/download/v{version}/{archive.name}',
        '{%s}edSignature' % SPARKLE: signature,
        'length': str(archive.stat().st_size), 'type': 'application/octet-stream'})
    ET.indent(root)
    return ET.tostring(root, encoding='utf-8', xml_declaration=True)


def package(version, build):
    validate_version(version)
    if not re.fullmatch(r'[1-9][0-9]*', build):
        raise ValueError('Build must be a positive integer')
    notes = release_notes(version)
    run(['Scripts/build.sh'], env=dict(os.environ, MARKETING_VERSION=version, CURRENT_PROJECT_VERSION=build))
    app = ROOT / 'dist/Luna.app'
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    assert info['CFBundleShortVersionString'] == version and info['CFBundleVersion'] == build
    assert info['SURequireSignedFeed'] and info['SUVerifyUpdateBeforeExtraction']
    assert info['SUFeedURL'] == f'https://github.com/{REPO}/releases/latest/download/appcast.xml'
    if os.environ.get('SPARKLE_ED_PRIVATE_KEY'):
        run(['swift', 'Scripts/validate-signing-key.swift', app / 'Contents/Info.plist'], input=os.environ['SPARKLE_ED_PRIVATE_KEY'].encode())
    else:
        public = run([ROOT / '.build/artifacts/sparkle/Sparkle/bin/generate_keys', '--account', 'dev.luna.app', '-p'], capture_output=True).stdout.decode().strip()
        if public != info['SUPublicEDKey']:
            raise ValueError('Local signing key does not match the embedded public key')
    architecture = run(['/usr/bin/uname', '-m'], capture_output=True).stdout.decode().strip()
    if architecture != 'arm64':
        raise ValueError('Stable Luna releases currently require an Apple Silicon builder')
    name = f'Luna-{version}-{build}-macos-arm64'
    archive = ROOT / 'dist' / (name + '.zip')
    if archive.exists():
        raise ValueError('Refusing to replace an existing release archive: ' + str(archive))
    installation = f'''Luna {version} — Apple Silicon, macOS 14 or newer

Move Luna.app to /Applications or ~/Applications before opening it.
This personal-preview build is ad-hoc signed and is not Apple-notarized.
If macOS blocks first open, use System Settings > Privacy & Security > Open Anyway.
Only approve a copy downloaded from https://github.com/{REPO}/releases.

Luna checks for signed updates automatically. Review and install them in the app.
Use Luna > Check for Updates to check manually. Automatic checks can be disabled
in Luna's menu. Recovery copies are flushed before update installation and quit.

Enable the luna terminal command in the welcome setup or Luna > Settings.
'''
    with tempfile.TemporaryDirectory(prefix='luna-release-') as directory:
        stage = Path(directory) / name
        stage.mkdir()
        run(['/usr/bin/ditto', app, stage / 'Luna.app'])
        (stage / 'INSTALL.txt').write_text(installation)
        (stage / 'Sparkle-LICENSE.txt').write_bytes((app / 'Contents/Resources/Sparkle-LICENSE.txt').read_bytes())
        run(['/usr/bin/ditto', '-c', '-k', '--keepParent', '--norsrc', '--noextattr', stage, archive])
    tool = ROOT / '.build/artifacts/sparkle/Sparkle/bin/sign_update'
    args, options = signing_args(tool)
    signature = run(args + ['-p', archive], capture_output=True, **options).stdout.decode().strip()
    feed = ROOT / 'dist/appcast.xml'
    feed.write_bytes(make_feed(version, build, archive, signature, notes))
    run(args + [feed], **options)
    # Verify both final files without changing them after signing.
    run(args + ['--verify', archive, signature], **options)
    run(args + ['--verify', feed], **options)
    body = f'# Luna {version}\n\n{notes}\n\n## Install\n\nApple Silicon · macOS 14+\n\nDownload the ZIP, unzip, and move **Luna.app** to Applications. This preview is **ad-hoc signed, not Apple-notarized**, matching Sora. If macOS blocks first open, use **System Settings → Privacy & Security → Open Anyway** for your downloaded copy.\n\nFuture updates appear inside Luna, with signed downloads and release notes. Enable the terminal command in the welcome setup or **Luna → Settings…**.\n'
    (ROOT / 'dist/release-notes.md').write_text(body)
    print('Release archive and signed feed verified:', archive.name)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('version')
    parser.add_argument('--build')
    parser.add_argument('--notes-only', action='store_true')
    parser.add_argument('--check-order', action='store_true')
    args = parser.parse_args()
    if args.check_order:
        result = run(['gh', 'release', 'list', '--repo', REPO, '--limit', '100', '--json', 'tagName,isDraft,isPrerelease'], capture_output=True)
        validate_release_order(args.version, json.loads(result.stdout))
        print('Release version is newer than all published stable versions')
    elif args.notes_only:
        print(release_notes(args.version))
    elif args.build:
        package(args.version, args.build)
    else:
        parser.error('--build is required when packaging')
