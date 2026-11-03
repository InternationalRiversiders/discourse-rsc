import importlib.util
from pathlib import Path
import subprocess
import unittest
from unittest.mock import patch
spec=importlib.util.spec_from_file_location('deploy',Path(__file__).parents[1]/'script/deploy-blue-green.py')
deploy=importlib.util.module_from_spec(spec);spec.loader.exec_module(deploy)
class DrainTest(unittest.TestCase):
 def test_only_verified_idle_workers_allow_stop(self):
  for code,expected in [(0,True),(2,False),(1,False)]:
   with patch.object(deploy.subprocess,'run',return_value=subprocess.CompletedProcess([],code)) as run:
    self.assertEqual(expected,deploy.drain_background('web_a','web_a'))
    args=run.call_args.args[0]
    self.assertIn('web_a',args);self.assertIn('rails',args)
 def test_timeout_keeps_old_container(self):
  with patch.object(deploy.subprocess,'run',side_effect=subprocess.TimeoutExpired('probe',130)):
   self.assertFalse(deploy.drain_background('web_b','web_b'))
if __name__=='__main__':unittest.main()
