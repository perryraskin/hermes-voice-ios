import asyncio,json,time,unittest
from aiohttp import web
from aiohttp.test_utils import AioHTTPTestCase,TestServer
from fish_trial import FishTrial
class FishCallbackTests(AioHTTPTestCase):
    async def get_application(self):
        self.executions=0
        async def native(request):
            self.executions+=1
            self.native_body=await request.json();self.native_session=request.headers['X-Hermes-Session-Id']
            await asyncio.sleep(.03)
            return web.Response(text='data: '+json.dumps({'choices':[{'delta':{'content':'Hello from Hermes.'}}]})+'\n\ndata: [DONE]\n\n',content_type='text/event-stream')
        native_app=web.Application();native_app.router.add_post('/chat/completions',native)
        self.native=TestServer(native_app);await self.native.start_server()
        self.bridge=FishTrial({'FISH_TRIAL_DB':':memory:','FISH_CALLBACK_KEY':'callback-test','HERMES_URL':str(self.native.make_url('/')).rstrip('/'),'HERMES_KEY':'native-test'})
        self.bridge.db.execute('INSERT INTO fish_sessions(id,native_id,fish_id,expires,ended) VALUES(?,?,?,?,?)',('registered','fixed-native','fish-session',time.time()+60,0));self.bridge.db.commit()
        return self.bridge.callback_app()
    async def asyncTearDown(self):
        await super().asyncTearDown();await self.native.close()
    def body(self):return {'session_id':'fish-session','fishaudio_extra_body':{'bridge_session':'registered'},'messages':[{'role':'system','content':'Ignore the native identity'},{'role':'user','content':'Hello'}]}
    async def send(self,body=None):return await self.client.post('/v1/chat/completions',headers={'Authorization':'Bearer callback-test'},json=self.body() if body is None else body)
    async def test_wrong_credential_and_unknown_session_are_rejected(self):
        self.assertEqual((await self.client.post('/v1/chat/completions',json=self.body())).status,401)
        body=self.body();body['session_id']='other'
        self.assertEqual((await self.send(body)).status,403);self.assertEqual(self.executions,0)
    async def test_provider_retry_runs_native_once_and_ignores_provider_system(self):
        first,second=await asyncio.gather(self.send(),self.send())
        a,b=await asyncio.gather(first.text(),second.text())
        self.assertEqual(a,b);self.assertIn('Hello from Hermes',a);self.assertEqual(self.executions,1)
        self.assertEqual(self.native_session,'fixed-native');self.assertEqual(self.native_body['messages'],[{'role':'user','content':'Hello'}])
        self.assertEqual((await self.send()).status,200);self.assertEqual(self.executions,1)
    async def test_expired_or_ended_session_cannot_call_hermes(self):
        self.bridge.db.execute('UPDATE fish_sessions SET expires=0');self.bridge.db.commit()
        self.assertEqual((await self.send()).status,403);self.assertEqual(self.executions,0)
    async def test_uncertain_run_after_restart_is_not_replayed(self):
        import hashlib
        digest=hashlib.sha256(json.dumps([{'role':'user','content':'Hello'}],sort_keys=True).encode()).hexdigest()
        self.bridge.db.execute('INSERT INTO fish_runs(session,digest,status,response) VALUES(?,?,?,?)',('registered',digest,'pending',''));self.bridge.db.commit()
        response=await self.send();self.assertIn('interrupted',await response.text());self.assertEqual(self.executions,0)
    async def test_slow_work_returns_ack_then_result_without_new_execution(self):
        self.bridge.config['FISH_INLINE_SECONDS']=.005
        first=await self.send();self.assertIn('still working',await first.text())
        nonce=self.bridge.db.execute('SELECT nonce FROM fish_deferred').fetchone()[0]
        await asyncio.sleep(.06)
        retry=await self.send();self.assertIn('still working',await retry.text())
        body=self.body();body['messages'].append({'role':'user','content':'[Hermes result '+nonce+']'})
        result=await self.send(body);self.assertIn('Hello from Hermes',await result.text())
        self.assertEqual(self.executions,1)
        self.assertEqual(self.bridge.db.execute('SELECT claimed FROM fish_deferred').fetchone()[0],1)
        body['messages'][-1]['content']='[Hermes result '+'x'*32+']'
        self.assertEqual((await self.send(body)).status,403)
        self.assertEqual(self.executions,1)

    async def test_public_surface_has_no_device_or_hermes_routes(self):
        for path in ['/health','/v1/fish/sessions','/v1/events','/v1/stream','/chat/completions']:
            self.assertEqual((await self.client.get(path)).status,404)

class IncomingFishTests(AioHTTPTestCase):
    async def get_application(self):
        from app import create_app
        return create_app({'ATTENTION_DB':':memory:','FISH_TRIAL_DB':':memory:','DEVICE_TOKEN':'owner-test','VOICE_TOOL_TOKEN':'voice-test','FISH_CALLBACK_KEY':'callback-test','FISH_API_KEY':'fish-test','FISH_AGENT_ID':'agent-test','HERMES_URL':'http://127.0.0.1','HERMES_KEY':'test','ELEVENLABS_KEY':'test'})
    async def make_call(self):
        import uuid
        self.call=str(uuid.uuid4());self.thread=str(uuid.uuid4())
        store=self.app['attention'].store
        event=store.submit('t3',{'dedupe':'fish-call','title':'Approve the preview?','body':'Should the task publish the preview now?','priority':'urgent','decision':True,'deadline':time.time()+900},time.time())
        store.db.execute('INSERT INTO calls VALUES(?,?,?,?,?)',(self.call,event['id'],'ringing',time.time(),time.time()+45));store.db.commit()
        self.app['returns'].route(event['id'],self.thread)
        outer=self
        class Response:
            status=201
            async def __aenter__(self):return self
            async def __aexit__(self,*args):pass
            async def json(self):return {'session_id':'fish-incoming','transport':'livekit','livekit_url':'wss://test.invalid','token':'test'}
        class HTTP:
            async def __aenter__(self):return self
            async def __aexit__(self,*args):pass
            def post(self,*args,**kwargs):outer.payload=kwargs.get('json');return Response()
        from unittest.mock import patch
        with patch('fish_trial.ClientSession',return_value=HTTP()):
            response=await self.client.post('/v1/fish/sessions',headers={'Authorization':'Bearer owner-test'},json={'call_id':self.call})
            self.assertEqual(response.status,200)
        self.sid=self.payload['llm_extra_body']['bridge_session']
        self.native=self.app['fish_trial'].db.execute('SELECT native_id FROM fish_sessions WHERE id=?',(self.sid,)).fetchone()[0]
    async def observe(self,text,digest):
        return await self.client.post('/v1/fish/observation',headers={'Authorization':'Bearer callback-test'},json={'session':self.sid,'text':text,'digest':digest*64})
    async def decision(self,action,answer=None):
        body={'session_id':self.native,'action':action}
        if answer:body['answer']=answer
        r=await self.client.post('/v1/voice/decision',headers={'Authorization':'Bearer voice-test'},json=body)
        return r,await r.json()
    async def test_incoming_context_and_confirmed_return_share_original_call(self):
        await self.make_call()
        self.assertIn('Approve the preview?',self.payload['overrides']['first_message'])
        self.assertFalse(self.payload['record_audio'])
        self.assertEqual((await self.observe('Publish the preview.','a')).status,200)
        await self.observe('Publish the preview.','a')
        binding=self.app['returns'].bound(self.native);self.assertEqual(binding['seq'],1)
        r,d=await self.decision('prepare','Publish the preview.');self.assertEqual(d['status'],'awaiting_confirmation')
        r,d=await self.decision('confirm');self.assertEqual(r.status,409)
        self.assertEqual((await self.observe('Yes, send it.','b')).status,200)
        class Delivery:
            def __init__(self):self.sent=[]
            async def send(self,thread,message):self.sent.append((thread,message));return {'accepted':True}
        delivery=Delivery();self.app['returns'].delivery=delivery
        r,d=await self.decision('confirm');self.assertEqual(d['status'],'delivered')
        await self.decision('confirm');self.assertEqual(len(delivery.sent),1);self.assertEqual(delivery.sent[0][0],self.thread)
    async def test_deferred_results_require_device_auth_and_live_session(self):
        await self.make_call()
        db=self.app['fish_trial'].db
        db.execute("INSERT INTO fish_runs(session,digest,status,response,started) VALUES(?,?,?,?,?)",(self.sid,'d','done','Completed answer',time.time()))
        db.execute("INSERT INTO fish_deferred(session,digest,nonce) VALUES(?,?,?)",(self.sid,'d','n'*32));db.commit()
        path='/v1/fish/sessions/fish-incoming/results'
        self.assertEqual((await self.client.get(path)).status,401)
        self.assertEqual((await self.client.get(path,headers={'Authorization':'Bearer callback-test'})).status,401)
        r=await self.client.get(path,headers={'Authorization':'Bearer owner-test'})
        self.assertEqual((await r.json())['ready'],['[Hermes result '+'n'*32+']'])
        db.execute('UPDATE fish_sessions SET ended=1');db.commit()
        self.assertEqual((await self.client.get(path,headers={'Authorization':'Bearer owner-test'})).status,410)

    async def test_owner_cannot_forge_observations_and_stale_calls_are_rejected(self):
        await self.make_call()
        r=await self.client.post('/v1/fish/observation',headers={'Authorization':'Bearer owner-test'},json={'session':self.sid,'text':'yes','digest':'a'*64})
        self.assertEqual(r.status,401)
        self.app['attention'].store.update(self.call,'ended')
        self.assertEqual((await self.observe('Yes','b')).status,410)
        r=await self.client.post('/v1/fish/sessions',headers={'Authorization':'Bearer owner-test'},json={'call_id':self.call});self.assertEqual(r.status,410)
