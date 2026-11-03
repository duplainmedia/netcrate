# REVIEW EXPORT: fictional deployment constants; see docs/CONFIGURATION.md.
import hashlib
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
import office_media_progress as p
from progress_producer import Producer

class ProgressTests(unittest.TestCase):
    def test_structured_ffmpeg(self):
        self.assertEqual(p.parse_ffmpeg('frame=90\nout_time_us=3000000\nspeed=1.5x\nprogress=continue\n')['seconds'], 3)
        self.assertEqual(p.parse_ffmpeg('out_time_ms=2500000\nprogress=end\n')['seconds'], 2.5)
        self.assertEqual(p.parse_ffmpeg('out_time=00:01:02.500\nprogress=continue\n')['seconds'], 62.5)
        self.assertIsNone(p.parse_ffmpeg('out_time_us=N/A\nspeed=nanx\n')['seconds'])

    def test_weighted_eta_warmup_and_unknown(self):
        # A 10-second clip + a 990-second clip: completing one is 1%, not 50%.
        self.assertEqual(p.phase_eta(1000, 10, 10, 30), (2970.0, 30))
        self.assertEqual(p.phase_eta(1000, 10, 10, 29), (None, 29))
        for total in (None, 0, float('nan')):
            self.assertIsNone(p.phase_eta(total, 10, 10, 40)[0])
        self.assertIsNone(p.phase_eta(100, 10, 0, 40)[0])

    def test_exact_association_sequence_and_reuse(self):
        request={'SnapshotId':'a'*64,'ProjectPath':'/D/Projects/Example'}
        meta={'JobId':'existing-job','AttemptId':'b'*32,'Stage':'Complete','TotalClips':2,'CompletedClips':2,'ProxyFilesCompleted':2,'ContactSheetsCompleted':2}
        first=p.make_status(request,meta,None,now=1000)
        self.assertEqual(first['RequestId'],hashlib.sha256((request['SnapshotId']+'|'+request['ProjectPath']).encode()).hexdigest())
        self.assertEqual(first['SourceSnapshotId'], 'a'*64)
        second=p.make_status(dict(request,SnapshotId='c'*64),meta,None,now=1001)
        self.assertNotEqual(first['RequestId'],second['RequestId'])
        self.assertEqual(first['JobId'],second['JobId'])
        next_status=p.make_status(request,meta,first,now=1002)
        self.assertEqual(next_status['Sequence'],first['Sequence']+1)
        reset=p.make_status(request,dict(meta,AttemptId='d'*32),next_status,now=1003)
        self.assertEqual(reset['Sequence'],0)
        self.assertEqual(first['Stage'],'Complete')

    def test_sanitization_and_stale_eta(self):
        request={'SnapshotId':'a'*64,'ProjectPath':'/D/Projects/Example'}
        meta={'JobId':'job','AttemptId':'b'*32,'Stage':'GeneratingProxies','TotalClips':2,'CompletedClips':1,'ProxyFilesCompleted':1,'ContactSheetsCompleted':1,'CurrentClip':'../secret','EtaSeconds':12,'EtaScope':'phase','EtaBasis':'observed','EtaSampleSeconds':40,'ObservedEpoch':900}
        result=p.make_status(request,meta,None,now=1000)
        self.assertEqual(result['CurrentClip'],'')
        self.assertIsNone(result['EtaSeconds'])
        with self.assertRaises(ValueError):
            p.make_status(dict(request,ProjectPath='/D/Projects/../bad'),meta,None)

    def test_reporter_unknown_durations_and_stage_totals(self):
        with tempfile.TemporaryDirectory() as folder:
            context=Path(folder)/'context.json'
            p.atomic_json(context,{'AttemptId':'a'*32,'JobId':'job'})
            r=p.Reporter(context,[{'duration':10},{'duration':990}],clock=lambda:100)
            r.start_clip('Camera/clip.mov',10,0)
            r.proxy_sample(5,now=140)
            data=json.loads(r.path.read_text())
            self.assertEqual(data['StageTotalUnits'],1000)
            self.assertEqual(data['StageCompletedUnits'],5)
            self.assertEqual(data['EtaSeconds'],7960)
            r.sheet_stage(0)
            r.sheet_frame(3)
            data=json.loads(r.path.read_text())
            self.assertEqual((data['StageUnit'],data['StageTotalUnits'],data['StageCompletedUnits']),('frames',24,3))
            self.assertIsNone(data['EtaSeconds'])
            for duration in (0,None,float('nan')):
                unknown=p.Reporter(context,[{'duration':duration}],clock=lambda:100)
                self.assertIsNone(unknown.total_seconds)

    def test_atomic_one_file_public_payload(self):
        with tempfile.TemporaryDirectory() as folder:
            path=Path(folder)/'progress.json'
            p.atomic_json(path,{'Version':1})
            p.atomic_json(path,{'Version':2})
            self.assertEqual(list(Path(folder).iterdir()),[path])
            self.assertEqual(json.loads(path.read_text())['Version'],2)

    def test_instrumentation_failure_never_escapes(self):
        reporter=p.SafeReporter('missing-context.json',[{'duration':1}])
        reporter.start_clip('clip.mov',1,0)
        reporter.poll_file('missing-progress.txt')
        reporter.clip_done()

    @unittest.skip('Opt-in native integration; not run for export review; configure tool path first.')
    def test_real_structured_ffmpeg_and_callback_failure(self):
        import subprocess
        from disk_reserve import run_guarded
        with tempfile.TemporaryDirectory() as folder:
            path=Path(folder)/'ffmpeg.txt'
            result=run_guarded([r'C:\ProgramData\NetCrate\Office\Tools\FFmpeg\ffmpeg.exe','-nostdin','-v','error','-f','lavfi','-i','testsrc2=size=64x64:rate=30','-t','1','-progress',str(path),'-f','null','-'],Path(folder),capture_output=True,text=True,on_poll=lambda:(_ for _ in ()).throw(ValueError('Reporting failed')))
            self.assertEqual(result.returncode,0)
            measured=p.parse_ffmpeg(path.read_text())
            self.assertGreater(measured['seconds'],0)
            self.assertEqual(measured['frames'],30)

    def test_short_transitions_are_durable_between_polls(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder); transport='c'*64
            request={'Version':1,'Kind':'request','SourceComputer':'SOURCE-PC','Repository':'rest:https://backup.example:8000/sample-user/source-pc/','BackupExitCode':0,'SnapshotId':'a'*64,'ProjectPath':'/D/Projects/Example'}
            p.atomic_json(root/'AutoState/Requests'/f'{transport}.json',{'State':'Accepted','JobId':'job'})
            p.atomic_json(root/'AutoState/Incoming'/transport/'request.json',request)
            p.atomic_json(root/'Queue/job.json',{'JobId':'job','State':'Processing'})
            context={'JobId':'job','AttemptId':'b'*32,'OwnerPid':1,'OwnerStartedEpoch':1,'UpdatedEpoch':999,'TotalClips':2}
            for index,stage in enumerate(('Queued','Probing','GeneratingProxies','Verifying')):
                event=dict(context,Stage=stage)
                p.atomic_json(root/'ProgressState/Events/job'/f'{index:020d}.json',event)
            p.atomic_json(root/'ProgressState/Jobs/job.json',event)
            Producer(root,alive=lambda *args:True).tick(now=1000)
            pending=sorted((root/'ProgressState/Pending').glob('*/*.json'))
            self.assertEqual([json.loads(f.read_text())['Stage'] for f in pending],['Queued','Probing','GeneratingProxies','Verifying'])
            self.assertEqual([json.loads(f.read_text())['Sequence'] for f in pending],[0,1,2,3])

    def test_producer_restart_heartbeat_failure_and_complete_reuse(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder); transport='c'*64; job_id='job'
            request={'Version':1,'Kind':'request','SourceComputer':'SOURCE-PC','Repository':'rest:https://backup.example:8000/sample-user/source-pc/','BackupExitCode':0,'SnapshotId':'a'*64,'ProjectPath':'/D/Projects/Example'}
            p.atomic_json(root/'AutoState/Requests'/f'{transport}.json',{'State':'Accepted','JobId':job_id})
            p.atomic_json(root/'AutoState/Incoming'/transport/'request.json',request)
            job={'JobId':job_id,'State':'Processing','SnapshotId':'a'*64,'OutputPath':str(root/'Output')}
            p.atomic_json(root/'Queue/job.json',job)
            context={'JobId':job_id,'AttemptId':'b'*32,'Stage':'RestoringOriginals','TotalClips':2,'OwnerPid':123,'OwnerStartedEpoch':1,'UpdatedEpoch':990}
            p.atomic_json(root/'ProgressState/Jobs/job.json',context)
            producer=Producer(root,alive=lambda *args:True)
            producer.tick(now=1000)
            request_id=hashlib.sha256((request['SnapshotId']+'|'+request['ProjectPath']).encode()).hexdigest()
            path=root/'ProgressPublish'/request_id/'progress.json'
            first=json.loads(path.read_text()); self.assertEqual(first['Stage'],'RestoringOriginals')
            Producer(root,alive=lambda *args:True).tick(now=1011)
            resumed=json.loads(path.read_text()); self.assertGreater(resumed['Sequence'],first['Sequence'])
            Producer(root,alive=lambda *args:False).tick(now=1022)
            failed=json.loads(path.read_text()); self.assertEqual(failed['Stage'],'Failed')
            job['State']='Published';job['ResultSnapshot']='d'*64
            p.atomic_json(root/'Queue/job.json',job)
            p.atomic_json(root/'Output/COMPLETE.json',{'verified':True,'snapshot_id':'a'*64,'clips':2,'proxy_files':2,'contact_sheets':2})
            context.update(Stage='Complete',TotalClips=2,CompletedClips=2,ProxyFilesCompleted=2,ContactSheetsCompleted=2,UpdatedEpoch=1030)
            p.atomic_json(root/'ProgressState/Jobs/job.json',context)
            Producer(root,alive=lambda *args:False).tick(now=1031)
            complete=json.loads(path.read_text());self.assertEqual(complete['Stage'],'Complete')
            self.assertEqual(complete['CompletedClips'],2)
            self.assertEqual([v.name for v in path.parent.iterdir()],['progress.json'])
            Producer(root,alive=lambda *args:False).tick(now=1045)
            self.assertEqual(json.loads(path.read_text())['Sequence'],complete['Sequence'])

if __name__=='__main__': unittest.main()
