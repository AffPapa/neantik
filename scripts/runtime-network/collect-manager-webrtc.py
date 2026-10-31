#!/usr/bin/env python3
"""Live manager/relay and UDP4 socket custody for the owned WebRTC fixture."""
import argparse
import importlib.util
import os
from pathlib import Path
import re
import stat
import time
import uuid

SPEC=importlib.util.spec_from_file_location('webrtc_kernel_core',Path(__file__).with_name('collect-manager-dns.py'))
CORE=importlib.util.module_from_spec(SPEC);SPEC.loader.exec_module(CORE)
PHASES=('before-launch','proxy-success','direct-control','proxy-repeat')


def owned_state(path):
    state=CORE.load(path);root=Path(state['root']);info=root.lstat()
    CORE.require(root.parent==Path('/private/tmp') and root.name.startswith('neantik-update-audit-')
                 and str(uuid.UUID(root.name.removeprefix('neantik-update-audit-')))==root.name.removeprefix('neantik-update-audit-')
                 and stat.S_ISDIR(info.st_mode) and info.st_uid==os.getuid() and not info.st_mode&0o077,'unsafe-webrtc-root')
    CORE.require(state['data']==str(root/'manager-data') and state['manifest']==str(root/'candidate-manifest.json')
                 and state['webrtcFixture']['mode']=='manager-webrtc' and len(state['profiles'])==2
                 and [p['name'] for p in state['profiles']]==['QA route proxy','QA route direct'],'wrong-webrtc-state')
    for p in state['profiles']:CORE.require(str(uuid.UUID(p['id'])).lower()==p['id'].lower(),'invalid-profile-id')
    return state,root


def socket_peer(state,root,channel,*,direct):
    # Initial HTTP can race the manager's final running lease write. Wait on
    # the same accepted connection, never relaunch/rewrite the browser.
    deadline=time.monotonic()+3
    while True:
        try:return CORE.socket_peer(state,root,channel,direct=direct)
        except (ValueError,FileNotFoundError):
            if time.monotonic()>=deadline:raise
            time.sleep(.03)


def udp_socket_owner(output,source_port,destination_port):
    CORE.require(type(source_port) is int and type(destination_port) is int and 0<source_port<65536 and 0<destination_port<65536,'wrong-udp-ports')
    names={f'*:{source_port}',f'127.0.0.1:{source_port}',f'127.0.0.1:{source_port}->127.0.0.1:{destination_port}'}
    pid=None;found=set()
    for line in output.splitlines():
        if line.startswith('p'):
            CORE.require(line[1:].isdigit(),'invalid-udp-pid');pid=int(line[1:])
        elif line.startswith('n') and line[1:] in names:
            CORE.require(pid is not None,'udp-pid-missing');found.add(pid)
    CORE.require(len(found)==1,'ambiguous-or-missing-udp-owner');return found.pop()


def udp_peer(state,root,peer,server_port):
    CORE.require(peer[0]=='127.0.0.1','non-loopback-udp-peer')
    profile=state['profiles'][1];lock=root/'manager-data/Profiles'/profile['id']/'.neantik.lock'
    raw=CORE.read_private(lock);lease=CORE.json.loads(raw);app=Path(state['app']);manager_exe=app/'Contents/MacOS/NeAntik'
    runtime=app/'Contents/Resources/NeAntik Browser.app';browser_exe=runtime/'Contents/MacOS/NeAntik Browser'
    CORE.require(lease['phase']=='running' and lease['managerPID']==state['managerPID'] and lease.get('relay') is None,'not-owned-direct-lease')
    manager=CORE.kernel_process(state['managerPID'],manager_exe);browser=CORE.kernel_process(lease['pid'],browser_exe)
    CORE.require(browser['parentPID']==manager['pid'],'udp-browser-parent')
    listing=CORE.subprocess.run(['/usr/sbin/lsof','-nP','-iUDP:'+str(peer[1]),'-Fpn'],capture_output=True,text=True,timeout=4)
    CORE.require(listing.returncode==0,'udp-inventory-unavailable');pid=udp_socket_owner(listing.stdout,peer[1],server_port)
    chain=[];paths=[]
    for _ in range(4):
        path=CORE.process_path(pid)
        CORE.require(path==browser_exe.resolve() or (path.is_relative_to((runtime/'Contents/Frameworks').resolve())
                     and path.name.startswith('NeAntik Browser Helper')),'udp-not-owned-browser-code')
        item=CORE.kernel_process(pid,path);chain.append(item);paths.append(path)
        if item==browser:break
        pid=item['parentPID']
    CORE.require(chain[-1]==browser and CORE.read_private(lock)==raw and CORE.kernel_process(manager['pid'],manager_exe)==manager
                 and CORE.kernel_process(browser['pid'],browser_exe)==browser,'udp-generation-changed')
    CORE.require(all(CORE.kernel_process(item['pid'],path)==item for item,path in zip(chain,paths)),'udp-helper-generation-changed')
    return dict(manager=manager,browser=browser,peerChain=chain,profileID=profile['id'].lower(),sessionGeneration=lease['ownerToken'].lower(),
                socketTupleSHA256=CORE.sha(f'127.0.0.1:{peer[1]}->127.0.0.1:{server_port}'.encode()),
                attribution='live UDP source port and signed helper chain; wildcard binding admitted only for exact observed source port')


def capture(state,root,phase):
    CORE.require(phase in PHASES,'wrong-webrtc-phase');value=CORE.capture(state,root,phase,manager_webrtc=True)
    value['webrtcCollectorSHA256']=CORE.sha(Path(__file__).read_bytes())
    if phase=='before-launch':
        prefs=root/'manager-data/Profiles'/state['profiles'][0]['id']/'BrowserData/Default/Preferences'
        value['attemptedUserPreferences']=CORE.load(prefs);value['attemptedUserPreferencesSHA256']=CORE.sha(CORE.read_private(prefs))
    else:
        expected='default_public_interface_only' if phase=='direct-control' else 'disable_non_proxied_udp'
        args=CORE.argv_for(value['browser']['pid']);CORE.flag(args,'--webrtc-ip-handling-policy',expected)
        CORE.require(not any(arg.lstrip('-').startswith('force-webrtc-ip-handling-policy') for arg in args),'ambiguous-webrtc-policy')
        value['observedWebRTCPolicy']=expected
        manifest=CORE.load(root/'candidate-manifest.json');app=Path(state['app'])
        for key in ['runtimeExecutable','runtimeFramework']:
            record=manifest['criticalFiles'][key];actual=CORE.sha((app/record['bundlePath']).read_bytes())
            CORE.require(actual==record['sha256'],'runtime-changed');value[key+'SHA256']=actual
    return value


def cleanup(state,root,receipts):
    samples=[CORE.load(receipts/('webrtc-custody-'+phase+'.json')) for phase in PHASES]
    pids={p['pid'] for sample in samples for key in ('manager','browser','relayOwner') if (p:=sample.get(key))}
    inventory=CORE.subprocess.check_output(['/bin/ps','-axo','pid=,uid=,command='],text=True,timeout=5);remaining=0
    for line in inventory.splitlines():
        parts=line.strip().split(None,2)
        if len(parts)!=3:continue
        pid,uid,command=parts
        if int(pid) in pids or (int(uid)==os.getuid() and (str(root) in command or str(root).replace('/private/tmp/','/tmp/') in command)):remaining+=1
    exits=[]
    manifest=CORE.load(root/'candidate-manifest.json')
    CORE.require(CORE.sha(CORE.read_private(root/'candidate-manifest.json'))==state['candidateManifestSHA256'],'manifest-changed')
    runtime_info=Path(state['app'])/'Contents/Resources/NeAntik Browser.app/Contents/Info.plist'
    import plistlib
    runtime_bytes=runtime_info.read_bytes()
    CORE.require(CORE.sha(runtime_bytes)==manifest['criticalFiles']['runtimeInfoPlist']['sha256'],'runtime-info-changed')
    runtime_version=plistlib.loads(runtime_bytes)['CFBundleShortVersionString']
    for profile in state['profiles']:
        name=str(uuid.UUID(profile['id'])).upper()+'.manager.log'
        raw=CORE.read_private(root/'manager-data/Logs'/name,65536)
        exits.append(dict(profileID=profile['id'].lower(),logSHA256=CORE.sha(raw),**exit_observation(raw.decode('utf-8'),runtime_version)))
    return dict(schemaVersion=1,at=time.monotonic(),ownedProcessesRemaining=remaining,browserExitObservations=exits,
                collectorSHA256=CORE.sha(Path(__file__).read_bytes()),ordinaryInstanceTouched=False,gracefulCloseQualified=False)


def exit_observation(text,version):
    # Fresh owned log, one browser launch per profile. The signed manager
    # records Process.terminationReason/status from its actual child handler.
    launches=re.findall(r'^\S+ browser_launch version=([^\r\n]+)$',text,re.M)
    exits=re.findall(r'^\S+ browser_exit reason=([0-9]+) status=(-?[0-9]+)$',text,re.M)
    CORE.require(launches==[version] and len(exits)==1,'browser-exit-record-missing-or-ambiguous')
    return dict(launchCount=1,terminationReason=int(exits[0][0]),terminationStatus=int(exits[0][1]),
                source='signed manager child termination handler; no claim about all renderer exit statuses')


def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--state',type=Path,required=True)
    parser.add_argument('--phase',choices=(*PHASES,'cleanup'),required=True);args=parser.parse_args()
    try:
        state,root=owned_state(args.state);receipts=CORE.receipt_directory(args.state)
        value=cleanup(state,root,receipts) if args.phase=='cleanup' else capture(state,root,args.phase)
        CORE.write_new(receipts/('webrtc-custody-'+args.phase+'.json'),value)
    except (KeyError,TypeError,ValueError,OSError,CORE.subprocess.SubprocessError):parser.exit(1,'Owned WebRTC custody refused.\n')
    print('{"result":"captured","browserQualification":false}')


if __name__=='__main__':main()
