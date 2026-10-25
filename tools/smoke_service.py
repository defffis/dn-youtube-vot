#!/usr/bin/env python3
"""Opt-in live protocol probe against Yandex using the compiled C++ encoder."""
import argparse,base64,hashlib,hmac,json,subprocess,time,urllib.error,urllib.parse,urllib.request,uuid
from pathlib import Path

KEY=b'bt8xH3VOlb4mqf0nqAibnDOoiPlXsisf'
COMPONENT='26.10.0.1796'
HOST='https://api.browser.yandex.ru'
UA='Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/150.0.0.0 YaBrowser/26.8.0.0 Safari/537.36'
def vi(n):
    out=bytearray()
    while n>127:out.append((n&127)|128);n>>=7
    out.append(n);return bytes(out)
def string(n,text):
    text=text.encode() if isinstance(text,str) else text
    return vi(n<<3|2)+vi(len(text))+text
def parse(data):
    out={};position=0
    def read():
        nonlocal position
        result=0
        for i in range(10):
            c=data[position];position+=1;result|=(c&127)<<(i*7)
            if c<128:return result
        raise ValueError('varint overflow')
    while position<len(data):
        tag=read();field,wire=tag>>3,tag&7
        if wire==0:out[field]=read()
        elif wire==2:
            size=read();out[field]=data[position:position+size];position+=size
        elif wire in (1,5):position+=8 if wire==1 else 4
        else:raise ValueError('bad wire')
    return out
sign=lambda data:hmac.new(KEY,data,hashlib.sha256).hexdigest()
def main():
    p=argparse.ArgumentParser()
    p.add_argument('--url');p.add_argument('--source-url',default='');p.add_argument('--video',default='jNQXAC9IVRw');p.add_argument('--duration',type=float,default=19)
    p.add_argument('--wait',type=int,default=0,help='seconds to wait/poll; 0 means one request')
    p.add_argument('--fallback',action='store_true',help='request server-side audio retrieval if status=6')
    p.add_argument('--output',type=Path,default=Path('build/service-smoke.json'))
    args=p.parse_args()
    binary=Path(__file__).resolve().parents[1]/'build/core_tests'
    encode=lambda op,*values:bytes.fromhex(subprocess.check_output([str(binary),op,*map(str,values)],text=True).strip())
    uid=uuid.uuid4().hex.upper();events=[];secret=None
    def request(path,body,secured=False,method='POST',json_body=False):
        headers={'User-Agent':UA,'Content-Type':'application/json' if json_body else 'application/x-protobuf','Accept':'application/json' if json_body else 'application/x-protobuf','Accept-Language':'en','Cache-Control':'no-cache'}
        if not json_body:headers['Vtrans-Signature']=sign(body)
        if secured:
            token=uid+':'+path+':'+COMPONENT
            headers['Sec-Vtrans-Sk']=secret;headers['Sec-Vtrans-Token']=sign(token.encode())+':'+token
        req=urllib.request.Request(HOST+path,data=body,headers=headers,method=method)
        try:
            with urllib.request.urlopen(req,timeout=40) as response:
                result=response.read(2*1024*1024);code=response.status
        except urllib.error.HTTPError as error:code=error.code;result=error.read(1000)
        event={'path':path,'http_status':code};events.append(event)
        print(json.dumps(event),flush=True)
        if code!=200:raise RuntimeError(f'HTTP {code} from {path}')
        return result
    body=encode('session',uid);session=parse(request('/session/create',body))
    secret=session[1].decode();assert secret
    deadline=time.monotonic()+args.wait;did_fallback=False;attempt=0
    while True:
        body=(encode('custom',args.url,args.duration,args.source_url,'1') if args.url else encode('translation',args.video,args.duration,'1'));attempt+=1
        result=parse(request('/video-translation/translate',body,True))
        state=result.get(4,0)
        event={'translation_status':state,'remaining_seconds':result.get(5),'has_audio_url':bool(result.get(1)),'message':result.get(9,b'').decode(errors='replace'),'detected_language':result.get(8,b'').decode(errors='replace')};events.append(event);print(json.dumps(event),flush=True)
        if result.get(1):
            url=result[1].decode();assert urllib.parse.urlparse(url).scheme=='https'
            req=urllib.request.Request(url,headers={'Range':'bytes=0-1023'})
            with urllib.request.urlopen(req,timeout=40) as response:
                sample=response.read(1024)
                events.append({'audio_http_status':response.status,'audio_sample_bytes':len(sample),'content_type':response.headers.get('Content-Type')})
            break
        if state==6 and args.fallback and not did_fallback:
            did_fallback=True
            out=json.loads(request('/video-translation/fail-audio-js',json.dumps({'video_url':'https://youtu.be/'+args.video}).encode(),method='PUT',json_body=True))
            assert out.get('status')==1
            info=string(1,'fallback-empty-audio:video-translation:'+args.video)
            audio=string(1,result[7])+string(2,'https://youtu.be/'+args.video)+string(6,info)
            uploaded=parse(request('/video-translation/audio',audio,True,method='PUT'))
            events.append({'audio_submission_status':uploaded.get(1)})
        if state not in (2,3,5,6) or time.monotonic()>=deadline:break
        time.sleep(min(15,max(3,deadline-time.monotonic())))
    report={'engine':'Yandex VOT','video_id':None if args.url else args.video,'input_kind':'custom_video_url' if args.url else 'youtube','video_url':args.url if args.url else 'https://youtu.be/'+args.video,'time_utc':time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime()),'events':events,'translated_audio_received':bool(result.get(1)),'ios_runtime_tested':False}
    args.output.parent.mkdir(parents=True,exist_ok=True);args.output.write_text(json.dumps(report,indent=2)+'\n')
    print('Saved',args.output,flush=True)
if __name__=='__main__':main()
