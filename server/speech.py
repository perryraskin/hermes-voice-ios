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

async def stream_dialogue(http,key,text_chunks,voice='iP95p4xoKVk53GoZ742B'):
    """One continuous v4 prosody context per reply; yield playable PCM immediately.

    Text production and audio consumption run concurrently. Cancelling playback
    must not cancel a potentially executing Hermes action, so the caller drains
    its model stream even when its playback revision becomes stale.
    """
    import asyncio
    url='https://api.elevenlabs.io/v1/text-to-dialogue/stream-input?model_id=eleven_v4_turbo&output_format=pcm_24000'
    async with http.ws_connect(url,headers={'xi-api-key':key},max_msg_size=4*1024*1024) as ws:
        await ws.send_json({'voices':[voice]})
        async def write_text():
            try:
                async for text in text_chunks:
                    if text: await ws.send_json({'inputs':[{'text':text,'voice_id':voice}]})
                await ws.send_json({'close_socket':True})
            except Exception:
                await ws.close()
                raise
        async def keep_alive():
            while True:
                await asyncio.sleep(8)
                if not ws.closed: await ws.send_json({'keep_alive':True})
        writer=asyncio.create_task(write_text());keeper=asyncio.create_task(keep_alive())
        try:
            while True:
                message=await ws.receive(timeout=90)
                if message.type != WSMsgType.TEXT:
                    raise RuntimeError('Speech connection closed before final audio')
                event=json.loads(message.data)
                if event.get('error') or event.get('message_type')=='error':raise RuntimeError('Eleven v4 streaming rejected')
                if event.get('audio'):yield base64.b64decode(event['audio'])
                if event.get('is_final'):break
            await writer
        finally:
            writer.cancel();keeper.cancel()
            await asyncio.gather(writer,keeper,return_exceptions=True)
