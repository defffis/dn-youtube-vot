#!/usr/bin/env python3
"""Independent byte-level oracle using Google's Protobuf runtime."""
import subprocess
from pathlib import Path
from google.protobuf import descriptor_pb2,descriptor_pool,message_factory

fd=descriptor_pb2.FileDescriptorProto(name='dnvot_test.proto',syntax='proto3')
for msgname,fields in [('Session',[(1,'uuid',9),(2,'module',9)]),('Translation',[(3,'url',9),(5,'first_request',8),(6,'duration',1),(7,'unknown0',8),(8,'language',9),(14,'response_language',9),(15,'unknown2',8),(16,'config_version',5),(18,'lively',8)])]:
    msg=fd.message_type.add(name=msgname)
    for n,name,t in fields:msg.field.add(name=name,number=n,type=t,label=1)
pool=descriptor_pool.DescriptorPool();pool.Add(fd)
Session=message_factory.GetMessageClass(pool.FindMessageTypeByName('Session'))
Translation=message_factory.GetMessageClass(pool.FindMessageTypeByName('Translation'))
cli=Path(__file__).resolve().parents[1]/'build/core_tests'
s=Session(uuid='0123456789ABCDEF0123456789ABCDEF',module='video-translation')
actual=bytes.fromhex(subprocess.check_output([str(cli),'session',s.uuid],text=True).strip())
assert actual==s.SerializeToString()
t=Translation(url='https://youtu.be/jNQXAC9IVRw',first_request=True,duration=19,unknown0=True,language='en',response_language='ru',unknown2=True,config_version=2)
actual=bytes.fromhex(subprocess.check_output([str(cli),'translation','jNQXAC9IVRw','19'],text=True).strip())
assert actual==t.SerializeToString()
t.lively=True
actual=bytes.fromhex(subprocess.check_output([str(cli),'lively','jNQXAC9IVRw'],text=True).strip())
assert actual==t.SerializeToString()
print('PASS: C++ request bytes match Google Protobuf for session, standard translation and lively translation')
