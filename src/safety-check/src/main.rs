use std::process::{Command, exit, Stdio};
use std::fs;
use std::io::{self, Write, BufRead, BufReader};
use chrono::Local;
use colored::*;
use std::path::Path;

/// Where the safety check keeps its logs. It runs as root, so this must be a root-owned folder: it used to be ~/logs of the user,
/// and a symlink planted there by any program of that user made root write (or create files) anywhere. /var/log/halcyon is made
/// by sysmode, or here; ~/logs points at it. Without root (nothing can be created in /var/log) it falls back to the user's own state folder.
fn log_dir_path() -> String {
    let sys = "/var/log/halcyon/safety_check";
    if fs::create_dir_all(sys).is_ok() {
        return sys.to_string();
    }
    let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".to_string());
    let own = format!("{}/.local/state/halcyon/safety_check", home);
    fs::create_dir_all(&own).ok();
    own
}

fn get_log_file_path() -> String {
    let today = Local::now().format("%Y-%m-%d").to_string();
    format!("{}/safety_check_{}.log", log_dir_path(), today)
}

fn strip_ansi(s: &str) -> String {
    let mut result = String::new();
    let mut in_escape = false;
    let mut in_bracket = false;
    for c in s.chars() {
        if in_escape {
            if c == '[' {
                in_bracket = true;
            } else if c.is_ascii_alphabetic() {
                in_escape = false;
            }
        } else if in_bracket {
            if c.is_ascii_alphabetic() {
                in_bracket = false;
                in_escape = false;
            }
        } else if c == '\x1B' {
            in_escape = true;
        } else {
            result.push(c);
        }
    }
    result
}

fn write_to_log(msg: &str) {
    let log_path = get_log_file_path();
    if let Some(log_dir) = Path::new(&log_path).parent() {
        fs::create_dir_all(log_dir).ok();
    }
    if let Ok(mut file) = fs::OpenOptions::new().create(true).append(true).open(&log_path) {
        let clean_msg = strip_ansi(msg);
        writeln!(file, "[{}] {}", Local::now().format("%H:%M:%S"), clean_msg).ok();
    }
}

fn notify(msg: &str, urgency: &str, real_user: &str) {
    if real_user == "root" {
        return;
    }
    let user_id_output = Command::new("id").args(["-u", real_user]).output();
    if let Ok(out) = user_id_output {
        let uid_str = String::from_utf8_lossy(&out.stdout).trim().to_string();
        let dbus_addr = format!("unix:path=/run/user/{}/bus", uid_str);
        Command::new("sudo")
            .args([
                "-u",
                real_user,
                "env",
                &format!("DBUS_SESSION_BUS_ADDRESS={}", dbus_addr),
                &format!("XDG_RUNTIME_DIR=/run/user/{}", uid_str),
                "notify-send",
                "Safety Check",
                msg,
                "--urgency",
                urgency,
            ])
            .status()
            .ok();
    }
}

fn main() {
    if !is_root() {
        eprintln!("{}", "Error: This script must be run with root privileges (sudo).".red());
        exit(1);
    }

    // --auto: started by the timer that Settings > Backup > Safety check > "Run it automatically" installs (nobody is there to
    // answer questions, so it never updates the system, never asks for a disk and never formats anything)
    let auto = std::env::args().any(|a| a == "--auto");

    let real_user = std::env::var("SUDO_USER").unwrap_or_else(|_| std::env::var("USER").unwrap_or_else(|_| "root".to_string()));
    let real_home = if real_user == "root" { "/root".to_string() } else { format!("/home/{}", real_user) };
    let log_dir = log_dir_path();

    let start_time = Local::now();
    let header = format!("═══════════════════════════════════════════════\n Safety Check started — {}\n Running as: {}\n═══════════════════════════════════════════════", start_time.format("%Y-%m-%d %H:%M:%S"), real_user);
    println!("{}", header.cyan());
    write_to_log(&header);

    let mut errors = 0;

    // 1. System Update
    section("1/7 — System Update");
    notify("1/7 — System Update", "normal", &real_user);
    if auto {
        log_warn("Automatic run: the system is not updated unattended (run the safety check by hand for that)");
    } else if command_exists("pacman") {
        if run_command("pacman", &["-Syu", "--noconfirm"]) {
            log_success("System updated successfully (pacman)");
        } else {
            log_error("System update failed");
            errors += 1;
        }
    } else if command_exists("apt-get") {
        if run_command("apt-get", &["update"]) && run_command("env", &["DEBIAN_FRONTEND=noninteractive", "apt-get", "upgrade", "-y"]) {
            log_success("System updated successfully (apt)");
        } else {
            log_error("System update failed");
            errors += 1;
        }
    } else {
        log_warn("No supported package manager (pacman / apt-get) found for automatic update");
    }

    // 2. ClamAV
    section("2/7 — ClamAV Malware Scan");
    notify("2/7 — ClamAV Malware Scan", "normal", &real_user);
    if command_exists("freshclam") {
        println!("↻ Updating ClamAV signatures...");
        run_command("freshclam", &[]);
    }
    if command_exists("clamscan") {
        let scan_dirs = [real_home.as_str(), "/etc", "/usr/bin", "/usr/local/bin", "/tmp", "/var/tmp"];
        println!("↻ Scanning: {:?}", scan_dirs);
        println!("{}", "  [EXEC] Running: clamscan -r --bell ...".bold().yellow());
        write_to_log("Running: clamscan -r --bell ...");
        
        let status = Command::new("clamscan")
            .arg("-r")
            .arg("--bell")
            .args(scan_dirs)
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .and_then(|mut child| {
                let stdout = child.stdout.take().expect("spawned with a pipe");
                let stderr = child.stderr.take().expect("spawned with a pipe");
                
                let stderr_handle = std::thread::spawn(move || {
                    let reader = BufReader::new(stderr);
                    for l in reader.lines().map_while(Result::ok) {
                        println!("    {} {}", "[STDERR]".red(), l);
                        write_to_log(&format!("[STDERR] {}", l));
                    }
                });

                let reader = BufReader::new(stdout);
                let mut infected = 0;
                for l in reader.lines().map_while(Result::ok) {
                    write_to_log(&l);
                    if l.contains("FOUND") {
                        println!("    {}", l.bold().red());
                    } else {
                        println!("    {}", l.dimmed());
                    }
                    if l.contains("Infected files:") {
                        if let Some(count_str) = l.split_whitespace().last() {
                            infected = count_str.parse::<i32>().unwrap_or(0);
                        }
                    }
                }
                let _ = stderr_handle.join();
                child.wait().map(|s| (s, infected))
            });

        match status {
            Ok((_, infected)) => {
                if infected == 0 {
                    log_success("No threats found by ClamAV");
                } else {
                    log_error(&format!("ClamAV found {} infected file(s)!", infected));
                    notify(&format!("⚠ ClamAV found {} infected file(s)!", infected), "critical", &real_user);
                    errors += 1;
                }
            }
            Err(_) => {
                log_error("Failed to run ClamAV scan");
                errors += 1;
            }
        }
    } else {
        log_warn("ClamAV not installed");
    }

    // 3. rkhunter
    section("3/7 — rkhunter Rootkit Check");
    notify("3/7 — rkhunter Rootkit Check", "normal", &real_user);
    if command_exists("rkhunter") {
        println!("↻ Updating rkhunter database...");
        run_command("rkhunter", &["--update"]);
        
        println!("↻ Running rkhunter rootkit check...");
        println!("{}", "  [EXEC] Running: rkhunter --check --sk".bold().yellow());
        write_to_log("Running: rkhunter --check --sk");
        
        let child = Command::new("rkhunter")
            .args(["--check", "--sk"])
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn();
            
        match child {
            Ok(mut child_proc) => {
                let stdout = child_proc.stdout.take().expect("spawned with a pipe");
                let stderr = child_proc.stderr.take().expect("spawned with a pipe");
                
                let stderr_handle = std::thread::spawn(move || {
                    let reader = BufReader::new(stderr);
                    for l in reader.lines().map_while(Result::ok) {
                        println!("    {} {}", "[STDERR]".red(), l);
                        write_to_log(&format!("rkhunter stderr: {}", l));
                    }
                });
                
                let reader = BufReader::new(stdout);
                let mut warn_count = 0;
                for l in reader.lines().map_while(Result::ok) {
                    write_to_log(&format!("rkhunter: {}", l));
                    if l.contains("Warning") {
                        warn_count += 1;
                        println!("    {}", l.bold().red());
                    } else {
                        println!("    {}", l.dimmed());
                    }
                }
                
                let _ = stderr_handle.join();
                let _status = child_proc.wait();
                
                if warn_count > 0 {
                    log_error(&format!("rkhunter found {} warning(s) — review logs", warn_count));
                    notify(&format!("⚠ rkhunter: {} warning(s) found", warn_count), "critical", &real_user);
                    errors += 1;
                } else {
                    log_success("No rootkits detected");
                }
            }
            Err(_) => {
                log_error("Failed to run rkhunter");
                errors += 1;
            }
        }
    } else {
        log_warn("rkhunter not installed");
    }

    // 4. Firewall
    section("4/7 — Firewall Status");
    notify("4/7 — Firewall Status", "normal", &real_user);
    // Halcyon's ai-firewall when it is installed (install.sh --firewall ai): its service conflicts with ufw's, so
    // "re-enabling" ufw here would switch ai-firewall off
    if std::path::Path::new("/usr/local/bin/ai-firewall").exists() {
        println!("{}", "  [EXEC] Running: systemctl is-active ai-firewall".bold().yellow());
        let active = Command::new("systemctl")
            .args(["is-active", "--quiet", "ai-firewall"])
            .status()
            .map(|s| s.success())
            .unwrap_or(false);
        let state = if active { "active" } else { "inactive" };
        println!("    {}", format!("Status: {state}").dimmed());
        write_to_log(&format!("ai-firewall status: Status: {state}"));
        if active {
            log_success("Firewall is active (ai-firewall)");
        } else {
            log_error("Firewall is INACTIVE. Starting ai-firewall...");
            notify("⚠ Firewall was OFF — restarting ai-firewall!", "critical", &real_user);
            run_command("systemctl", &["start", "ai-firewall"]);
        }
    } else if command_exists("ufw") {
        println!("{}", "  [EXEC] Running: ufw status".bold().yellow());
        let status = match Command::new("ufw").arg("status").output() {
            Ok(output) => String::from_utf8_lossy(&output.stdout).to_string(),
            Err(e) => {
                log_warn(&format!("Could not run ufw status: {}", e));
                String::new()
            }
        };
        println!("  Firewall Status output:");
        for line in status.lines() {
            println!("    {}", line.dimmed());
            write_to_log(&format!("ufw status: {}", line));
        }
        if status.contains("inactive") {
            log_error("Firewall is INACTIVE. Enabling...");
            notify("⚠ Firewall was OFF — re-enabling!", "critical", &real_user);
            run_command("ufw", &["enable"]);
        } else {
            log_success("Firewall is active");
        }
    } else {
        log_warn("No firewall installed (./install.sh --firewall ai, or ufw)");
    }

    // 5. Lynis
    section("5/7 — Lynis Security Audit");
    notify("5/7 — Lynis Security Audit", "normal", &real_user);
    if command_exists("lynis") {
        run_command("lynis", &["audit", "system", "--quick"]);
        log_success("Lynis audit complete");
    } else {
        log_warn("Lynis not installed");
    }

    // 6. AIDE
    section("6/7 — AIDE File Integrity Check");
    notify("6/7 — AIDE File Integrity Check", "normal", &real_user);
    if command_exists("aide") {
        let db_path = "/var/lib/aide/aide.db";
        let month_marker = format!("{}/.last_aide_run", log_dir);
        
        if !Path::new(db_path).exists() {
            println!("↻ No AIDE database found — initializing (this takes a while)...");
            notify("AIDE initializing database — please wait...", "normal", &real_user);
            if run_command("aide", &["--init"]) {
                let aide_new = "/var/lib/aide/aide.db.new";
                if Path::new(aide_new).exists() {
                    fs::rename(aide_new, db_path).ok();
                    log_success("AIDE database initialized");
                } else {
                    log_error("AIDE database init failed (aide.db.new not found)");
                    errors += 1;
                }
            } else {
                log_error("AIDE initialization failed");
                errors += 1;
            }
            fs::write(&month_marker, "").ok();
        } else {
            let run_aide = if !Path::new(&month_marker).exists() {
                true
            } else {
                let modified = fs::metadata(&month_marker)
                    .and_then(|m| m.modified())
                    .unwrap_or(std::time::UNIX_EPOCH);          // unreadable marker: treat as very old, so AIDE runs
                let now = std::time::SystemTime::now();
                let thirty_days = std::time::Duration::from_secs(30 * 24 * 60 * 60);
                now.duration_since(modified).unwrap_or(std::time::Duration::from_secs(0)) > thirty_days
            };

            if run_aide {
                println!("↻ Running AIDE integrity check...");
                notify("Running AIDE scan — this may take a few minutes...", "normal", &real_user);
                
                println!("{}", "  [EXEC] Running: aide --check".bold().yellow());
                write_to_log("Running: aide --check");
                
                let child = Command::new("aide")
                    .arg("--check")
                    .stdout(Stdio::piped())
                    .stderr(Stdio::piped())
                    .spawn();
                
                match child {
                    Ok(mut child_proc) => {
                        let stdout = child_proc.stdout.take().expect("spawned with a pipe");
                        let stderr = child_proc.stderr.take().expect("spawned with a pipe");
                        
                        let stderr_handle = std::thread::spawn(move || {
                            let reader = BufReader::new(stderr);
                            for l in reader.lines().map_while(Result::ok) {
                                println!("    {} {}", "[STDERR]".red(), l);
                                write_to_log(&format!("AIDE stderr: {}", l));
                            }
                        });
                        
                        let reader = BufReader::new(stdout);
                        let mut changes = 0;
                        for l in reader.lines().map_while(Result::ok) {
                            write_to_log(&format!("AIDE: {}", l));
                            if l.contains("changed") || l.contains("added") || l.contains("removed") {
                                changes += 1;
                                println!("    {}", l.bold().red());
                            } else {
                                println!("    {}", l.dimmed());
                            }
                        }
                        
                        let _ = stderr_handle.join();
                        let _status = child_proc.wait();
                        
                        if changes > 0 {
                            log_error(&format!("AIDE detected {} changes — review logs", changes));
                            notify(&format!("⚠ AIDE: {} file change(s) detected!", changes), "critical", &real_user);
                            errors += 1;
                        } else {
                            log_success("No integrity changes detected");
                        }
                    }
                    Err(_) => {
                        log_error("Failed to run AIDE check");
                        errors += 1;
                    }
                }
                
                run_command("aide", &["--update"]);
                let aide_new = "/var/lib/aide/aide.db.new";
                if Path::new(aide_new).exists() {
                    fs::rename(aide_new, db_path).ok();
                }
                fs::write(&month_marker, "").ok();
            } else {
                log_success("Skipping AIDE — last run was less than 30 days ago");
            }
        }
    } else {
        log_warn("AIDE not installed");
    }

    // 7. Backup
    section("7/7 — Backup to External Drive");
    notify("7/7 — Backup to External Drive", "normal", &real_user);
    
    let uuid_conf = format!("{}/.config/Halcyon/backup-uuid.conf", real_home);
    let target_uuid = std::env::var("HALCYON_BACKUP_UUID")
        .ok()
        .or_else(|| fs::read_to_string(&uuid_conf).ok().map(|s| s.trim().to_string()))
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| "none".to_string());
    let uuid_path = format!("/dev/disk/by-uuid/{}", target_uuid);
    let backup_dest = "/mnt/backup";
    
    let backup_dev;
    let mut auto_backup = false;
    
    if Path::new(&uuid_path).exists() {
        println!("✓ Auto-detected backup partition with UUID: {}", target_uuid.cyan());
        backup_dev = uuid_path;
        auto_backup = true;
    } else if auto {
        backup_dev = String::new();       // automatic run: no question can be answered, so no disk = no backup this time
    } else {
        println!("\nAvailable disks:");
        Command::new("lsblk").args(["-o", "NAME,SIZE,TYPE,MOUNTPOINT"]).status().ok();
        
        print!("\nEnter backup device [Default: sda1]: ");
        let _ = io::stdout().flush();
        let mut user_input = String::new();
        let _ = io::stdin().read_line(&mut user_input);
        let mut input_dev = user_input.trim().to_string();
        if input_dev.is_empty() {
            input_dev = "sda1".to_string();
        }
        if !input_dev.starts_with("/dev/") {
            input_dev = format!("/dev/{}", input_dev);
        }
        backup_dev = input_dev;
    }

    if auto && backup_dev.is_empty() {
        log_warn("Automatic run: the backup disk is not connected, so there is no backup this time");
    } else if !Path::new(&backup_dev).exists() {
        log_error(&format!("Device {} not found — skipping backup", backup_dev));
        notify("⚠ Backup skipped — drive not found", "critical", &real_user);
    } else {
        let label_output = Command::new("blkid").args(["-o", "value", "-s", "LABEL", &backup_dev]).output().ok();
        let label = label_output.map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string()).unwrap_or_else(|| "none".to_string());
        
        println!("Selected backup device: {} (Label: {})", backup_dev.yellow(), label.cyan());
        write_to_log(&format!("Selected backup device: {} (Label: {})", backup_dev, label));

        let mut proceed = true;
        if !auto_backup {
            if let Some(mounts) = mounted_at(&backup_dev) {
                if mounts.lines().any(|m| m != backup_dest) {
                    log_error(&format!(
                        "{} is in use (mounted at {}): unmount it first or pick another device. Backup skipped.",
                        backup_dev,
                        mounts.lines().collect::<Vec<_>>().join(", ")
                    ));
                    notify("⚠ Backup skipped — that device is in use", "critical", &real_user);
                    proceed = false;
                }
            }
        }
        if !auto_backup && proceed {
            if backup_dev.contains("nvme") {
                println!("\n{} DANGER: You selected an INTERNAL NVMe partition!", "⚠".red());
                print!("Type WIPE-NVME to confirm: ");
                let _ = io::stdout().flush();
                let mut confirm = String::new();
                let _ = io::stdin().read_line(&mut confirm);
                if confirm.trim() != "WIPE-NVME" {
                    println!("↻ Backup cancelled — refusing to touch internal NVMe");
                    proceed = false;
                }
            }

            if proceed {
                println!("\n{} WARNING: This will FORMAT {} as ext4 and ERASE ALL DATA!", "⚠".red(), backup_dev);
                print!("Type YES to continue: ");
                let _ = io::stdout().flush();
                let mut confirm = String::new();
                let _ = io::stdin().read_line(&mut confirm);
                if confirm.trim() != "YES" {
                    println!("↻ Backup skipped — user cancelled");
                    proceed = false;
                }
            }
        }

        if proceed {
            let fs_type_output = Command::new("blkid").args(["-o", "value", "-s", "TYPE", &backup_dev]).output().ok();
            let fs_type = fs_type_output.map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string()).unwrap_or_default();
            
            if fs_type != "ext4" {
                if auto_backup {
                    log_error("Auto-detected device is not ext4 formatted! Skipping auto-backup.");
                    proceed = false;
                } else {
                    println!("↻ Formatting {} as ext4...", backup_dev);
                    if run_command("mkfs.ext4", &["-L", "ArchBackup", &backup_dev]) {
                        log_success("Formatted successfully");
                    } else {
                        log_error("Formatting failed");
                        proceed = false;
                    }
                }
            } else {
                log_success(&format!("{} already ext4 — skipping format", backup_dev));
            }

            if proceed {
                fs::create_dir_all(backup_dest).ok();
                
                // Unmount if already mounted
                Command::new("umount").arg(backup_dest).stderr(Stdio::null()).status().ok();
                
                if run_command("mount", &[&backup_dev, backup_dest]) {
                    log_success(&format!("Mounted {} at {}", backup_dev, backup_dest));
                    
                    println!("↻ Starting rsync backup (this will take a while)...");
                    notify("Backing up system with rsync — please wait...", "normal", &real_user);
                    
                    println!("{}", "  [EXEC] Running rsync ...".bold().yellow());
                    write_to_log("Running rsync ...");
                    
                    let child = Command::new("rsync")
                        .args([
                            "-aAXH",
                            "--delete",
                            "--info=progress2",
                            "--exclude=/dev/*",
                            "--exclude=/proc/*",
                            "--exclude=/sys/*",
                            "--exclude=/tmp/*",
                            "--exclude=/run/*",
                            "--exclude=/mnt/*",
                            "--exclude=/media/*",
                            "--exclude=/var/tmp/*",
                            "--exclude=/var/cache/pacman/pkg/*",
                            "--exclude=/swapfile",
                            "--exclude=/lost+found",
                            "/",
                            &format!("{}/arch-backup/", backup_dest),
                        ])
                        .stdout(Stdio::piped())
                        .stderr(Stdio::piped())
                        .spawn();
                        
                    match child {
                        Ok(mut child_proc) => {
                            let stdout = child_proc.stdout.take().expect("spawned with a pipe");
                            let stderr = child_proc.stderr.take().expect("spawned with a pipe");
                            
                            let stderr_handle = std::thread::spawn(move || {
                                let reader = BufReader::new(stderr);
                                for l in reader.lines().map_while(Result::ok) {
                                    println!("    {} {}", "[STDERR]".red(), l);
                                    write_to_log(&format!("rsync stderr: {}", l));
                                }
                            });
                            
                            let reader = BufReader::new(stdout);
                            for l in reader.lines().map_while(Result::ok) {
                                println!("    {}", l);
                                write_to_log(&l);
                            }
                            
                            let _ = stderr_handle.join();
                            let status = child_proc.wait();
                            
                            if status.map(|s| s.success()).unwrap_or(false) {
                                log_success("Backup completed successfully");
                                notify("✓ Backup complete!", "normal", &real_user);
                            } else {
                                log_error("rsync backup failed");
                                notify("⚠ Backup failed!", "critical", &real_user);
                                errors += 1;
                            }
                        }
                        Err(_) => {
                            log_error("Failed to start rsync backup");
                            notify("⚠ Backup failed!", "critical", &real_user);
                            errors += 1;
                        }
                    }

                    println!("↻ Syncing filesystem caches...");
                    Command::new("sync").status().ok();
                    println!("↻ Unmounting backup drive...");
                    Command::new("umount").arg(backup_dest).status().ok();
                    log_success("Drive unmounted safely");
                } else {
                    log_error(&format!("Failed to mount {} at {}", backup_dev, backup_dest));
                    errors += 1;
                }
            }
        }
    }

    let end_msg = format!("\n Check complete — {}\n Errors found: {}", Local::now().format("%Y-%m-%d %H:%M:%S"), errors);
    println!("\n{}", "═══════════════════════════════════════════════".cyan());
    write_to_log(&end_msg);
    if errors == 0 {
        let ok_msg = "✓ All checks passed!";
        println!("{}", ok_msg.bold().green());
        notify(ok_msg, "normal", &real_user);
    } else {
        let err_msg = format!("⚠ {} issue(s) found during check.", errors);
        println!("{}", err_msg.bold().yellow());
        notify(&err_msg, "critical", &real_user);
    }
    println!("{}", "═══════════════════════════════════════════════".cyan());
}

/// Where a device is mounted right now (one mount point per line), or None when it is not mounted.
fn mounted_at(dev: &str) -> Option<String> {
    let out = Command::new("findmnt").args(["-rn", "-o", "TARGET", "-S", dev]).output().ok()?;
    let text = String::from_utf8_lossy(&out.stdout).trim().to_string();
    if text.is_empty() {
        None
    } else {
        Some(text)
    }
}

fn is_root() -> bool {
    match Command::new("id").arg("-u").output() {
        Ok(output) => String::from_utf8_lossy(&output.stdout).trim() == "0",
        Err(_) => false,
    }
}

fn section(title: &str) {
    let line = "─────────────────────────────────────────────";
    println!("\n{}", title.bold().blue());
    println!("{}", line.blue());
    write_to_log(&format!("\n{}\n{}", title, line));
}

fn log_success(msg: &str) {
    println!(" {} {}", "✓".green(), msg);
    write_to_log(&format!("✓ {}", msg));
}

fn log_error(msg: &str) {
    println!(" {} {}", "⚠".red(), msg);
    write_to_log(&format!("⚠ {}", msg));
}

fn log_warn(msg: &str) {
    println!(" {} {}", "!".yellow(), msg);
    write_to_log(&format!("! {}", msg));
}

fn command_exists(cmd: &str) -> bool {
    Command::new("which").arg(cmd).output().map(|o| o.status.success()).unwrap_or(false)
}

fn run_command(cmd: &str, args: &[&str]) -> bool {
    let cmd_str = format!("{} {}", cmd, args.join(" "));
    println!("{}", format!("  [EXEC] Running: {}", cmd_str).bold().yellow());
    write_to_log(&format!("[EXEC] Running: {}", cmd_str));

    let mut child = match Command::new(cmd)
        .args(args)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn() {
            Ok(c) => c,
            Err(e) => {
                log_error(&format!("Failed to start command {}: {}", cmd, e));
                return false;
            }
        };

    let stdout = child.stdout.take().expect("Failed to open stdout");
    let stderr = child.stderr.take().expect("Failed to open stderr");

    // Spawn a thread to read stderr and print/log it
    let stderr_handle = std::thread::spawn(move || {
        let reader = BufReader::new(stderr);
        for l in reader.lines().map_while(Result::ok) {
            println!("    {} {}", "[STDERR]".red(), l);
            write_to_log(&format!("[STDERR] {}", l));
        }
    });

    let stdout_reader = BufReader::new(stdout);
    for l in stdout_reader.lines().map_while(Result::ok) {
        println!("    {}", l);
        write_to_log(&l);
    }

    let _ = stderr_handle.join();

    match child.wait() {
        Ok(status) => {
            let success = status.success();
            if success {
                println!("{}", format!("  [EXEC] Command completed: {}", cmd).green());
            } else {
                println!("{}", format!("  [EXEC] Command failed with code: {:?}", status.code()).red());
            }
            success
        }
        Err(e) => {
            log_error(&format!("Error waiting for command {}: {}", cmd, e));
            false
        }
    }
}
