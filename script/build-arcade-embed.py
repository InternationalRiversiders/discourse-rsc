#!/usr/bin/env python3
"""Build the standalone page from the SAME UI modules and SCSS as the forum.
Run with --sass /path/to/dart-sass/sass; --check verifies committed artifacts.
"""
import argparse, hashlib, json, re, subprocess
from pathlib import Path
root=Path(__file__).resolve().parents[1]
base=root/'assets/javascripts/discourse/lib'
parser=argparse.ArgumentParser();parser.add_argument('--sass',required=True);parser.add_argument('--check',action='store_true');args=parser.parse_args()
sources={}
def module(name,binding,result):
 source=(base/(name+'.js')).read_text();sources[name]=hashlib.sha256(source.encode()).hexdigest()
 source=re.sub(r'^import .*?;\n','',source,flags=re.M)
 source=source.replace('export default ArcadeCore;','').replace('export default ','').replace('export function ','function ').replace('export const ','const ')
 source=re.sub(r'^export \{.*?\};\n','',source,flags=re.M)
 return f'const {binding}=(()=>{{\n{source}\nreturn {result};\n}})();\n'
js='/* Generated from the forum UI. Do not edit. */\n(()=>{"use strict";\n'
for row in [('arcade-core','Core','ArcadeCore'),('arcade-playback','Playback','ArcadePlayback'),('arcade-effects','Effects','ArcadeEffects'),('arcade-draw','draw','draw'),('arcade-sprites','{loadMergeSprites}','{loadMergeSprites}'),('campus-time','{formatDateTime}','{formatDateTime}'),('arcade-cover','drawCover','drawCover'),('arcade-ui','{renderArcade}','{renderArcade}'),('arcade-app','{ArcadeApp,GAMES}','{ArcadeApp,GAMES}'),('arcade-transport','{arcadeRequest}','{arcadeRequest}'),('arcade-bridge','ArcadeBridge','ArcadeBridge')]:js+=module(*row)
source=(base/'arcade-embed.js').read_text();sources['arcade-embed']=hashlib.sha256(source.encode()).hexdigest();js+=re.sub(r'^import .*?;\n','',source,flags=re.M)+'\n})();\n'
css=subprocess.check_output([args.sass,'--style=compressed','--no-source-map',str(root/'assets/stylesheets/rsc-arcade-embed.scss')],text=True)
for name in ['rsc-arcade.scss','rsc-arcade-embed.scss']:sources[name]=hashlib.sha256((root/'assets/stylesheets'/name).read_bytes()).hexdigest()
out=root/'public/arcade';prefix='/plugins/discourse-rsc/arcade/'
sha=lambda data:hashlib.sha256(data.encode()).hexdigest()
js_name='arcade-embed-'+sha(js)[:16]+'.js';css_name='arcade-embed-'+sha(css)[:16]+'.css'
html=f'''<!doctype html>
<html lang="zh-CN" data-theme="auto"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover"><meta name="referrer" content="same-origin"><title>街机区</title><link rel="stylesheet" href="{prefix+css_name}"><script defer src="{prefix+js_name}"></script></head><body><main class="ra-embed"><p id="connection" role="status">正在连接游戏…</p><div class="ra-hub"><section id="arcade" class="ra-app" aria-label="街机区"></section></div></main></body></html>
'''
manifest=json.dumps({'protocol':1,'rules_version':2,'entry':'/rsc/arcade/embed','script':prefix+js_name,'stylesheet':prefix+css_name,'sha256':{'script':sha(js),'stylesheet':sha(css)},'sources':sources},ensure_ascii=False,indent=2)+'\n'
for name,content in [(js_name,js),(css_name,css),('embed.html',html),('embed-manifest.json',manifest)]:
 if args.check:assert (out/name).read_text()==content,'Outdated embed artifact: '+name
 else:(out/name).write_text(content)
print(js_name,css_name)
