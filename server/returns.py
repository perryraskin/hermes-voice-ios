"""Call-scoped, confirmed owner decisions back to an originating local T3 thread."""
import asyncio
import json
import re
import time
import uuid
from aiohttp import web


class DecisionError(ValueError):
    pass


def affirmative(text):
    normalized = re.sub(r"[^a-z0-9 ]", "", text.lower()).strip()
    return normalized in {'yes', 'yeah', 'yes please', 'yes send it', 'send it',
                          'confirmed', 'correct', 'thats correct', 'thats right',
                          'go ahead', 'yes go ahead'}


class T3Delivery:
    def __init__(self, cli):
        self.cli = cli

    async def command(self, *args, message=None):
        if not self.cli:
            raise DecisionError('T3 return delivery is not configured on this host.')
        process = await asyncio.create_subprocess_exec(
            self.cli, *args, stdin=asyncio.subprocess.PIPE if message is not None else asyncio.subprocess.DEVNULL,
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
        try:
            out, _ = await asyncio.wait_for(process.communicate(message.encode() if message is not None else None), 15)
        except BaseException:
            if process.returncode is None:
                process.kill()
                await process.wait()
            raise
        if process.returncode:
            raise DecisionError('T3 did not confirm the request. Check the original thread before retrying.')
        return json.loads(out)

    async def read(self, thread):
        result = await self.command('thread', 'show', thread, '--json', '--messages', '0')
        if result.get('thread', {}).get('threadId') != thread or result['thread'].get('archived'):
            raise DecisionError('The originating T3 thread is unavailable.')
        return result['thread']

    async def send(self, thread, message):
        await self.read(thread)  # Resolve the exact existing thread; never start a new one.
        return await self.command('thread', 'send', thread, '-', '--json', message=message)


class ReturnBridge:
    def __init__(self, store, delivery):
        self.store = store
        self.db = store.db
        self.delivery = delivery
        self.lock = asyncio.Lock()
        self.db.executescript('''
        CREATE TABLE IF NOT EXISTS return_routes(event_id TEXT PRIMARY KEY,thread_id TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS voice_bindings(session_id TEXT PRIMARY KEY,call_id TEXT NOT NULL,
          active INTEGER NOT NULL,seq INTEGER NOT NULL DEFAULT 0,latest_text TEXT NOT NULL DEFAULT '',
          proposal TEXT,proposal_seq INTEGER,expires REAL NOT NULL);
        CREATE TABLE IF NOT EXISTS decisions(id TEXT PRIMARY KEY,event_id TEXT UNIQUE NOT NULL,
          answer TEXT NOT NULL,confirmation TEXT NOT NULL,status TEXT NOT NULL,created REAL NOT NULL,
          receipt TEXT,ack_status TEXT,ack_note TEXT);
        ''')
        # A crash between sending and recording a receipt must never automatically resend.
        self.db.execute("UPDATE decisions SET status='delivery_unknown' WHERE status='sending'")
        self.db.commit()

    async def validate_origin(self, source, origin):
        if origin is None:
            return None  # Legacy notification-only events retain their original behavior.
        if source != 't3' or not isinstance(origin, dict) or origin.get('kind') != 't3':
            raise DecisionError('Only an originating local T3 thread is supported for decision returns.')
        thread = origin.get('thread_id', '')
        try:
            if str(uuid.UUID(thread)) != thread:
                raise ValueError()
        except (ValueError, TypeError, AttributeError):
            raise DecisionError('Provide the originating T3 thread UUID.')
        await self.delivery.read(thread)
        return thread

    def route(self, event_id, thread):
        existing = self.db.execute('SELECT thread_id FROM return_routes WHERE event_id=?', (event_id,)).fetchone()
        if existing and existing[0] != thread:
            raise DecisionError('This issue is already bound to a different T3 thread.')
        self.db.execute('INSERT OR IGNORE INTO return_routes VALUES (?,?)', (event_id, thread))
        self.db.commit()

    def bind(self, session, call):
        self.db.execute('INSERT INTO voice_bindings(session_id,call_id,active,expires) VALUES (?,?,1,?)',
                        (session, call, time.time() + 14400))
        self.db.commit()

    def heard(self, session, text):
        # A correction or a new question invalidates the previous read-back.
        if not affirmative(text):
            self.db.execute('UPDATE voice_bindings SET proposal=NULL,proposal_seq=NULL WHERE session_id=?', (session,))
        self.db.execute('UPDATE voice_bindings SET seq=seq+1,latest_text=? WHERE session_id=? AND active=1', (text, session))
        self.db.commit()

    def close(self, session):
        self.db.execute("UPDATE voice_bindings SET active=0,latest_text='',proposal=NULL,proposal_seq=NULL WHERE session_id=?", (session,))
        self.db.commit()

    def bound(self, session):
        row = self.db.execute('''SELECT v.*,c.event_id,r.thread_id,e.title,e.deadline FROM voice_bindings v
          JOIN calls c ON c.id=v.call_id JOIN events e ON e.id=c.event_id
          JOIN return_routes r ON r.event_id=c.event_id
          WHERE v.session_id=? AND v.active=1 AND v.expires>? AND c.status IN ('offering','ringing','answered')''',
          (session, time.time())).fetchone()
        if not row:
            raise DecisionError('This voice session has no active originating T3 decision to return.')
        return row

    def result(self, event):
        row = self.db.execute('SELECT id,answer,status,ack_status,ack_note FROM decisions WHERE event_id=?', (event,)).fetchone()
        return dict(row) if row else {'status': 'not_sent'}

    async def act(self, session, action, answer=None):
        async with self.lock:
            bound = self.bound(session)
            event = bound['event_id']
            existing = self.result(event)
            if action == 'status' or existing['status'] != 'not_sent':
                return existing
            if action == 'prepare':
                if not isinstance(answer, str) or not 1 <= len(answer.strip()) <= 4000:
                    raise DecisionError('Provide a concise decision to read back.')
                if not bound['seq']:
                    raise DecisionError('Wait for Perry to state his decision first.')
                self.db.execute('UPDATE voice_bindings SET proposal=?,proposal_seq=? WHERE session_id=?',
                                (answer.strip(), bound['seq'], session))
                self.db.commit()
                return {'status': 'awaiting_confirmation', 'answer': answer.strip(),
                        'instruction': 'Read this decision back and ask: Send that to the original T3 task? Wait for a new explicit yes before send_voice_decision.'}
            if action != 'confirm':
                raise DecisionError('Unknown voice decision operation.')
            if not bound['proposal'] or bound['seq'] <= bound['proposal_seq'] or not affirmative(bound['latest_text']):
                raise DecisionError('Read back the decision and wait for a new explicit yes or send it. Nothing was sent.')
            if bound['deadline'] <= time.time():
                raise DecisionError('This decision deadline has passed. Recheck the task before acting.')
            identifier = str(uuid.uuid4())
            self.db.execute('INSERT INTO decisions(id,event_id,answer,confirmation,status,created) VALUES (?,?,?,?,?,?)',
                            (identifier, event, bound['proposal'], bound['latest_text'], 'sending', time.time()))
            self.db.commit()
            message = ('Hermes Voice owner decision\n'
                       f'Decision ID: {identifier}\nEvent ID: {event}\nQuestion: {bound["title"]}\n'
                       f'Perry confirmed this read-back by voice: {json.dumps(bound["proposal"])}\n'
                       'Use this only for the originating question. Do not widen scope or bypass a pending tool approval. '
                       'Check current task state before continuing; if the decision is stale, ambiguous or outside the existing authorization, stop and clarify. '
                       'Acknowledge receipt before proceeding, using your existing local producer credential:\n'
                       f'scripts/attention acknowledge --source t3 --decision-id {identifier} --status accepted --note "Received; applying to the original question."\n'
                       'Run that command from the Hermes Voice repository, or use the absolute publisher path from the owner-attention skill. '
                       'Use needs_clarification or declined instead of accepted when appropriate. '
                       'After acknowledgment, resume only the authorized task. Do not ask Perry the same question again unless something materially changed.')
            try:
                receipt = await self.delivery.send(bound['thread_id'], message)
                self.db.execute("UPDATE decisions SET status='delivered',receipt=? WHERE id=?", (json.dumps(receipt), identifier))
                self.db.commit()
            except BaseException:
                self.db.execute("UPDATE decisions SET status='delivery_unknown' WHERE id=?", (identifier,))
                self.db.commit()
                raise
            return self.result(event)

    def acknowledge(self, source, identifier, status, note):
        row = self.db.execute('SELECT d.*,e.source FROM decisions d JOIN events e ON e.id=d.event_id WHERE d.id=?', (identifier,)).fetchone()
        if not row or row['source'] != source:
            raise DecisionError('No decision for this producer.')
        if status not in ['accepted', 'needs_clarification', 'declined'] or not isinstance(note, str) or len(note) > 1000:
            raise DecisionError('Invalid acknowledgment.')
        if row['ack_status'] and (row['ack_status'] != status or row['ack_note'] != note):
            raise DecisionError('This decision was already acknowledged; do not replace it.')
        self.db.execute('UPDATE decisions SET ack_status=?,ack_note=? WHERE id=?', (status, note, identifier))
        self.db.commit()
        return {'acknowledged': True, 'decision_id': identifier, 'status': status}


async def voice_decision(request):
    try:
        data = await request.json()
        result = await request.app['returns'].act(data.get('session_id', ''), data.get('action'), data.get('answer'))
        return web.json_response(result)
    except DecisionError as error:
        return web.json_response({'error': str(error)}, status=409)
    except Exception:
        return web.json_response({'error': 'Decision delivery could not be confirmed. Check its status; do not resend.'}, status=502)


async def acknowledge(request):
    try:
        data = await request.json()
        return web.json_response(request.app['returns'].acknowledge(request['producer'], request.match_info['id'], data.get('status'), data.get('note', '')))
    except DecisionError as error:
        return web.json_response({'error': str(error)}, status=409)


def install(app, config):
    app['returns'] = ReturnBridge(app['attention'].store, T3Delivery(config.get('T3_CLI_PATH', '')))
    app.router.add_post('/v1/voice/decision', voice_decision)
    app.router.add_post('/v1/decisions/{id}/ack', acknowledge)
