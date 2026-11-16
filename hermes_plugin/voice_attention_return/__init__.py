"""Install in the dedicated voice profile and enable toolset voice_returns."""
import json
from pathlib import Path
import urllib.request
import urllib.error


def call(action, answer=None):
    from gateway.session_context import get_session_env
    if get_session_env('HERMES_SESSION_PLATFORM','') != 'api_server' or get_session_env('HERMES_SESSION_PROFILE','') != 'voice':
        return json.dumps({'error':'Decision returns are available only in the dedicated voice API session.'})
    session=get_session_env('HERMES_SESSION_ID','')
    if not session:return json.dumps({'error':'No bound voice session. Nothing was sent.'})
    try:
        c=json.loads((Path.home()/'.config/hermes-voice/voice-tool.json').read_text())
        data={'session_id':session,'action':action}
        if answer is not None:data['answer']=answer
        request=urllib.request.Request(c['url'],data=json.dumps(data).encode(),headers={'Authorization':'Bearer '+c['token'],'Content-Type':'application/json'})
        with urllib.request.urlopen(request,timeout=22) as response:return response.read().decode()
    except urllib.error.HTTPError as error:
        return error.read().decode()
    except Exception:
        return json.dumps({'error':'The return could not be confirmed. Check status before retrying; do not claim delivery.'})


def register(ctx):
    tools=[
        ('prepare_voice_decision','Read back a decision for the originating T3 task. After this tool, repeat the answer and ask Perry to confirm sending it. Do not send until a new explicit yes.',{'answer':{'type':'string'}},['answer'],lambda args=None,**kw:call('prepare',(args or kw).get('answer'))),
        ('send_voice_decision','Send the prepared decision only after Perry confirms the read-back. The broker checks a newer spoken confirmation and the fixed originating thread. Delivered means accepted by T3, not agent-acknowledged or completed.',{},[],lambda args=None,**kw:call('confirm')),
        ('check_voice_decision','Check whether the decision was delivered and whether the original T3 agent acknowledged it. Never equate receipt with task completion.',{},[],lambda args=None,**kw:call('status')),
    ]
    for name,description,properties,required,handler in tools:
        ctx.register_tool(name=name,toolset='voice_returns',description=description,schema={'name':name,'description':description,'parameters':{'type':'object','properties':properties,'required':required}},handler=handler)
