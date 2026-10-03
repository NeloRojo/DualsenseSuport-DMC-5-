"""Read-only development client for the bridge already loaded in REFramework."""
import argparse
import json
import time
from pathlib import Path


def request(bridge, command, timeout=4, **parameters):
    bridge = Path(bridge)
    live = json.loads((bridge/'dev_live.json').read_bytes())
    if not live.get('enabled') or time.time()-live['heartbeat']>3:
        raise RuntimeError('The development bridge is not active in the game')
    seq = time.time_ns()//100000
    message = dict(parameters, session=live['session'], seq=seq, command=command)
    temporary = bridge/'dev_request.client.tmp'
    temporary.write_text(json.dumps(message), encoding='utf-8')
    temporary.replace(bridge/'dev_request.json')
    deadline = time.monotonic()+timeout
    while time.monotonic()<deadline:
        try:
            response = json.loads((bridge/'dev_response.json').read_bytes())
            if response.get('session')==live['session'] and response.get('seq')==seq:
                if not response['ok']:
                    raise RuntimeError(response.get('error', 'SDK query failed'))
                return response['result']
        except (OSError, json.JSONDecodeError):
            pass
        time.sleep(.05)
    raise TimeoutError('REFramework did not answer the development query')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--bridge', type=Path, required=True)
    parser.add_argument('command', choices=['snapshot','inspect_type','inspect_object','start_trace','stop_trace','get_trace','clear_trace','watch'])
    parser.add_argument('--type-name')
    parser.add_argument('--filter', default='')
    parser.add_argument('--path', nargs='*', default=[])
    parser.add_argument('--seconds', type=float, default=30)
    args = parser.parse_args()
    if args.command=='watch':
        deadline=time.monotonic()+args.seconds
        previous=None
        while time.monotonic()<deadline:
            live=json.loads((args.bridge/'dev_live.json').read_bytes())
            if time.time()-live['heartbeat']>3:raise RuntimeError('Game bridge heartbeat expired')
            state=live.get('state')
            if state!=previous:print(json.dumps(state,ensure_ascii=False),flush=True);previous=state
            time.sleep(.2)
    else:
        print(json.dumps(request(args.bridge,args.command,type_name=args.type_name,filter=args.filter,path=args.path,seconds=args.seconds),ensure_ascii=False,indent=2))


if __name__=='__main__':
    main()
