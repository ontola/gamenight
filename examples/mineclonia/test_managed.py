import unittest
from managed import routed, Adapter
class Routing(unittest.TestCase):
    def test_superseded_notifications_do_not_close_world(self):
        adapter=Adapter.__new__(Adapter)
        adapter.receive({'type':'error','message':'stale participation session'})
        adapter.receive({'type':'error','message':'ready for unknown or non-preparing session'})
        with self.assertRaises(RuntimeError):
            adapter.receive({'type':'error','message':'invalid launch token'})
    def seat(self, token, kind="local"):
        return {"controller":token,"occupant":{"kind":kind}}
    def pad(self, token, buttons=1):
        return {"controller":token,"buttons":buttons,"axes":[1,2,3,4,5,6]}
    def test_token_mapping_not_device_order(self):
        result=routed([self.seat("b"),self.seat("a")],[self.pad("a",2),self.pad("b",1)])
        self.assertEqual([p[1] for p in result],[1,2])
    def test_missing_and_ai_neutral(self):
        self.assertEqual(routed([self.seat("a"),self.seat("b","ai")],[self.pad("b")]),[(False,0,[0]*6)]*2)
    def test_duplicate_seat_cannot_borrow_controller(self):
        result=routed([self.seat("a"),self.seat("a")],[self.pad("a")])
        self.assertTrue(result[0][0]);self.assertFalse(result[1][0])
    def test_back_consumed_and_start_preserved(self):
        self.assertEqual(routed([self.seat("a")],[self.pad("a",(1<<6)|(1<<7))])[0][1],1<<7)
    def test_invalid_frame_is_neutral(self):
        bad=self.pad("a");bad["axes"]=[65535]*6
        self.assertEqual(routed([self.seat("a")],[bad]),[(False,0,[0]*6)])
if __name__=="__main__":unittest.main()
