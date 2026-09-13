#!/usr/bin/env python3
"""Verify the public latest endpoint serves exactly the locally signed artifacts."""
import hashlib
import json
from pathlib import Path
import sys
import time
import urllib.request
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
REPO = 'elishaterada/luna'
NS = {'sparkle': 'http://www.andymatuschak.org/xml-namespaces/sparkle'}


def fetch(url):
    for attempt in range(5):
        try:
            with urllib.request.urlopen(urllib.request.Request(url, headers={'User-Agent': 'Luna-release-verifier'}), timeout=60) as response:
                return response.read()
        except Exception:
            if attempt == 4: raise
            time.sleep(2)


def verify(tag, build):
    release = json.loads(fetch(f'https://api.github.com/repos/{REPO}/releases/latest'))
    assert release['tag_name'] == tag and not release['draft'] and not release['prerelease']
    assert 'A little space' in release['body'] or len(release['body'].strip()) > 100
    feed_data = fetch(f'https://github.com/{REPO}/releases/latest/download/appcast.xml')
    assert feed_data == (ROOT / 'dist/appcast.xml').read_bytes(), 'Published feed differs from signed feed'
    feed = ET.fromstring(feed_data)
    item = feed.find('channel/item')
    assert item.findtext('sparkle:version', namespaces=NS) == build
    assert item.findtext('sparkle:shortVersionString', namespaces=NS) == tag[1:]
    assert item.findtext('description').strip()
    enclosure = item.find('enclosure')
    assert enclosure.attrib['{%s}edSignature' % NS['sparkle']]
    url = enclosure.attrib['url']
    assert url.startswith(f'https://github.com/{REPO}/releases/download/{tag}/')
    archive_data = fetch(url)
    assert len(archive_data) == int(enclosure.attrib['length'])
    local = ROOT / 'dist' / url.rsplit('/', 1)[-1]
    assert hashlib.sha256(archive_data).digest() == hashlib.sha256(local.read_bytes()).digest(), 'Published archive differs from signed archive'
    print(f'Verified public {tag}: latest link, release notes, signed appcast and archive match')

if __name__ == '__main__': verify(sys.argv[1], sys.argv[2])
