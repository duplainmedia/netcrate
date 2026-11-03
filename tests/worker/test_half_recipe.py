# REVIEW EXPORT: fictional deployment constants; see docs/CONFIGURATION.md.
import copy
import tempfile
import unittest
from pathlib import Path
from proxy_recipe import DEFAULT_DIVISOR, recipe_id, scale_filter
from verify_media import verify_sample

class RecipeTests(unittest.TestCase):
    def test_new_default_and_distinct_legacy_recipe(self):
        self.assertEqual(DEFAULT_DIVISOR,2)
        self.assertEqual(scale_filter(2),'scale=iw/2:ih/2')
        self.assertEqual(recipe_id(2),'half-prores-v2')
        self.assertNotEqual(recipe_id(2),recipe_id(4))
        with self.assertRaises(ValueError):scale_filter(1)

    def test_explicit_half_and_legacy_quarter_validation(self):
        with tempfile.TemporaryDirectory() as directory:
            proxy=Path(directory)/'proxy.mov';proxy.touch()
            sheet=Path(directory)/'sheet.jpg';sheet.touch()
            original={'video':{'width':3840,'height':2160,'avg_frame_rate':'30000/1001'},'audio':[],'duration':1,'timecode':None}
            sample={'original':original,'proxy':{'video':{'codec_name':'prores','profile':'Proxy','pix_fmt':'yuv422p10le','width':1920,'height':1080,'avg_frame_rate':'30000/1001','duration':'1'},'audio':[],'timecode':None},'proxy_scale_divisor':2,'proxy_recipe':'half-prores-v2','decode_passed':True,'proxy_path':str(proxy),'contact_sheet_path':str(sheet),'contact_sheet_timestamps':list(range(12))}
            verify_sample(sample)
            invalid=copy.deepcopy(sample);invalid['proxy']['video']['pix_fmt']='yuv422p'
            with self.assertRaises(AssertionError):verify_sample(invalid)
            invalid=copy.deepcopy(sample);invalid['proxy_recipe']='quarter-prores-v1'
            with self.assertRaises(AssertionError):verify_sample(invalid)
            del sample['proxy_scale_divisor'];del sample['proxy_recipe']
            with self.assertRaises(AssertionError):verify_sample(sample)
            sample['proxy']['video'].update(width=960,height=540)
            verify_sample(sample) # Existing saved quarter results remain verifiable.

if __name__=='__main__':unittest.main()
