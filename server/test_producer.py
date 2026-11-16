"""Exercise the real publisher and HTTP auth against an isolated queue; no APNs."""
import asyncio
import json
import os
from pathlib import Path
import tempfile
from aiohttp.test_utils import AioHTTPTestCase
from app import create_app


class ProducerTests(AioHTTPTestCase):
    async def get_application(self):
        return create_app({'ATTENTION_DB': ':memory:', 'DEVICE_TOKEN': 'owner-test-key',
                           'PRODUCER_KEYS': {'hermes': 'hermes-test-key', 't3': 't3-test-key'}})

    async def publish(self, source, directory, dedupe='test-decision'):
        root = Path(directory) / '.config/hermes-voice'
        root.mkdir(parents=True, exist_ok=True)
        (root / ('producer-' + source + '.json')).write_text(json.dumps({
            'url': str(self.server.make_url('/v1/events')), 'token': source + '-test-key'}))
        process = await asyncio.create_subprocess_exec(
            str(Path(__file__).resolve().parents[1] / 'scripts/attention'),
            '--source', source, '--dedupe', dedupe, '--title', 'Isolated QA decision',
            '--body', 'Test only; no phone is connected.', '--priority', 'urgent',
            '--decision', '--minutes', '15', env={**os.environ, 'HOME': directory},
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
        stdout, stderr = await asyncio.wait_for(process.communicate(), 15)
        self.assertEqual(process.returncode, 0, stderr.decode())
        return json.loads(stdout)

    async def test_both_agent_sources_and_call_gates(self):
        with tempfile.TemporaryDirectory() as directory:
            hermes = await self.publish('hermes', directory)
            t3 = await self.publish('t3', directory)
            repeat = await self.publish('t3', directory)
        self.assertTrue(hermes['queued'])
        self.assertTrue(t3['queued'])
        self.assertEqual(t3['id'], repeat['id'])
        self.assertNotEqual(hermes['id'], t3['id'])
        store = self.app['attention'].store
        import time
        now = time.time()
        self.assertIsNone(store.offer(now, True))
        headers = {'Authorization': 'Bearer owner-test-key'}
        response = await self.client.patch('/v1/attention/preferences',
                                           headers=headers, json={'enabled': True})
        self.assertEqual(response.status, 200)
        self.assertIsNone(store.offer(now, True))
        response = await self.client.post('/v1/driving', headers=headers, json={'active': True})
        self.assertEqual(response.status, 200)
        self.assertIsNone(store.offer(now, False))
        call = store.offer(now, True)
        self.assertIsNotNone(call)
        context = store.context(call['id'], now)
        self.assertIn(context['source'], ['hermes', 't3'])
        self.assertEqual(context['body'], 'Test only; no phone is connected.')

    async def test_producer_cannot_enable_calls_or_spoof_owner(self):
        response = await self.client.patch('/v1/attention/preferences',
            headers={'Authorization': 'Bearer t3-test-key'}, json={'enabled': True})
        self.assertEqual(response.status, 401)
        response = await self.client.post('/v1/events',
            headers={'Authorization': 'Bearer owner-test-key'}, json={})
        self.assertEqual(response.status, 401)
