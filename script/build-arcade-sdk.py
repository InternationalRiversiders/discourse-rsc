#!/usr/bin/env python3
"""Build the same rules/playback/renderer for an embedded WebView, no npm deps."""
import argparse, hashlib, json
from pathlib import Path
root = Path(__file__).resolve().parents[1]
base = root / 'assets/javascripts/discourse/lib'
parts = {}
for name in ('core', 'playback', 'effects', 'draw', 'sprites'):
    parts[name] = (base / f'arcade-{name}.js').read_text()
core = parts['core'].replace('export default ArcadeCore;', 'return ArcadeCore;')
playback = parts['playback'].replace('import Core from "./arcade-core";', '').replace('export default class ArcadePlayback', 'class ArcadePlayback') + '\nreturn ArcadePlayback;'
effects = parts['effects'].replace('export function tileTracks', 'function tileTracks').replace('export default class ArcadeEffects', 'class ArcadeEffects') + '\nreturn ArcadeEffects;'
draw = parts['draw'].replace('import Core from "./arcade-core";', '').replace('export default function draw', 'function draw') + '\nreturn draw;'
sprites = parts['sprites'].replace('export const ', 'const ').replace('export function ', 'function ')
body = ('/* Riverside Arcade: generated from the forum modules. Do not edit. */\n'
        '(() => { "use strict";\nconst Core=(()=>{\n' + core + '\n})();\n'
        'const Playback=(()=>{\n' + playback + '\n})();\n'
        'const Effects=(()=>{\n' + effects + '\n})();\n'
        'const draw=(()=>{\n' + draw + '\n})();\n'
        + sprites + '\nglobalThis.RiversideArcade=Object.freeze({protocol:1,rulesVersion:Core.version,Core,Playback,Effects,draw,loadMergeSprites,mergeSpriteFiles});\n})();\n')
digest = hashlib.sha256(body.encode()).hexdigest()
out = root / 'public/arcade'
filename = f'rsc-arcade-sdk-{digest[:16]}.js'
manifest = json.dumps({'protocol': 1, 'rules_version': 5, 'script': '/plugins/discourse-rsc/arcade/' + filename,
    'sha256': digest, 'assets': [{'url': '/plugins/discourse-rsc/arcade/merge/'+a['file'], 'sha256': a['sha256']} for a in json.loads((out / 'merge/source.json').read_text())['assets']], 'sources': {k: hashlib.sha256(v.encode()).hexdigest() for k, v in parts.items()}}, indent=2) + '\n'
parser = argparse.ArgumentParser(); parser.add_argument('--check', action='store_true'); args = parser.parse_args()
if args.check:
    assert (out / filename).read_text() == body, 'SDK is out of date'
    assert (out / 'manifest.json').read_text() == manifest, 'Manifest is out of date'
else:
    out.mkdir(parents=True, exist_ok=True)
    (out / filename).write_text(body); (out / 'manifest.json').write_text(manifest)
print(filename)
