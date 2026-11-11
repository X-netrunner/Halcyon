//! Minimal `sd_notify` implementation (no libsystemd dependency).
//!
//! Talks to `$NOTIFY_SOCKET` (a Unix datagram socket, possibly in the
//! abstract namespace) directly through libc. If the variable is absent —
//! not running under systemd — every call is a silent no-op so the daemon
//! also works when started by hand or by the GUI.

use std::ffi::CString;
use std::os::unix::ffi::OsStrExt;

/// Send `READY=1` so systemd knows the socket is up.
pub fn notify_ready() {
    send("READY=1");
}

/// Send `WATCHDOG=1`. Call more often than `WatchdogSec/2`.
pub fn notify_watchdog() {
    send("WATCHDOG=1");
}

/// Tell systemd the main PID (relevant when the GUI spawns the daemon).
pub fn notify_main_pid() {
    let pid = std::process::id();
    send(&format!("MAINPID={pid}"));
}

fn send(msg: &str) {
    let Some(sock_var) = std::env::var_os("NOTIFY_SOCKET") else {
        return;
    };
    let addr_os = std::ffi::OsStr::new(&sock_var);
    let bytes = addr_os.as_bytes();

    // systemd uses an abstract socket when the path starts with '@'.
    let (addr, addr_len): (Vec<u8>, libc::socklen_t) = if let Some(rest) = bytes
        .first()
        .filter(|b| **b == b'@')
        .and_then(|_| bytes.get(1..))
    {
        let mut raw = vec![0u8; 1 + rest.len()]; // leading NUL = abstract
        if let Some(dst) = raw.get_mut(1..) {
            dst.copy_from_slice(rest);
        }
        let len = raw.len() as libc::socklen_t;
        (raw, len)
    } else {
        let mut raw = Vec::from(bytes);
        raw.push(0); // NUL terminator for filesystem paths
        let len = raw.len() as libc::socklen_t;
        (raw, len)
    };

    let c_msg = match CString::new(msg) {
        Ok(m) => m,
        Err(_) => return,
    };

    unsafe {
        let fd = libc::socket(libc::AF_UNIX, libc::SOCK_DGRAM | libc::SOCK_CLOEXEC, 0);
        if fd < 0 {
            return;
        }
        let mut sa: libc::sockaddr_un = std::mem::zeroed();
        sa.sun_family = libc::AF_UNIX as libc::sa_family_t;
        let copy_len = addr.len().min(std::mem::size_of_val(&sa.sun_path));
        std::ptr::copy_nonoverlapping(addr.as_ptr(), sa.sun_path.as_mut_ptr() as *mut u8, copy_len);
        libc::sendto(
            fd,
            c_msg.as_ptr() as *const libc::c_void,
            c_msg.as_bytes().len(),
            0,
            &sa as *const libc::sockaddr_un as *const libc::sockaddr,
            addr_len + 2, // + family field offset
        );
        libc::close(fd);
    }
}
