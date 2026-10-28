import importlib.util,ssl,struct,tempfile,unittest
from pathlib import Path
spec=importlib.util.spec_from_file_location('bridge',Path(__file__).parents[1]/'_service/bridge/bridge.py')
b=importlib.util.module_from_spec(spec);spec.loader.exec_module(b)
QUERY=struct.pack('!6H',0x4321,0x100,1,0,0,0)+b'\x07example\x03com\0'+struct.pack('!HH',1,1)
REPLY=bytearray(QUERY);REPLY[2]=0x81;REPLY[3]=0x80;REPLY=bytes(REPLY)
class Protocol(unittest.TestCase):
 def test_tls_authentication_required(self):
  x=b.DoH('abcdef');self.assertTrue(x.context.check_hostname);self.assertEqual(x.context.verify_mode,ssl.CERT_REQUIRED);self.assertEqual(x.context.minimum_version,ssl.TLSVersion.TLSv1_3);self.assertEqual(x.context.maximum_version,ssl.TLSVersion.TLSv1_3)
 def test_bad_profile_rejected(self):
  for value in ['abcdef/other','https://x','12345','1234567','abcdef\n']:
   with self.assertRaises(ValueError):b.DoH(value)
 def hello(self,host=b.HOST):
  ctx=ssl.create_default_context();i,o=ssl.MemoryBIO(),ssl.MemoryBIO();x=ctx.wrap_bio(i,o,server_hostname=host)
  with self.assertRaises(ssl.SSLWantReadError):x.do_handshake()
  return o.read()
 def test_fragment_preserves_all_handshake_bytes(self):
  raw=self.hello();out=b.split_hello(raw);n=int.from_bytes(out[3:5],'big');second=out[5+n:];m=int.from_bytes(second[3:5],'big')
  self.assertEqual(out[:3],raw[:3]);self.assertEqual(second[:3],raw[:3]);self.assertEqual(out[5:5+n]+second[5:5+m],raw[5:]);self.assertEqual(len(out),len(raw)+5)
 def test_trailer_preserved(self):
  raw=self.hello();trailer=b'\x14\x03\x03\x00\x01\x01';self.assertTrue(b.split_hello(raw+trailer).endswith(trailer))
 def test_unknown_destination_rejected(self):
  with self.assertRaises(ValueError):b.split_hello(self.hello('example.com'))
 def test_truncated_record_rejected(self):
  for payload in [b'',b'abcde',self.hello()[:-1]]:
   with self.assertRaises(ValueError):b.split_hello(payload)
 def test_encrypted_failover_same_provider(self):
  x=b.DoH('abcdef');calls=[]
  def request(q,server):
   calls.append(server)
   if server==b.SERVERS[0]:raise TimeoutError()
   return REPLY
  x.request=request;self.assertEqual(x.query(QUERY),REPLY);self.assertEqual(calls,list(b.SERVERS));self.assertEqual(x.preferred,1)
 def test_invalid_response_never_accepted(self):
  x=b.DoH('abcdef');x.request=lambda q,s: bytes([0,0])+REPLY[2:]
  with self.assertRaises(OSError):x.query(QUERY)
 def test_no_plaintext_fallback(self):
  x=b.DoH('abcdef');calls=[]
  def request(q,s):calls.append(s);raise EOFError()
  x.request=request
  with self.assertRaises(OSError):x.query(QUERY)
  self.assertEqual(calls,list(b.SERVERS))
 def test_servfail_preserves_query(self):
  result=b.failure(QUERY);self.assertEqual(result[:2],QUERY[:2]);self.assertEqual(result[12:],QUERY[12:]);self.assertEqual(result[3]&15,2);self.assertTrue(result[2]&128);self.assertEqual(result[4:12],QUERY[4:12])
 def test_concurrency_is_bounded(self):
  class Pool:
   def __init__(self):self.items=[]
   def submit(self,fn):self.items.append(fn)
   def shutdown(self,**kw):pass
  with tempfile.TemporaryDirectory(prefix='bridge-protocol-') as folder:
   x=b.Bridge('abcdef',5355,folder);x.pool.shutdown();x.pool=Pool()
   for _ in range(64):self.assertTrue(x.submit(lambda:None))
   self.assertFalse(x.submit(lambda:None));x.pool.items.pop()();self.assertTrue(x.submit(lambda:None));x.close()
if __name__=='__main__':unittest.main(verbosity=1)
