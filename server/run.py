from pathlib import Path
import json
from aiohttp import web
from app import create_app
if __name__=='__main__':
 config=json.loads((Path.home()/'.config/hermes-voice/service.json').read_text())
 web.run_app(create_app(config),host='127.0.0.1',port=12322,access_log=None)
