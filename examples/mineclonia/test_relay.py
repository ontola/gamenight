"""Contract checks for the experimental host boundary; no synthetic gameplay."""
import time,unittest,tempfile
from pathlib import Path
from unittest.mock import patch, Mock
from relay import execute, snapshot
class Contract(unittest.TestCase):
 def test_pairing_stays_available_without_running_world(self):
  host=Mock();host.status.return_value={};host.seats.return_value=[{'index':0,'player':'guest','revision':1}]
  with tempfile.TemporaryDirectory() as folder:
   state=snapshot(Path(folder),'test',host=host,allow_loading=True)
   self.assertEqual(state['seats'],host.seats.return_value)
   self.assertIsNone(state['discovery']['controls'])
   self.assertEqual(snapshot(Path(folder),'test',host=host)['seats'],state['seats'])
 def test_other_game_uses_declared_controls_without_a_mineclonia_world(self):
  host=Mock()
  host.status.return_value={"active_session":{"id":"game-1","game":"neon-siege"},
    "connected_games":["neon-siege"],"library":[{"id":"neon-siege"},{"id":"mineclonia-prototype"},{"id":"lobby"}],
    "settings":[{"game":"neon-siege","revision":3,"can_undo":True,
      "specs":[{"key":"wormholes","kind":"toggle","label":"Wormholes"}],"values":{"wormholes":False}}]}
  host.seats.return_value=[{"index":0,"player":"guest","revision":1}]
  with tempfile.TemporaryDirectory() as folder:
   state=snapshot(Path(folder),'test',host=host,receipt={"id":"done","ok":True})
   c=state["discovery"]["controls"]
   self.assertEqual(c["game"],"neon-siege")
   self.assertEqual(c["settings"]["wormholes"]["value"],False)
   self.assertEqual({g["id"] for g in state["discovery"]["games"]},{"neon-siege","mineclonia"})
   self.assertEqual(state["discovery"]["acknowledged"],"done")
 def request(self):
  return {"id":"request-1","game":"mineclonia","expires":int(time.time())+60,"seat":{"index":0,"player":"Couch1","revision":1},"command":{"action":"set","instance":"world-1","expected_revision":2,"values":{"gravity":.5}}}
 def test_reject_before_mailbox(self):
  cases=[]
  r=self.request();r["command"]["values"]={"shell":1};cases.append(r)
  r=self.request();r["command"]["values"]={"gravity":True};cases.append(r)
  r=self.request();r["command"]["values"]={"gravity":float("nan")};cases.append(r)
  r=self.request();r["command"]["values"]={"gravity":0};cases.append(r)
  r=self.request();del r["command"]["expected_revision"];cases.append(r)
  r=self.request();r["command"]["instance"]="other-world";cases.append(r)
  r=self.request();r["expires"]=0;cases.append(r)
  r=self.request();r["seat"]["revision"]=2;cases.append(r)
  r=self.request();r["command"]["action"]="shutdown";cases.append(r)
  with patch("relay.snapshot",return_value={"seats":[self.request()["seat"]],"discovery":{"controls":{"instance":"world-1"}}}),patch("relay.command") as command:
   for r in cases:
    with self.subTest(r=r),self.assertRaises(ValueError):execute(Path("."),"world-1",r)
   command.assert_not_called()
if __name__=="__main__":unittest.main()
