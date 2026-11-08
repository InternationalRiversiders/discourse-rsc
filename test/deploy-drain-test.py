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

class FrontendTest(unittest.TestCase):
 def response(self, body):
  from unittest.mock import MagicMock
  response=MagicMock();response.status=200;response.read.return_value=body
  response.__enter__.return_value=response
  return response

 def test_browser_layout_required_not_crawler_or_error_page(self):
  for body,valid in [(b'<script type="importmap">{}</script>',True),
                     (b'<html>crawler view</html>',False),
                     (b'importmap The software powering this discussion forum encountered',False)]:
   with patch.object(deploy.urllib.request,'build_opener') as build:
    build.return_value.open.return_value=self.response(body)
    if valid: deploy.check_frontend(8002)
    else:
     with self.assertRaises(RuntimeError):deploy.check_frontend(8002)
    request=build.return_value.open.call_args.args[0]
    self.assertIn('Chrome/',request.get_header('User-agent'))
    self.assertTrue(request.full_url.startswith('http://127.0.0.1:8002/'))

if __name__=='__main__':unittest.main()
