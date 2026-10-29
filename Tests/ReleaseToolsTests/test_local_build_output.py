from pathlib import Path
import subprocess
import tempfile
import unittest
ROOT=Path(__file__).resolve().parents[2]
class LocalOutputTests(unittest.TestCase):
    def test_fresh_indexable_development_bundle_is_rejected_before_building(self):
        (ROOT/'build').mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(dir=ROOT/'build') as tmp:
            app=Path(tmp)/'Tilvero.app'
            p=subprocess.run(['bash',str(ROOT/'scripts/build-local-app.sh'),'--output',str(app)],capture_output=True,text=True,timeout=30)
            self.assertNotEqual(p.returncode,0)
            self.assertIn('.noindex folder',p.stderr)
            self.assertFalse(app.exists())

    def test_existing_explicit_output_is_rejected_before_building(self):
        with tempfile.TemporaryDirectory() as tmp:
            app=Path(tmp)/'Tilvero.app';app.mkdir();sentinel=app/'preserve';sentinel.write_text('original')
            p=subprocess.run(['bash',str(ROOT/'scripts/build-local-app.sh'),'--output',str(app)],capture_output=True,text=True,timeout=30)
            self.assertNotEqual(p.returncode,0)
            self.assertIn('output already exists',p.stderr.lower())
            self.assertEqual(sentinel.read_text(),'original')
if __name__=='__main__':unittest.main()
