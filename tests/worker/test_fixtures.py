import csv, hashlib, json, unittest
from pathlib import Path

class FixtureTests(unittest.TestCase):
    def test_request_result_ack_progress_and_payload_hashes(self):
        root=Path(__file__).resolve().parent/'examples'
        def load(name):return json.loads((root/name).read_text(encoding='utf-8-sig'))
        request=load('request.json'); ids=load('identities.json'); progress=load('progress.json')
        complete=load('COMPLETE.json'); ack=load('delivery.json'); identity=load('footage-identity.json')
        self.assertEqual(ids['RequestId'],hashlib.sha256((request['SnapshotId']+'|'+request['ProjectPath']).encode()).hexdigest())
        self.assertEqual(ids['JobId'],'auto-'+identity['Fingerprint'])
        self.assertEqual(ack['JobId'],ids['JobId']);self.assertEqual(ack['ResultSnapshot'],ids['ResultSnapshotId'])
        self.assertEqual(complete['snapshot_id'],request['SnapshotId']);self.assertEqual(ack['MediaFiles'],complete['proxy_files']+complete['contact_sheets'])
        self.assertEqual(len(progress),25);self.assertEqual(progress['RequestId'],ids['RequestId']);self.assertEqual(progress['AttemptId'],ids['AttemptId'])
        spec=load('synthetic-payload-spec.json')
        with (root/'Files-SHA256.csv').open(encoding='utf-8-sig',newline='') as handle:
            rows=list(csv.DictReader(handle))
        self.assertEqual(len(rows),2)
        for row in rows:
            data=spec[row['RelativePath']].encode();self.assertEqual(int(row['Bytes']),len(data));self.assertEqual(row['SHA256'],hashlib.sha256(data).hexdigest().upper())

if __name__=='__main__':unittest.main()
