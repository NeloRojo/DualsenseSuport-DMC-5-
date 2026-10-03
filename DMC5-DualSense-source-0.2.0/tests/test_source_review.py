import json,sys,unittest
from pathlib import Path
from lupa import LuaRuntime
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'helper'))
from dualsense import trigger_block,packet
from effects import ExceedContext
from main import profile
class ReviewTests(unittest.TestCase):
 def test_python_syntax(self):
  for folder in ['helper','tools','scripts']:
   for p in (ROOT/folder).glob('*.py'):compile(p.read_text(encoding='utf-8'),str(p),'exec')
 def test_lua_syntax(self):
  lua=LuaRuntime()
  for p in (ROOT/'reframework/autorun').glob('*.lua'):lua.compile(p.read_text(encoding='utf-8'))
 def test_profiles(self):
  p=profile(ROOT/'profiles/nero.json')
  self.assertIn('dante_sdt_luce_hit',p['effects'])
  self.assertEqual(p['sdt_attack_triggers']['demolition']['active']['strength'],8)
 def test_trigger_feedback(self):
  b=trigger_block(dict(mode='feedback',start=0,strength=8))
  self.assertEqual(b[0],0x21);self.assertEqual(int.from_bytes(b[1:3],'little'),1023)
  self.assertEqual(int.from_bytes(b[3:7],'little'),(1<<30)-1)
  with self.assertRaises(ValueError):trigger_block(dict(mode='feedback',start=10,strength=8))
 def test_hit_pulse_and_pause(self):
  p=profile(ROOT/'profiles/nero.json');c=ExceedContext()
  def mode(tick,hits,t,paused=False):
   c.update(dict(session='s',tick=tick,dante_sdt_active=True,dante_sdt_luce_hits=hits,game_paused=paused),'s',t)
   e,f=c.sdt_triggers({}, {},p['sdt_attack_triggers'],t)
   return packet(e,f)[11]
  self.assertEqual(mode(1,50,1),0)
  self.assertEqual(mode(2,51,1.05),0x26)
  self.assertEqual(mode(3,51,1.2),0)
  self.assertEqual(mode(4,52,1.25,True),0)
 def test_no_game_archives_or_compiled_files(self):
  forbidden={'.wav','.wem','.bnk','.pck','.pak','.dmcpack','.dll','.exe','.pyd'}
  for folder in ['helper','profiles','native','reframework']:
   for p in (ROOT/folder).rglob('*'):
    if p.is_file():self.assertNotIn(p.suffix.lower(),forbidden,str(p))
if __name__=='__main__':unittest.main()
