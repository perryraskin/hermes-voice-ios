"""Eleven v4 Turbo dialogue synthesis, compatible with the shipped MP3 client."""
import base64,json
from aiohttp import WSMsgType
async def synthesize(http, key, text, voice='JBFqnCBsd6RMkjVDRZzb'):
    url='https://api.elevenlabs.io/v1/text-to-dialogue/stream-input?model_id=eleven_v4_turbo&output_format=mp3_44100_128'
    audio=bytearray()
    async with http.ws_connect(url,headers={'xi-api-key':key},max_msg_size=4*1024*1024) as ws:
        await ws.send_json({'voices':[voice]})
        await ws.send_json({'inputs':[{'text':text,'voice_id':voice}],'close_socket':True})
        while True:
            message=await ws.receive(timeout=30)
            if message.type != WSMsgType.TEXT: break
            event=json.loads(message.data)
            if event.get('error'): raise RuntimeError('Eleven v4 synthesis rejected')
            if event.get('audio'): audio.extend(base64.b64decode(event['audio']))
            if event.get('is_final'): break
    if not audio: raise RuntimeError('Eleven v4 returned no audio')
    return bytes(audio)
