"""Owned normal-page WebRTC integration; real manager/relay, no CDP flags.

UDP counters are independent of the page's completion receipt. Peer custody
binds HTTP page/receipt sockets to the live relay or Direct browser generation.
This is loopback UDP4 evidence, not arbitrary interface or OS policy coverage.
"""
import importlib.util
import json
from pathlib import Path
import socket
import struct
import threading
import uuid
from urllib.parse import parse_qs, urlsplit

SPEC=importlib.util.spec_from_file_location('webrtc_route_base',Path(__file__).with_name('manager-route-fixture.py'))
BASE=importlib.util.module_from_spec(SPEC);SPEC.loader.exec_module(BASE)
PHASES=('proxy-success','direct-control','proxy-repeat')
PROBE=Path(__file__).with_name('manager-webrtc-probe.js')
DIAGNOSTIC_STAGES=frozenset(('request-header','request-line','client-authentication','destination-parse',
    'destination-scope','peer-custody','owned-request-validation','fault-injection','upstream-connect',
    'connect-response','tunnel-header','target-parse','nonce-validation','forward-request','relay-copy',
    'origin-scope','receipt-validation','page-control','response-write','unknown'))
DIAGNOSTIC_CATEGORIES=frozenset(('not-read','malformed','favicon','owned-route','owned-stream','https-callback','other'))
DIAGNOSTIC_FAILURES=frozenset(('timeout','io','incomplete-header','protocol'))


def request_category(target):
    """Only fixed categories leave memory; never serialize path/query values."""
    if target is None:return 'not-read'
    if not isinstance(target,str) or len(target)>16384:return 'malformed'
    try:path=urlsplit(target).path
    except (ValueError,UnicodeError):return 'malformed'
    return {'/favicon.ico':'favicon','/owned-route':'owned-route','/owned-stream':'owned-stream',
            '/__neantik_route/ack':'https-callback'}.get(path,'other')


def failure_category(error):
    if isinstance(error,socket.timeout):return 'timeout'
    if isinstance(error,OSError):return 'io'
    if isinstance(error,ValueError) and error.args==('incomplete-header',):return 'incomplete-header'
    return 'protocol'


def require(value):
    if not value:raise ValueError('owned-webrtc-input')


def binding_response(packet,port):
    require(20<=len(packet)<=4096 and struct.unpack_from('!HHI',packet)==(1,len(packet)-20,0x2112a442)
            and (len(packet)-20)%4==0 and 0<port<65536)
    return struct.pack('!HHI',0x101,12,0x2112a442)+packet[8:20]+struct.pack('!HHBBHI',0x20,8,0,1,port^0x2112,0x7f000001^0x2112a442)


class OwnedSTUN:
    def __init__(self,on_request=None):
        self.socket=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);self.socket.bind(('127.0.0.1',0));self.socket.settimeout(.15)
        self.port=self.socket.getsockname()[1];self.lock=threading.Lock();self.stopping=threading.Event()
        self.token=uuid.uuid4().bytes[:12];self.control=0;self.requests=0;self.invalid=0;self.measuring=False;self.closed=False
        self.on_request=on_request
        self.thread=threading.Thread(target=self.receive,daemon=True);self.thread.start()

    def receive(self):
        while not self.stopping.is_set():
            try:packet,peer=self.socket.recvfrom(4097)
            except socket.timeout:continue
            except OSError:break
            try:
                require(peer[0]=='127.0.0.1');reply=binding_response(packet,peer[1])
                canary=packet[8:20]==self.token
                with self.lock:
                    if canary:self.control+=1
                    else:require(self.measuring);self.requests+=1
                if not canary and self.on_request:self.on_request(peer,self.port)
                self.socket.sendto(reply,peer)
            except Exception:
                # An attribution error fails the case, never kills its observer
                # thread or turns an already counted packet into a zero.
                with self.lock:self.invalid+=1

    def canary(self):
        with self.lock:require(not self.measuring and self.control==self.requests==self.invalid==0)
        with socket.socket(socket.AF_INET,socket.SOCK_DGRAM) as client:
            client.settimeout(1.5);client.sendto(struct.pack('!HHI',1,0,0x2112a442)+self.token,('127.0.0.1',self.port));reply,peer=client.recvfrom(128)
            require(peer==('127.0.0.1',self.port) and len(reply)==32 and reply[8:20]==self.token
                    and struct.unpack_from('!H',reply,26)[0]^0x2112==client.getsockname()[1])
        with self.lock:
            require(self.control==1 and self.requests==self.invalid==0);self.measuring=True
        return dict(canaryAcknowledged=True,canaryCount=1,resetVerified=True,countAfterReset=0)

    def close(self):
        if not self.closed:
            self.stopping.set();self.socket.close();self.thread.join(2);self.closed=True
        with self.lock:return dict(browserRequests=self.requests,invalidRequests=self.invalid,canaryCount=self.control,
                                   closed=self.closed,threadDrained=not self.thread.is_alive())


def validate_probe(value,nonce):
    require(isinstance(value,dict) and set(value)=={'nonce','gatheringComplete','iceGatheringState','timedOut','candidates','errorCodes','rawICEExported'})
    require(value['nonce']==nonce and type(value['gatheringComplete']) is bool and type(value['timedOut']) is bool
            and value['iceGatheringState'] in ('new','gathering','complete') and value['rawICEExported'] is False)
    require(isinstance(value['candidates'],dict) and set(value['candidates'])=={'host','srflx','prflx','relay','other'}
            and all(type(x) is int and 0<=x<=1024 for x in value['candidates'].values()))
    require(isinstance(value['errorCodes'],list) and len(value['errorCodes'])<=16
            and all(type(x) is int and 0<=x<=65535 for x in value['errorCodes']))
    return {k:v for k,v in value.items() if k!='nonce'}


class ManagerWebRTCFixture(BASE.Fixture):
    def __init__(self,root):
        self.peer_inspector=None;self.udp_inspector=None;self.control_lock=threading.RLock();self.started=set();self.completed=set();self.stun={}
        super().__init__(root);self.nonces={phase:uuid.uuid4().hex for phase in PHASES}
        try:
            for phase in PHASES:self.stun[phase]=OwnedSTUN(lambda peer,port,p=phase:self.observe_udp(p,peer,port))
        except BaseException:
            self.close();raise

    def navigation_phases(self):return PHASES

    def failure_diagnostic(self,stage,target,channel,error,*,incoming):
        # Bind only the fixture's own loopback origin TCP tuple. The per-run
        # private salt prevents exported IDs from revealing ephemeral ports.
        # This is fixture correlation, not browser PID or route attestation.
        correlation=None
        if channel is not None:
            try:
                local,peer=channel.getsockname(),channel.getpeername()
                origin=local if incoming else peer;source=peer if incoming else local
                if (origin==self.origin.server_address and len(source)==2 and source[0]=='127.0.0.1'
                        and type(source[1]) is int and 0<source[1]<65536):
                    material=b'owned-origin-v1\0'+bytes.fromhex(self.hop)+struct.pack('!HH',source[1],origin[1])
                    correlation=BASE.hashlib.sha256(material).hexdigest()
            except (OSError,ValueError,AttributeError):pass
        return dict(diagnosticVersion=1,stage=stage if isinstance(stage,str) and stage in DIAGNOSTIC_STAGES else 'unknown',
                    requestCategory=request_category(target),failureCategory=failure_category(error),
                    originConnectionSHA256=correlation)

    def proxy_failure_diagnostic(self,stage,target,upstream,error):
        return self.failure_diagnostic(stage,target,upstream,error,incoming=False)

    def phase(self,target):
        if len(target)>8192:return None
        parsed=urlsplit(target);query=parse_qs(parsed.query,keep_blank_values=True)
        if parsed.path!='/owned-route' or set(query) not in ({'phase','nonce'},{'phase','nonce','result'}) or any(len(v)!=1 for v in query.values()):return None
        phase=query['phase'][0]
        return phase if phase in self.nonces and query['nonce'][0]==self.nonces[phase] else None

    def prepare_profiles(self,data,profiles):
        # Owned fresh BrowserData only; never change a running profile or identity.
        profile=profiles[0];require(str(uuid.UUID(profile['id'])).lower()==profile['id'].lower())
        default=data/'Profiles'/profile['id']/'BrowserData'/'Default'
        current=data
        for name in ('Profiles',profile['id'],'BrowserData','Default'):
            current=current/name
            if not current.exists():current.mkdir(mode=0o700)
            require(current.is_dir() and not current.is_symlink())
        values={'webrtc':{'ip_handling_policy':'default','ip_handling_url':[{'url':'http://127.0.0.1:*','handling':'default'}],
                          'local_ips_allowed_urls':['http://127.0.0.1:*']}}
        BASE.private_json(default/'Preferences',values)
        self.ledger.record('webrtc-permissive-user-prefs',profileID=profile['id'].lower(),preferences=values,
                           preferencesSHA256=BASE.digest(default/'Preferences'))

    def begin_owned_request(self,host,port):return {'requestID':uuid.uuid4().hex}

    def observe_proxy_peer(self,context,client):
        require(self.peer_inspector is not None)
        context['peer']=self.peer_inspector(client,False)

    def validate_owned_request(self,context,target):
        phase=self.phase(target);require(phase is not None and phase!='direct-control' and 'peer' in context)
        self.ledger.record('webrtc-upstream-peer',phase=phase,isReceipt='result' in parse_qs(urlsplit(target).query),
                           requestIDSHA256=BASE.hashlib.sha256(context['requestID'].encode()).hexdigest(),**context['peer'])

    def owned_request_headers(self,context):
        return b'X-NeAntik-Owned-WebRTC-Request: '+context['requestID'].encode()+b'\r\n'

    def observe_udp(self,phase,peer,port):
        if phase!='direct-control':
            self.ledger.record('webrtc-protected-udp',phase=phase);return
        require(self.udp_inspector is not None)
        self.ledger.record('webrtc-udp-peer',phase=phase,**self.udp_inspector(peer,port))

    def origin_request(self,channel):
        self.track(channel);channel.settimeout(10)
        stage,target='request-header',None
        try:
            request=BASE.header(channel);pieces=request.split(b'\r\n',1)[0].split()
            stage='request-line'
            require(len(pieces)==3 and pieces[0]==b'GET');target=pieces[1].decode('ascii');phase=self.phase(target)
            if phase is None:BASE.answer(channel,b'404 Not Found',b'');return
            stage='origin-scope'
            query=parse_qs(urlsplit(target).query);protected=b'X-NeAntik-Owned-Hop: '+self.hop.encode() in request.split(b'\r\n')
            require(protected==(phase!='direct-control') and self.peer_inspector is not None)
            peer=self.peer_inspector(channel,not protected) if not protected else None
            if protected:
                # The origin socket belongs to this owned fixture; relay custody
                # was measured at its live upstream-facing socket above.
                ids=[line.split(b': ',1)[1] for line in request.split(b'\r\n') if line.startswith(b'X-NeAntik-Owned-WebRTC-Request: ')]
                require(len(ids)==1 and len(ids[0])==32 and all(c in b'0123456789abcdef' for c in ids[0]))
                peer=dict(throughOwnedFixture=True,requestIDSHA256=BASE.hashlib.sha256(ids[0]).hexdigest())
            if 'result' in query:
                stage='receipt-validation'
                value=validate_probe(json.loads(query['result'][0]),self.nonces[phase])
                with self.control_lock:
                    require(phase in self.started and phase not in self.completed);self.completed.add(phase)
                self.ledger.record('webrtc-probe',phase=phase,throughOwnedUpstream=protected,probe=value,peer=peer)
                stage='response-write'
                BASE.answer(channel,b'200 OK',b'owned completion accepted');return
            stage='page-control'
            with self.control_lock:
                require(phase not in self.started);control=self.stun[phase].canary();self.started.add(phase)
            self.ledger.record('webrtc-stun-control',phase=phase,**control)
            self.ledger.record('webrtc-page',phase=phase,throughOwnedUpstream=protected,peer=peer)
            config=dict(nonce=self.nonces[phase],stunURL='stun:127.0.0.1:'+str(self.stun[phase].port))
            links=''.join('<p><a href="'+self.url(p)+'">'+p+'</a></p>' for p in PHASES)
            body='<!doctype html><title>OWN MANAGER WEBRTC '+phase+'</title><body data-own-fixture="'+self.nonces[phase]+'"><h1>Owned manager WebRTC</h1><p id="result">WebRTC running</p>'+links+'<script>globalThis.OWN_WEBRTC_CONFIG='+json.dumps(config)+';</script><script>'+PROBE.read_text()+'</script></body>'
            stage='response-write'
            BASE.answer(channel,b'200 OK',body.encode())
        except (OSError,ValueError,UnicodeError,KeyError) as error:
            try:diagnostic=self.failure_diagnostic(stage,target,channel,error,incoming=True)
            except (OSError,ValueError,TypeError,AttributeError):diagnostic={}
            self.ledger.record('webrtc-origin-refused',**(diagnostic if isinstance(diagnostic,dict) else {}))
            try:BASE.answer(channel,b'400 Bad Request',b'owned fixture refused')
            except OSError:pass
        finally:self.untrack(channel)

    def description(self):
        return dict(schemaVersion=1,mode='manager-webrtc',urls={phase:self.url(phase) for phase in PHASES},
                    scope='Normal page, owned loopback UDP4, HTTP-auth upstream via manager SOCKS5 relay; no CDP')

    def close(self):
        drained=super().close()
        for phase,server in self.stun.items():
            value=server.close();self.ledger.record('webrtc-stun-final',phase=phase,**value);drained=drained and value['threadDrained']
        return drained
