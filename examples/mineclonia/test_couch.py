import unittest
from couch import select
class Seats(unittest.TestCase):
 def pads(self):return [{"path":"pad-a","game_controller":True},{"path":"pad-b","game_controller":True}]
 def test_saved_seats_survive_enumeration_reordering(self):
  self.assertEqual([p["path"] for p in select(list(reversed(self.pads())),["pad-a","pad-b"])],["pad-a","pad-b"])
 def test_missing_pad_does_not_assign_someone_else(self):
  with self.assertRaises(ValueError):select(self.pads(),["pad-a","disconnected"])
 def test_no_shared_or_missing_binding(self):
  for pads in ([],self.pads()[:1],[self.pads()[0]]*2):
   with self.assertRaises(ValueError):select(pads)
 def test_duplicate_saved_assignment_is_invalid(self):
  with self.assertRaises(ValueError):select(self.pads(),["pad-a","pad-a"])
if __name__=="__main__":unittest.main()
