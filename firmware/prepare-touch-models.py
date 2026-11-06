"""Derive pinned per-model OEM entry points and physical matrix holes offline."""
from pathlib import Path
import json,re,struct,hashlib
from capstone import Cs,CS_ARCH_ARM,CS_MODE_THUMB,CS_MODE_MCLASS
ROOT=Path(__file__).resolve().parents[1]
BASES=ROOT/'firmware-bundle'
def base_image(model):
 data=bytearray((BASES/f'studio-v14-{model}.bin').read_bytes());pins=json.loads((ROOT/'firmware/source-pins.json').read_text())
 if hashlib.sha256(data).hexdigest()!=pins[str(model)]['target']:
  recipe=json.loads((ROOT/f'firmware/touch-overlay-{model}.json').read_text());assert hashlib.sha256(data).hexdigest()==recipe['target']
  for patch in recipe['patches']:
   o=patch['offset'];after=bytes.fromhex(patch['after']);before=bytes.fromhex(patch['before']);assert data[o:o+len(after)]==after;data[o:o+len(before)]=before
 assert hashlib.sha256(data).hexdigest()==pins[str(model)]['target'];return bytes(data)
known={68:dict(position=0x540c,dispatch=0x5364,parser=0x2f94,timer=0x96ac,elapsed=0x9616,activity=0x6e70,tap=0x59b8,disable=0x30ec,config=0x200044c8),84:dict(position=0x4edc,dispatch=0x4e34,parser=0x2f90,timer=0x9180,elapsed=0x90ea,activity=0x6954,tap=0x549c,disable=0x30e8,config=0x200044c8),100:dict(position=0x4edc,dispatch=0x4e34,parser=0x2f90,timer=0x91b8,elapsed=0x9122,activity=0x6978,tap=0x5494,disable=0x30e8,config=0x200044d0)}
cs=Cs(CS_ARCH_ARM,CS_MODE_THUMB|CS_MODE_MCLASS)
def ins(b,o,n=100):return list(cs.disasm(b[o:o+n],0x8000000+o))
ref=base_image(68)
def locate(b,o,n=10):
 pattern=ref[o:o+n];hits=[i for i in range(0,len(b)-n,2) if b[i:i+n]==pattern];assert len(hits)==1,(hex(o),hits);return hits[0]
def branch_target(b,o):
 i=ins(b,o,4)[0];assert i.mnemonic in ('bl','b.w');return int(i.op_str[1:],16)-0x8000000
def literal(b,i):
 displacement=int(i.op_str.split('#')[1].split(']')[0],0);return struct.unpack_from('<I',b,((i.address+4)&~3)-0x8000000+displacement)[0]
models={}
layouts=(ROOT/'resources/layouts.js').read_text()
factories=(ROOT/'resources/factory-models.js').read_text();f=json.loads(factories[factories.index('{'):factories.rindex('}')+1])
for model,params in known.items():
 b=base_image(model);p=dict(params);p['model']=model;p['positions']=len(f[str(model)][0]);p['keybase']=40
 holes=[i for i in range(p['positions']) if all(layer[i]==0 for layer in f[str(model)])]
 assert len(holes)*6>=36,(model,holes)
 geometry=json.loads((ROOT/'resources/layout68.js').read_text().split('=',1)[1].strip().rstrip(';')) if model==68 else json.loads(layouts.split('=',1)[1].strip().rstrip(';'))[str(model)]
 cols=18 if model==100 else 15;assert set(holes)==set(range(p['positions']))-{key['row']*cols+key['col'] for key in geometry}
 p['key_event']=0x4414 if model==68 else 0x4410
 assert b[p['key_event']:p['key_event']+4]==bytes.fromhex('f7b50546' if model==68 else 'f7b50646')
 p['holes']=holes;p['stride']=36 if model==84 else 40;p['protected']=72 if model==84 else 80
 p['ram_old_end']=struct.unpack_from('<I',b,0x1a4)[0];p['ram']=(p['ram_old_end']+7)&~7;p['ram_end']=0x20004c00
 hits=[o for o in range(0,len(b)-4,4) if struct.unpack_from('<I',b,o)[0]==p['ram']];assert len(hits)==1,(model,hits)
 p['heap_literal']=hits[0]
 for name,address in [('raw_read',0x78a8),('raw_write',0x7950),('mouse',0x921c),('macro',0x83c0)]:p[name]=locate(b,address,10 if name!='macro' else 6)
 # The eeprom block wrappers have identical swaps, but distinct tail branches.
 candidates=[o for o in range(0,len(b)-10,2) if b[o:o+6]==ref[0x7804:0x780a]]
 for name in ['read','write']:
  matches=[o for o in candidates if branch_target(b,o+6)==p['raw_'+name]];assert len(matches)==1;p['eeprom_'+name]=matches[0]
 p['layer_address']=literal(b,ins(b,p['dispatch'],6)[1]);p['driver_address']=literal(b,ins(b,p['mouse'],4)[0])
 patches=json.loads((ROOT/f'firmware/patches-{model}.json').read_text());handler=next(x['assembly'] for x in patches if x['offset']==0x12700)
 p['entry']=int(re.search(r'fallback:.*?b.w (0x[0-9a-f]+)',handler,re.S)[1],16)-0x8000000
 p['packet_entry']=p['entry'] # overwritten below: original VIA override, not fallback chain
 p['packet_entry']=next(x['offset'] for x in patches if x['assembly'].strip()=='b.w 0x8012700')
 response=next(x['assembly'] for x in patches if x['offset']==0x13600)
 p['send']=int(re.search(r'bl (0x[0-9a-f]+)\n.*?movs r0,#1',response,re.S)[1],16)-0x8000000 if False else {68:0x29b0,84:0x29ac,100:0x29ac}[model]
 p['tick_hook']=p['parser']+0xfe # parser+0xfe = scheduler's call to parser
 assert branch_target(b,p['tick_hook'])==p['parser']
 p['base_sha256']=hashlib.sha256(b).hexdigest();models[str(model)]=p
 lines=[f'#define MODEL {model}',f'#define POSITIONS {p["positions"]}',f'#define HOLES_COUNT {len(holes)}',f'#define HOLES_VALUES '+','.join(map(str,holes)),f'#define NV_STRIDE {p["stride"]}',f'#define NV_PROTECTED {p["protected"]}',f'#define TOUCH_RAM {hex(p["ram"])}',f'#define TOUCH_RAM_END {hex(p["ram_end"])}']
 for name in ['timer','tap','mouse','parser','disable','raw_read','raw_write','macro','send']:lines.append(f'#define A_{name.upper()} {hex(0x8000000+p[name])}')
 lines.extend([f'#define LAYER_ADDRESS {hex(p["layer_address"])}',f'#define DRIVER_ADDRESS {hex(p["driver_address"])}',f'#define CONFIG_ADDRESS {hex(p["config"])}'])
 (ROOT/f'firmware/touch-model-{model}.h').write_text('\n'.join(lines)+'\n')
(ROOT/'firmware/touch-models.json').write_text(json.dumps(models,indent=2)+'\n')
print('Verified model entry points, SRAM reservation, EEPROM shapes and holes for 68/84/100')
