"""Optional Live 3 trial. Only the callback app is exposed through its own tunnel.

The existing device API and native Hermes API remain private. Callback identities
are minted locally; provider retries attach to one persisted native execution.
"""
import asyncio,hashlib,hmac,json,secrets,sqlite3,time,uuid
from pathlib import Path
from aiohttp import web,ClientSession,ClientTimeout

class FishTrial:
    def __init__(self,config):
        self.config=config
        path=config.get('FISH_TRIAL_DB',':memory:' if config.get('ATTENTION_DB')==':memory:' else str(Path.home()/'.config/hermes-voice/fish-trial.db'))
        self.db=sqlite3.connect(path)
        if path!=':memory:':Path(path).chmod(0o600)
        self.db.executescript('''CREATE TABLE IF NOT EXISTS fish_sessions (id TEXT PRIMARY KEY, native_id TEXT, fish_id TEXT, expires REAL, ended INTEGER DEFAULT 0);
CREATE TABLE IF NOT EXISTS fish_runs (session TEXT, digest TEXT, status TEXT, response TEXT, PRIMARY KEY(session,digest));''')
        self.runs={};self.created=[];self.session_locks={}

    @property
    def ready(self):return all(self.config.get(k) for k in ('FISH_API_KEY','FISH_AGENT_ID','FISH_CALLBACK_KEY'))

    async def create_session(self,request):
        if not self.ready:raise web.HTTPServiceUnavailable(text='Fish trial is not configured')
        now=time.time()
        self.db.execute('DELETE FROM fish_runs WHERE session IN (SELECT id FROM fish_sessions WHERE expires<?)',(now-3600,))
        self.db.execute('DELETE FROM fish_sessions WHERE expires<?',(now-3600,));self.db.commit()
        self.created=[t for t in self.created if t>now-60]
        if len(self.created)>=2:raise web.HTTPTooManyRequests(text='Please wait before starting another trial')
        if self.db.execute('SELECT count(*) FROM fish_sessions WHERE ended=0 AND expires>?',(now,)).fetchone()[0]>=3:raise web.HTTPTooManyRequests(text='End the previous trial first')
        self.created.append(now)
        sid=secrets.token_urlsafe(32);native='fish-voice-'+str(uuid.uuid4())
        self.db.execute('INSERT INTO fish_sessions(id,native_id,expires) VALUES(?,?,?)',(sid,native,now+660));self.db.commit()
        try:
            async with ClientSession(timeout=ClientTimeout(total=20)) as http:
                async with http.post('https://api.fish.audio/v1/agent/sessions',headers={'Authorization':'Bearer '+self.config['FISH_API_KEY']},json={'agent_id':self.config['FISH_AGENT_ID'],'end_user_id':'hermes-owner','timezone':'America/New_York','record_audio':False,'tool_events':False,'llm_extra_body':{'bridge_session':sid}}) as response:
                    if response.status!=201:raise web.HTTPBadGateway(text='Fish could not start a trial session. Check credit and configuration.')
                    result=await response.json()
            if result.get('transport')!='livekit':raise web.HTTPBadGateway(text='Unsupported Fish transport')
            self.db.execute('UPDATE fish_sessions SET fish_id=? WHERE id=?',(result['session_id'],sid));self.db.commit()
            return web.json_response(result,headers={'Cache-Control':'no-store'})
        except Exception:
            self.db.execute('UPDATE fish_sessions SET ended=1 WHERE id=?',(sid,));self.db.commit();raise

    async def end_session(self,request):
        fish=request.match_info['session']
        row=self.db.execute('SELECT id FROM fish_sessions WHERE fish_id=?',(fish,)).fetchone()
        if not row:raise web.HTTPNotFound()
        self.db.execute('UPDATE fish_sessions SET ended=1 WHERE fish_id=?',(fish,));self.db.commit()
        async with ClientSession(timeout=ClientTimeout(total=10)) as http:
            async with http.post(f'https://api.fish.audio/v1/agent/sessions/{fish}/end',headers={'Authorization':'Bearer '+self.config['FISH_API_KEY']}) as r:
                if r.status not in (200,204,404,409):raise web.HTTPBadGateway()
        return web.Response(status=204)

    async def callback(self,request):
        expected=self.config.get('FISH_CALLBACK_KEY','')
        if not expected or not hmac.compare_digest(request.headers.get('Authorization',''),'Bearer '+expected):raise web.HTTPUnauthorized()
        for key in [k for k,r in self.runs.items() if r['done'] and not self.db.execute('SELECT 1 FROM fish_sessions WHERE id=? AND expires>?',(k[0],time.time()-3600)).fetchone()]:
            self.runs.pop(key)
        body=await request.json();sid=body.get('fishaudio_extra_body',{}).get('bridge_session','')
        row=self.db.execute('SELECT native_id,fish_id,expires,ended FROM fish_sessions WHERE id=?',(sid,)).fetchone()
        if not row or row[2]<time.time() or row[3] or row[1]!=body.get('session_id'):raise web.HTTPForbidden()
        # Reject invented/model-selected sessions and destinations. System prompts,
        # tool definitions and provider model names never alter native privileges.
        messages=body.get('messages',[])
        history=[{'role':m.get('role'),'content':m.get('content')} for m in messages if m.get('role') in ('user','assistant')]
        if not history or history[-1]['role']!='user' or not isinstance(history[-1]['content'],str):raise web.HTTPBadRequest()
        text=history[-1]['content'].strip()
        if not text or len(text)>12000:raise web.HTTPBadRequest()
        digest=hashlib.sha256(json.dumps(history,sort_keys=True).encode()).hexdigest();key=(sid,digest)
        cached=self.db.execute('SELECT status,response FROM fish_runs WHERE session=? AND digest=?',key).fetchone()
        if key not in self.runs:
            if cached:
                # A pending row after restart has an uncertain native outcome.
                answer=cached[1] if cached[0]=='done' else 'That request was interrupted. Please check its outcome before repeating an action.'
                self.runs[key]={'chunks':[answer],'done':True,'changed':asyncio.Condition()}
            else:
                self.db.execute('INSERT INTO fish_runs VALUES(?,?,?,?)',(sid,digest,'pending',''));self.db.commit()
                self.runs[key]={'chunks':[],'done':False,'changed':asyncio.Condition()}
                self.runs[key]['task']=asyncio.create_task(self.generate(key,row[0],text))
        run=self.runs[key]
        response=web.StreamResponse(headers={'Content-Type':'text/event-stream','Cache-Control':'no-store'});await response.prepare(request)
        index=0
        while True:
            async with run['changed']:
                await run['changed'].wait_for(lambda:index<len(run['chunks']) or run['done'])
                chunks=run['chunks'][index:];index=len(run['chunks']);done=run['done']
            for text in chunks:
                event={'id':'hermes-'+digest[:16],'object':'chat.completion.chunk','choices':[{'index':0,'delta':{'content':text},'finish_reason':None}]}
                try:await response.write(('data: '+json.dumps(event)+'\n\n').encode())
                except (ConnectionResetError,asyncio.CancelledError):return response
            if done:break
        await response.write(b'data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}\n\ndata: [DONE]\n\n')
        return response

    async def generate(self,key,native,text):
        async with self.session_locks.setdefault(native,asyncio.Lock()):
            await self.generate_once(key,native,text)

    async def generate_once(self,key,native,text):
        run=self.runs[key]
        async def add(text):
            async with run['changed']:
                run['chunks'].append(text);run['changed'].notify_all()
        try:
            async with ClientSession(timeout=ClientTimeout(total=90)) as http:
                async with http.post(self.config['HERMES_URL'].rstrip('/')+'/chat/completions',headers={'Authorization':'Bearer '+self.config['HERMES_KEY'],'X-Hermes-Session-Id':native},json={'model':'hermes-agent','model_options':{'reasoning_effort':'low','service_tier':'priority'},'stream':True,'messages':[{'role':'user','content':text}]}) as response:
                    response.raise_for_status()
                    async for raw in response.content:
                        line=raw.decode().strip()
                        if not line.startswith('data:'):continue
                        if line[5:].strip()=='[DONE]':break
                        choices=json.loads(line[5:]).get('choices',[])
                        if choices:
                            chunk=choices[0].get('delta',{}).get('content','')
                            if chunk:await add(chunk)
            answer=''.join(run['chunks']) or 'I did not receive a response. Please check before repeating that request.'
            if not run['chunks']:await add(answer)
            self.db.execute('UPDATE fish_runs SET status=?,response=? WHERE session=? AND digest=?',('done',answer,*key));self.db.commit()
        except Exception:
            # Persist uncertainty rather than retrying a potentially executed tool.
            if not run['chunks']:await add('That request was interrupted. Please check its outcome before repeating an action.')
        finally:
            async with run['changed']:run['done']=True;run['changed'].notify_all()

    def callback_app(self):
        app=web.Application(client_max_size=256*1024)
        app.router.add_post('/v1/chat/completions',self.callback)
        return app

def install(app,config):
    trial=FishTrial(config);app['fish_trial']=trial
    app.router.add_post('/v1/fish/sessions',trial.create_session)
    app.router.add_post('/v1/fish/sessions/{session}/end',trial.end_session)
    return trial

if __name__=='__main__':
    config=json.loads((Path.home()/'.config/hermes-voice/service.json').read_text())
    web.run_app(FishTrial(config).callback_app(),host='127.0.0.1',port=12323,access_log=None)
