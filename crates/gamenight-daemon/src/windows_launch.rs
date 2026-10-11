//! Initial Windows visibility for warm games, before their SDK can run.
//! The helper stays alive as the child's lifetime owner; it never hides or
//! refocuses a window after launch. Engines still own their start/resume policy.
use std::{ffi::OsString, io, mem::size_of, os::windows::ffi::OsStrExt, ptr};
use windows_sys::Win32::{
    Foundation::{CloseHandle, HANDLE, INVALID_HANDLE_VALUE, WAIT_OBJECT_0},
    System::{
        Console::{GetStdHandle, STD_ERROR_HANDLE, STD_INPUT_HANDLE, STD_OUTPUT_HANDLE},
        JobObjects::{
            AssignProcessToJobObject, CreateJobObjectW, JobObjectExtendedLimitInformation,
            SetInformationJobObject, JOBOBJECT_EXTENDED_LIMIT_INFORMATION,
            JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE,
        },
        Threading::{
            CreateProcessW, GetExitCodeProcess, ResumeThread, TerminateProcess,
            WaitForSingleObject, CREATE_NO_WINDOW, CREATE_SUSPENDED, INFINITE, PROCESS_INFORMATION,
            STARTF_USESHOWWINDOW, STARTF_USESTDHANDLES, STARTUPINFOW,
        },
    },
    UI::WindowsAndMessaging::SW_HIDE,
};

struct Handle(HANDLE);
impl Drop for Handle {
    fn drop(&mut self) {
        unsafe { CloseHandle(self.0) };
    }
}

// Windows CRT quoting: preserve empty arguments, quotes, Unicode and trailing
// backslashes. No shell is involved, so metacharacters remain literal.
fn command_line(args: &[OsString]) -> io::Result<Vec<u16>> {
    let mut out = Vec::new();
    for (index, arg) in args.iter().enumerate() {
        if index != 0 {
            out.push(b' ' as u16);
        }
        out.push(b'"' as u16);
        let mut slashes = 0;
        for unit in arg.encode_wide() {
            if unit == 0 {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidInput,
                    "NUL in launch argument",
                ));
            }
            if unit == b'\\' as u16 {
                slashes += 1;
                continue;
            }
            out.extend(std::iter::repeat_n(
                b'\\' as u16,
                slashes * if unit == b'"' as u16 { 2 } else { 1 },
            ));
            slashes = 0;
            if unit == b'"' as u16 {
                out.push(b'\\' as u16);
            }
            out.push(unit);
        }
        out.extend(std::iter::repeat_n(b'\\' as u16, slashes * 2));
        out.push(b'"' as u16);
    }
    out.push(0);
    Ok(out)
}

pub fn run(args: Vec<OsString>) -> io::Result<u32> {
    if args.first().is_none_or(|arg| arg.is_empty()) {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "Missing game executable",
        ));
    }
    let mut line = command_line(&args)?;
    unsafe {
        let job = CreateJobObjectW(ptr::null(), ptr::null());
        if job.is_null() {
            return Err(io::Error::last_os_error());
        }
        let _job = Handle(job);
        let mut limits: JOBOBJECT_EXTENDED_LIMIT_INFORMATION = std::mem::zeroed();
        limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        if SetInformationJobObject(
            job,
            JobObjectExtendedLimitInformation,
            &limits as *const _ as _,
            size_of_val(&limits) as u32,
        ) == 0
        {
            return Err(io::Error::last_os_error());
        }
        let mut startup: STARTUPINFOW = std::mem::zeroed();
        startup.cb = size_of::<STARTUPINFOW>() as u32;
        startup.dwFlags = STARTF_USESHOWWINDOW;
        startup.wShowWindow = SW_HIDE as u16;
        let handles = [
            GetStdHandle(STD_INPUT_HANDLE),
            GetStdHandle(STD_OUTPUT_HANDLE),
            GetStdHandle(STD_ERROR_HANDLE),
        ];
        if handles
            .iter()
            .all(|h| !h.is_null() && *h != INVALID_HANDLE_VALUE)
        {
            startup.dwFlags |= STARTF_USESTDHANDLES;
            [startup.hStdInput, startup.hStdOutput, startup.hStdError] = handles;
        }
        let mut process: PROCESS_INFORMATION = std::mem::zeroed();
        if CreateProcessW(
            ptr::null(),
            line.as_mut_ptr(),
            ptr::null(),
            ptr::null(),
            1,
            CREATE_NO_WINDOW | CREATE_SUSPENDED,
            ptr::null(),
            ptr::null(),
            &startup,
            &mut process,
        ) == 0
        {
            return Err(io::Error::last_os_error());
        }
        let _process = Handle(process.hProcess);
        let _thread = Handle(process.hThread);
        if AssignProcessToJobObject(job, process.hProcess) == 0 {
            let error = io::Error::last_os_error();
            TerminateProcess(process.hProcess, 1);
            return Err(error);
        }
        if ResumeThread(process.hThread) == u32::MAX {
            return Err(io::Error::last_os_error());
        }
        if WaitForSingleObject(process.hProcess, INFINITE) != WAIT_OBJECT_0 {
            return Err(io::Error::last_os_error());
        }
        let mut code = 1;
        if GetExitCodeProcess(process.hProcess, &mut code) == 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(code)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn quotes_arguments_without_a_shell() {
        let args: Vec<_> = [
            "C:\\game dir\\game.exe",
            "",
            "two words",
            "quote\"inside",
            "trailing\\",
            "雪 & $HOME",
        ]
        .into_iter()
        .map(OsString::from)
        .collect();
        let line = command_line(&args).unwrap();
        assert_eq!(String::from_utf16_lossy(&line[..line.len()-1]), "\"C:\\game dir\\game.exe\" \"\" \"two words\" \"quote\\\"inside\" \"trailing\\\\\" \"雪 & $HOME\"");
        assert!(command_line(&[OsString::from("bad\0arg")]).is_err());
    }
}
