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

pub struct Updates {
    manager: Option<velopack::UpdateManager>,
    worker: Option<std::thread::JoinHandle<()>>,
    log: PathBuf,
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
        let log = data.join("updater.log");
        let manager = match velopack::UpdateManager::new(source, None, None) {
            Ok(manager) if !manager.get_is_portable() => Some(manager),
            Ok(_) => None,
            Err(error) => {
                append_log(&log, &format!("Portable/uninstalled build: {error}"));
                None
            }
        };
        let worker = manager.clone().map(|manager| {
            let log = log.clone();
            std::thread::spawn(move || {
                let result = (|| -> Result<(), velopack::Error> {
                    if let velopack::UpdateCheck::UpdateAvailable(update) =
                        manager.check_for_updates()?
                    {
                        manager.download_updates(&update, None)?;
                        append_log(&log, "Update downloaded; waiting for GameNight to close.");
                    }
                    Ok(())
                })();
                if let Err(error) = result {
                    append_log(&log, &format!("Update check/download skipped: {error}"));
                }
            })
        });
        Self {
            manager,
            worker,
            log,
        }
    }
    /// Call only after all application children have stopped. Never block exit on networking.
    pub fn apply_on_exit(self) {
        if self
            .worker
            .as_ref()
            .is_some_and(|worker| !worker.is_finished())
        {
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
