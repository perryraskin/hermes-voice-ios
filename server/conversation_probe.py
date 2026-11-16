import asyncio,base64,json,subprocess
from pathlib import Path
from aiohttp import ClientSession,ClientTimeout
async def main():
 c=json.loads((Path.home()/'.config/hermes-voice/service.json').read_text())
 phrases=['For this conversation only, our test word is mango. Say okay.','What was our test word?','What is two plus two?','Add three to that result.','What was the test word again?']
 async with ClientSession(timeout=ClientTimeout(total=180)) as h:
  async with h.ws_connect(c.get('PUBLIC_URL','http://127.0.0.1:12322').replace('https://','wss://').replace('http://','ws://').rstrip('/')+'/v1/stream',headers={'Authorization':'Bearer '+c['DEVICE_TOKEN']}) as ws:
   assert (await ws.receive_json(timeout=20))['type']=='ready'
   for phrase in phrases:
    async with h.post('https://api.elevenlabs.io/v1/text-to-speech/JBFqnCBsd6RMkjVDRZzb',headers={'xi-api-key':c['ELEVENLABS_KEY']},json={'text':phrase,'model_id':'eleven_flash_v2_5'}) as r:
     r.raise_for_status();audio=await r.read()
    pcm=subprocess.run(['ffmpeg','-loglevel','error','-i','pipe:0','-f','s16le','-ac','1','-ar','16000','pipe:1'],input=audio,capture_output=True,check=True).stdout+bytes(64000)
    async def send():
     for i in range(0,len(pcm),3200):
      await ws.send_json({'type':'audio','audio':base64.b64encode(pcm[i:i+3200]).decode()});await asyncio.sleep(.1)
    t=asyncio.create_task(send());texts=[];audio_bytes=0
    while True:
     e=await ws.receive_json(timeout=45)
     print('event',e['type'], e.get('text','') if e['type'] != 'partial' else '',flush=True)
     if e['type']=='text':texts.append(e['text'])
     if e['type']=='audio':audio_bytes+=len(base64.b64decode(e['audio']))
     if e['type']=='error':raise RuntimeError(e.get('text'))
     if e['type']=='done':break
    await t;print('Turn',phrases.index(phrase)+1,':',' '.join(texts),'audio bytes:',audio_bytes,flush=True);assert audio_bytes>0
asyncio.run(main())
