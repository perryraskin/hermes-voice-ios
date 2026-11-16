"""Read-only end-to-end audio fixture: synthesis -> STT -> Hermes -> synthesis."""
import asyncio,base64,json,subprocess,time
from pathlib import Path
from aiohttp import ClientSession,ClientTimeout
async def main():
 c=json.loads((Path.home()/'.config/hermes-voice/service.json').read_text()); started=time.monotonic()
 async with ClientSession(timeout=ClientTimeout(total=90)) as h:
  async with h.post('https://api.elevenlabs.io/v1/text-to-speech/JBFqnCBsd6RMkjVDRZzb',headers={'xi-api-key':c['ELEVENLABS_KEY']},json={'text':'Hello Hermes. What is two plus two? Please answer briefly.','model_id':'eleven_flash_v2_5'}) as r:
   r.raise_for_status();mp3=await r.read()
  pcm=subprocess.run(['ffmpeg','-loglevel','error','-i','pipe:0','-f','s16le','-ac','1','-ar','16000','pipe:1'],input=mp3,capture_output=True,check=True).stdout+bytes(64000)
  async with h.ws_connect(c.get('PUBLIC_URL','http://127.0.0.1:12322').replace('https://','wss://').replace('http://','ws://').rstrip('/')+'/v1/stream',headers={'Authorization':'Bearer '+c['DEVICE_TOKEN']}) as ws:
   first=await ws.receive_json(timeout=20); print('Initial:',first['type'],flush=True)
   async def send():
    for i in range(0,len(pcm),3200):
     await ws.send_json({'type':'audio','audio':base64.b64encode(pcm[i:i+3200]).decode()}); await asyncio.sleep(.1)
   sender=asyncio.create_task(send())
   try:
    while True:
     e=await ws.receive_json(timeout=45)
     if e['type']!='partial':print(e['type'],e.get('text',''),flush=True)
     if e['type']=='audio':
      d=base64.b64decode(e['audio']); Path('/tmp/hermes-voice-e2e-response.mp3').write_bytes(d);print('Audio bytes:',len(d),'Elapsed:',round(time.monotonic()-started,1),flush=True);break
     if e['type']=='error':raise RuntimeError(e.get('text'))
   finally:sender.cancel();await asyncio.gather(sender,return_exceptions=True)
asyncio.run(main())
