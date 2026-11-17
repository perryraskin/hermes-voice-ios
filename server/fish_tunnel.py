"""Keep the trial's dedicated tunnel and Fish callback URL in sync (no AI polling).

Only loopback :12323 is exposed, never the device API or native Hermes API.
Requires the Fish agent to have already been provisioned in private configuration.
"""
import json,logging,os,re,signal,subprocess,urllib.request
from logging.handlers import RotatingFileHandler
from pathlib import Path

CONFIG=Path.home()/'.config/hermes-voice/service.json'
def configure(url):
    config=json.loads(CONFIG.read_text())
    headers={'Authorization':'Bearer '+config['FISH_API_KEY'],'Content-Type':'application/json'}
    body={'llm':{'custom':{'base_url':url+'/v1','model':'hermes-agent','api_key':config['FISH_CALLBACK_KEY']}}}
    base='https://api.fish.audio/v1/agent/agents/'+config['FISH_AGENT_ID']
    for endpoint,method,data in [(base+'/config','PATCH',body),(base+'/publish','POST',{})]:
        request=urllib.request.Request(endpoint,data=json.dumps(data).encode(),headers=headers,method=method)
        with urllib.request.urlopen(request,timeout=20) as response:
            if response.status not in (200,201):raise RuntimeError('Fish configuration failed')
    # Reread so unrelated private settings aren't replaced by an old snapshot.
    config=json.loads(CONFIG.read_text());config['FISH_CALLBACK_URL']=url
    temporary=CONFIG.with_suffix('.tunnel-new');temporary.write_text(json.dumps(config,indent=2));temporary.chmod(0o600);os.replace(temporary,CONFIG)

if __name__=='__main__':
    path=Path.home()/'.config/hermes-voice/fish-tunnel.log'
    handler=RotatingFileHandler(path,maxBytes=524288,backupCount=1);path.chmod(0o600)
    logger=logging.getLogger('fish.trial.tunnel');logger.addHandler(handler);logger.setLevel(logging.INFO)
    process=subprocess.Popen(['/opt/homebrew/bin/cloudflared','tunnel','--url','http://127.0.0.1:12323','--no-autoupdate'],stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True)
    def stop(*args):raise KeyboardInterrupt()
    signal.signal(signal.SIGTERM,stop)
    configured=False
    try:
        for line in process.stdout:
            logger.info(line.rstrip())
            match=re.search(r'https://[a-z0-9-]+\.trycloudflare.com',line)
            if match and not configured:
                configure(match.group());configured=True;logger.info('Fish trial callback URL configured and published')
        raise SystemExit(process.wait() or 1)
    except Exception as error:
        logger.error('Trial tunnel setup failed: %s',type(error).__name__)
        raise SystemExit(1)
    finally:
        process.terminate()
        try:process.wait(timeout=5)
        except subprocess.TimeoutExpired:process.kill()
