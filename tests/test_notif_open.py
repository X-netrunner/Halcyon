"""scripts/notif-open.py: what a click on a notification does (a saved recording plays, a Halcyon notice opens its Settings page,
another app's window comes to the front). No desktop needed: subprocess and the window lookup are replaced."""
import importlib.util
import os
import sys
import tempfile
import unittest
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("notif_open", os.path.join(HERE, "..", "scripts", "notif-open.py"))
no = importlib.util.module_from_spec(spec)
spec.loader.exec_module(no)


class Routes(unittest.TestCase):
    def test_halcyon_notices_go_to_their_place(self):
        want = {
            "Power Manager": "settings:power",
            "Charge limit": "settings:power",
            "Halcyon Auto power is on": "settings:power",
            "Hyprland Layout": "settings:workspaces",
            "Live wallpaper": "settings:wallpaper",
            "Wallpaper kept": "settings:wallpaper",
            "Lock screen": "settings:lockscreen",
            "Terminal greeting": "settings:greeting",
            "Calendar is switched off": "settings:calendar",
            "No browser found": "settings:apps",
            "No file app found": "settings:apps",
            "Halcyon: island shell": "settings:debug",
            "Focus session complete": "settings:focus",
            "Break time": "settings:focus",
            "Gaming mode": "gamecenter",
            "Hades is already running": "gamecenter",
            "Recording started": "capture",
            "Audio recording started": "capture",
            "Recording without sound": "capture",
            "Voice note saved": "notes",
            "Reminder": "notes",
            "Before you update": "versions",
        }
        for title, cid in want.items():
            self.assertEqual(no.halcyon_target(title), cid, title)

    def test_notices_with_nowhere_to_go_do_nothing(self):
        for title in ("Timer done", "Emoji picker", "RAM details", "Switch user", "Hotspot", "Screenshot"):
            self.assertIsNone(no.halcyon_target(title), title)

    def test_who_is_halcyon(self):
        self.assertTrue(no.is_halcyon("Halcyon", "Power Manager"))
        self.assertTrue(no.is_halcyon("notify-send", "Halcyon safety check"))
        self.assertFalse(no.is_halcyon("Firefox", "New message"))


class Click(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.calls = []
        self.which = mock.patch.object(no.shutil, "which", lambda c: "/usr/bin/" + c)
        self.popen = mock.patch.object(no.subprocess, "Popen", lambda cmd, **kw: self.calls.append(("popen", cmd)))
        self.run = mock.patch.object(no, "run", lambda cmd, timeout=6: self.calls.append(("run", cmd)) or True)
        self.focus = mock.patch.object(no, "focus_app", lambda app, entry: self.calls.append(("focus", app, entry)) or True)
        for p in (self.which, self.popen, self.run, self.focus):
            p.start()
            self.addCleanup(p.stop)

    def click(self, app, summary, body="", icon="", mode="auto", entry=""):
        with mock.patch.object(sys, "argv", ["notif-open.py", app, entry, icon, summary, body, mode]):
            return no.main()

    def test_saved_recording_plays(self):
        f = os.path.join(self.dir, "recording_2026-11-05_10-00-00.mp4")
        open(f, "wb").close()
        self.assertEqual(self.click("Halcyon", "Recording saved", f), 0)
        self.assertEqual(self.calls, [("popen", ["xdg-open", f])])

    def test_audio_recording_plays(self):
        f = os.path.join(self.dir, "audio_x.m4a")
        open(f, "wb").close()
        self.click("Halcyon", "Recording saved", f)
        self.assertEqual(self.calls, [("popen", ["xdg-open", f])])

    def test_screenshot_still_opens_the_file_manager(self):
        f = os.path.join(self.dir, "1.png")
        open(f, "wb").close()
        self.click("Halcyon", "Screenshot", "Saved and copied", icon=f)
        kinds = [c[0] for c in self.calls]
        self.assertNotIn(["xdg-open", f], [c[1] for c in self.calls if c[0] == "popen"])
        self.assertTrue(kinds)                      # gdbus ShowItems (run) or a file manager (popen)

    def test_halcyon_notice_opens_its_settings_page(self):
        self.assertEqual(self.click("Halcyon", "Power Manager", "Enabled (Automatic Mode)"), 0)
        self.assertEqual(self.calls, [("run", ["quickshell", "ipc", "-p", no.IPC_DIR, "call", "island", "command", "settings:power"])])

    def test_halcyon_notice_with_nowhere_to_go(self):
        self.assertEqual(self.click("Halcyon", "Timer done", "tea"), 1)
        self.assertEqual(self.calls, [])

    def test_browser_notification_focuses_the_browser(self):
        self.assertEqual(self.click("Firefox", "New message", "from Sam", entry="firefox.desktop"), 0)
        self.assertEqual(self.calls, [("focus", "Firefox", "firefox.desktop")])

    def test_app_with_its_own_default_action_is_still_focused(self):
        self.assertEqual(self.click("Google Chrome", "Mail", "", mode="focus"), 0)
        self.assertEqual(self.calls, [("focus", "Google Chrome", "")])


if __name__ == "__main__":
    unittest.main()
