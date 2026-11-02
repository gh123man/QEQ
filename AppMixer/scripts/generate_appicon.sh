#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
python3 - <<'PY'
import json, subprocess
from pathlib import Path
assets=Path('AppMixer/App/Resources/Assets.xcassets')
icons=assets/'AppIcon.appiconset'
icons.mkdir(parents=True,exist_ok=True)
entries=[]
for size in (16,32,128,256,512):
    for scale in (1,2):
        name=f'icon_{size}x{size}'+('@2x' if scale==2 else '')+'.png'
        subprocess.run(['sips','-z',str(size*scale),str(size*scale),'AppMixer/Branding/QEQ-icon.png','--out',str(icons/name)],check=True,stdout=subprocess.DEVNULL)
        entries.append({'size':f'{size}x{size}','idiom':'mac','filename':name,'scale':f'{scale}x'})
(icons/'Contents.json').write_text(json.dumps({'images':entries,'info':{'version':1,'author':'xcode'}},indent=2)+'\n')
(assets/'Contents.json').write_text(json.dumps({'info':{'version':1,'author':'xcode'}},indent=2)+'\n')
PY
