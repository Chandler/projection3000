#!/usr/bin/env python3
"""Small client for Patch's loopback API. No third-party dependencies."""
import argparse,json,os,pathlib,sys,urllib.request,urllib.error
parser=argparse.ArgumentParser(description='Control the running Patch app')
parser.add_argument('command',choices=['state','schema','catalog','send','health','install','stage','job','commit','refresh'])
parser.add_argument('value',nargs='?',help='JSON for send/stage, shader path for install, job ID for job/commit')
parser.add_argument('--port',type=int,default=int(os.environ.get('PATCH_API_PORT','9417')))
parser.add_argument('--kind',default='shaderEffect',help='Installed shader kind')
parser.add_argument('--name',help='Installed effect name')
parser.add_argument('--expected-revision',help='Graph revision read from state')
parser.add_argument('--allow-live-changes',action='store_true',help='Explicitly authorize an edit to an active output branch; requires --expected-revision')
args=parser.parse_args()
headers={'Content-Type':'application/json'}
if args.command!='health':headers['Authorization']='Bearer '+(pathlib.Path.home()/'Library/Application Support/Patch/api-token').read_text().strip()
body=None
if args.command in ['send','stage']:
    body=json.loads(args.value or sys.stdin.read());path='/v1/commands' if args.command=='send' else '/v1/branches'
elif args.command=='install':
    if not args.value:parser.error('install requires a Metal source path')
    source=pathlib.Path(args.value);body=dict(name=args.name or source.stem,kind=args.kind,source=source.read_text());path='/v1/effects'
elif args.command in ['job','commit']:
    if not args.value:parser.error('job/commit requires a job ID')
    path='/v1/jobs/'+args.value if args.command=='job' else '/v1/branches/'+args.value+'/commit'
    if args.command=='commit':body={}
elif args.command=='refresh':path='/v1/commands';body={'op':'library_refresh'}
else:path={'state':'/v1/state','schema':'/v1/schema','catalog':'/v1/catalog','health':'/health'}[args.command]
if args.allow_live_changes and not args.expected_revision:parser.error('--allow-live-changes requires --expected-revision')
if body is not None and (args.expected_revision or args.allow_live_changes):
    if isinstance(body,list):body={'commands':body}
    if args.expected_revision:body['expectedRevision']=args.expected_revision
    if args.allow_live_changes:body['allowLiveChanges']=True
try:
    req=urllib.request.Request(f'http://127.0.0.1:{args.port}{path}',data=None if body is None else json.dumps(body).encode(),headers=headers)
    with urllib.request.urlopen(req,timeout=10) as response:print(json.dumps(json.load(response),indent=2))
except urllib.error.HTTPError as error:print(error.read().decode(),file=sys.stderr);sys.exit(1)
except urllib.error.URLError as error:print(f'Cannot reach Patch on port {args.port}: {error.reason}',file=sys.stderr);sys.exit(1)
