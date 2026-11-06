"""Reproducible Touch Bar overlay, pinned separately to Studio 0.9 bases for 68/84/100.
Compile touch-runtime.c with a Cortex-M3 freestanding C compiler and touch.ld.
This script reads an ELF and writes a complete image; never accesses hardware.
"""
from pathlib import Path
import struct,json,hashlib,sys
from elftools.elf.elffile import ELFFile
from keystone import Ks,KS_ARCH_ARM,KS_MODE_THUMB
ROOT=Path(__file__).resolve().parents[1]
MODELS=json.loads((ROOT/'firmware/touch-models.json').read_text())
def overlay(base,elfpath,model=68):
 p=MODELS[str(model)]
 assert len(base)==262144 and hashlib.sha256(base).hexdigest()==p['base_sha256']
 target=bytearray(base);ks=Ks(KS_ARCH_ARM,KS_MODE_THUMB)
 def asm(text,offset):return bytes(ks.asm(text,addr=0x8000000+offset)[0])
 with open(elfpath,'rb') as f:
  elf=ELFFile(f);text=elf.get_section_by_name('.text');data=text.data();offset=text['sh_addr']-0x8000000
  symbols={s.name:s['st_value'] for s in elf.get_section_by_name('.symtab').iter_symbols() if s.name.startswith('touch_')}
  assert offset==0x15000 and len(data)<0x4000 and not any(base[offset:offset+len(data)])
  for name in ('.data','.bss'):
   section=elf.get_section_by_name(name);assert not section or not section['sh_size']
  target[offset:offset+len(data)]=data
 # Startup clears reserved state; heap starts beyond it, separately per model.
 for o,old in [(0x1a4,p['ram_old_end']),(p['heap_literal'],p['ram'])]:
  assert struct.unpack_from('<I',base,o)[0]==old;struct.pack_into('<I',target,o,p['ram_end'])
 position=p['position'];assert base[position:position+4]==bytes.fromhex('f8b5324e')
 literal=struct.unpack_from('<I',base,position+0xcc)[0]
 trampoline=asm(f'push {{r3,r4,r5,r6,r7,lr}}; ldr r6,={literal}; b.w {hex(0x8000000+position+4)}; .align 2; .ltorg',0x14f00)
 assert not any(base[0x14f00:0x15000]);target[0x14f00:0x14f00+len(trampoline)]=trampoline
 key_event=p['key_event'];prologue=bytes.fromhex('f7b50546' if model==68 else 'f7b50646')
 assert base[key_event:key_event+4]==prologue
 target[0x14f40:0x14f48]=prologue+asm(f'b.w {hex(0x8000000+key_event+4)}',0x14f44)
 for o,name,kind in [(key_event,'touch_key_event','b.w'),(position,'touch_position','b.w'),(p['dispatch'],'touch_dispatch','b.w'),(p['tick_hook'],'touch_tick','bl'),(p['packet_entry'],'touch_packet','b.w'),(p['eeprom_read'],'touch_eeprom_read','b.w'),(p['eeprom_write'],'touch_eeprom_write','b.w')]:
  blob=asm(f'{kind} {hex(symbols[name]&~1)}',o);assert len(blob)==4;target[o:o+4]=blob
 literal=struct.pack('<I',0x14090000|model);assert target.count(literal)==1
 o=target.index(literal);target[o:o+4]=struct.pack('<I',0x140a0000|model)
 return bytes(target)
if __name__=='__main__':
 base=Path(sys.argv[1]).read_bytes();target=overlay(base,sys.argv[2],int(sys.argv[4]) if len(sys.argv)>4 else 68);Path(sys.argv[3]).write_bytes(target)
 print('Touch firmware:',hashlib.sha256(target).hexdigest())
