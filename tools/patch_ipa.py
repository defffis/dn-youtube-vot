#!/usr/bin/env python3
"""Inject the standalone dylib into a COPY of a decrypted ARM64 YouTube IPA.

This tool does not decrypt, install, or sign apps. Existing tweaks are preserved.
"""
import argparse,hashlib,json,os,plistlib,struct,zipfile
from pathlib import Path

LC_SEGMENT_64=0x19
LC_CODE_SIGNATURE=0x1D
LC_LOAD_DYLIB=0xC
LIBRARY='DNYouTubeVOT.dylib'
INSTALL_NAME='@rpath/'+LIBRARY

def commands(data):
    if data[:4]!=b'\xcf\xfa\xed\xfe':raise ValueError('Only thin 64-bit Mach-O is supported')
    if struct.unpack_from('<I',data,4)[0]!=0x0100000C:raise ValueError('Only ARM64 is supported')
    count,size=struct.unpack_from('<II',data,16)
    p=32
    for _ in range(count):
        cmd,length=struct.unpack_from('<II',data,p)
        if length<8 or p+length>32+size:raise ValueError('Malformed load commands')
        yield p,cmd,bytes(data[p:p+length])
        p+=length
    if p!=32+size:raise ValueError('Malformed command size')

def dependencies(data):
    out=[]
    for p,cmd,raw in commands(data):
        if cmd in (0xC,0x80000018,0x8000001F,0x80000023):
            start=struct.unpack_from('<I',raw,8)[0]
            out.append(raw[start:].split(b'\0',1)[0].decode())
    return out

def inject(data):
    image=bytearray(data);old=[];endpoints=[];signature=None
    for p,cmd,raw in commands(image):
        if cmd in (0x21,0x2C) and struct.unpack_from('<I',raw,16)[0]!=0:
            raise ValueError('IPA executable is encrypted; this tool cannot decrypt it')
        if cmd==LC_CODE_SIGNATURE:
            signature=struct.unpack_from('<II',raw,8);continue
        if cmd==LC_SEGMENT_64:
            for i in range(struct.unpack_from('<I',raw,64)[0]):
                o=72+80*i;size=struct.unpack_from('<Q',raw,o+40)[0];offset=struct.unpack_from('<I',raw,o+48)[0]
                if offset and size:endpoints.append(offset)
        old.append(bytearray(raw))
    before=dependencies(image)
    if INSTALL_NAME in before:raise ValueError('This IPA already has DNYouTubeVOT')
    encoded=INSTALL_NAME.encode()+b'\0';size=(24+len(encoded)+7)&~7
    load=bytearray(struct.pack('<6I',LC_LOAD_DYLIB,size,24,0,0,0)+encoded)
    load.extend(b'\0'*(size-len(load)))
    old.append(load)
    new_size=sum(map(len,old))
    if not endpoints or 32+new_size>min(endpoints):raise ValueError('Not enough Mach-O header padding')
    if signature and signature[0]+signature[1]==len(image):
        del image[signature[0]:]
        for raw in old:
            if struct.unpack_from('<I',raw)[0]==LC_SEGMENT_64 and raw[8:24].rstrip(b'\0')==b'__LINKEDIT':
                fileoff=struct.unpack_from('<Q',raw,40)[0]
                filesize=len(image)-fileoff
                if filesize<0:raise ValueError('Invalid __LINKEDIT')
                struct.pack_into('<Q',raw,48,filesize)
                struct.pack_into('<Q',raw,32,(filesize+16383)&~16383)
    oldsize=struct.unpack_from('<I',image,20)[0]
    image[32:32+max(oldsize,new_size)]=b'\0'*max(oldsize,new_size)
    struct.pack_into('<II',image,16,len(old),new_size)
    image[32:32+new_size]=b''.join(old)
    assert dependencies(image)==before+[INSTALL_NAME]
    assert all(cmd!=LC_CODE_SIGNATURE for _,cmd,_ in commands(image))
    return bytes(image),before

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('ipa',type=Path);p.add_argument('dylib',type=Path);p.add_argument('output',type=Path)
    args=p.parse_args()
    if args.ipa.resolve()==args.output.resolve():raise SystemExit('Output must be a separate file')
    if args.output.exists():raise SystemExit('Output already exists; use a new filename')
    library=args.dylib.read_bytes()
    for _,cmd,raw in commands(library):
        if cmd==LC_SEGMENT_64:break
    thirdparty=[n for n in dependencies(library) if not n.startswith(('/usr/lib/','/System/Library/'))]
    if thirdparty:raise SystemExit('Patch has non-system dependencies: '+repr(thirdparty))
    report={'source_ipa_sha256':hashlib.sha256(args.ipa.read_bytes()).hexdigest(),'patch_sha256':hashlib.sha256(library).hexdigest(),'signed':False,'ios_runtime_tested':False}
    with zipfile.ZipFile(args.ipa) as src:
        infos=[n for n in src.namelist() if n.count('/')==2 and n.endswith('.app/Info.plist')]
        if len(infos)!=1:raise ValueError('Expected exactly one main app')
        app=infos[0][:-len('Info.plist')];info=plistlib.loads(src.read(infos[0]))
        if info.get('CFBundleExecutable')!='YouTube':raise ValueError('Expected YouTube executable')
        executable=app+info['CFBundleExecutable']
        patched,dependencies_before=inject(src.read(executable))
        target=app+'Frameworks/'+LIBRARY
        if target in src.namelist():raise ValueError('Patch library already exists')
        args.output.parent.mkdir(parents=True,exist_ok=True)
        with zipfile.ZipFile(args.output,'w',compression=zipfile.ZIP_DEFLATED,compresslevel=6) as out:
            for item in src.infolist():
                if item.filename.startswith(app+'_CodeSignature/'):continue
                payload=patched if item.filename==executable else src.read(item.filename)
                out.writestr(item,payload)
            entry=zipfile.ZipInfo(target);entry.create_system=3;entry.external_attr=0o100755<<16;entry.compress_type=zipfile.ZIP_DEFLATED
            out.writestr(entry,library)
        report.update({'youtube_version':info.get('CFBundleShortVersionString'),'original_bundle_id':info.get('CFBundleIdentifier'),'injected_path':target,'previous_dependencies_preserved':len(dependencies_before),'new_load_command':INSTALL_NAME})
    with zipfile.ZipFile(args.output) as out:
        assert out.testzip() is None
        assert out.read(target)==library
        assert dependencies(out.read(executable))==dependencies_before+[INSTALL_NAME]
        assert plistlib.loads(out.read(app+'Info.plist'))==info
    report['output_ipa_sha256']=hashlib.sha256(args.output.read_bytes()).hexdigest()
    report_path=args.output.with_suffix('.verification.json');report_path.write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report,indent=2))
if __name__=='__main__':main()
