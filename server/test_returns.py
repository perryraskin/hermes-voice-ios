import asyncio
import json
import os
from pathlib import Path
import tempfile
import time
import unittest
from aiohttp.test_utils import AioHTTPTestCase
from app import create_app
from attention import AttentionStore
from returns import ReturnBridge, DecisionError, T3Delivery

THREAD='11111111-1111-4111-8111-111111111111'

class FakeDelivery:
    def __init__(self):self.sent=[];self.fail=False
    async def read(self, thread):return {'threadId':thread}
    async def send(self, thread, message):
        self.sent.append((thread,message));await asyncio.sleep(0)
        if self.fail:raise TimeoutError()
        return {'threadId':thread,'delivery':'queued','runId':'test-run'}

class ReturnTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.store=AttentionStore(':memory:');self.delivery=FakeDelivery();self.bridge=ReturnBridge(self.store,self.delivery)
        now=time.time();self.event=self.store.submit('t3',{'dedupe':'choice','title':'Pick a target','body':'Choose staging or production.','priority':'urgent','decision':True,'deadline':now+600},now)
        self.bridge.route(self.event['id'],THREAD)
        self.store.set('enabled',True);self.store.set('driving',{'active':True,'updated':now})
        self.call=self.store.offer(now,True);self.store.update(self.call['id'],'answered');self.bridge.bind('voice-test',self.call['id'])
    def tearDown(self):self.store.db.close()
    async def prepare(self):
        self.bridge.heard('voice-test','Use staging, not production.')
        return await self.bridge.act('voice-test','prepare','Use staging only.')
    async def confirm(self):
        await self.prepare();self.bridge.heard('voice-test','Yes, send it.')
        return await self.bridge.act('voice-test','confirm')
    async def test_confirmed_delivery_and_idempotence(self):
        result=await self.confirm();self.assertEqual(result['status'],'delivered')
        self.assertIsNone(result['ack_status']);self.assertEqual(self.delivery.sent[0][0],THREAD)
        self.assertIn('Use staging only.',self.delivery.sent[0][1]);self.assertIn('acknowledge --source t3',self.delivery.sent[0][1])
        self.assertEqual(await self.bridge.act('voice-test','confirm'),result);self.assertEqual(len(self.delivery.sent),1)
        self.bridge.acknowledge('t3',result['id'],'accepted','Received.')
        self.assertEqual((await self.bridge.act('voice-test','status'))['ack_status'],'accepted')
    async def test_requires_new_confirmation_after_readback(self):
        self.bridge.heard('voice-test','Yes');await self.bridge.act('voice-test','prepare','Use staging.')
        with self.assertRaises(DecisionError):await self.bridge.act('voice-test','confirm')
        self.bridge.heard('voice-test','No, use production instead.')
        with self.assertRaises(DecisionError):await self.bridge.act('voice-test','confirm')
        self.bridge.heard('voice-test','Yes')
        with self.assertRaises(DecisionError):await self.bridge.act('voice-test','confirm')
        self.assertEqual(self.delivery.sent,[])
    async def test_no_other_session_or_ended_call(self):
        with self.assertRaises(DecisionError):await self.bridge.act('different-session','prepare','Deploy')
        await self.prepare();self.bridge.heard('voice-test','Yes');self.bridge.close('voice-test')
        with self.assertRaises(DecisionError):await self.bridge.act('voice-test','confirm')
    async def test_expired_decision_does_not_resume(self):
        await self.prepare();self.bridge.heard('voice-test','Yes')
        self.store.db.execute('UPDATE events SET deadline=?',(time.time()-1,));self.store.db.commit()
        with self.assertRaises(DecisionError):await self.bridge.act('voice-test','confirm')
        self.assertEqual(self.delivery.sent,[])
    async def test_uncertain_send_is_not_replayed(self):
        self.delivery.fail=True
        with self.assertRaises(TimeoutError):await self.confirm()
        result=await self.bridge.act('voice-test','confirm')
        self.assertEqual(result['status'],'delivery_unknown');self.assertEqual(len(self.delivery.sent),1)
    async def test_concurrent_confirm_sends_once(self):
        await self.prepare();self.bridge.heard('voice-test','Yes')
        a,b=await asyncio.gather(self.bridge.act('voice-test','confirm'),self.bridge.act('voice-test','confirm'))
        self.assertEqual(a['id'],b['id']);self.assertEqual(len(self.delivery.sent),1)
    async def test_fixed_origin_and_producer_ack(self):
        with self.assertRaises(DecisionError):self.bridge.route(self.event['id'],'22222222-2222-4222-8222-222222222222')
        result=await self.confirm()
        with self.assertRaises(DecisionError):self.bridge.acknowledge('hermes',result['id'],'accepted','Wrong producer')
        self.bridge.acknowledge('t3',result['id'],'needs_clarification','Which staging account?')
        with self.assertRaises(DecisionError):self.bridge.acknowledge('t3',result['id'],'accepted','Replace answer')
    async def test_crash_marks_inflight_unknown(self):
        self.store.db.execute("INSERT INTO decisions(id,event_id,answer,confirmation,status,created) VALUES ('inflight',?,'Staging','Yes','sending',?)",(self.event['id'],time.time()));self.store.db.commit()
        bridge=ReturnBridge(self.store,self.delivery)
        self.assertEqual(bridge.result(self.event['id'])['status'],'delivery_unknown')

class ReturnAuthTests(AioHTTPTestCase):
    async def get_application(self):
        app=create_app({'ATTENTION_DB':':memory:','DEVICE_TOKEN':'owner','VOICE_TOOL_TOKEN':'voice-only','PRODUCER_KEYS':{'t3':'producer'}})
        app['returns'].delivery=FakeDelivery();return app
    async def test_voice_token_is_narrow_and_owner_cannot_impersonate_tool(self):
        for key in ['owner','producer']:
            response=await self.client.post('/v1/voice/decision',headers={'Authorization':'Bearer '+key},json={})
            self.assertEqual(response.status,401)
        response=await self.client.patch('/v1/attention/preferences',headers={'Authorization':'Bearer voice-only'},json={'enabled':True})
        self.assertEqual(response.status,401)
    async def test_t3_submit_must_carry_origin(self):
        data={'dedupe':'missing','title':'Question','body':'Decide','priority':'urgent','decision':True,'deadline':time.time()+300}
        headers={'Authorization':'Bearer producer'}
        response=await self.client.post('/v1/events',headers=headers,json=data);self.assertEqual(response.status,400)
        data['origin']={'kind':'t3','thread_id':THREAD}
        response=await self.client.post('/v1/events',headers=headers,json=data);self.assertEqual(response.status,200)
        self.assertTrue((await response.json())['decision_return'])
    async def test_owner_cannot_ack_as_producer(self):
        response=await self.client.post('/v1/decisions/missing/ack',headers={'Authorization':'Bearer owner'},json={})
        self.assertEqual(response.status,401)

    async def test_http_loop_and_real_publisher_acknowledgment(self):
        data={'dedupe':'roundtrip','title':'Choose environment','body':'Staging or production?',
              'priority':'urgent','decision':True,'deadline':time.time()+300,
              'origin':{'kind':'t3','thread_id':THREAD}}
        response=await self.client.post('/v1/events',headers={'Authorization':'Bearer producer'},json=data)
        event=(await response.json())['id']
        store=self.app['attention'].store;bridge=self.app['returns']
        store.set('enabled',True);store.set('driving',{'active':True,'updated':time.time()})
        call=store.offer(time.time(),True);store.update(call['id'],'answered');bridge.bind('voice-roundtrip',call['id'])
        bridge.heard('voice-roundtrip','Use staging only.')
        headers={'Authorization':'Bearer voice-only'}
        response=await self.client.post('/v1/voice/decision',headers=headers,
            json={'session_id':'voice-roundtrip','action':'prepare','answer':'Use staging only.'})
        self.assertEqual((await response.json())['status'],'awaiting_confirmation')
        bridge.heard('voice-roundtrip','Yes, send it.')
        response=await self.client.post('/v1/voice/decision',headers=headers,
            json={'session_id':'voice-roundtrip','action':'confirm'})
        decision=await response.json();self.assertEqual(decision['status'],'delivered')
        self.assertEqual(len(bridge.delivery.sent),1)
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory)/'.config/hermes-voice';root.mkdir(parents=True)
            (root/'producer-t3.json').write_text(json.dumps({'url':str(self.server.make_url('/v1/events')),'token':'producer'}))
            process=await asyncio.create_subprocess_exec(str(Path(__file__).resolve().parents[1]/'scripts/attention'),
                'acknowledge','--source','t3','--decision-id',decision['id'],'--status','accepted','--note','Received staging choice.',
                env={**os.environ,'HOME':directory},stdout=asyncio.subprocess.PIPE,stderr=asyncio.subprocess.PIPE)
            out,err=await asyncio.wait_for(process.communicate(),10)
            self.assertEqual(process.returncode,0,err.decode());self.assertTrue(json.loads(out)['acknowledged'])
        response=await self.client.post('/v1/voice/decision',headers=headers,
            json={'session_id':'voice-roundtrip','action':'status'})
        status=await response.json();self.assertEqual(status['ack_status'],'accepted')
        self.assertEqual(status['ack_note'],'Received staging choice.')
        self.assertEqual(status['id'],decision['id'])

class CLIDeliveryTests(unittest.IsolatedAsyncioTestCase):
    async def test_sends_literal_message_over_stdin_to_exact_thread(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);cli=root/'fake-t3';record=root/'record.json'
            cli.write_text('#!/usr/bin/env python3\nimport sys,json\nfrom pathlib import Path\n'
                'if sys.argv[2]=="show":print(json.dumps({"thread":{"threadId":sys.argv[3]}}))\n'
                'else:\n data=sys.stdin.read();Path('+repr(str(record))+').write_text(json.dumps({"args":sys.argv[1:],"message":data}));print(json.dumps({"delivery":"queued","threadId":sys.argv[3]}))\n')
            cli.chmod(0o700)
            message='Use staging. $(never-run) `no-shell`\nLine two.'
            await T3Delivery(str(cli)).send(THREAD,message)
            saved=json.loads(record.read_text());self.assertEqual(saved['message'],message)
            self.assertEqual(saved['args'],['thread','send',THREAD,'-','--json'])
