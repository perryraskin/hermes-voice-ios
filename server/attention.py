"""Single-owner attention broker. Producers submit; only broker policy may ring."""
import asyncio,json,sqlite3,time,uuid,hmac,re
from pathlib import Path
from aiohttp import web

class AttentionStore:
    def __init__(self,path):
        self.db=sqlite3.connect(str(path));self.db.row_factory=sqlite3.Row
        self.db.executescript('''CREATE TABLE IF NOT EXISTS state(key TEXT PRIMARY KEY,value TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS events(id TEXT PRIMARY KEY,source TEXT NOT NULL,dedupe TEXT UNIQUE NOT NULL,title TEXT NOT NULL,body TEXT NOT NULL,priority TEXT NOT NULL,decision INTEGER NOT NULL,deadline REAL NOT NULL,created REAL NOT NULL);
        CREATE TABLE IF NOT EXISTS calls(id TEXT PRIMARY KEY,event_id TEXT UNIQUE NOT NULL,status TEXT NOT NULL,created REAL NOT NULL,expires REAL NOT NULL);''');self.db.commit()
    def get(self,key,default=None):
        row=self.db.execute('SELECT value FROM state WHERE key=?',(key,)).fetchone();return json.loads(row[0]) if row else default
    def set(self,key,value):
        self.db.execute('INSERT OR REPLACE INTO state VALUES (?,?)',(key,json.dumps(value)));self.db.commit()
    def submit(self,source,data,now):
        required=['dedupe','title','body','priority','decision','deadline']
        if not all(k in data for k in required) or data['priority'] not in ['routine','important','urgent'] or type(data['decision'])!=bool: raise ValueError('Invalid attention request')
        if not all(isinstance(data[k],str) and 0<len(data[k])<=limit for k,limit in [('dedupe',160),('title',120),('body',6000)]):raise ValueError('Invalid text')
        if type(data['deadline']) not in (int,float) or not now<float(data['deadline'])<=now+604800:raise ValueError('Invalid deadline')
        identifier=str(uuid.uuid4());dedupe=source+':'+data['dedupe']
        self.db.execute('INSERT OR IGNORE INTO events VALUES (?,?,?,?,?,?,?,?,?)',(identifier,source,dedupe,data['title'],data['body'],data['priority'],int(data['decision']),data['deadline'],now));self.db.commit()
        return dict(self.db.execute('SELECT * FROM events WHERE dedupe=?',(dedupe,)).fetchone())
    def offer(self,now,ready,test=False):
        self.db.execute("UPDATE calls SET status='missed' WHERE status IN ('offering','ringing') AND expires<?",(now,));self.db.commit()
        if not ready:return None
        if not test:
            driving=self.get('driving',{})
            if not self.get('enabled',False) or not driving.get('active') or now-driving.get('updated',0)>14400:return None
            if now-self.get('last_call',0)<600:return None
        if self.db.execute("SELECT 1 FROM calls WHERE status IN ('offering','ringing','answered')").fetchone():return None
        source_filter=" AND e.source='owner-test'" if test else " AND e.source!='owner-test'"
        event=self.db.execute("SELECT e.* FROM events e LEFT JOIN calls c ON c.event_id=e.id WHERE c.id IS NULL AND e.deadline>? AND e.deadline<=? AND e.priority='urgent' AND e.decision=1"+source_filter+" ORDER BY e.deadline LIMIT 1",(now,now+1800)).fetchone()
        if not event:return None
        call={'id':str(uuid.uuid4()),'event_id':event['id'],'status':'offering','created':now,'expires':now+45}
        self.db.execute('INSERT INTO calls VALUES (:id,:event_id,:status,:created,:expires)',call);self.db.commit();self.set('last_call',now)
        return call
    def update(self,identifier,status):
        self.db.execute('UPDATE calls SET status=? WHERE id=?',(status,identifier));self.db.commit()
    def context(self,identifier,now):
        row=self.db.execute('SELECT c.*,e.title,e.body,e.source FROM calls c JOIN events e ON e.id=c.event_id WHERE c.id=?',(identifier,)).fetchone()
        if not row or row['status'] not in ['offering','ringing','answered'] or (row['status']!='answered' and row['expires']<now):return None
        return dict(row)
    def listing(self):return [dict(r) for r in self.db.execute('SELECT e.id,e.source,e.title,e.body,e.priority,e.deadline,c.status FROM events e LEFT JOIN calls c ON c.event_id=e.id ORDER BY e.created DESC LIMIT 30')]

class AttentionBroker:
    def __init__(self,config,path):self.config=config;self.store=AttentionStore(path);self.lock=asyncio.Lock();self.task=None
    def ready(self):return all(self.config.get(k) for k in ['APNS_KEY_PATH','APNS_KEY_ID','APNS_TEAM_ID']) and bool(self.store.get('device'))
    async def dispatch(self,test=False):
        async with self.lock:
            call=self.store.offer(time.time(),self.ready(),test)
            if not call:return None
            device=self.store.get('device');c=self.config
            try:
                import jwt,httpx
                token=jwt.encode({'iss':c['APNS_TEAM_ID'],'iat':int(time.time())},Path(c['APNS_KEY_PATH']).read_text(),algorithm='ES256',headers={'kid':c['APNS_KEY_ID']})
                endpoint='api.sandbox.push.apple.com' if device['environment']=='sandbox' else 'api.push.apple.com'
                async with httpx.AsyncClient(http2=True,timeout=10) as client:
                    result=await client.post('https://'+endpoint+'/3/device/'+device['token'],headers={'authorization':'bearer '+token,'apns-topic':'com.perryraskin.hermes.voice.voip','apns-push-type':'voip','apns-priority':'10','apns-expiration':'0'},json={'aps':{},'call_id':call['id']})
                self.store.update(call['id'],'ringing' if result.status_code==200 else 'failed')
                if result.status_code in [400,410] and result.json().get('reason') in ['BadDeviceToken','Unregistered']:self.store.set('device',None)
            except Exception:self.store.update(call['id'],'delivery_unknown')
            return call
    async def tick(self):
        while True:
            await self.dispatch();await asyncio.sleep(10)

async def status(request):
    b=request.app['attention'];return web.json_response({'enabled':b.store.get('enabled',False),'driving':b.store.get('driving',{}).get('active',False),'push_ready':b.ready(),'events':b.store.listing()})
async def preferences(request):
    b=request.app['attention'];data=await request.json()
    if type(data.get('enabled'))!=bool:raise web.HTTPBadRequest()
    b.store.set('enabled',data['enabled']);return await status(request)
async def driving(request):
    b=request.app['attention'];data=await request.json()
    if type(data.get('active'))!=bool:raise web.HTTPBadRequest()
    b.store.set('driving',{'active':data['active'],'updated':time.time()});return web.json_response({'ok':True})
async def register_device(request):
    data=await request.json()
    if not re.fullmatch(r'[a-f0-9]{32,256}',data.get('token','')) or data.get('environment') not in ['sandbox','production']:raise web.HTTPBadRequest()
    request.app['attention'].store.set('device',data);return web.json_response({'registered':True})
async def submit(request):
    try:
        data=await request.json()
        if request['producer']=='t3' and data.get('decision') and not data.get('origin'):
            raise ValueError('T3 decisions need an originating thread')
        thread=await request.app['returns'].validate_origin(request['producer'],data.get('origin'))
        event=request.app['attention'].store.submit(request['producer'],data,time.time())
        if thread:request.app['returns'].route(event['id'],thread)
    except (ValueError,TypeError):raise web.HTTPBadRequest(text='Invalid attention request')
    return web.json_response({'id':event['id'],'queued':True,'decision_return':bool(thread)})
async def test_call(request):
    b=request.app['attention']
    if not b.ready():return web.json_response({'error':'Incoming calls need an APNs signing key on the Mac and a registered physical iPhone.'},status=503)
    b.store.submit('owner-test',{'dedupe':str(uuid.uuid4()),'title':'Hermes test call','body':'This is the incoming-call connection test Perry requested. Greet him briefly.','priority':'urgent','decision':True,'deadline':time.time()+120},time.time())
    call=await b.dispatch(test=True)
    return web.json_response({'offered':bool(call)})
async def call_state(request):
    b=request.app['attention'];identifier=request.match_info['id'];data=await request.json();action=data.get('action')
    if action not in ['answered','ended','declined']:raise web.HTTPBadRequest()
    context=b.store.context(identifier,time.time())
    if not context:raise web.HTTPGone()
    b.store.update(identifier,action);return web.json_response({'ok':True})
def install(app,config):
    root=Path.home()/'.config/hermes-voice';root.mkdir(mode=0o700,parents=True,exist_ok=True)
    app['attention']=AttentionBroker(config,config.get('ATTENTION_DB',root/'attention.db'))
    for method,path,handler in [('GET','/v1/attention',status),('PATCH','/v1/attention/preferences',preferences),('POST','/v1/driving',driving),('POST','/v1/devices',register_device),('POST','/v1/events',submit),('POST','/v1/calls/test',test_call),('POST','/v1/calls/{id}',call_state)]:app.router.add_route(method,path,handler)
    async def start(app):app['attention'].task=asyncio.create_task(app['attention'].tick())
    async def stop(app):
        app['attention'].task.cancel();await asyncio.gather(app['attention'].task,return_exceptions=True);app['attention'].store.db.close()
    app.on_startup.append(start);app.on_cleanup.append(stop)
