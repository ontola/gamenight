using System;
using System.Collections;
using System.Runtime.InteropServices;
using UnityEngine;

namespace GameNightSdk
{
    /// <summary>
    /// Screen manners for a GameNight session: who is on the TV, and how much of
    /// the machine a game may use while nobody is looking at it. Added next to
    /// <see cref="GameNight"/> and inert unless GameNight launched the process.
    /// Left alone it needs no code: it goes quiet at boot (muted, off-screen),
    /// throttles once you report Ready, takes the screen on Start and Resume
    /// (borderless fullscreen, sound on) and gets out of the way on Pause and
    /// Dispose. Your own Paused handler must still freeze the simulation.
    ///
    /// Set <see cref="Automatic"/> to false to drive it yourself with
    /// <see cref="GoQuiet"/>, <see cref="Settle"/> and <see cref="TakeTheScreen"/>.
    /// </summary>
    [DisallowMultipleComponent]
    public sealed class GameNightScreen : MonoBehaviour
    {
        /// <summary>Follow the session lifecycle without being asked.</summary>
        public bool Automatic = true;
        /// <summary>Frames per second once warm and loaded: enough to answer the host, no core spent on a still image.</summary>
        public int WarmMaxFps = 10;

        const float RetrySeconds = 0.25f;
        const float OffScreenDeadline = 8f;

        int _epoch;
        bool _screenOwned;
        bool _throttled;
        int _fpsBefore = -1;
        int _vsyncBefore = 1;
        float _volumeBefore = 1f;
        bool _muted;

        void Start()
        {
            var gn = GameNight.Client;
            if (!gn.LaunchedByHost || !Automatic) return;
            GoQuiet("warm");
            // Reporting Ready is the moment loading ends, not one frame before.
            gn.ReadySent += _ => Settle();
            gn.Started += _ => TakeTheScreen("start");
            gn.Resumed += _ => TakeTheScreen("resume");
            gn.Paused += _ => GoQuiet("pause");
            gn.Disposed += _ => GoQuiet("dispose");
        }

        /// <summary>Get off the screen and mute. Not a frame cap: warming is loading, and loading needs those frames.</summary>
        public void GoQuiet(string why = "warm")
        {
            Debug.Log($"[gamenight][{GameNight.Client.GameId}] {why}: muted and off-screen until start");
            // Grant before minimising: afterwards this process can no longer hand the foreground to the lobby.
            if (why == "pause" && _screenOwned && Application.isFocused) NativeWindow.AllowLobbyForeground();
            _screenOwned = false;
            if (!_muted)
            {
                _volumeBefore = AudioListener.volume;
                _muted = true;
            }
            AudioListener.volume = 0f;
            Unthrottle();
            _epoch++;
            StartCoroutine(LeaveTheScreen(_epoch, why == "warm"));
        }

        /// <summary>Loaded, and nobody watching yet: stop spending a core on it. Only after Ready.</summary>
        public void Settle()
        {
            if (_throttled) return;
            _throttled = true;
            _fpsBefore = Application.targetFrameRate;
            _vsyncBefore = QualitySettings.vSyncCount;
            // vSync overrides targetFrameRate, so it has to go while warm.
            QualitySettings.vSyncCount = 0;
            Application.targetFrameRate = WarmMaxFps;
        }

        /// <summary>Back to the frame budget the player's own settings asked for.</summary>
        public void Unthrottle()
        {
            if (!_throttled) return;
            _throttled = false;
            QualitySettings.vSyncCount = _vsyncBefore;
            Application.targetFrameRate = _fpsBefore;
        }

        /// <summary>We are the game being played: full speed, sound on, screen ours.</summary>
        public void TakeTheScreen(string why = "start")
        {
            Debug.Log($"[gamenight][{GameNight.Client.GameId}] {why}: taking the screen");
            if (_muted) AudioListener.volume = _volumeBefore;
            _muted = false;
            Unthrottle();
            _epoch++;
            _screenOwned = true;
            StartCoroutine(ClaimTheScreen(_epoch));
        }

        /// <summary>Asked again until it takes: a window that is still being created, or
        /// still animating, drops requests. Whoever bumped the epoch last wins.</summary>
        IEnumerator LeaveTheScreen(int epoch, bool warm)
        {
            if (Application.isBatchMode) yield break;
            if (warm) NativeWindow.Park();
            var deadline = Time.realtimeSinceStartup + OffScreenDeadline;
            while (epoch == _epoch)
            {
                if (NativeWindow.IsHidden()) yield break;
                if (Time.realtimeSinceStartup >= deadline)
                {
                    // The window server refused; the lobby must still end up in front.
                    Debug.Log($"[gamenight][{GameNight.Client.GameId}] could not minimise; parking the window off-screen");
                    NativeWindow.Park();
                    yield break;
                }
                NativeWindow.Hide();
                yield return new WaitForSecondsRealtime(RetrySeconds);
            }
        }

        IEnumerator ClaimTheScreen(int epoch)
        {
            if (Application.isBatchMode) yield break;
            var deadline = Time.realtimeSinceStartup + OffScreenDeadline;
            while (epoch == _epoch && Time.realtimeSinceStartup < deadline)
            {
                NativeWindow.Show();
                // Borderless fullscreen, never exclusive: no display-mode switch
                // between games, and on macOS no separate Space the party can't leave.
                if (Screen.fullScreenMode != FullScreenMode.FullScreenWindow)
                {
                    var display = Screen.mainWindowDisplayInfo;
                    Screen.SetResolution(display.width, display.height, FullScreenMode.FullScreenWindow);
                }
                yield return new WaitForSecondsRealtime(RetrySeconds);
                if ((!NativeWindow.Supported || !NativeWindow.IsHidden()) && Screen.fullScreenMode == FullScreenMode.FullScreenWindow)
                {
                    NativeWindow.Show();
                    yield break;
                }
            }
        }
    }

    /// <summary>The bits of window handling Unity has no API for.</summary>
    static class NativeWindow
    {
#if UNITY_STANDALONE_WIN && !UNITY_EDITOR
        const int SW_SHOWMINNOACTIVE = 7;
        const int SW_RESTORE = 9;
        const uint SWP_NOSIZE = 0x0001, SWP_NOZORDER = 0x0004, SWP_NOACTIVATE = 0x0010;
        public static readonly bool Supported = true;
        static IntPtr _hwnd;

        [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr hwnd, int cmd);
        [DllImport("user32.dll")] static extern bool IsIconic(IntPtr hwnd);
        [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr hwnd);
        [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr hwnd, IntPtr after, int x, int y, int w, int h, uint flags);
        [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr FindWindowEx(IntPtr parent, IntPtr after, string cls, string title);

        static IntPtr Handle()
        {
            if (_hwnd != IntPtr.Zero) return _hwnd;
            var pid = (uint)System.Diagnostics.Process.GetCurrentProcess().Id;
            var hwnd = IntPtr.Zero;
            while ((hwnd = FindWindowEx(IntPtr.Zero, hwnd, "UnityWndClass", null)) != IntPtr.Zero)
            {
                GetWindowThreadProcessId(hwnd, out var owner);
                if (owner == pid) return _hwnd = hwnd;
            }
            return IntPtr.Zero;
        }

        public static bool IsHidden() { var h = Handle(); return h == IntPtr.Zero || IsIconic(h); }
        public static void Hide() { var h = Handle(); if (h != IntPtr.Zero) ShowWindow(h, SW_SHOWMINNOACTIVE); }
        public static void Park() { var h = Handle(); if (h != IntPtr.Zero) SetWindowPos(h, IntPtr.Zero, -30000, -30000, 0, 0, SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE); }
        public static void Show()
        {
            var h = Handle();
            if (h == IntPtr.Zero) return;
            if (IsIconic(h)) ShowWindow(h, SW_RESTORE);
            SetForegroundWindow(h);
        }

        /// <summary>Windows only lets the foreground process hand the foreground on; the host ships a helper for it.</summary>
        public static void AllowLobbyForeground()
        {
            var helper = Environment.GetEnvironmentVariable("GAMENIGHT_FOREGROUND_HELPER");
            if (string.IsNullOrEmpty(helper) || !System.IO.File.Exists(helper)) return;
            try
            {
                using (var p = System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(helper, "--allow-foreground") { UseShellExecute = false, CreateNoWindow = true }))
                    p?.WaitForExit(2000);
            }
            catch (Exception e) { Debug.LogWarning("GameNight: foreground helper failed: " + e.Message); }
        }
#elif UNITY_STANDALONE_OSX && !UNITY_EDITOR
        // [NSApp hide:nil] and [NSApp unhide:nil] through the Objective-C runtime.
        public static readonly bool Supported = true;
        const string ObjC = "/usr/lib/libobjc.A.dylib";
        [DllImport(ObjC)] static extern IntPtr objc_getClass(string name);
        [DllImport(ObjC)] static extern IntPtr sel_registerName(string name);
        [DllImport(ObjC, EntryPoint = "objc_msgSend")] static extern IntPtr Send(IntPtr target, IntPtr selector);
        [DllImport(ObjC, EntryPoint = "objc_msgSend")] static extern IntPtr Send(IntPtr target, IntPtr selector, IntPtr arg);
        [DllImport(ObjC, EntryPoint = "objc_msgSend")] static extern bool SendBool(IntPtr target, IntPtr selector);
        [DllImport(ObjC, EntryPoint = "objc_msgSend")] static extern void SendFlag(IntPtr target, IntPtr selector, bool flag);

        static IntPtr App() => Send(objc_getClass("NSApplication"), sel_registerName("sharedApplication"));
        public static bool IsHidden() => SendBool(App(), sel_registerName("isHidden"));
        public static void Hide() => Send(App(), sel_registerName("hide:"), IntPtr.Zero);
        public static void Park() => Hide();
        public static void Show()
        {
            var app = App();
            Send(app, sel_registerName("unhide:"), IntPtr.Zero);
            SendFlag(app, sel_registerName("activateIgnoringOtherApps:"), true);
        }
        public static void AllowLobbyForeground() { }
#else
        // Linux and the editor: no portable hide. Muting and throttling still apply.
        public static readonly bool Supported = false;
        public static bool IsHidden() => true;
        public static void Hide() { }
        public static void Park() { }
        public static void Show() { }
        public static void AllowLobbyForeground() { }
#endif
    }
}
