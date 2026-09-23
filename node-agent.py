#!/usr/bin/env python3
"""RGNODES™ Remote LXD Node Agent v2.1.

Stdlib-only authenticated API for the RGNODES™ Discord bot.
GET  /health
GET  /api/ping
GET  /api/get_host_stats
POST /api/get_container_stats  {"container":"name"}
POST /api/execute               {"command":"lxc ..."}

Authentication is X-API-Key or Authorization: Bearer <key> only.
No shell is invoked. /api/execute accepts only an lxc command.
TLS is optional and can be enabled with --certfile and --keyfile.
"""
from __future__ import annotations

import argparse
import hmac
import json
import os
import re
import shlex
import shutil
import socket
import ssl
import subprocess
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

MAX_BODY = 128 * 1024
MAX_OUTPUT = 100_000
COMMAND_TIMEOUT = 900
STATS_TIMEOUT = 12


def lxc_bin() -> str:
    path = shutil.which('lxc') or '/snap/bin/lxc'
    if not os.path.exists(path):
        raise FileNotFoundError('lxc executable is unavailable')
    return path


def run_lxc(args: list[str], timeout: float = COMMAND_TIMEOUT):
    proc = subprocess.run(
        [lxc_bin(), *args], stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        text=True, timeout=timeout, check=False,
    )
    return proc.returncode, proc.stdout, proc.stderr


def read_cpu() -> float:
    def snap():
        with open('/proc/stat', 'r', encoding='utf-8') as f:
            for line in f:
                if line.startswith('cpu '):
                    vals = [int(x) for x in line.split()[1:]]
                    return sum(vals), vals[3] + (vals[4] if len(vals) > 4 else 0)
        return 0, 0
    try:
        a_total, a_idle = snap()
        time.sleep(0.15)
        b_total, b_idle = snap()
        total = b_total - a_total
        idle = b_idle - a_idle
        return round(max(0.0, min(100.0, (total-idle)*100.0/total)), 1) if total > 0 else 0.0
    except Exception:
        return 0.0


def read_ram():
    total = available = 0
    try:
        with open('/proc/meminfo', 'r', encoding='utf-8') as f:
            for line in f:
                p = line.split()
                if len(p) >= 2 and p[0] == 'MemTotal:': total = int(p[1]) * 1024
                elif len(p) >= 2 and p[0] == 'MemAvailable:': available = int(p[1]) * 1024
    except Exception:
        return {'used': 0, 'total': 0, 'percent': 0.0}
    used = max(0, total-available)
    return {'used': used, 'total': total, 'percent': round(used/total*100.0, 1) if total else 0.0}


def host_stats():
    disk = shutil.disk_usage('/')
    ram = read_ram()
    uptime = 0.0
    try: uptime = float(Path('/proc/uptime').read_text(encoding='utf-8').split()[0])
    except Exception: pass
    return {'cpu': read_cpu(), 'ram': ram['percent'],
            'ram_bytes_used': ram['used'], 'ram_bytes_total': ram['total'],
            'disk': {'used': disk.used, 'total': disk.total, 'free': disk.free,
                     'percent': round(disk.used/disk.total*100.0,1) if disk.total else 0.0},
            'uptime': uptime, 'hostname': socket.gethostname()}


def valid_container_name(name: str) -> bool:
    return bool(re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]{0,62}', name))


def container_stats(container: str):
    if not valid_container_name(container): raise ValueError('invalid container name')
    code, info, err = run_lxc(['info', container], timeout=6)
    if code != 0: raise RuntimeError(err.strip() or info.strip() or 'container info failed')
    status = next((line.split(': ',1)[1].strip().lower() for line in info.splitlines() if line.startswith('Status: ')), 'unknown')
    result={'status':status,'cpu':0.0,'ram':{'used':0,'total':0,'pct':0.0},'disk':'Unknown','uptime':'Unknown'}
    if status != 'running': return result
    try:
        code,out,_=run_lxc(['exec',container,'--','top','-bn1'],timeout=STATS_TIMEOUT)
        if code==0:
            for line in out.splitlines():
                if '%Cpu(s):' not in line: continue
                vals=[]
                for item in line.split('%Cpu(s):',1)[1].split(','):
                    try: vals.append(float(item.split()[0]))
                    except (ValueError,IndexError): vals.append(0.0)
                if len(vals)>=8:
                    result['cpu']=max(0.0,min(100.0,sum(vals[i] for i in (0,1,2,4,5,6,7)))); break
    except Exception: pass
    try:
        code,out,_=run_lxc(['exec',container,'--','free','-m'],timeout=STATS_TIMEOUT)
        if code==0:
            for line in out.splitlines():
                if line.lstrip().startswith('Mem:'):
                    p=line.split()
                    if len(p)>=3:
                        total,used=int(p[1]),int(p[2]); result['ram']={'used':used,'total':total,'pct':round(used/total*100.0,1) if total else 0.0}; break
    except Exception: pass
    try:
        code,out,_=run_lxc(['exec',container,'--','df','-h','/'],timeout=STATS_TIMEOUT)
        if code==0:
            for line in out.splitlines():
                p=line.split()
                if len(p)>=5 and p[-1]=='/': result['disk']=f'{p[2]}/{p[1]} ({p[4]})'; break
    except Exception: pass
    try:
        code,out,_=run_lxc(['exec',container,'--','uptime'],timeout=STATS_TIMEOUT)
        if code==0 and out.strip(): result['uptime']=out.strip()
    except Exception: pass
    return result


def api_key_from_request(handler: BaseHTTPRequestHandler) -> str:
    value=handler.headers.get('X-API-Key','').strip()
    if not value:
        auth=handler.headers.get('Authorization','')
        if auth.lower().startswith('bearer '): value=auth[7:].strip()
    return value


class Handler(BaseHTTPRequestHandler):
    server_version='RGNODES-NodeAgent/2.1'
    def log_message(self,fmt,*args): print(f'[{self.address_string()}] {fmt % args}',flush=True)
    def send_json(self,status,payload):
        data=json.dumps(payload,ensure_ascii=False).encode('utf-8')
        self.send_response(status); self.send_header('Content-Type','application/json; charset=utf-8')
        self.send_header('Content-Length',str(len(data))); self.send_header('Cache-Control','no-store'); self.end_headers(); self.wfile.write(data)
    def authorized(self):
        expected=getattr(self.server,'api_key',''); supplied=api_key_from_request(self)
        return bool(expected) and hmac.compare_digest(supplied,expected)
    def read_json(self):
        length=int(self.headers.get('Content-Length','0'))
        if length<=0 or length>MAX_BODY: raise ValueError('invalid content length')
        return json.loads(self.rfile.read(length).decode('utf-8'))
    def do_GET(self):
        path=self.path.split('?',1)[0].rstrip('/')
        if path=='/health': self.send_json(200,{'status':'ok','service':'rgnodes-node-agent'}); return
        if not self.authorized(): self.send_json(401,{'error':'unauthorized'}); return
        if path=='/api/ping': self.send_json(200,{'status':'ok','service':'rgnodes-node-agent','hostname':socket.gethostname()}); return
        if path=='/api/get_host_stats': self.send_json(200,host_stats()); return
        self.send_json(404,{'error':'not_found'})
    def do_POST(self):
        path=self.path.split('?',1)[0].rstrip('/')
        if not self.authorized(): self.send_json(401,{'error':'unauthorized'}); return
        try:
            payload=self.read_json()
            if path=='/api/get_container_stats':
                self.send_json(200,container_stats(str(payload.get('container','')).strip())); return
            if path!='/api/execute': self.send_json(404,{'error':'not_found'}); return
            command=str(payload.get('command','')).strip()
            if not command or len(command)>12000: raise ValueError('valid command is required')
            argv=shlex.split(command)
            if not argv or argv[0]!='lxc': self.send_json(400,{'error':'only lxc commands are accepted'}); return
            proc=subprocess.run([lxc_bin(),*argv[1:]],stdin=subprocess.DEVNULL,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,timeout=COMMAND_TIMEOUT,check=False)
            self.send_json(200,{'returncode':proc.returncode,'stdout':proc.stdout[-MAX_OUTPUT:],'stderr':proc.stderr[-MAX_OUTPUT:]})
        except subprocess.TimeoutExpired: self.send_json(408,{'error':'command timed out'})
        except (ValueError,json.JSONDecodeError) as exc: self.send_json(400,{'error':str(exc)})
        except FileNotFoundError as exc: self.send_json(503,{'error':str(exc)})
        except Exception as exc: self.send_json(500,{'error':str(exc)})


def main():
    parser=argparse.ArgumentParser(description='RGNODES™ LXD remote node agent')
    parser.add_argument('--host',default=os.getenv('RGNODES_AGENT_HOST','0.0.0.0'))
    parser.add_argument('--port',type=int,default=int(os.getenv('RGNODES_AGENT_PORT','18443')))
    parser.add_argument('--api_key',default=os.getenv('RGNODES_NODE_API_KEY',''))
    parser.add_argument('--certfile',default=os.getenv('RGNODES_AGENT_CERT',''))
    parser.add_argument('--keyfile',default=os.getenv('RGNODES_AGENT_KEY',''))
    args=parser.parse_args()
    if not args.api_key or len(args.api_key)<48: raise SystemExit('A strong --api_key (48+ characters) is required.')
    if not 1<=args.port<=65535: raise SystemExit('Port must be 1-65535.')
    if bool(args.certfile) != bool(args.keyfile): raise SystemExit('Both --certfile and --keyfile are required for TLS.')
    server=ThreadingHTTPServer((args.host,args.port),Handler); server.daemon_threads=True; server.api_key=args.api_key
    if args.certfile and args.keyfile:
        context=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); context.load_cert_chain(args.certfile,args.keyfile)
        server.socket=context.wrap_socket(server.socket,server_side=True)
        proto='https'
    else: proto='http'
    print(f'RGNODES™ node agent listening on {proto}://{args.host}:{args.port}',flush=True)
    try: server.serve_forever(poll_interval=0.5)
    except KeyboardInterrupt: pass
    finally: server.server_close()

if __name__=='__main__': main()
