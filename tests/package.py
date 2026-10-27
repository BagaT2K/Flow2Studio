"""Current release integrity; no historical artifacts or hardware access."""
from pathlib import Path
import hashlib,json,re,struct
root=Path(__file__).resolve().parents[1]
sha=lambda data:hashlib.sha256(data).hexdigest()
pins=json.loads((root/'firmware/source-pins.json').read_text())
expected=set()
for model in [68,84,100]:
 name=f'model-{model}-v14.json';raw=(root/'firmware-bundle'/name).read_bytes();meta=json.loads(raw)
 assert f'case {model}:return "{sha(raw)}"' in (root/'mac/FlowV14Registry.h').read_text()
 assert len(meta['images'])==2
 expected.add(name)
 for item in meta['images']:
  data=(root/'firmware-bundle'/item['file']).read_bytes();expected.add(item['file'])
  assert len(data)==262144 and sha(data)==item['sha256']
  if item['id']==meta['target']:
   assert data.count(bytes([model,0,9,20]))==1 and sha(data)==pins[str(model)]['target']
  else:assert sha(data)==pins[str(model)]['factory']
 assert sha((root/f'firmware/patches-{model}.json').read_bytes())==pins[str(model)]['sources']
 stock=(root/f'firmware-bundle/factory-{model}-usb14.bin').read_bytes();target=(root/f'firmware-bundle/studio-v14-{model}.bin').read_bytes()
 assert meta['pages']==[o for o in range(0,len(stock),256) if stock[o:o+256]!=target[o:o+256]]
assert {p.name for p in (root/'firmware-bundle').glob('*.bin')}=={x for x in expected if x.endswith('.bin')}
assert not list(root.glob('CHANGELOG*'))
assert (root/'LICENSE').read_text().startswith('MIT License\n')
assert 'Copyright (c) 2026 BagaT2K' in (root/'LICENSE').read_text()
assert 'MIT' in (root/'README.md').read_text()
for name in ['PRIVACY.md','SECURITY.md','DISTRIBUTION.md','THIRD-PARTY-NOTICES.txt']:
 assert not (root/name).exists()
assert 'app.flow2studio</string>' in (root/'scripts/build-app.sh').read_text()
for name in ['Build-DMG.command','Build-and-Run.command','scripts/build-app.sh','scripts/check.sh']:
 assert (root/name).is_file()
source=(root/'scripts/build-app.sh').read_text()
assert '<string>0.9.7</string>' in source and 'FlowUpdates.m' in source
# Every local C/Objective-C include must survive cleanup.
for folder in ['mac','tests']:
 for path in (root/folder).iterdir():
  if path.suffix not in ['.h','.m','.c']:continue
  for name in re.findall(r'^\s*#(?:include|import)\s+"([^"]+)"',path.read_text(),re.M):assert (path.parent/name).is_file(),(path,name)
print('Passed: current 68/84/100 binaries, source/catalog pins, release identity, exact version-only changes, page maps, clean package and all local includes.')
