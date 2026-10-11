"""Native initial-visibility and child-lifetime checks on an unshown desktop.

Usage: python scripts/test-windows-preload.py path/to/gamenight-daemon.exe
No game or window is launched on the user's desktop.
"""
import ctypes as C
from ctypes import wintypes as W
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time


def configure():
    kernel, user = C.windll.kernel32, C.windll.user32
    for name in ["OpenProcess", "GetModuleHandleW"]:
        getattr(kernel, name).restype = W.HANDLE
    kernel.OpenProcess.argtypes = [W.DWORD, W.BOOL, W.DWORD]
    kernel.TerminateProcess.argtypes = [W.HANDLE, W.UINT]
    kernel.WaitForSingleObject.argtypes = [W.HANDLE, W.DWORD]
    kernel.GetExitCodeProcess.argtypes = [W.HANDLE, C.POINTER(W.DWORD)]
    kernel.CloseHandle.argtypes = [W.HANDLE]
    user.CreateDesktopW.restype = W.HANDLE
    user.CreateDesktopW.argtypes = [W.LPCWSTR, W.LPCWSTR, C.c_void_p, W.DWORD, W.DWORD, C.c_void_p]
    user.CloseDesktop.argtypes = [W.HANDLE]
    user.CreateWindowExW.restype = W.HWND
    user.CreateWindowExW.argtypes = [W.DWORD, W.LPCWSTR, W.LPCWSTR, W.DWORD,
        C.c_int, C.c_int, C.c_int, C.c_int, W.HWND, W.HMENU, W.HINSTANCE, C.c_void_p]
    user.ShowWindow.argtypes = [W.HWND, C.c_int]
    user.IsWindowVisible.argtypes = [W.HWND]
    user.DestroyWindow.argtypes = [W.HWND]
    return kernel, user


def wait_for(predicate, timeout=15):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        result = predicate()
        if result:
            return result
        time.sleep(0.02)
    raise AssertionError("Fixture timed out")


def worker(folder):
    kernel, user = configure()
    window = user.CreateWindowExW(0, "STATIC", "GameNight preload fixture", 0x00CF0000,
        20, 20, 320, 200, None, None, kernel.GetModuleHandleW(None), None)
    assert window
    user.ShowWindow(window, 5)  # First normal show must obey the inherited SW_HIDE.
    first = bool(user.IsWindowVisible(window))
    (folder / "initial.json").write_text(json.dumps({"visible": first, "pid": os.getpid(),
        "args": sys.argv[3:], "marker": os.environ.get("GN_PRELOAD_TEST"), "cwd": os.getcwd()}))
    wait_for(lambda: (folder / "start").exists())
    user.ShowWindow(window, 5)  # An explicit lifecycle start must still be able to show.
    (folder / "started.json").write_text(json.dumps({"visible": bool(user.IsWindowVisible(window))}))
    print("child stdout preserved", flush=True)
    if (folder / "kill-test").exists():
        grandchild = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)"],
            creationflags=subprocess.CREATE_NO_WINDOW)
        (folder / "grandchild.pid").write_text(str(grandchild.pid))
        time.sleep(60)
    user.DestroyWindow(window)
    raise SystemExit(37)


class Startup(C.Structure):
    _fields_ = [("cb", W.DWORD), ("reserved", W.LPWSTR), ("desktop", W.LPWSTR),
        ("title", W.LPWSTR), ("x", W.DWORD), ("y", W.DWORD), ("cx", W.DWORD),
        ("cy", W.DWORD), ("chars_x", W.DWORD), ("chars_y", W.DWORD),
        ("fill", W.DWORD), ("flags", W.DWORD), ("show", W.WORD),
        ("reserved_bytes", W.WORD), ("reserved_ptr", C.c_void_p),
        ("stdin", W.HANDLE), ("stdout", W.HANDLE), ("stderr", W.HANDLE)]


class Process(C.Structure):
    _fields_ = [("process", W.HANDLE), ("thread", W.HANDLE), ("pid", W.DWORD), ("tid", W.DWORD)]


def main(binary):
    import msvcrt
    kernel, user = configure()
    kernel.CreateProcessW.argtypes = [W.LPCWSTR, W.LPWSTR, C.c_void_p, C.c_void_p,
        W.BOOL, W.DWORD, C.c_void_p, W.LPCWSTR, C.POINTER(Startup), C.POINTER(Process)]
    name = "gamenight-preload-" + str(time.time_ns())
    desktop = user.CreateDesktopW(name, None, None, 0, 0x01FF, None)
    assert desktop, "Cannot create isolated desktop"
    os.environ["GN_PRELOAD_TEST"] = "environment preserved"
    try:
        with tempfile.TemporaryDirectory(prefix="gamenight-preload-") as temporary:
            root = Path(temporary)
            for kill in [False, True]:
                folder = root / ("kill" if kill else "exit")
                folder.mkdir()
                if kill: (folder / "kill-test").touch()
                args = ["", "two words", 'literal"quote', "trailing\\", "雪 & $HOME"]
                command = [str(Path(binary).resolve()), "--launch-hidden", sys.executable,
                    str(Path(__file__).resolve()), "--worker", str(folder), *args]
                with (folder / "stdout.log").open("w+") as output, open(os.devnull) as input_file:
                    stdin, stdout = msvcrt.get_osfhandle(input_file.fileno()), msvcrt.get_osfhandle(output.fileno())
                    os.set_handle_inheritable(stdin, True)
                    os.set_handle_inheritable(stdout, True)
                    startup = Startup()
                    startup.cb = C.sizeof(startup)
                    startup.desktop = name
                    startup.flags = 0x0100  # STARTF_USESTDHANDLES
                    startup.stdin, startup.stdout, startup.stderr = stdin, stdout, stdout
                    process = Process()
                    assert kernel.CreateProcessW(None, C.create_unicode_buffer(subprocess.list2cmdline(command)),
                        None, None, True, 0x08000000, None, str(folder), C.byref(startup), C.byref(process))
                    kernel.CloseHandle(process.thread)
                    worker_process = None
                    try:
                        wait_for(lambda: (folder / "initial.json").exists())
                        initial = json.loads((folder / "initial.json").read_text())
                        worker_process = kernel.OpenProcess(0x00100000, False, initial["pid"])
                        assert worker_process
                        assert not initial["visible"], initial
                        assert initial["args"] == args, initial
                        assert initial["marker"] == "environment preserved"
                        assert Path(initial["cwd"]) == folder
                        (folder / "start").touch()
                        wait_for(lambda: (folder / "started.json").exists())
                        assert json.loads((folder / "started.json").read_text())["visible"]
                        if kill:
                            wait_for(lambda: (folder / "grandchild.pid").exists())
                            descendant = kernel.OpenProcess(0x00100000, False, int((folder / "grandchild.pid").read_text()))
                            assert descendant
                            try:
                                kernel.TerminateProcess(process.process, 1)
                                assert kernel.WaitForSingleObject(descendant, 5000) == 0, "Orphaned descendant"
                            finally:
                                kernel.CloseHandle(descendant)
                        else:
                            assert kernel.WaitForSingleObject(process.process, 5000) == 0
                            code = W.DWORD()
                            assert kernel.GetExitCodeProcess(process.process, C.byref(code))
                            assert code.value == 37, code.value
                        output.seek(0)
                        assert "child stdout preserved" in output.read()
                    finally:
                        kernel.TerminateProcess(process.process, 1)
                        kernel.WaitForSingleObject(process.process, 5000)
                        kernel.CloseHandle(process.process)
                        if worker_process:
                            # Job termination is asynchronous: the helper may
                            # exit before the worker releases inherited logs.
                            assert kernel.WaitForSingleObject(worker_process, 5000) == 0
                            kernel.CloseHandle(worker_process)
        print("PASS: hidden first show, explicit start, arguments/env/cwd/stdout, exit code and descendant cleanup")
    finally:
        user.CloseDesktop(desktop)


if __name__ == "__main__":
    if sys.argv[1] == "--worker": worker(Path(sys.argv[2]))
    else: main(sys.argv[1])
