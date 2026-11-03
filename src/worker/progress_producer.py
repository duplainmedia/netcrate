# REVIEW EXPORT: fictional deployment constants; see docs/CONFIGURATION.md.
"""Local metadata producer; contains no repository or transport credential loader."""
import argparse
import ctypes
import hashlib
import json
import os
import re
import time
import uuid
from pathlib import Path
from office_media_progress import atomic_json, make_status, public_lock

def load(path): return json.loads(Path(path).read_text(encoding='utf-8-sig'))

def process_alive(pid,started):
    # Bind PID to creation time, so a recycled process ID cannot renew heartbeats.
    kernel=ctypes.WinDLL('kernel32',use_last_error=True)
    kernel.OpenProcess.restype=ctypes.c_void_p
    kernel.GetProcessTimes.argtypes=[ctypes.c_void_p]+[ctypes.c_void_p]*4
    kernel.CloseHandle.argtypes=[ctypes.c_void_p]
    handle=kernel.OpenProcess(0x1000,False,int(pid))
    if not handle:return False
    try:
        times=[ctypes.c_ulonglong() for _ in range(4)]
        if not kernel.GetProcessTimes(handle,*[ctypes.byref(t) for t in times]):return False
        return abs(times[0].value/10_000_000-11644473600-float(started))<1
    finally:kernel.CloseHandle(handle)

class Producer:
    def __init__(self,root,alive=process_alive):self.root=Path(root);self.alive=alive
    def sync_public(self,value):
        request_id=value['RequestId']
        path=self.root/'ProgressPublish'/request_id/'progress.json'
        try:
            with public_lock(self.root/'ProgressState/PublicLocks'/f'{request_id}.lock'):
                old=load(path) if path.exists() else None
                if old!=value:atomic_json(path,value,staging=self.root/'ProgressState/Staging')
        except PermissionError:pass
    def emit(self,request,meta,state,cursor,now,transition):
        previous=state.get('Status') if state else None
        value=make_status(request,meta,previous,now=now)
        request_id=value['RequestId']
        if transition:
            pending=self.root/'ProgressState/Pending'/request_id/f"{value['AttemptId']}-{value['Sequence']:020d}.json"
            atomic_json(pending,value)
        state={'Status':value,'EventCursor':cursor}
        atomic_json(self.root/'ProgressState/Latest'/f'{request_id}.json',state)
        self.sync_public(value)
        return state
    def tick(self,now=None):
        now=time.time() if now is None else now
        errors=0; written=0
        for receipt_path in (self.root/'AutoState/Requests').glob('*.json'):
            try:
                if not re.fullmatch('[a-f0-9]{64}',receipt_path.stem):continue
                receipt=load(receipt_path)
                if receipt.get('State') not in ('Accepted','Deduplicated'):continue
                request=load(self.root/'AutoState/Incoming'/receipt_path.stem/'request.json')
                if request.get('ValidationOrigin'):continue # Old office-loopback fixture is not a source request.
                if request.get('Version')!=1 or request.get('Kind')!='request' or request.get('SourceComputer')!='SOURCE-PC' or request.get('BackupExitCode')!=0 or request.get('Repository')!='rest:https://backup.example:8000/sample-user/source-pc/':raise ValueError('Invalid request.')
                job_id=receipt['JobId']
                if not re.fullmatch('[a-z0-9][a-z0-9._-]{0,100}',job_id):raise ValueError('Invalid job.')
                job=load(self.root/'Queue'/f'{job_id}.json')
                if job['JobId']!=job_id:raise ValueError('Job binding mismatch.')
                # Only worker-created attempt contexts are public; the worker also
                # creates Queued contexts for waiting jobs before processing starts.
                context=load(self.root/'ProgressState/Jobs'/f'{job_id}.json')
                meta=dict(context)
                telemetry=self.root/'ProgressState/Jobs'/f'{job_id}.telemetry.json'
                if telemetry.exists():
                    measured=load(telemetry)
                    if measured['AttemptId']==context['AttemptId'] and measured['UpdatedEpoch']>=context['UpdatedEpoch']:meta.update(measured)
                if meta['Stage']=='Complete':
                    complete=load(Path(job['OutputPath'])/'COMPLETE.json')
                    if job.get('State')!='Published' or not re.fullmatch('[a-f0-9]{64}',job.get('ResultSnapshot','')) or complete.get('verified') is not True or complete['snapshot_id']!=job['SnapshotId'] or complete['clips']!=complete['proxy_files'] or complete['clips']!=complete['contact_sheets']:raise ValueError('Publication not confirmed.')
                    meta.update(TotalClips=complete['clips'],CompletedClips=complete['clips'],ProxyFilesCompleted=complete['clips'],ContactSheetsCompleted=complete['clips'])
                elif meta['Stage'] not in ('Failed','Queued') and not self.alive(context['OwnerPid'],context['OwnerStartedEpoch']):
                    meta.update(Stage='Failed',EtaSeconds=None)
                request_id=hashlib.sha256((request['SnapshotId']+'|'+request['ProjectPath']).encode()).hexdigest()
                state_path=self.root/'ProgressState/Latest'/f'{request_id}.json'
                state=load(state_path) if state_path.exists() else None
                cursor=state.get('EventCursor','') if state else ''
                # Persist short phase transitions in order, even when several
                # occurred between local producer/publisher polling intervals.
                for event_path in sorted((self.root/'ProgressState/Events'/job_id).glob('*.json')):
                    if event_path.name<=cursor:continue
                    event=load(event_path)
                    if event.get('AttemptId')!=context['AttemptId']:continue
                    state=self.emit(request,event,state,event_path.name,float(event.get('UpdatedEpoch',now)),True)
                    cursor=event_path.name
                previous=state.get('Status') if state else None
                if previous and previous['AttemptId']==meta['AttemptId'] and previous['Stage']==meta['Stage']:
                    if meta['Stage'] in ('Complete','Failed'):
                        self.sync_public(previous)
                        continue
                    from datetime import datetime
                    if now-datetime.fromisoformat(previous['UpdatedUtc'].replace('Z','+00:00')).timestamp()<10:
                        self.sync_public(previous)
                        continue
                transition=not previous or previous['AttemptId']!=meta['AttemptId'] or previous['Stage']!=meta['Stage']
                self.emit(request,meta,state,cursor,now,transition)
                written+=1
            except FileNotFoundError:continue # Context is created by the next worker run.
            except Exception:errors+=1
        atomic_json(self.root/'Logs/progress-producer-health.json',{'State':'Ready' if not errors else 'RetryPending','Errors':errors,'UpdatedEpoch':now,'WrittenThisTick':written,'Pid':os.getpid()})

def main():
    parser=argparse.ArgumentParser();parser.add_argument('--root',type=Path,default=Path(r'C:\ProgramData\NetCrate\Office'));args=parser.parse_args()
    import msvcrt
    args.root.joinpath('ProgressState').mkdir(exist_ok=True)
    with (args.root/'ProgressState/producer.lock').open('a+b') as lock:
        lock.seek(0);lock.write(b'0');lock.flush();lock.seek(0)
        try:msvcrt.locking(lock.fileno(),msvcrt.LK_NBLCK,1)
        except OSError:return
        while not (args.root/'progress.stop').exists():
            try:Producer(args.root).tick()
            except Exception:pass
            time.sleep(1)

if __name__=='__main__':main()
