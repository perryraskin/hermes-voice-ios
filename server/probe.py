import asyncio,json
from pathlib import Path
from aiohttp import ClientSession
async def main():
 c=json.loads((Path.home()/'.config/hermes-voice/service.json').read_text())
 async with ClientSession() as h:
  async with h.post(c['HERMES_URL']+'/chat/completions',headers={'Authorization':'Bearer '+c['HERMES_KEY'],'X-Hermes-Session-Id':'voice-setup-readonly'},json={'model':'hermes-agent','stream':False,'messages':[{'role':'user','content':'In one sentence, identify yourself. Do not call tools or modify anything.'}]}) as r:
   print('Hermes status:',r.status);d=await r.json();print('Hermes result:',d.get('choices',[{}])[0].get('message',{}).get('content',str(d)[:200]))
  async with h.ws_connect('https://api.elevenlabs.io/v1/speech-to-text/realtime?model_id=scribe_v2_realtime&audio_format=pcm_16000&commit_strategy=vad',headers={'xi-api-key':c['ELEVENLABS_KEY']}) as ws:
   e=await ws.receive_json(timeout=15);print('Speech event:',e.get('message_type'));print('Speech error:',e.get('error','none'))
asyncio.run(main())
