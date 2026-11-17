import asyncio,base64,json,unittest
from types import SimpleNamespace
from aiohttp import WSMsgType
from speech import stream_dialogue

class StreamingTests(unittest.IsolatedAsyncioTestCase):
    async def test_audio_arrives_before_model_finishes(self):
        release=asyncio.Event()
        class Socket:
            closed=False
            def __init__(self):self.sent=[];self.messages=asyncio.Queue()
            async def __aenter__(self):return self
            async def __aexit__(self,*args):self.closed=True
            async def send_json(self,value):
                self.sent.append(value)
                if value.get('inputs'):await self.messages.put({'audio':base64.b64encode(b'\x01\x00'*100).decode()})
                if value.get('close_socket'):await self.messages.put({'is_final':True})
            async def receive(self,timeout):return SimpleNamespace(type=WSMsgType.TEXT,data=json.dumps(await self.messages.get()))
        class HTTP:
            def ws_connect(self,url,**kwargs):self.url=url;self.socket=Socket();return self.socket
        async def text():
            yield 'This first phrase can play before the rest is ready. '
            await release.wait()
            yield 'And here is the rest.'
        http=HTTP();stream=stream_dialogue(http,'test',text())
        first=await asyncio.wait_for(stream.__anext__(),1)
        self.assertEqual(first,b'\x01\x00'*100)
        self.assertFalse(release.is_set())
        self.assertIn('pcm_24000',http.url)
        release.set()
        rest=[audio async for audio in stream]
        self.assertEqual(len(rest),1)
        self.assertEqual(sum('voices' in frame for frame in http.socket.sent),1)
        self.assertEqual(http.socket.sent[-1],{'close_socket':True})

    async def test_provider_failure_is_not_silently_accepted(self):
        class Socket:
            closed=False
            async def __aenter__(self):return self
            async def __aexit__(self,*args):self.closed=True
            async def send_json(self,value):pass
            async def receive(self,timeout):return SimpleNamespace(type=WSMsgType.TEXT,data=json.dumps({'error':'quota'}))
        class HTTP:
            def ws_connect(self,*args,**kwargs):return Socket()
        async def text():yield 'Hello.'
        with self.assertRaises(RuntimeError):
            _=[audio async for audio in stream_dialogue(HTTP(),'test',text())]
