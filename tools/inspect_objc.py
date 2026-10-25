"""Read Objective-C class/method metadata in this ARM64 chained-fixups Mach-O."""
import struct,json,sys
from pathlib import Path
b=Path(sys.argv[1]).read_bytes()
u32=lambda o:struct.unpack_from('<I',b,o)[0]
u64=lambda o:struct.unpack_from('<Q',b,o)[0]
i32=lambda o:struct.unpack_from('<i',b,o)[0]
segments=[];sections=[];p=32
for _ in range(u32(16)):
 cmd,sz=struct.unpack_from('<II',b,p)
 if cmd==0x19:
  name=b[p+8:p+24].split(b'\0')[0].decode();va,vsz,fo,fs=struct.unpack_from('<4Q',b,p+24)
  segments.append((va,vsz,fo,fs,name))
  for i in range(u32(p+64)):
   o=p+72+i*80;sn=b[o:o+16].split(b'\0')[0].decode();sv,ss=struct.unpack_from('<QQ',b,o+32)
   sections.append((sn,sv,ss,u32(o+48)))
 p+=sz
base=min(va for va,vs,fo,fs,n in segments if fs)
def off(va):
 for v,vs,f,fs,n in segments:
  if v<=va<v+fs:return f+va-v
 raise ValueError(hex(va))
def ptr(o):
 n=u64(o)
 if not n or n>>63:return 0
 # DYLD_CHAINED_PTR_64_OFFSET: low 36 bits, high8 at bit 36; rebases relative to image base.
 return base+(n&0xfffffffff)
def text(va):
 if not va:return ''
 o=off(va);return b[o:b.index(b'\0',o)].decode(errors='replace')
def methods(va):
 if not va:return []
 o=off(va);flags,count=struct.unpack_from('<II',b,o);entry=flags&0xffff;out=[]
 for i in range(count):
  m=o+8+i*entry
  try:
   if flags&0x80000000:
    nm=base+(m+i32(m))
    if not flags&0x40000000:nm=ptr(off(nm))
    types=base+m+4+i32(m+4)
   else:nm=ptr(m);types=ptr(m+8)
   out.append({'name':text(nm),'types':text(types)})
  except (ValueError,struct.error):pass
 return out
classes=[]
sec=next(s for s in sections if s[0]=='__objc_classlist')
for o in range(sec[3],sec[3]+sec[2],8):
 try:
  c=ptr(o);co=off(c);ro=ptr(co+32)&~7;rooff=off(ro)
  name=text(ptr(rooff+24))
  if not name.startswith(('YT','ML','HAM','GCK','GV')):continue
  meta=ptr(co);mro=ptr(off(meta)+32)&~7 if meta else 0
  ivars=[];iv=ptr(rooff+48)
  if iv:
   ivo=off(iv);size,count=struct.unpack_from('<II',b,ivo)
   for i in range(count):
    io=ivo+8+i*size
    ivars.append({'name':text(ptr(io+8)),'type':text(ptr(io+16))})
  classes.append({'name':name,'methods':methods(ptr(rooff+32)),'classMethods':methods(ptr(off(mro)+32)) if mro else [],'ivars':ivars})
 except (ValueError,struct.error):pass
print(json.dumps(classes,ensure_ascii=False,indent=2))
