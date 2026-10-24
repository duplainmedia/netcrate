# REVIEW EXPORT: fictional deployment constants; see docs/CONFIGURATION.md.
"""Non-secret, best-effort Version 1 office progress and measured encode ETA."""
import ctypes
import datetime as dt
import hashlib
import json
import math
import os
import re
import time
import uuid
import unicodedata
from contextlib import contextmanager
from pathlib import Path

STAGES = {'Queued','RestoringOriginals','Probing','GeneratingProxies','GeneratingContactSheets','Verifying','Publishing','Complete','Failed'}
MESSAGES = {'Queued':'Waiting for the office worker.', 'RestoringOriginals':'Restoring and verifying source footage locally.', 'Probing':'Inspecting source media.', 'GeneratingProxies':'Encoding Premiere ProRes proxies.', 'GeneratingContactSheets':'Extracting source frames for contact sheets.', 'Verifying':'Verifying generated media.', 'Publishing':'Publishing verified office results.', 'Complete':'Office publication complete; source verification determines readiness.', 'Failed':'Office attempt stopped; retained work will be retried. Check office job diagnostics.'}

def number(value):
    try:
        result=float(value)
        return result if math.isfinite(result) and result >= 0 else None
    except (ValueError,TypeError): return None

def atomic_json(path, value, staging=None):
    path=Path(path)
    path.parent.mkdir(parents=True,exist_ok=True)
    temporary=Path(staging or path.parent)/('progress-'+uuid.uuid4().hex+'.writing')
    temporary.parent.mkdir(parents=True,exist_ok=True)
    data=json.dumps(value,ensure_ascii=False,allow_nan=False,indent=2).encode('utf-8')
    if len(data)>32768: raise ValueError('Progress metadata exceeds contract limit.')
    try:
        temporary.write_bytes(data)
        temporary.replace(path)
    finally:
        temporary.unlink(missing_ok=True)

def stage_event(context,value):
    directory=Path(context).parent.parent/'Events'/value['JobId']
    atomic_json(directory/(f'{time.time_ns():020d}-'+uuid.uuid4().hex+'.json'),value)

@contextmanager
def public_lock(path):
    """Same nonblocking Windows share lock used by the native publisher."""
    Path(path).parent.mkdir(parents=True,exist_ok=True)
    kernel=ctypes.WinDLL('kernel32',use_last_error=True)
    kernel.CreateFileW.argtypes=[ctypes.c_wchar_p,ctypes.c_uint,ctypes.c_uint,ctypes.c_void_p,ctypes.c_uint,ctypes.c_uint,ctypes.c_void_p]
    kernel.CreateFileW.restype=ctypes.c_void_p
    kernel.CloseHandle.argtypes=[ctypes.c_void_p]
    handle=kernel.CreateFileW(str(path),0xC0000000,0,None,4,0x80,None)
    if handle in (None,ctypes.c_void_p(-1).value):raise PermissionError('Progress file is publishing.')
    try:yield
    finally:kernel.CloseHandle(handle)

def parse_ffmpeg(text):
    values={}
    for line in text.splitlines():
        if '=' in line:
            key,value=line.split('=',1)
            values[key.strip()]=value.strip()
    seconds=None
    for name in ('out_time_us','out_time_ms'):
        value=number(values.get(name))
        if value is not None:
            seconds=value/1_000_000
            break
    if seconds is None:
        try:
            h,m,s=values['out_time'].split(':')
            seconds=number(float(h)*3600+float(m)*60+float(s))
        except (KeyError,ValueError): pass
    return {'seconds':seconds,'frames':number(values.get('frame')),'speed':number(values.get('speed','').rstrip('x'))}

def phase_eta(total,completed,observed_source,observed_wall):
    total=number(total)
    if total is None or total<=0 or observed_wall<30 or observed_source<=0:
        return None,observed_wall
    return max(0,total-completed)*observed_wall/observed_source,observed_wall

def make_status(request, meta, previous=None, now=None):
    now=time.time() if now is None else now
    snapshot=request['SnapshotId']; project=request['ProjectPath']
    if not re.fullmatch('[a-f0-9]{64}',snapshot) or not re.fullmatch(r'/D/Projects/[^/\\:*?\[\]"<>|\x00-\x1f]+',project) or project.endswith(('.', ' ')) or project.rsplit('/',1)[-1] in ('.','..'):
        raise ValueError('Invalid progress request association.')
    if any(unicodedata.category(ch)=='Cc' for ch in project):raise ValueError('Control character in project.')
    if not re.fullmatch('[a-z0-9][a-z0-9._-]{0,100}',meta['JobId']) or not re.fullmatch('[a-f0-9]{32}',meta['AttemptId']) or meta['Stage'] not in STAGES:
        raise ValueError('Invalid progress attempt identity.')
    total=int(number(meta.get('TotalClips')) or 0)
    def count(key): return min(total,int(number(meta.get(key)) or 0))
    clip=meta.get('CurrentClip','').replace('\\','/')
    if clip.startswith('/') or any(part in ('.','..','') for part in clip.split('/')) or re.search(r'[:\x00-\x1f\x7f]',clip) or any(unicodedata.category(ch)=='Cc' for ch in clip): clip=''
    units=number(meta.get('StageCompletedUnits'))
    unit_total=number(meta.get('StageTotalUnits'))
    if unit_total is not None and (unit_total<=0 or (units is not None and units>unit_total)): unit_total=None
    eta=number(meta.get('EtaSeconds'))
    sample=number(meta.get('EtaSampleSeconds')) or 0
    if meta['Stage']!='GeneratingProxies' or sample<30 or now-meta.get('ObservedEpoch',0)>30: eta=None
    sequence=int(previous['Sequence'])+1 if previous and previous['AttemptId']==meta['AttemptId'] else 0
    return {'Version':1,'Kind':'office-media-progress','SourceComputer':'SOURCE-PC','WorkerComputer':'WORKER-PC',
        'RequestId':hashlib.sha256((snapshot+'|'+project).encode('utf-8')).hexdigest(),
        'SourceSnapshotId':snapshot,'ProjectPath':project,'JobId':meta['JobId'],'AttemptId':meta['AttemptId'],
        'Sequence':sequence,'UpdatedUtc':dt.datetime.fromtimestamp(now,dt.timezone.utc).isoformat().replace('+00:00','Z'),
        'Stage':meta['Stage'],'TotalClips':total,'CompletedClips':count('CompletedClips'),
        'ProxyFilesCompleted':count('ProxyFilesCompleted'),'ContactSheetsCompleted':count('ContactSheetsCompleted'),
        'StageCompletedUnits':units,'StageTotalUnits':unit_total,
        'StageUnit':meta.get('StageUnit') if meta.get('StageUnit') in ('source-seconds','frames','clips','bytes','unknown') else 'unknown',
        'CurrentClip':clip,'EtaSeconds':eta,'EtaScope':'phase' if eta is not None else '',
        'EtaBasis':'Observed encoded source seconds / encode wall seconds; excludes sheets, checks and transfer.' if eta is not None else '',
        'EtaSampleSeconds':sample,'Message':MESSAGES[meta['Stage']]}

class Reporter:
    def __init__(self,context,inventory,clock=time.monotonic):
        self.context=Path(context)
        self.meta=json.loads(self.context.read_text(encoding='utf-8-sig'))
        self.path=self.context.with_suffix('.telemetry.json')
        self.clock=clock; self.total=len(inventory)
        durations=[number(i.get('duration')) for i in inventory]
        self.total_seconds=sum(durations) if all(v is not None and v>0 for v in durations) else None
        self.finished_seconds=0; self.observed_source=0; self.observed_wall=0
        self.done=0; self.proxies=0; self.sheets=0; self.last_write=0

    def emit(self,stage,units=None,total=None,unit='unknown',force=True,eta=None,sample=0):
        now=self.clock()
        if not force and now-self.last_write<5: return
        self.last_write=now
        value={'AttemptId':self.meta['AttemptId'],'JobId':self.meta['JobId'],'UpdatedEpoch':time.time(),'ObservedEpoch':time.time(),
            'Stage':stage,'TotalClips':self.total,'CompletedClips':self.done,'ProxyFilesCompleted':self.proxies,
            'ContactSheetsCompleted':self.sheets,'CurrentClip':getattr(self,'clip',''),'StageCompletedUnits':units,
            'StageTotalUnits':total,'StageUnit':unit,'EtaSeconds':eta,'EtaSampleSeconds':sample}
        atomic_json(self.path,value)
        if getattr(self,'last_stage',None)!=stage:
            stage_event(self.context,value)
            self.last_stage=stage

    def start_clip(self,clip,duration,done):
        self.clip=clip; self.duration=number(duration); self.done=done
        self.started=self.clock(); self.current_seconds=0
        self.emit('GeneratingProxies',self.finished_seconds,self.total_seconds,'source-seconds')

    def proxy_sample(self,seconds,now=None):
        now=self.clock() if now is None else now
        if seconds is not None:
            self.current_seconds=max(self.current_seconds,min(seconds,self.duration) if self.duration else seconds)
        sample=self.observed_wall+max(0,now-self.started)
        eta,_=phase_eta(self.total_seconds,self.finished_seconds+self.current_seconds,self.observed_source+self.current_seconds,sample)
        self.emit('GeneratingProxies',self.finished_seconds+self.current_seconds,self.total_seconds,'source-seconds',eta=eta,sample=sample)

    def poll_file(self,path):
        with Path(path).open('rb') as stream:
            stream.seek(max(0,stream.seek(0,2)-8192))
            data=stream.read().decode('utf-8',errors='replace')
        self.proxy_sample(parse_ffmpeg(data)['seconds'])

    def end_proxy(self):
        value=self.duration or self.current_seconds
        self.finished_seconds+=value; self.observed_source+=value
        self.observed_wall+=max(0,self.clock()-self.started)

    def verify_stage(self): self.emit('Verifying',self.done,self.total,'clips')
    def sheet_stage(self,index):
        self.proxies=index+1
        self.emit('GeneratingContactSheets',self.sheets*12,self.total*12,'frames')
    def sheet_frame(self,frame): self.emit('GeneratingContactSheets',self.sheets*12+frame,self.total*12,'frames')
    def sheet_done(self): self.sheets+=1
    def clip_done(self):
        self.done+=1; self.proxies=self.done; self.sheets=self.done
        self.emit('Verifying',self.done,self.total,'clips')
    def reused(self,duration):
        self.finished_seconds+=number(duration) or 0
        self.clip_done()

class SafeReporter:
    """Instrumentation errors never escape into the media pipeline."""
    def __init__(self,context,inventory):
        try: self.reporter=Reporter(context,inventory) if context else None
        except Exception: self.reporter=None
    def __getattr__(self,name):
        def call(*args,**kwargs):
            try:
                if self.reporter: return getattr(self.reporter,name)(*args,**kwargs)
            except Exception: pass
        return call
