#!/usr/bin/env python3
"""Disposable loopback CONNECT proxy for bounded Google/Booking QA only."""
import argparse,ipaddress,json,re,select,socket,socketserver,sys,threading
ALLOW=('google.com','googleusercontent.com','gstatic.com','googleapis.com','booking.com','bstatic.com')
parser=argparse.ArgumentParser(description="Local, allowlisted WebKit site QA proxy")
parser.add_argument('--synthetic-host', required=True)
parser.add_argument('--synthetic-port', type=int, required=True)
parser.add_argument('--tunnel-port', type=int, required=True)
args=parser.parse_args()
if not re.fullmatch(r'[a-f0-9]{32}\.neantik-dns\.invalid', args.synthetic_host) or not (1 <= args.synthetic_port <= 65535 and 1 <= args.tunnel_port <= 65535):
 parser.error('invalid synthetic fixture host or ports')
SYNTHETIC=args.synthetic_host;SYNPORT=str(args.synthetic_port);TUNNEL=args.tunnel_port
counts={'synthetic':0,'google':0,'booking':0,'denied':0,'failed':0}; lock=threading.Lock()
def record(key):
 with lock: counts[key]+=1
class Handler(socketserver.BaseRequestHandler):
 def handle(self):
  client=self.request;client.settimeout(12);data=b''
  try:
   while b'\r\n\r\n' not in data and len(data)<16384:
    block=client.recv(4096)
    if not block:return
    data+=block
   header=data.split(b'\r\n\r\n',1)[0]; lines=header.split(b'\r\n')
   if any(x.lower().startswith(b'proxy-authorization:') for x in lines[1:]):record('denied');return
   method,target,_=lines[0].decode('ascii').split();host,port=target.rsplit(':',1);host=host.lower().rstrip('.')
   synthetic=host==SYNTHETIC and port==SYNPORT
   match=next((domain for domain in ALLOW if host==domain or host.endswith('.'+domain)),None)
   if method!='CONNECT' or (not synthetic and (port!='443' or match is None)):
    record('denied');client.sendall(b'HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n');return
   if synthetic:
    upstream=socket.create_connection(('127.0.0.1',TUNNEL),timeout=12);upstream.sendall(data);response=b''
    while b'\r\n\r\n' not in response and len(response)<16384:
     part=upstream.recv(4096)
     if not part:upstream.close();return
     response+=part
    client.sendall(response)
    if not response.startswith(b'HTTP/1.1 200'):upstream.close();return
    record('synthetic')
   else:
    upstream=None
    for family,typ,proto,_,addr in socket.getaddrinfo(host,443,type=socket.SOCK_STREAM):
     if not ipaddress.ip_address(addr[0]).is_global:continue
     candidate=socket.socket(family,typ,proto);candidate.settimeout(12)
     try:candidate.connect(addr);upstream=candidate;break
     except OSError:candidate.close()
    if upstream is None:record('failed');return
    client.sendall(b'HTTP/1.1 200 Connection Established\r\n\r\n');record('booking' if match in ('booking.com','bstatic.com') else 'google')
   client.settimeout(None);upstream.settimeout(None)
   with upstream:
    while True:
     ready,_,_=select.select([client,upstream],[],[],20)
     if not ready:return
     for src in ready:
      buf=src.recv(65536)
      if not buf:return
      (upstream if src is client else client).sendall(buf)
  except (OSError,ValueError,UnicodeError):record('failed')
class Server(socketserver.ThreadingTCPServer):
 allow_reuse_address=False;daemon_threads=True
with Server(('127.0.0.1',0),Handler) as server:
 threading.Thread(target=server.serve_forever,kwargs={'poll_interval':.2},daemon=True).start()
 print(json.dumps({'status':'ready','port':server.server_address[1]}),flush=True)
 for line in sys.stdin:
  try:command=json.loads(line)
  except ValueError:continue
  if command=={'action':'status'}:
   with lock:print(json.dumps({'status':'snapshot','counts':counts}),flush=True)
  elif command=={'action':'stop'}:break
 server.shutdown();print(json.dumps({'status':'stopped'}),flush=True)
