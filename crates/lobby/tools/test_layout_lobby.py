"""Regression checks for visual door clearance, including one-way platforms."""
import unittest
import yaml
from layout_lobby import build, validate


class DoorClearance(unittest.TestCase):
    def setUp(self):
        self.room = yaml.safe_load(build()[0])
        self.anchors = [160 + i * 112 for i in range(8)]

    def test_leave_door_rejects_both_old_platform_heights(self):
        for row in (4, 6):
            with self.subTest(row=row):
                tile = dict(pos=[2, row], idx=44, collision='JumpThrough')
                self.room['layers'][0]['tiles'].append(tile)
                with self.assertRaisesRegex(AssertionError, 'Blocked Leave door'):
                    validate(self.room, self.anchors)
                self.room['layers'][0]['tiles'].remove(tile)

    def test_profile_door_also_rejects_jump_through_platform(self):
        self.room['layers'][0]['tiles'].append(
            dict(pos=[5, 4], idx=44, collision='JumpThrough'))
        with self.assertRaisesRegex(AssertionError, 'Blocked profile doorway'):
            validate(self.room, self.anchors)


if __name__ == '__main__':
    unittest.main()
