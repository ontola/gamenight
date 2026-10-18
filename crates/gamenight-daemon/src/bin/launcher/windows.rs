use std::{
    fs::OpenOptions,
    io::{self, Write},
    os::windows::io::AsRawHandle,
    path::{Path, PathBuf},
    process::Child,
};
use windows_sys::Win32::{
    Foundation::{CloseHandle, HANDLE},
    System::JobObjects::{
        AssignProcessToJobObject, CreateJobObjectW, JobObjectBasicAccountingInformation,
        JobObjectExtendedLimitInformation, QueryInformationJobObject, SetInformationJobObject,
        TerminateJobObject, JOBOBJECT_BASIC_ACCOUNTING_INFORMATION,
        JOBOBJECT_EXTENDED_LIMIT_INFORMATION, JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE,
    },
};

/// Own all descendants, including games that outlive their immediate parent.
pub struct ProcessTree(HANDLE);
impl ProcessTree {
    pub fn attach(child: &Child) -> io::Result<Self> {
        // SAFETY: null security/name pointers request an unnamed, private job.
        let handle = unsafe { CreateJobObjectW(std::ptr::null(), std::ptr::null()) };
        if handle.is_null() {
            return Err(io::Error::last_os_error());
        }
        let job = Self(handle);
        let mut limits: JOBOBJECT_EXTENDED_LIMIT_INFORMATION = unsafe { std::mem::zeroed() };
        limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        // SAFETY: the live job and Child own these handles; the structure size matches its class.
        if unsafe {
            SetInformationJobObject(
                handle,
                JobObjectExtendedLimitInformation,
                &limits as *const _ as *const _,
                std::mem::size_of_val(&limits) as u32,
            )
        } == 0
        {
            return Err(io::Error::last_os_error());
        }
        if unsafe { AssignProcessToJobObject(handle, child.as_raw_handle() as HANDLE) } == 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(job)
    }
    pub fn close(self) -> io::Result<()> {
        // Termination is asynchronous. Wait for every descendant before handing off to Update.exe.
        if unsafe { TerminateJobObject(self.0, 0) } == 0 {
            return Err(io::Error::last_os_error());
        }
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
        loop {
            let mut accounting: JOBOBJECT_BASIC_ACCOUNTING_INFORMATION =
                unsafe { std::mem::zeroed() };
            if unsafe {
                QueryInformationJobObject(
                    self.0,
                    JobObjectBasicAccountingInformation,
                    &mut accounting as *mut _ as *mut _,
                    std::mem::size_of_val(&accounting) as u32,
                    std::ptr::null_mut(),
                )
            } == 0
            {
                return Err(io::Error::last_os_error());
            }
            if accounting.ActiveProcesses == 0 {
                return Ok(());
            }
            if std::time::Instant::now() >= deadline {
                return Err(io::Error::other(
                    "Games are still closing; update postponed",
                ));
            }
            std::thread::sleep(std::time::Duration::from_millis(50));
        }
    }
}
impl Drop for ProcessTree {
    fn drop(&mut self) {
        unsafe {
            CloseHandle(self.0);
        }
    }
}

/// A party PC can keep GameNight open for days, so look again now and then.
const RECHECK: std::time::Duration = std::time::Duration::from_secs(30 * 60);

/// Files the launcher shares with the daemon for in-place updates; see
/// `gamenight_daemon::HostUpdate`.
pub struct UpdateFiles {
    pub ready: PathBuf,
    pub resume: PathBuf,
    pub splash: PathBuf,
}
impl UpdateFiles {
    pub fn new(data: &Path) -> Self {
        Self {
            ready: data.join("update-ready.json"),
            resume: data.join("resume.json"),
            splash: data.join("update-splash.flag"),
        }
    }
}

pub struct Updates {
    manager: Option<velopack::UpdateManager>,
    /// True while a check or download is running; never block exit on it.
    busy: std::sync::Arc<std::sync::atomic::AtomicBool>,
    stop: std::sync::Arc<std::sync::atomic::AtomicBool>,
    log: PathBuf,
    files: UpdateFiles,
}
impl Updates {
    pub fn start(data: &Path) -> Self {
        // No token in the client. The installed manifest chooses stable or preview;
        // including GitHub prereleases cannot switch a stable install's channel.
        let source =
            velopack::sources::GithubSource::new("https://github.com/ontola/gamenight", None, true);
        Self::with_source(data, source)
    }
    pub fn with_source(
        data: &Path,
        source: impl velopack::sources::UpdateSource + 'static,
    ) -> Self {
        use std::sync::{atomic::AtomicBool, atomic::Ordering, Arc};
        let log = data.join("updater.log");
        let files = UpdateFiles::new(data);
        // Readiness is re-established by this session's check, never inherited.
        let _ = std::fs::remove_file(&files.ready);
        let manager = match velopack::UpdateManager::new(source, None, None) {
            Ok(manager) if !manager.get_is_portable() => Some(manager),
            Ok(_) => None,
            Err(error) => {
                append_log(&log, &format!("Portable/uninstalled build: {error}"));
                None
            }
        };
        let busy = Arc::new(AtomicBool::new(manager.is_some()));
        let stop = Arc::new(AtomicBool::new(false));
        if let Some(manager) = manager.clone() {
            let (log, busy, stop) = (log.clone(), busy.clone(), stop.clone());
            let ready = files.ready.clone();
            std::thread::spawn(move || loop {
                busy.store(true, Ordering::SeqCst);
                let result = (|| -> Result<Option<String>, velopack::Error> {
                    if let velopack::UpdateCheck::UpdateAvailable(update) =
                        manager.check_for_updates()?
                    {
                        manager.download_updates(&update, None)?;
                        return Ok(Some(update.TargetFullRelease.Version.clone()));
                    }
                    Ok(None)
                })();
                // Clear before logging, so whoever reads the log may exit and apply.
                busy.store(false, Ordering::SeqCst);
                match result {
                    Ok(Some(version)) => {
                        // Tell the lobby, which offers a restart between games.
                        let note = serde_json::json!({ "version": version }).to_string();
                        let temporary = ready.with_extension("tmp");
                        if std::fs::write(&temporary, note).is_ok() {
                            let _ = std::fs::rename(&temporary, &ready);
                        }
                        append_log(
                            &log,
                            &format!(
                                "Update downloaded ({version}); waiting for GameNight to close."
                            ),
                        );
                        return;
                    }
                    Ok(None) => {}
                    Err(error) => {
                        append_log(&log, &format!("Update check/download skipped: {error}"))
                    }
                }
                let wake = std::time::Instant::now() + RECHECK;
                while std::time::Instant::now() < wake {
                    if stop.load(Ordering::SeqCst) {
                        return;
                    }
                    std::thread::sleep(std::time::Duration::from_secs(1));
                }
            });
        }
        Self {
            manager,
            busy,
            stop,
            log,
            files,
        }
    }
    pub fn files(&self) -> &UpdateFiles {
        &self.files
    }
    /// The daemon saved the party and stopped to update. Apply the update and
    /// start again, with a cover over the screen until the new lobby is up.
    /// Returns false when no update could be applied, so the caller restarts
    /// the current version itself.
    pub fn restart_into_update(self) -> bool {
        use std::sync::atomic::Ordering;
        self.stop.store(true, Ordering::SeqCst);
        let _ = std::fs::remove_file(&self.files.ready);
        let Some(manager) = self.manager else {
            return false;
        };
        let Some(update) = manager.get_update_pending_restart() else {
            append_log(&self.log, "Restart requested but no update is pending.");
            return false;
        };
        if let Err(error) = spawn_splash(&self.files.splash) {
            append_log(&self.log, &format!("Update cover unavailable: {error}"));
        }
        // Silent: the cover is the progress, and nobody is at a keyboard.
        match manager.wait_exit_then_apply_updates(update, true, true, Vec::<String>::new()) {
            Ok(()) => {
                append_log(&self.log, "Applying update and restarting with the party.");
                true
            }
            Err(error) => {
                append_log(&self.log, &format!("Could not apply update: {error}"));
                let _ = std::fs::remove_file(&self.files.splash);
                false
            }
        }
    }
    /// Call only after all application children have stopped. Never block exit on networking.
    pub fn apply_on_exit(self) {
        use std::sync::atomic::Ordering;
        self.stop.store(true, Ordering::SeqCst);
        if self.busy.load(Ordering::SeqCst) {
            append_log(
                &self.log,
                "Download still running; update deferred to a later session.",
            );
            return;
        }
        if let Some(manager) = self.manager {
            if let Some(update) = manager.get_update_pending_restart() {
                if let Err(error) = manager.apply_updates_and_exit(update) {
                    append_log(&self.log, &format!("Could not apply update: {error}"));
                }
            }
        }
    }
}
/// Run a copy of this executable from outside the install directory, which
/// the updater is about to replace, as a full-screen cover.
fn spawn_splash(flag: &Path) -> io::Result<()> {
    use std::os::windows::process::CommandExt;
    let exe = std::env::current_exe()?;
    let source = exe
        .parent()
        .ok_or_else(|| io::Error::other("No package directory"))?;
    let target = std::env::temp_dir().join("GameNightUpdateCover");
    std::fs::create_dir_all(&target)?;
    // The bundled C runtime travels along; the machine may not have one.
    for entry in std::fs::read_dir(source)? {
        let path = entry?.path();
        if path
            .extension()
            .is_some_and(|ext| ext.eq_ignore_ascii_case("dll"))
        {
            std::fs::copy(&path, target.join(path.file_name().unwrap()))?;
        }
    }
    let copy = target.join("GameNightUpdateCover.exe");
    std::fs::copy(&exe, &copy)?;
    std::fs::write(flag, b"updating")?;
    std::process::Command::new(copy)
        .arg("--update-cover")
        .arg(flag)
        .current_dir(&target)
        // DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP: outlive this launcher.
        .creation_flags(0x0000_0008 | 0x0000_0200)
        .spawn()?;
    Ok(())
}

static COVER_FLAG: std::sync::OnceLock<(PathBuf, std::time::Instant)> = std::sync::OnceLock::new();

/// A borderless black window over every screen saying GameNight is updating.
/// It goes when the new lobby removes `flag`, or after two minutes at most.
pub fn show_update_cover(flag: PathBuf) {
    use windows_sys::Win32::{
        Graphics::Gdi::{CreateSolidBrush, UpdateWindow},
        System::LibraryLoader::GetModuleHandleW,
        UI::WindowsAndMessaging::{
            AllowSetForegroundWindow, CreateWindowExW, DispatchMessageW, GetMessageW,
            GetSystemMetrics, RegisterClassW, SetForegroundWindow, SetTimer, ShowCursor,
            ShowWindow, TranslateMessage, ASFW_ANY, MSG, SM_CXVIRTUALSCREEN, SM_CYVIRTUALSCREEN,
            SM_XVIRTUALSCREEN, SM_YVIRTUALSCREEN, SW_SHOW, WNDCLASSW, WS_EX_TOOLWINDOW,
            WS_EX_TOPMOST, WS_POPUP, WS_VISIBLE,
        },
    };
    let _ = COVER_FLAG.set((flag, std::time::Instant::now()));
    let class: Vec<u16> = "GameNightUpdateCover\0".encode_utf16().collect();
    let title: Vec<u16> = "GameNight\0".encode_utf16().collect();
    unsafe {
        let instance = GetModuleHandleW(std::ptr::null());
        let mut window_class: WNDCLASSW = std::mem::zeroed();
        window_class.lpfnWndProc = Some(cover_proc);
        window_class.hInstance = instance;
        window_class.hbrBackground = CreateSolidBrush(COVER_BACKGROUND);
        window_class.lpszClassName = class.as_ptr();
        RegisterClassW(&window_class);
        let window = CreateWindowExW(
            WS_EX_TOPMOST | WS_EX_TOOLWINDOW,
            class.as_ptr(),
            title.as_ptr(),
            WS_POPUP | WS_VISIBLE,
            GetSystemMetrics(SM_XVIRTUALSCREEN),
            GetSystemMetrics(SM_YVIRTUALSCREEN),
            GetSystemMetrics(SM_CXVIRTUALSCREEN),
            GetSystemMetrics(SM_CYVIRTUALSCREEN),
            std::ptr::null_mut(),
            std::ptr::null_mut(),
            instance,
            std::ptr::null(),
        );
        if window.is_null() {
            return;
        }
        ShowWindow(window, SW_SHOW);
        UpdateWindow(window);
        SetForegroundWindow(window);
        ShowCursor(0);
        // We hold the foreground now; let the new lobby take it from us.
        AllowSetForegroundWindow(ASFW_ANY);
        SetTimer(window, 1, 250, None);
        let mut message: MSG = std::mem::zeroed();
        while GetMessageW(&mut message, std::ptr::null_mut(), 0, 0) > 0 {
            TranslateMessage(&message);
            DispatchMessageW(&message);
        }
    }
}

/// #0b0b12 as COLORREF (0x00BBGGRR), the lobby's own background.
const COVER_BACKGROUND: u32 = 0x0012_0b0b;

unsafe extern "system" fn cover_proc(
    window: windows_sys::Win32::Foundation::HWND,
    message: u32,
    wparam: windows_sys::Win32::Foundation::WPARAM,
    lparam: windows_sys::Win32::Foundation::LPARAM,
) -> windows_sys::Win32::Foundation::LRESULT {
    use windows_sys::Win32::{
        Foundation::RECT,
        Graphics::Gdi::{
            BeginPaint, CreateFontW, DeleteObject, DrawTextW, EndPaint, SelectObject, SetBkMode,
            SetTextColor, DT_CENTER, DT_SINGLELINE, DT_VCENTER, PAINTSTRUCT, TRANSPARENT,
        },
        UI::WindowsAndMessaging::{
            DefWindowProcW, DestroyWindow, GetClientRect, GetSystemMetrics, PostQuitMessage,
            SM_CYSCREEN, WM_DESTROY, WM_PAINT, WM_TIMER,
        },
    };
    match message {
        WM_TIMER => {
            let done = COVER_FLAG.get().is_none_or(|(flag, started)| {
                !flag.exists() || started.elapsed() > std::time::Duration::from_secs(120)
            });
            if done {
                DestroyWindow(window);
            }
            0
        }
        WM_PAINT => {
            let mut paint: PAINTSTRUCT = std::mem::zeroed();
            let dc = BeginPaint(window, &mut paint);
            let mut rect: RECT = std::mem::zeroed();
            GetClientRect(window, &mut rect);
            let face: Vec<u16> = "Segoe UI\0".encode_utf16().collect();
            let font = CreateFontW(
                GetSystemMetrics(SM_CYSCREEN) / 18,
                0,
                0,
                0,
                600,
                0,
                0,
                0,
                0,
                0,
                0,
                5, // CLEARTYPE_QUALITY
                0,
                face.as_ptr(),
            );
            let previous = SelectObject(dc, font);
            SetBkMode(dc, TRANSPARENT as i32);
            SetTextColor(dc, 0x00f8_f1f2);
            let mut text: Vec<u16> = "Updating GameNight\u{2026}".encode_utf16().collect();
            DrawTextW(
                dc,
                text.as_mut_ptr(),
                text.len() as i32,
                &mut rect,
                DT_CENTER | DT_VCENTER | DT_SINGLELINE,
            );
            SelectObject(dc, previous);
            DeleteObject(font);
            EndPaint(window, &paint);
            0
        }
        WM_DESTROY => {
            PostQuitMessage(0);
            0
        }
        _ => DefWindowProcW(window, message, wparam, lparam),
    }
}

fn append_log(path: &Path, message: &str) {
    if let Ok(mut file) = OpenOptions::new().create(true).append(true).open(path) {
        let _ = writeln!(file, "{message}");
    }
}
pub fn show_error(message: &str) {
    use windows_sys::Win32::UI::WindowsAndMessaging::{MessageBoxW, MB_ICONERROR, MB_OK};
    let text: Vec<u16> = format!("GameNight could not start or close.\n\n{message}")
        .encode_utf16()
        .chain(Some(0))
        .collect();
    let title: Vec<u16> = "GameNight".encode_utf16().chain(Some(0)).collect();
    unsafe {
        MessageBoxW(
            std::ptr::null_mut(),
            text.as_ptr(),
            title.as_ptr(),
            MB_OK | MB_ICONERROR,
        );
    }
}
