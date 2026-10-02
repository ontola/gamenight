import unittest
from unittest.mock import patch
from host import Host, GAME
from modding import generate

class HostTests(unittest.TestCase):
    def party(self, count=2, phase="ready"):
        return {"seats": [{"index":i, "occupant":{"kind":"local","player_id":f"person-{i}"}, "controller":f"host:{i}"} for i in range(count)],
            "warm_session":{"game":GAME,"id":"session","phase":phase}}

    def test_identity_is_host_player_and_binding_changes_revision(self):
        p=self.party();before=Host.seats(p)
        p["seats"][0]["controller"]="host:replacement"
        after=Host.seats(p)
        self.assertEqual(before[0]["player"],"person-0")
        self.assertNotEqual(before[0]["revision"],after[0]["revision"])

    def test_one_player_cannot_launch_two_player_game(self):
        p=self.party(1); h=Host()
        with patch.object(h,"status",return_value=p),patch.object(h,"request") as send:
            with self.assertRaisesRegex(ValueError,"Join with 2"):
                h.launch(Host.seats(p)[0])
            send.assert_not_called()

    def test_launch_waits_for_actual_running_phase(self):
        p=self.party();h=Host();playing=dict(p,active_session={"game":GAME,"phase":"running"},overlay_open=False)
        with patch.object(h,"status",side_effect=[p,playing]),patch.object(h,"request") as send:
            self.assertEqual(h.launch(Host.seats(p)[0]),playing)
            send.assert_called_once_with({"type":"next"})

    def test_resume_does_not_start_a_new_session(self):
        p=self.party();p["active_session"]={"game":GAME,"phase":"paused"}
        h=Host();playing=dict(p,active_session={"game":GAME,"phase":"running"},overlay_open=False)
        with patch.object(h,"status",side_effect=[p,playing]),patch.object(h,"request") as send:
            h.launch(Host.seats(p)[0]);send.assert_called_once_with({"type":"close_overlay"})

    def test_generated_recipe_cannot_contain_code_or_paths(self):
        for bad in [{"lua":"os.execute('bad')"},{"bounce":True},{"bounce":float('nan')},{"bounce":-1},{"bounce":4},{"bounce":"1; os.exit()"},{"bounce":1,"path":"../other"}]:
            with self.subTest(bad=bad),self.assertRaises(ValueError): generate(bad)
        self.assertIn("local strength = 1.5",generate({"bounce":1.5}))

if __name__=="__main__":unittest.main()
