import unittest,tempfile,time
from pathlib import Path
from attention import AttentionStore
class PolicyTests(unittest.TestCase):
    def setUp(self):
        self.store=AttentionStore(':memory:');self.now=time.time()
    def tearDown(self):self.store.db.close()
    def event(self,**changes):
        data={'dedupe':'issue-1','title':'Decision','body':'A decision is needed.','priority':'urgent','decision':True,'deadline':self.now+300};data.update(changes);return self.store.submit('test',data,self.now)
    def enable(self):self.store.set('enabled',True);self.store.set('driving',{'active':True,'updated':self.now})
    def test_default_does_not_call(self):self.event();self.assertIsNone(self.store.offer(self.now,True))
    def test_requires_driving_and_push(self):
        self.event();self.store.set('enabled',True);self.assertIsNone(self.store.offer(self.now,True));self.enable();self.assertIsNone(self.store.offer(self.now,False))
    def test_urgent_offer_only_once(self):
        self.enable();self.event();first=self.store.offer(self.now,True);self.assertIsNotNone(first);self.store.update(first['id'],'declined');self.assertIsNone(self.store.offer(self.now+601,True))
    def test_deduplication(self):self.assertEqual(self.event()['id'],self.event()['id'])
    def test_routine_queued(self):self.enable();self.event(priority='routine');self.assertIsNone(self.store.offer(self.now,True))
    def test_stale_driving(self):self.event(deadline=self.now+15000);self.enable();self.assertIsNone(self.store.offer(self.now+14500,True))
    def test_cooldown(self):
        self.enable();self.event();first=self.store.offer(self.now,True);self.store.update(first['id'],'ended');self.event(dedupe='second');self.assertIsNone(self.store.offer(self.now+10,True))
    def test_expired_call_not_answerable(self):self.enable();self.event();call=self.store.offer(self.now,True);self.assertIsNone(self.store.context(call['id'],self.now+46))
    def test_invalid_request(self):
        with self.assertRaises(ValueError):self.event(deadline=self.now-1)
