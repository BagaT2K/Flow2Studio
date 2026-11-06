"""Build the current OEM14-based firmware from pinned factories and Thumb sources. No device access.
Dependencies: keystone-engine, capstone. Version 0.9 uses protocol generation 19.
"""
from pathlib import Path
import argparse,json,hashlib,re
from keystone import Ks,KS_ARCH_ARM,KS_MODE_THUMB,KS_MODE_V8
ROOT=Path(__file__).resolve().parents[1]
ks=Ks(KS_ARCH_ARM,KS_MODE_THUMB)
divks=Ks(KS_ARCH_ARM,KS_MODE_THUMB|KS_MODE_V8)
def assemble(text,addr):
 # Keystone's V8 branch relocation differs by four bytes. Only use V8 to encode
 # the non-PC-relative UDIV already present in the OEM Cortex-M3 firmware.
 divisions=[]
 def div(m):
  marker=0xd100+len(divisions);divisions.append((marker,bytes(divks.asm(m.group(0).strip())[0])));return '    movw r12,#'+str(marker)
 text=re.sub(r'(?m)^[ \t]*udiv[^\n]*',div,text)
 text=re.sub(r'(?m)^(\s*)cb(z|nz)\s+(r[0-9]+),\s*([a-zA-Z_][a-zA-Z_0-9]*)',lambda m:m[1]+'cmp '+m[3]+',#0\n    '+('beq.w ' if m[2]=='z' else 'bne.w ')+m[4],text)
 # Force widths before assembly: branch relaxation can otherwise shift absolute BL targets.
 text=re.sub(r'(?m)^(\s*)(b(?:eq|ne|hi|ls|hs|lo|gt|le|pl|mi|cc|cs|ge|lt)?)(?![a-zA-Z.])\s+',r'\1\2.w ',text)
 data,count=ks.asm(text,addr=addr);data=bytes(data)
 for marker,opcode in divisions:
  placeholder=bytes(ks.asm('movw r12,#'+str(marker))[0]);assert data.count(placeholder)==1;data=data.replace(placeholder,opcode)
 # Independently decode all numeric branch targets: no four-byte relocation drift allowed.
 from capstone import Cs,CS_ARCH_ARM,CS_MODE_THUMB
 from collections import Counter
 expected=Counter(int(v,16) for v in re.findall(r'(?m)^\s*b(?:l|\.w)\s+(0x[0-9a-fA-F]+)',text))
 decoded=Counter(int(i.op_str[1:],16) for i in Cs(CS_ARCH_ARM,CS_MODE_THUMB).disasm(data,addr) if i.mnemonic in ('bl','b.w') and i.op_str.startswith('#0x'))
 assert all(decoded[t]>=n for t,n in expected.items()),(hex(addr),expected,decoded)
 return list(data),count

def digest(data):return hashlib.sha256(data).hexdigest()
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--base-dir',type=Path,help='Also emit the exact Studio 0.9 base images used by build-touch.py.')
args=parser.parse_args()
if args.base_dir:args.base_dir.mkdir(parents=True,exist_ok=True)
pins=json.loads((ROOT/'firmware/source-pins.json').read_text())
for model in [68,84,100]:
 source=(ROOT/f'firmware-bundle/factory-{model}-usb14.bin').read_bytes()
 assert len(source)==262144 and digest(source)==pins[str(model)]['factory']
 patchfile=ROOT/f'firmware/patches-{model}.json'
 assert digest(patchfile.read_bytes())==pins[str(model)]['sources']
 target=bytearray(source)
 for patch in json.loads(patchfile.read_text()):
  blob=bytes((ks.asm(patch['assembly'],addr=0x08000000+patch['offset']) if patch.get('direct') else assemble(patch['assembly'],0x08000000+patch['offset']))[0])
  assert len(blob)==patch['size']
  o=patch['offset'];target[o:o+len(blob)]=blob
 assert digest(target)==pins[str(model)]['target']
 if args.base_dir:(args.base_dir/f'studio-base-{model}.bin').write_bytes(target)
 (ROOT/f'firmware-bundle/studio-v14-{model}.bin').write_bytes(target)
 print(f'Flow 2 {model}: firmware 0.9 verified and rebuilt')

# Reapply independently pinned Touch Bar overlays; no compiler needed here.
for model in [68,84,100]:
 meta=json.loads((ROOT/f'firmware/touch-overlay-{model}.json').read_text())
 for source,expected in meta['sources'].items():assert digest((ROOT/'firmware'/source).read_bytes())==expected
 path=ROOT/f'firmware-bundle/studio-v14-{model}.bin';image=bytearray(path.read_bytes());assert digest(image)==meta['base']
 for p in meta['patches']:
  o=p['offset'];before=bytes.fromhex(p['before']);after=bytes.fromhex(p['after']);assert len(before)==len(after) and image[o:o+len(before)]==before;image[o:o+len(after)]=after
 assert digest(image)==meta['target'];path.write_bytes(image)
 print(f'Flow 2 {model}: Touch Bar firmware 0.10 verified')
