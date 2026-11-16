import unittest
from aiohttp.test_utils import AioHTTPTestCase
from app import create_app
class ServiceTests(AioHTTPTestCase):
    async def get_application(self):
        return create_app({'ATTENTION_DB':':memory:','DEVICE_TOKEN':'test','HERMES_URL':'http://127.0.0.1','HERMES_KEY':'test','ELEVENLABS_KEY':'test'})
    async def test_missing_auth(self):
        r=await self.client.get('/v1/capabilities'); self.assertEqual(r.status,401)
    async def test_wrong_auth(self):
        r=await self.client.get('/v1/capabilities',headers={'Authorization':'Bearer wrong'}); self.assertEqual(r.status,401)
    async def test_capabilities(self):
        r=await self.client.get('/v1/capabilities',headers={'Authorization':'Bearer test'}); self.assertEqual(r.status,200); self.assertEqual((await r.json())['profile'],'voice')
if __name__=='__main__': unittest.main()

class PairingTests(AioHTTPTestCase):
    async def get_application(self):
        return create_app({'ATTENTION_DB':':memory:','DEVICE_TOKEN':'test'})
    async def test_pairing_one_time(self):
        import tempfile,json,time
        from pathlib import Path
        from unittest.mock import patch
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory); (root/'.config/hermes-voice').mkdir(parents=True)
            file=root/'.config/hermes-voice/pairing.json'
            file.write_text(json.dumps({'code':'test-pairing-code','expires':time.time()+60}))
            with patch('app.Path.home',return_value=root):
                rejected=await self.client.post('/v1/pair',json={'code':'wrong'}); self.assertEqual(rejected.status,401)
                accepted=await self.client.post('/v1/pair',json={'code':'test-pairing-code'}); self.assertEqual(accepted.status,200)
                replay=await self.client.post('/v1/pair',json={'code':'test-pairing-code'}); self.assertEqual(replay.status,401)

class SpeechTests(unittest.IsolatedAsyncioTestCase):
    async def test_v4_stream_collects_complete_mp3(self):
        import base64,json
        from types import SimpleNamespace
        from aiohttp import WSMsgType
        from speech import synthesize
        class Socket:
            def __init__(self): self.sent=[];self.events=iter([{'audio':base64.b64encode(b'first').decode()},{'audio':base64.b64encode(b'second').decode()},{'is_final':True}])
            async def __aenter__(self): return self
            async def __aexit__(self,*args): pass
            async def send_json(self,value): self.sent.append(value)
            async def receive(self,timeout): return SimpleNamespace(type=WSMsgType.TEXT,data=json.dumps(next(self.events)))
        class HTTP:
            def ws_connect(self,url,**kwargs): self.url=url;self.socket=Socket();return self.socket
        http=HTTP();result=await synthesize(http,'test','Hello')
        self.assertEqual(result,b'firstsecond');self.assertIn('eleven_v4_turbo',http.url);self.assertTrue(http.socket.sent[1]['close_socket'])
