//! Crash reports: a panic hook that writes a report (backtrace + the tail of
//! the log file) to the state dir before the supervisor restarts us.

use std::path::Path;
use std::sync::Once;

static INSTALL: Once = Once::new();

pub fn install(state_dir: &Path) {
    let dir = state_dir.to_path_buf();
    INSTALL.call_once(move || {
        let default_hook = std::panic::take_hook();
        std::panic::set_hook(Box::new(move |info| {
            // Still print to stderr for the journal.
            default_hook(info);
            write_crash_report(&dir, info);
        }));
    });
}

fn write_crash_report(state_dir: &Path, info: &std::panic::PanicHookInfo<'_>) {
    let ts = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let path = state_dir.join(format!("crash-{ts}.log"));
    let mut report = String::new();
    report.push_str("halcyon-musicd crash report\n");
    report.push_str(&format!("timestamp: {ts}\n"));
    report.push_str(&format!("panic: {info}\n"));
    report.push_str(&format!("backtrace:\n{}\n", std::backtrace::Backtrace::force_capture()));
    report.push_str("\n--- last log lines ---\n");
    report.push_str(&tail_of_log(state_dir, 200));

    // Best effort: never panic in the panic hook.
    if let Ok(mut f) = std::fs::File::create(&path) {
        use std::io::Write;
        let _ = f.write_all(report.as_bytes());
        let _ = f.sync_all();
    }
    eprintln!("crash report written to {}", path.display());
}

/// Read the newest `.log` file in the state dir and return its last `n` lines.
fn tail_of_log(state_dir: &Path, n: usize) -> String {
    let mut logs: Vec<_> = match std::fs::read_dir(state_dir) {
        Ok(rd) => rd
            .filter_map(|e| e.ok())
            .map(|e| e.path())
            .filter(|p| p.file_name().map(|n| n.to_string_lossy().starts_with("halcyon-musicd.log")).unwrap_or(false))
            .collect(),
        Err(_) => return String::new(),
    };
    logs.sort();
    let Some(newest) = logs.pop() else { return String::new() };
    let Ok(content) = std::fs::read_to_string(&newest) else { return String::new() };
    let lines: Vec<&str> = content.lines().collect();
    let start = lines.len().saturating_sub(n);
    lines.get(start..).unwrap_or(&[]).join("\n")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tail_returns_last_n_lines() {
        let dir = tempfile::tempdir().expect("tempdir");
        let mut long = String::new();
        for i in 0..300 {
            long.push_str(&format!("line {i}\n"));
        }
        std::fs::write(dir.path().join("halcyon-musicd.log"), long).expect("write log");
        let tail = tail_of_log(dir.path(), 200);
        let count = tail.lines().count();
        assert_eq!(count, 200);
        assert!(tail.contains("line 299"));
        assert!(!tail.contains("line 0"));
    }

    #[test]
    fn tail_handles_missing_log() {
        let dir = tempfile::tempdir().expect("tempdir");
        assert_eq!(tail_of_log(dir.path(), 200), "");
    }
}
