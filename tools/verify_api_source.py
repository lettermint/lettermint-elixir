#!/usr/bin/env python3
"""Fail when the API source differs from the verified contract."""
import argparse
import hashlib
import json
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]

def verify(api):
    record = json.loads((ROOT/'specs/api-source-verification.json').read_text())
    differences = []
    for relative, digest in record['files'].items():
        path = api/relative
        if not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest() != digest:
            differences.append(relative)
    for pattern in record['source_patterns']:
        differences.extend(str(p.relative_to(api)) for p in api.glob(pattern) if str(p.relative_to(api)) not in record['files'])
    for name in ['sending', 'team']:
        upstream = api/'docs/api-reference'/f'{name}-openapi.json'
        if json.loads(upstream.read_text()) != json.loads((ROOT/'specs'/f'{name}-openapi.json').read_text()):
            differences.append(f'SDK snapshot: {name}')
    fixture = ROOT/'test/fixtures/api-source.json'
    if hashlib.sha256(fixture.read_bytes()).hexdigest() != record['fixtures_sha256']:
        differences.append('API fixture snapshot')
    return sorted(set(differences))

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('api_repository', type=Path)
    args = parser.parse_args()
    differences = verify(args.api_repository)
    if differences:
        raise SystemExit('API contract review required:\n'+'\n'.join(differences))
    print('API source and SDK snapshots match the verified contract.')
