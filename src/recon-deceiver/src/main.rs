use chrono::Local;
use flate2::write::GzEncoder;
use flate2::Compression;
use regex::{Regex, RegexBuilder};
use std::collections::{HashMap, HashSet};
use std::fs::{self, File, OpenOptions};
use std::io::{BufRead, BufReader, Read, Write};
use std::net::{IpAddr, Ipv4Addr, SocketAddr, TcpListener, TcpStream, UdpSocket};
use std::os::unix::fs::{MetadataExt, PermissionsExt};
use std::path::Path;
use std::process::Command;
use std::sync::{Arc, LazyLock, Mutex};
use std::thread;
use std::time::{Duration, Instant};

const TIME_LIMIT_BEFORE_BAN: u64 = 120;
const COWRIE_ACTIVE_FILE: &str = "/run/cowrie.active";

static PROBE_HEADER_PATTERN: LazyLock<Regex> = LazyLock::new(|| {
    RegexBuilder::new(
        r"(SIP/2\.0|HTTP/1\.[01]|^(GET|POST|OPTIONS|HEAD|PROPFIND)\s|^(Via|Call-ID|CSeq|Max-Forwards|Contact|User-Agent|From|To):)"
    )
    .case_insensitive(true)
    .build()
    .unwrap()
});

static SUSPICIOUS_PATH_PATTERN: LazyLock<Regex> = LazyLock::new(|| {
    RegexBuilder::new(
        r"(wp-admin|wp-login|wp-content|phpmyadmin|\.env|\.git/|\.aws/|\.ssh/|config\.php|config\.json|backup|shell|etc/passwd|\.sql$|\.bak$|xmlrpc\.php|server-status|actuator|\.well-known/security|credentials|secrets|id_rsa|\.htpasswd)"
    )
    .case_insensitive(true)
    .build()
    .unwrap()
});

#[derive(Clone)]
struct AppState {
    logs_dir: String,
    hostname: String,
    telnet_user: String,
    telnet_pass: String,
    uploaded_webshells: Arc<Mutex<HashMap<String, String>>>,
    banned_ips: Arc<Mutex<HashSet<String>>>,
    first_seen: Arc<Mutex<HashMap<String, Instant>>>,
    last_notification: Arc<Mutex<HashMap<String, Instant>>>,
    last_scan: Arc<Mutex<HashMap<String, Instant>>>,
}

fn get_hostname() -> String {
    let mut buf = [0u8; 256];
    let res = unsafe { libc::gethostname(buf.as_mut_ptr() as *mut libc::c_char, buf.len()) };
    if res == 0 {
        if let Ok(s) = std::ffi::CStr::from_bytes_until_nul(&buf) {
            if let Ok(host) = s.to_str() {
                if !host.is_empty() {
                    return host.to_string();
                }
            }
        }
    }
    "ubuntu-server".to_string()
}

fn sys_user() -> String {
    if let Ok(u) = std::env::var("SUDO_USER") {
        if !u.is_empty() && u != "root" {
            return u;
        }
    }
    if let Ok(u) = std::env::var("USER") {
        if !u.is_empty() && u != "root" {
            return u;
        }
    }
    if let Ok(passwd) = fs::read_to_string("/etc/passwd") {
        for line in passwd.lines() {
            let parts: Vec<&str> = line.split(':').collect();
            if parts.len() > 2 {
                if let Ok(uid) = parts[2].parse::<u32>() {
                    if (1000..60000).contains(&uid) {
                        return parts[0].to_string();
                    }
                }
            }
        }
    }
    "netrunner".to_string()
}

fn sys_uid(user: &str) -> u32 {
    if let Ok(passwd) = fs::read_to_string("/etc/passwd") {
        for line in passwd.lines() {
            let parts: Vec<&str> = line.split(':').collect();
            if parts.len() > 2 && parts[0] == user {
                if let Ok(uid) = parts[2].parse::<u32>() {
                    return uid;
                }
            }
        }
    }
    1000
}

fn get_desktop_env(uid: u32) -> HashMap<String, String> {
    let mut env = HashMap::new();
    env.insert("DISPLAY".to_string(), ":0".to_string());
    env.insert("XDG_RUNTIME_DIR".to_string(), format!("/run/user/{}", uid));
    env.insert(
        "DBUS_SESSION_BUS_ADDRESS".to_string(),
        format!("unix:path=/run/user/{}/bus", uid),
    );

    if let Ok(entries) = fs::read_dir("/proc") {
        for entry in entries.flatten() {
            let name = entry.file_name().to_string_lossy().to_string();
            if !name.bytes().all(|b| b.is_ascii_digit()) {
                continue;
            }
            if let Ok(meta) = fs::metadata(entry.path()) {
                if meta.uid() == uid {
                    if let Ok(raw) = fs::read(format!("/proc/{}/environ", name)) {
                        let mut proc_vars = HashMap::new();
                        for item in raw.split(|b| *b == 0) {
                            if let Ok(s) = std::str::from_utf8(item) {
                                if let Some((k, v)) = s.split_once('=') {
                                    proc_vars.insert(k.to_string(), v.to_string());
                                }
                            }
                        }
                        if proc_vars.contains_key("WAYLAND_DISPLAY")
                            || proc_vars.contains_key("DISPLAY")
                        {
                            for k in [
                                "DISPLAY",
                                "WAYLAND_DISPLAY",
                                "XDG_RUNTIME_DIR",
                                "DBUS_SESSION_BUS_ADDRESS",
                            ] {
                                if let Some(v) = proc_vars.get(k) {
                                    env.insert(k.to_string(), v.clone());
                                }
                            }
                            return env;
                        }
                    }
                }
            }
        }
    }
    env
}

fn run_notify_send(title: &str, message: &str, urgency: &str, icon: &str) {
    let user = sys_user();
    let uid = sys_uid(&user);
    let env_map = get_desktop_env(uid);

    let is_root = unsafe { libc::geteuid() == 0 };
    let mut cmd = if is_root {
        let mut c = Command::new("sudo");
        c.arg("-u").arg(&user).arg("env");
        for (k, v) in &env_map {
            c.arg(format!("{}={}", k, v));
        }
        c.arg("notify-send");
        c
    } else {
        let mut c = Command::new("notify-send");
        for (k, v) in &env_map {
            c.env(k, v);
        }
        c
    };

    let title_clean = title.replace('\0', "");
    let msg_clean = message.replace('\0', "");
    cmd.args(["-u", urgency, "-i", icon, &title_clean, &msg_clean]);
    let _ = cmd.spawn();
}

impl AppState {
    fn log_event(&self, msg: &str) {
        let path = format!("{}/recon-attempts.log", self.logs_dir);
        if let Some(parent) = Path::new(&path).parent() {
            let _ = fs::create_dir_all(parent);
        }
        let timestamp = Local::now().format("%Y-%m-%d %H:%M:%S").to_string();
        if let Ok(mut f) = OpenOptions::new().create(true).append(true).open(&path) {
            let _ = writeln!(f, "[{}] {}", timestamp, msg);
        }
    }

    fn send_notification(&self, ip: &str, port_info: &str) {
        let mut map = self.last_notification.lock().unwrap();
        let now = Instant::now();
        if let Some(last) = map.get(ip) {
            if now.duration_since(*last) < Duration::from_secs(10) {
                return;
            }
        }
        map.insert(ip.to_string(), now);
        drop(map);

        run_notify_send(
            "Recon Alert",
            &format!("Host {} is probing decoy ports (Port {})", ip, port_info),
            "critical",
            "security-medium",
        );
    }

    fn send_credential_notification(&self, ip: &str, service: &str, u: &str, p: &str) {
        run_notify_send(
            "Credential Harvested",
            &format!(
                "Host {} entered credentials on {}!\nUser: {}\nPass: {}",
                ip, service, u, p
            ),
            "critical",
            "security-high",
        );
    }

    fn send_ban_notification(&self, ip: &str) {
        run_notify_send(
            "Active Defense Lockout",
            &format!("Banned host {} for 10 minutes in UFW firewall", ip),
            "normal",
            "security-low",
        );
    }

    fn ban_ip(&self, ip: &str) {
        if ip == "127.0.0.1" || ip == "localhost" || ip == "::1" {
            return;
        }

        {
            let fs_map = self.first_seen.lock().unwrap();
            if let Some(first) = fs_map.get(ip) {
                if first.elapsed().as_secs() < TIME_LIMIT_BEFORE_BAN {
                    return;
                }
            } else {
                return;
            }
        }

        {
            let mut banned = self.banned_ips.lock().unwrap();
            if banned.contains(ip) {
                return;
            }
            banned.insert(ip.to_string());
        }

        self.log_event(&format!(
            "[ALERT] Tarpit time limit reached. Banning IP {} for 10 minutes...",
            ip
        ));
        self.send_ban_notification(ip);

        let _ = Command::new("ufw")
            .args(["insert", "1", "deny", "from", ip, "to", "any", "comment", "recon-deceiver-ban"])
            .output();

        let state_clone = self.clone();
        let ip_clone = ip.to_string();
        thread::spawn(move || {
            thread::sleep(Duration::from_secs(600));
            state_clone.log_event(&format!("[INFO] Unbanning IP {}...", ip_clone));
            let _ = Command::new("ufw")
                .args(["delete", "deny", "from", &ip_clone, "to", "any", "comment", "recon-deceiver-ban"])
                .output();
            let mut banned = state_clone.banned_ips.lock().unwrap();
            banned.remove(&ip_clone);
        });
    }

    fn scan_attacker(&self, ip: &str) {
        {
            let mut scans = self.last_scan.lock().unwrap();
            let now = Instant::now();
            if let Some(last) = scans.get(ip) {
                if now.duration_since(*last) < Duration::from_secs(300) {
                    return;
                }
            }
            scans.insert(ip.to_string(), now);
        }

        if skip_scan_target(ip) {
            return;
        }

        let state_clone = self.clone();
        let ip_clone = ip.to_string();
        thread::spawn(move || {
            let cmd = [
                "-Pn",
                "-sS",
                "-sV",
                "--version-light",
                "-O",
                "--top-ports",
                "100",
                "--max-retries",
                "1",
                "--host-timeout",
                "120s",
                "-oN",
                "-",
                &ip_clone,
            ];
            let res = Command::new("nmap").args(cmd).output();
            match res {
                Ok(output) if output.status.success() => {
                    let out_str = String::from_utf8_lossy(&output.stdout).to_string();
                    let scan_log = format!("{}/attacker-scans.log", state_clone.logs_dir);
                    if let Ok(mut f) = OpenOptions::new().create(true).append(true).open(&scan_log) {
                        let timestamp = Local::now().format("%Y-%m-%d %H:%M:%S").to_string();
                        let _ = writeln!(
                            f,
                            "\n===== COUNTER-SCAN {} at {} =====\n{}",
                            ip_clone, timestamp, out_str
                        );
                    }
                    let mut open_ports = Vec::new();
                    let mut os_match = "n/a".to_string();
                    for line in out_str.lines() {
                        if line.contains("/tcp") && line.contains("open") {
                            if let Some(port) = line.split_whitespace().next() {
                                open_ports.push(port.to_string());
                            }
                        }
                        if line.starts_with("OS details") || line.starts_with("OS guesses") {
                            os_match = line.to_string();
                        }
                    }
                    let ports_joined = if open_ports.is_empty() {
                        "none".to_string()
                    } else {
                        open_ports.join(",")
                    };
                    state_clone.log_event(&format!(
                        "[COUNTER-SCAN] {}: open ports={} os={}",
                        ip_clone, ports_joined, os_match
                    ));
                }
                _ => {}
            }
        });
    }

    fn touch_tracker(&self, ip: &str) {
        let mut fs_map = self.first_seen.lock().unwrap();
        fs_map.entry(ip.to_string()).or_insert_with(Instant::now);
    }
}

fn skip_scan_target(ip: &str) -> bool {
    if ip == "127.0.0.1" || ip == "::1" || ip == "localhost" {
        return true;
    }
    if let Ok(ip_addr) = ip.parse::<Ipv4Addr>() {
        let octets = ip_addr.octets();
        if octets[0] == 0 || octets[0] >= 224 {
            return true;
        }
        if octets[0] == 169 && octets[1] == 254 {
            return true;
        }
    } else {
        return true;
    }
    false
}

// ---------------------------------------------------------------------------
// Credentials & Mock Sandbox Data
// ---------------------------------------------------------------------------

const TELNET_USERNAMES: &[&str] = &[
    "ubuntu", "admin", "root", "backup", "deploy", "webadmin", "sysadmin",
    "support", "operator", "user", "test", "postgres", "mysql", "git",
    "ftp", "nobody", "guest", "default", "server", "office",
];

const TELNET_PASSWORD_WORDS: &[&str] = &[
    "Summer", "Winter", "Spring", "Autumn", "Shadow", "Dragon", "Monkey",
    "Tiger", "Eagle", "Wolf", "Delta", "Matrix", "Quantum", "Solar", "Nova",
    "Phantom", "Falcon", "Coffee", "Mango", "Bluebird", "Chocolate",
    "Welcome", "Letmein", "Admin", "Server", "Linux", "Backup", "Secure",
    "Temp", "Guest", "Test", "Sunshine", "Thunder", "Fire", "Ice", "Star",
];

fn generate_telnet_credentials() -> (String, String) {
    use rand::seq::SliceRandom;
    use rand::Rng;
    let mut rng = rand::thread_rng();

    let mut user = (*TELNET_USERNAMES.choose(&mut rng).unwrap()).to_string();
    if rng.gen_bool(0.45) {
        user.push_str(&rng.gen_range(1..100).to_string());
    }

    let word = *TELNET_PASSWORD_WORDS.choose(&mut rng).unwrap();
    let years = ["2024", "2025", "2026"];
    let year = years.choose(&mut rng).unwrap();
    let suffixes = ["", "", "1", "2", "123", "!", "@", "#", "!", "123", "456"];
    let suffix = suffixes.choose(&mut rng).unwrap();

    let pass = format!("{}{}{}", word, year, suffix);
    (user, pass)
}

const SANDBOX_HOME: &str = "/home/ubuntu";

fn sandbox_fs() -> HashMap<&'static str, Vec<&'static str>> {
    let mut m = HashMap::new();
    m.insert(
        "/",
        vec![
            "bin", "boot", "dev", "etc", "home", "lib", "media", "mnt", "opt", "proc",
            "root", "run", "sbin", "srv", "sys", "tmp", "usr", "var",
        ],
    );
    m.insert("/root", vec![]);
    m.insert("/tmp", vec![]);
    m.insert("/home", vec!["ubuntu", "sys_admin"]);
    m.insert(
        "/home/ubuntu",
        vec![".bash_history", ".ssh", ".bashrc", ".profile"],
    );
    m.insert("/home/ubuntu/.ssh", vec!["authorized_keys"]);
    m.insert(
        "/home/sys_admin",
        vec![".bash_history", ".ssh", "backup.tar.gz", "notes.txt"],
    );
    m.insert(
        "/home/sys_admin/.ssh",
        vec!["id_rsa", "id_rsa.pub", "authorized_keys"],
    );
    m.insert(
        "/etc",
        vec!["passwd", "shadow", "hostname", "hosts", "crontab", "resolv.conf"],
    );
    m.insert("/var", vec!["www", "log", "backups"]);
    m.insert("/var/www", vec!["html"]);
    m.insert(
        "/var/www/html",
        vec!["index.php", "config.php", "backdoor.php", "uploads"],
    );
    m.insert("/var/www/html/uploads", vec![]);
    m.insert("/var/backups", vec!["db_dump_2026-06-30.sql.gz"]);
    m.insert("/var/log", vec!["auth.log", "syslog"]);
    m
}

fn sandbox_files(hostname: &str) -> HashMap<String, String> {
    let mut m = HashMap::new();
    m.insert(
        "/etc/passwd".to_string(),
        "root:x:0:0:root:/root:/bin/bash\n\
         daemon:x:1:1:daemon:/usr/sbin:/usr/sbin/nologin\n\
         bin:x:2:2:bin:/bin:/usr/sbin/nologin\n\
         sys:x:3:3:sys:/dev:/usr/sbin/nologin\n\
         sync:x:4:65534:sync:/bin:/bin/sync\n\
         www-data:x:33:33:www-data:/var/www:/usr/sbin/nologin\n\
         ubuntu:x:1000:1000:Ubuntu:/home/ubuntu:/bin/bash\n\
         sys_admin:x:1001:1001:System Administrator:/home/sys_admin:/bin/bash\n"
            .to_string(),
    );
    m.insert("/etc/hostname".to_string(), format!("{}\n", hostname));
    m.insert(
        "/etc/hosts".to_string(),
        format!("127.0.0.1\tlocalhost\n127.0.1.1\t{}\n", hostname),
    );
    m.insert(
        "/etc/resolv.conf".to_string(),
        "nameserver 8.8.8.8\nnameserver 1.1.1.1\n".to_string(),
    );
    m.insert(
        "/etc/crontab".to_string(),
        "0 3 * * * root /usr/local/bin/backup.sh\n".to_string(),
    );
    m.insert(
        "/var/www/html/config.php".to_string(),
        "<?php\n\
         // Ubuntu System database configuration\n\
         define('DB_HOST', 'localhost');\n\
         define('DB_USER', 'sys_admin');\n\
         define('DB_PASS', 'UB_Admin_P@ss_2026_Secure');\n\
         define('DB_NAME', 'system_config');\n\
         ?>\n"
            .to_string(),
    );
    m.insert(
        "/home/ubuntu/.bash_history".to_string(),
        "sudo apt update\nls -la\ncd /var/www/html\nnano config.php\nsudo systemctl restart apache2\nexit\n"
            .to_string(),
    );
    m.insert(
        "/home/sys_admin/.bash_history".to_string(),
        "ls -la\ncat /etc/passwd\nmysql -u root -p'UB_Admin_P@ss_2026_Secure' system_config\nscp backup.tar.gz admin@10.0.0.5:/backups/\nsudo systemctl restart apache2\nhistory -c\n"
            .to_string(),
    );
    m.insert(
        "/home/sys_admin/notes.txt".to_string(),
        "TODO: rotate the db password again, last one leaked in a config commit\n\
         TODO: patch ProFTPD, saw a CVE mentioned on a forum\n\
         reminder: backup cron runs 0300 daily to /var/backups\n"
            .to_string(),
    );
    m.insert(
        "/home/sys_admin/.ssh/id_rsa.pub".to_string(),
        "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQC7k2Jd8pQmXz1RfN0v3aLd9wYp2Tn4Qm8Vb6Hs5Ej0Rk3Wc7Lp1Nx9Ad4Vt2Bq8Ym6Zf3Cw0Xr7Ku5Hb1Sd6Jn9Pe4Tv2Ol8Gm3Qz sys_admin@ubuntu-server\n"
            .to_string(),
    );
    m.insert(
        "/home/sys_admin/.ssh/id_rsa".to_string(),
        "-----BEGIN OPENSSH PRIVATE KEY-----\n\
         b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAABlwAAAAdzc2gtcn\n\
         NhAAAAAwEAAQAAAYEA1qk4Pfy8Bx0uW3Zj9Nr2Ld6QpAmYt7Vb2Sc5Hn8Fk3Wr0Cx4Bt\n\
         9Ym2Ql6Zj3Rf7Vn1Dw8Ep5Ct0Gr4Ky9Lu2Bx6Sm3Fq1Nd8Th5Wj0Az7Cv4Ro2Ye9Ku6\n\
         Ip1Bn3Sd8Fw2Cl5Xt0Rm7Vh4Yq9Gj6Nk1Bp3Ea8Wo5Uc2Fz7Lr0Tv4Xd9Ym1Sn6Qi3Kh\n\
         8Bt5Ce0Ao2Uj7Fw4Ry9Nv1Xd6Ql3Sm8Bh0Kt5Ei2Wc7Fo4Ur9Lp1Yn6Gj3Zx0Vb8Dm5\n\
         -----END OPENSSH PRIVATE KEY-----\n"
            .to_string(),
    );
    m.insert(
        "/home/sys_admin/.ssh/authorized_keys".to_string(),
        "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQDp4Sq1Yj9Fw6Nr3Cv0Bt8Ke5Ho2Lx7Wm1Ad4Uq9Ez6Rf3Tn0Cy8Jv5Pg2Bs7Xk4Om1Wt6Dh3Qz0Lu9Rc5Vi2Ea8Nf7Kj4Bp1Xo6Sm3Yg deploy@ci-runner\n"
            .to_string(),
    );
    m
}

fn fake_sql_dump() -> Vec<u8> {
    let sql = "-- MySQL dump 10.13  Distrib 5.5.54, for debian-linux-gnu (x86_64)\n\
               -- Host: localhost    Database: system_config\n\
               -- Server version\t5.5.54-0ubuntu0.14.04.1\n\n\
               CREATE TABLE `users` (\n\
                 `id` int(11) NOT NULL AUTO_INCREMENT,\n\
                 `username` varchar(64) NOT NULL,\n\
                 `password_hash` varchar(255) NOT NULL,\n\
                 `role` enum('admin','operator','viewer') NOT NULL DEFAULT 'viewer',\n\
                 PRIMARY KEY (`id`)\n\
               ) ENGINE=InnoDB DEFAULT CHARSET=utf8;\n\
               INSERT INTO `users` VALUES (1,'root','$6$rounds=656000$Kj9sXp2VbN0qZtWc$XWZ/QLjP/Q8bDy7uKc2sV9fEa1GhN4Rt3Wm5Vx8Yz0Cd6Lp2Tq7Jf1Sb4No8Ma3Ub9Ke5Oi7Qd9Yt3Wf1','admin'),\
               (2,'sys_admin','$6$rounds=656000$Q2mzC8oR1pW4tXn9$Ae3Gh7Lj2Mk5Pq9Rs0Tu6Vx4Wz8Yb1Cd3Ef5Gj7Hl2Km4Np6Qr9St1Uv3Wx8Yz0Ab5','admin'),\
               (3,'backup','$6$rounds=656000$L8r4Cv7yN2hB5kFq$Uv1Wd3Xf5Gh6Jk8Lm9Np1Qr3St4Uv6Wx8Yz0Ab2Cd4Ef7Gh9Jk1Lm3Np5Qr7St9Uv2Wx4Yz6Ab8','operator');\n\n\
               CREATE TABLE `credentials` (\n\
                 `id` int(11) NOT NULL AUTO_INCREMENT,\n\
                 `service` varchar(32) NOT NULL,\n\
                 `username` varchar(64) NOT NULL,\n\
                 `password` varchar(128) NOT NULL,\n\
                 PRIMARY KEY (`id`)\n\
               ) ENGINE=InnoDB DEFAULT CHARSET=utf8;\n\
               INSERT INTO `credentials` VALUES (1,'vpn_primary','netadmin','7nQz!Pw2$KvR9xLm'),\
               (2,'vpn_secondary','netadmin','xM4#LbT8@FcN6sVw'),\
               (3,'nas_admin','admin','S3rvice!T3am2026'),\
               (4,'router_cfg','cisco','C1sc0.R0ut3r!2026'),\
               (5,'api_dashboard','apiuser','9gH#2pLk$7nVm4Bq');\n\n\
               CREATE TABLE `backup_servers` (\n\
                 `id` int(11) NOT NULL AUTO_INCREMENT,\n\
                 `host` varchar(255) NOT NULL,\n\
                 `username` varchar(64) NOT NULL,\n\
                 `password` varchar(128) NOT NULL,\n\
                 PRIMARY KEY (`id`)\n\
               ) ENGINE=InnoDB DEFAULT CHARSET=utf8;\n\
               INSERT INTO `backup_servers` VALUES (1,'10.0.0.5','admin','B@ckup_Cr3d_2026!'),\
               (2,'backup.dc.example.com','archive','4rch!ve_K3y_2026');\n\n\
               CREATE TABLE `api_keys` (\n\
                 `id` int(11) NOT NULL AUTO_INCREMENT,\n\
                 `service` varchar(32) NOT NULL,\n\
                 `api_key` varchar(128) NOT NULL,\n\
                 PRIMARY KEY (`id`)\n\
               ) ENGINE=InnoDB DEFAULT CHARSET=utf8;\n\
               INSERT INTO `api_keys` VALUES (1,'payment','sk_live_51NgH8tKQv2XcLm4Rp7SjW3bY6zF8dA1eC0'),\
               (2,'cloud_sync','AKIA4XBQ2Z9Y7M1CP3U'),\
               (3,'monitoring','mtr_8fd3k2Lx9Qa1Zv6Np4Wc7R');\n";
    let mut encoder = GzEncoder::new(Vec::new(), Compression::default());
    let _ = encoder.write_all(sql.as_bytes());
    encoder.finish().unwrap_or_default()
}

fn fake_backup_tar() -> Vec<u8> {
    // Generate a valid gzip archive containing a tar file
    let mut tar_buf = Vec::new();
    {
        let mut tf = tar_builder(&mut tar_buf);
        tf.add("backup/config.php", b"<?php\ndefine('DB_HOST', 'localhost');\ndefine('DB_USER', 'sys_admin');\ndefine('DB_PASS', 'UB_Admin_P@ss_2026_Secure');\ndefine('DB_NAME', 'system_config');\n?>\n");
        tf.add("backup/credentials.txt", b"# Stored credentials\nvpn_primary netadmin 7nQz!Pw2$KvR9xLm\n");
        tf.add("backup/README.txt", b"Automated daily backup set.\n");
    }
    let mut encoder = GzEncoder::new(Vec::new(), Compression::default());
    let _ = encoder.write_all(&tar_buf);
    encoder.finish().unwrap_or_default()
}

struct TarBuilder<'a> {
    out: &'a mut Vec<u8>,
}

fn tar_builder<'a>(out: &'a mut Vec<u8>) -> TarBuilder<'a> {
    TarBuilder { out }
}

impl<'a> TarBuilder<'a> {
    fn add(&mut self, path: &str, content: &[u8]) {
        let mut header = [0u8; 512];
        let p_bytes = path.as_bytes();
        let p_len = p_bytes.len().min(100);
        header[..p_len].copy_from_slice(&p_bytes[..p_len]);
        // mode: 0644
        header[100..107].copy_from_slice(b"0000644");
        // uid: 1000
        header[108..115].copy_from_slice(b"0001750");
        // gid: 1000
        header[116..123].copy_from_slice(b"0001750");
        // size in octal
        let size_str = format!("{:011o}", content.len());
        header[124..135].copy_from_slice(size_str.as_bytes());
        // mtime
        header[136..147].copy_from_slice(b"1468065600 ");
        // checksum placeholder spaces
        header[148..156].copy_from_slice(b"        ");
        // typeflag: '0' (regular file)
        header[156] = b'0';
        // magic
        header[257..263].copy_from_slice(b"ustar\0");
        header[263..265].copy_from_slice(b"00");

        let chksum: u32 = header.iter().map(|b| *b as u32).sum();
        let chk_str = format!("{:06o}\0 ", chksum);
        header[148..156].copy_from_slice(chk_str.as_bytes());

        self.out.extend_from_slice(&header);
        self.out.extend_from_slice(content);
        let rem = content.len() % 512;
        if rem != 0 {
            self.out.extend(std::iter::repeat(0).take(512 - rem));
        }
    }
}

fn ftp_content(path: &str, hostname: &str) -> Option<Vec<u8>> {
    let files = sandbox_files(hostname);
    if let Some(c) = files.get(path) {
        return Some(c.as_bytes().to_vec());
    }
    if path == "/var/backups/db_dump_2026-06-30.sql.gz" {
        return Some(fake_sql_dump());
    }
    if path == "/home/sys_admin/backup.tar.gz" {
        return Some(fake_backup_tar());
    }
    if path == "/var/www/html/backdoor.php" {
        return Some(b"<?php if(isset($_REQUEST['c'])){system($_REQUEST['c']);} ?>\n".to_vec());
    }
    if path == "/var/www/html/index.php" {
        return Some(b"<?php echo \"srv-db-cluster internal status page\\n\"; ?>\n".to_vec());
    }
    if path == "/etc/hostname" {
        return Some(format!("{}\n", hostname).into_bytes());
    }
    None
}

fn sandbox_normalize(cwd: &str, target: &str) -> String {
    if target.is_empty() {
        return cwd.to_string();
    }
    let base = if target.starts_with('/') {
        target.to_string()
    } else if target == "~" || target.starts_with("~/") {
        format!("{}{}", SANDBOX_HOME, &target[1..])
    } else {
        format!("{}/{}", cwd.trim_end_matches('/'), target)
    };

    let mut parts = Vec::new();
    for seg in base.split('/') {
        if seg.is_empty() || seg == "." {
            continue;
        }
        if seg == ".." {
            parts.pop();
            continue;
        }
        parts.push(seg);
    }
    format!("/{}", parts.join("/"))
}

fn sandbox_display_cwd(cwd: &str) -> String {
    if cwd == SANDBOX_HOME {
        "~".to_string()
    } else if cwd.starts_with(&format!("{}/", SANDBOX_HOME)) {
        format!("~{}", &cwd[SANDBOX_HOME.len()..])
    } else {
        cwd.to_string()
    }
}

fn sandbox_owner(path: &str) -> &'static str {
    if path.starts_with("/home/ubuntu") {
        "ubuntu   ubuntu  "
    } else if path.starts_with("/home/sys_admin") {
        "sys_admin sys_admin"
    } else if path.starts_with("/var/www") {
        "www-data www-data"
    } else {
        "root     root    "
    }
}

fn sandbox_ls(cwd: &str, detailed: bool, hostname: &str) -> String {
    let fs_map = sandbox_fs();
    let entries = fs_map.get(cwd).cloned().unwrap_or_default();
    if !detailed {
        let mut sorted = entries.clone();
        sorted.sort();
        return if sorted.is_empty() {
            "".to_string()
        } else {
            format!("{}\n", sorted.join("  "))
        };
    }

    let owner = sandbox_owner(cwd);
    let mut lines = Vec::new();
    lines.push(format!("total {}", (entries.len() * 4).max(8)));
    lines.push(format!("drwxr-xr-x  2 {} 4096 Jul  9 12:00 .", owner));
    lines.push("drwxr-xr-x  3 root     root     4096 Jul  9 11:30 ..".to_string());

    let mut sorted = entries;
    sorted.sort();
    let files = sandbox_files(hostname);
    for name in sorted {
        let child = sandbox_normalize(cwd, name);
        if fs_map.contains_key(child.as_str()) {
            lines.push(format!("drwxr-xr-x  2 {} 4096 Jul  9 12:00 {}", owner, name));
        } else {
            let size = files
                .get(&child)
                .map(|s| s.len())
                .unwrap_or(220);
            let perm = if name.starts_with('.') || name == "id_rsa" {
                "-rw-------"
            } else {
                "-rw-r--r--"
            };
            lines.push(format!("{}  1 {} {:>5} Jul  9 12:00 {}", perm, owner, size, name));
        }
    }
    format!("{}\n", lines.join("\n"))
}

fn execute_mock_command(cmd: &str, hostname: &str) -> String {
    let clean_cmd = cmd.replace(['\'', '"'], "");
    let parts: Vec<&str> = clean_cmd.split_whitespace().collect();
    let base = parts.first().copied().unwrap_or("");

    match base {
        "whoami" => "www-data\n".to_string(),
        "id" => "uid=33(www-data) gid=33(www-data) groups=33(www-data)\n".to_string(),
        "uname" => format!(
            "Linux {} 4.15.0-142-generic #146-Ubuntu SMP Tue Apr 13 01:11:19 UTC 2021 x86_64 GNU/Linux\n",
            hostname
        ),
        "pwd" => "/var/www/html\n".to_string(),
        "ls" => "total 16\n\
                 drwxr-xr-x 2 www-data www-data 4096 Jul  9 12:00 .\n\
                 drwxr-xr-x 3 root     root     4096 Jul  9 11:30 ..\n\
                 -rw-r--r-- 1 www-data www-data  230 Jul  9 12:00 backdoor.php\n\
                 -rw-r--r-- 1 root     root     1024 Jul  9 11:30 index.php\n"
            .to_string(),
        _ if clean_cmd.contains("passwd") => "root:x:0:0:root:/root:/bin/bash\n\
                                              daemon:x:1:1:daemon:/usr/sbin:/usr/sbin/nologin\n\
                                              bin:x:2:2:bin:/bin:/usr/sbin/nologin\n\
                                              sys:x:3:3:sys:/dev:/usr/sbin/nologin\n\
                                              sync:x:4:65534:sync:/bin:/bin/sync\n\
                                              www-data:x:33:33:www-data:/var/www:/usr/sbin/nologin\n\
                                              sys_admin:x:1001:1001:System Administrator:/home/sys_admin:/bin/bash\n"
            .to_string(),
        _ if clean_cmd.contains("shadow") => "cat: /etc/shadow: Permission denied\n".to_string(),
        _ if clean_cmd.contains("config") => "<?php\n\
                                              define('DB_HOST', 'localhost');\n\
                                              define('DB_USER', 'sys_admin');\n\
                                              define('DB_PASS', 'UB_Admin_P@ss_2026_Secure');\n\
                                              define('DB_NAME', 'system_config');\n\
                                              ?>\n"
            .to_string(),
        "env" | "printenv" => "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\n\
                               PWD=/var/www/html\n\
                               USER=www-data\n\
                               HOME=/var/www\n\
                               AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE\n\
                               AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY\n"
            .to_string(),
        _ => format!("sh: 1: {}: Permission denied or command not found\n", base),
    }
}

fn execute_sandbox_command(
    cmd: &str,
    cwd: &mut String,
    state: &AppState,
) -> String {
    let clean_cmd = cmd.replace(['\'', '"'], "");
    let parts: Vec<&str> = clean_cmd.split_whitespace().collect();
    let base = parts.first().copied().unwrap_or("");
    let args = if parts.len() > 1 { &parts[1..] } else { &[] };

    let fs_map = sandbox_fs();
    let files = sandbox_files(&state.hostname);

    match base {
        "cd" => {
            let target = args.last().copied().unwrap_or(SANDBOX_HOME);
            let new_path = sandbox_normalize(cwd, target);
            if fs_map.contains_key(new_path.as_str()) {
                *cwd = new_path;
                "".to_string()
            } else if files.contains_key(&new_path) {
                format!("bash: cd: {}: Not a directory\n", target)
            } else {
                format!("bash: cd: {}: No such file or directory\n", target)
            }
        }
        "pwd" => format!("{}\n", cwd),
        "ls" => {
            let detailed = args.iter().any(|a| *a == "-l" || *a == "-la" || *a == "-al" || *a == "-lah" || *a == "-a");
            let target = args.iter().find(|a| !a.starts_with('-')).copied();
            let target_path = target
                .map(|t| sandbox_normalize(cwd, t))
                .unwrap_or_else(|| cwd.clone());

            if !fs_map.contains_key(target_path.as_str()) {
                if files.contains_key(&target_path) {
                    target.map(|t| format!("{}\n", t)).unwrap_or_default()
                } else {
                    format!("ls: cannot access '{}': No such file or directory\n", target.unwrap_or(""))
                }
            } else {
                sandbox_ls(&target_path, detailed, &state.hostname)
            }
        }
        "cat" | "more" | "less" | "head" | "tail" => {
            let non_flag = args.iter().find(|a| !a.starts_with('-')).copied();
            let target = match non_flag {
                Some(t) => t,
                None => return format!("{}: missing operand\n", base),
            };
            let full = sandbox_normalize(cwd, target);
            if full == "/etc/shadow" {
                return format!("{}: {}: Permission denied\n", base, target);
            }
            if let Some(content) = files.get(&full) {
                if base == "head" || base == "tail" {
                    let lines: Vec<&str> = content.lines().collect();
                    let n = 10.min(lines.len());
                    let slice = if base == "head" {
                        &lines[..n]
                    } else {
                        &lines[lines.len() - n..]
                    };
                    format!("{}\n", slice.join("\n"))
                } else {
                    content.clone()
                }
            } else if fs_map.contains_key(full.as_str()) {
                format!("{}: {}: Is a directory\n", base, target)
            } else {
                format!("{}: {}: No such file or directory\n", base, target)
            }
        }
        "rm" | "chmod" | "chown" | "mv" | "touch" | "mkdir" | "nano" | "vi" | "vim" => {
            if args.is_empty() {
                return format!("{}: missing operand\n", base);
            }
            let target = args.last().unwrap();
            let full = sandbox_normalize(cwd, target);
            if base == "mkdir" && fs_map.contains_key(full.as_str()) {
                format!("mkdir: cannot create directory '{}': File exists\n", target)
            } else if full == "/etc/shadow" || (full.starts_with("/etc") && (base == "rm" || base == "chmod" || base == "chown")) {
                format!("{}: cannot access '{}': Operation not permitted\n", base, target)
            } else {
                "".to_string()
            }
        }
        "grep" => {
            let non_flags: Vec<&str> = args.iter().filter(|a| !a.starts_with('-')).copied().collect();
            if non_flags.len() < 2 {
                return "Usage: grep [OPTION]... PATTERN [FILE]...\n".to_string();
            }
            let pattern = non_flags[0];
            let target = non_flags[1];
            let full = sandbox_normalize(cwd, target);
            if let Some(content) = files.get(&full) {
                let matches: Vec<&str> = content.lines().filter(|l| l.contains(pattern)).collect();
                if matches.is_empty() {
                    "".to_string()
                } else {
                    format!("{}\n", matches.join("\n"))
                }
            } else {
                format!("grep: {}: No such file or directory\n", target)
            }
        }
        "wget" | "curl" => {
            let url = args.last().copied().unwrap_or("");
            state.log_event(&format!(
                "[ALERT] Sandbox observed outbound fetch attempt: {} {}",
                base, url
            ));
            format!("{}: unable to resolve host address\n", base)
        }
        "history" => files.get("/home/ubuntu/.bash_history").cloned().unwrap_or_default(),
        "ps" => "  PID TTY          TIME CMD\n 1022 pts/0    00:00:00 bash\n 1841 pts/0    00:00:00 ps\n".to_string(),
        "netstat" | "ss" => "Active Internet connections (only servers)\n\
                             Proto Recv-Q Send-Q Local Address           Foreign Address         State\n\
                             tcp        0      0 0.0.0.0:21              0.0.0.0:*               LISTEN\n\
                             tcp        0      0 0.0.0.0:22              0.0.0.0:*               LISTEN\n\
                             tcp        0      0 0.0.0.0:80              0.0.0.0:*               LISTEN\n"
            .to_string(),
        "ifconfig" | "ip" => "eth0      Link encap:Ethernet  HWaddr 00:16:3e:2f:88:11\n\
                              inet addr:192.168.1.13  Bcast:192.168.1.255  Mask:255.255.255.0\n\
                              UP BROADCAST RUNNING MULTICAST  MTU:1500  Metric:1\n"
            .to_string(),
        "sudo" => "ubuntu is not in the sudoers file.  This incident will be reported.\n".to_string(),
        "crontab" if args.contains(&"-l") => files.get("/etc/crontab").cloned().unwrap_or_default(),
        "whoami" => "ubuntu\n".to_string(),
        "id" => "uid=1000(ubuntu) gid=1000(ubuntu) groups=1000(ubuntu),27(sudo)\n".to_string(),
        "uname" => format!("Linux {} 3.13.0-160-generic #210-Ubuntu SMP x86_64 GNU/Linux\n", state.hostname),
        "clear" => "".to_string(),
        _ => format!("{}: command not found\n", base),
    }
}

// ---------------------------------------------------------------------------
// Protocol Handlers
// ---------------------------------------------------------------------------

fn looks_like_protocol_probe(text: &str) -> bool {
    if text.is_empty() {
        return false;
    }
    if PROBE_HEADER_PATTERN.is_match(text) {
        return true;
    }
    let printable = text.chars().filter(|c| c.is_ascii_graphic() || *c == ' ').count();
    if text.len() > 4 && (printable as f64 / text.len() as f64) < 0.85 {
        return true;
    }
    false
}

const TELNET_IAC: u8 = 0xff;
const TELNET_WILL: u8 = 0xfb;
const TELNET_DO: u8 = 0xfd;
const TELNET_OPT_ECHO: u8 = 0x01;
const TELNET_OPT_SUPPRESS_GA: u8 = 0x03;
const TELNET_OPT_TERMTYPE: u8 = 0x18;

fn telnet_negotiate(stream: &mut TcpStream) {
    let handshake = [
        TELNET_IAC, TELNET_WILL, TELNET_OPT_ECHO,
        TELNET_IAC, TELNET_WILL, TELNET_OPT_SUPPRESS_GA,
        TELNET_IAC, TELNET_DO, TELNET_OPT_TERMTYPE,
    ];
    let _ = stream.write_all(&handshake);
    let _ = stream.set_read_timeout(Some(Duration::from_millis(500)));
    let mut buf = [0u8; 64];
    while let Ok(n) = stream.read(&mut buf) {
        if n == 0 || !buf[..n].contains(&TELNET_IAC) {
            break;
        }
    }
}

fn telnet_readline(stream: &mut TcpStream) -> String {
    let _ = stream.set_read_timeout(Some(Duration::from_secs(60)));
    let mut buf = Vec::new();
    let mut b = [0u8; 1];
    while let Ok(1) = stream.read(&mut b) {
        let ch = b[0];
        if ch == TELNET_IAC {
            let mut skip = [0u8; 2];
            let _ = stream.read_exact(&mut skip);
            continue;
        }
        if ch == b'\r' || ch == b'\n' {
            let _ = stream.set_read_timeout(Some(Duration::from_millis(50)));
            let mut pair = [0u8; 1];
            let _ = stream.read(&mut pair);
            let _ = stream.set_read_timeout(Some(Duration::from_secs(60)));
            break;
        }
        if ch == 0x08 || ch == 0x7f {
            buf.pop();
            continue;
        }
        buf.push(ch);
        if buf.len() > 500 {
            break;
        }
    }
    String::from_utf8_lossy(&buf).trim().to_string()
}

fn handle_telnet(mut stream: TcpStream, addr: SocketAddr, state: &AppState) {
    let ip = addr.ip().to_string();
    state.log_event(&format!(
        "[INFO] TELNET DECOY CONNECTED: Source IP {}:{}. Tarpit Engaged.",
        ip, addr.port()
    ));
    state.send_notification(&ip, "23 (Telnet Tarpit)");

    telnet_negotiate(&mut stream);
    let banner = format!("\r\nUbuntu 14.04.5 LTS\r\n\r\n{} login: ", state.hostname);
    let _ = stream.write_all(banner.as_bytes());

    let mut attempts = 0;
    loop {
        let username = telnet_readline(&mut stream);
        if looks_like_protocol_probe(&username) {
            return;
        }
        let _ = stream.write_all(b"Password: ");
        let password = telnet_readline(&mut stream);
        if looks_like_protocol_probe(&password) {
            return;
        }

        if username == state.telnet_user && password == state.telnet_pass {
            state.log_event(&format!(
                "[ALERT] CREDENTIALS HARVESTED (Telnet) from {}: Username={}, Password={} [VALID DECOY LOGIN]",
                ip, username, password
            ));
            state.send_credential_notification(&ip, "Telnet", &username, &password);
            break;
        }

        attempts += 1;
        state.log_event(&format!(
            "[INFO] Telnet login FAILURE from {}: Username={:?}, Password={:?}",
            ip, username, password
        ));
        let _ = stream.write_all(b"Login incorrect\r\n\r\n");
        if attempts >= 3 {
            state.log_event(&format!(
                "[INFO] Telnet login failures exceeded (3) from {}, dropping connection.",
                ip
            ));
            return;
        }
        let prompt = format!("{} login: ", state.hostname);
        let _ = stream.write_all(prompt.as_bytes());
    }

    let mut cwd = SANDBOX_HOME.to_string();
    let greeting = format!(
        "\r\nWelcome to Ubuntu 14.04.5 LTS (GNU/Linux 3.13.0-160-generic x86_64)\r\n\r\n\
         * Documentation:  https://help.ubuntu.com/\r\n\r\n\
         Last login: Thu Jul  9 11:12:04 2026 from 192.168.1.15\r\n\
         {}@{}:{}$ ",
        state.telnet_user,
        state.hostname,
        sandbox_display_cwd(&cwd)
    );
    let _ = stream.write_all(greeting.as_bytes());

    loop {
        let cmd_line = telnet_readline(&mut stream);
        if cmd_line.is_empty() || looks_like_protocol_probe(&cmd_line) {
            break;
        }
        state.log_event(&format!("[TELNET CLI] IP {} typed: {}", ip, cmd_line));
        if ["exit", "quit", "logout"].contains(&cmd_line.to_lowercase().as_str()) {
            let _ = stream.write_all(b"\r\nlogout\r\nConnection closed by foreign host.\r\n");
            break;
        }

        let output = execute_sandbox_command(&cmd_line, &mut cwd, state);
        let output_telnet = output.replace('\n', "\r\n");
        let prompt = format!(
            "{}{}@{}:{}$ ",
            output_telnet,
            state.telnet_user,
            state.hostname,
            sandbox_display_cwd(&cwd)
        );
        if stream.write_all(prompt.as_bytes()).is_err() {
            break;
        }
    }
}

fn handle_ftp(mut stream: TcpStream, addr: SocketAddr, state: &AppState) {
    let ip = addr.ip().to_string();
    state.log_event(&format!(
        "[INFO] FTP DECOY CONNECTED: Source IP {}:{}. Tarpit Engaged.",
        ip, addr.port()
    ));
    state.send_notification(&ip, "21 (FTP Tarpit)");

    let _ = stream.write_all(b"220 ProFTPD 1.3.5 Server (Ubuntu)\r\n");
    let _ = stream.set_read_timeout(Some(Duration::from_secs(15)));

    let mut user = "unknown".to_string();
    let mut cwd = "/".to_string();
    let mut current_cpfr: Option<String> = None;
    let mut pasv_listener: Option<TcpListener> = None;
    let mut port_endpoint: Option<SocketAddr> = None;

    let mut reader = BufReader::new(stream.try_clone().unwrap());
    let mut line = String::new();

    while let Ok(n) = reader.read_line(&mut line) {
        if n == 0 {
            break;
        }
        let trimmed = line.trim();
        if trimmed.is_empty() {
            line.clear();
            continue;
        }

        state.log_event(&format!("[FTP] Command from {}: {}", ip, trimmed));
        let (cmd, args) = match trimmed.split_once(' ') {
            Some((c, a)) => (c.to_uppercase(), a.trim().to_string()),
            None => (trimmed.to_uppercase(), "".to_string()),
        };

        match cmd.as_str() {
            "USER" => {
                user = args;
                let _ = stream.write_all(format!("331 Password required for {}\r\n", user).as_bytes());
            }
            "PASS" => {
                state.log_event(&format!(
                    "[ALERT] CREDENTIALS HARVESTED (FTP) from {}: USER={}, PASS={}",
                    ip, user, args
                ));
                state.send_credential_notification(&ip, "FTP", &user, &args);
                let _ = stream.write_all(b"230 User logged in, proceed\r\n");
            }
            "SYST" => {
                let _ = stream.write_all(b"215 UNIX Type: L8\r\n");
            }
            "FEAT" => {
                let _ = stream.write_all(b"211-Features:\r\n EPRT\r\n EPSV\r\n MDTM\r\n MLST type*;size*;modify*;\r\n MLSD\r\n PASV\r\n REST STREAM\r\n SIZE\r\n SITE\r\n211 End\r\n");
            }
            "PWD" => {
                let _ = stream.write_all(format!("257 \"{}\" is current directory\r\n", cwd).as_bytes());
            }
            "TYPE" | "STRU" | "MODE" | "ALLO" => {
                let _ = stream.write_all(b"200 Command okay.\r\n");
            }
            "CWD" => {
                let target = sandbox_normalize(&cwd, &args);
                let fs_map = sandbox_fs();
                if fs_map.contains_key(target.as_str()) {
                    cwd = target;
                    let _ = stream.write_all(b"250 Directory successfully changed.\r\n");
                } else {
                    let _ = stream.write_all(b"550 Failed to change directory.\r\n");
                }
            }
            "CDUP" => {
                let target = sandbox_normalize(&cwd, "..");
                let fs_map = sandbox_fs();
                if fs_map.contains_key(target.as_str()) {
                    cwd = target;
                    let _ = stream.write_all(b"250 Directory successfully changed.\r\n");
                } else {
                    let _ = stream.write_all(b"550 Failed to change directory.\r\n");
                }
            }
            "PASV" => {
                if let Ok(listener) = TcpListener::bind("0.0.0.0:0") {
                    if let Ok(local_addr) = listener.local_addr() {
                        let port = local_addr.port();
                        let my_ip = stream.local_addr().map(|a| a.ip()).unwrap_or(IpAddr::V4(Ipv4Addr::new(127, 0, 0, 1)));
                        let ip_str = my_ip.to_string().replace('.', ",");
                        let p1 = port >> 8;
                        let p2 = port & 0xff;
                        pasv_listener = Some(listener);
                        let _ = stream.write_all(
                            format!("227 Entering Passive Mode ({},{},{})\r\n", ip_str, p1, p2).as_bytes(),
                        );
                    }
                } else {
                    let _ = stream.write_all(b"425 Can't open data connection.\r\n");
                }
            }
            "EPSV" => {
                if let Ok(listener) = TcpListener::bind("0.0.0.0:0") {
                    if let Ok(local_addr) = listener.local_addr() {
                        let port = local_addr.port();
                        pasv_listener = Some(listener);
                        let _ = stream.write_all(
                            format!("229 Entering Extended Passive Mode (|||{}|)\r\n", port).as_bytes(),
                        );
                    }
                } else {
                    let _ = stream.write_all(b"425 Can't open data connection.\r\n");
                }
            }
            "LIST" | "NLST" | "MLSD" => {
                let target = if args.is_empty() || args.starts_with('-') {
                    cwd.clone()
                } else {
                    sandbox_normalize(&cwd, &args)
                };
                let fs_map = sandbox_fs();
                if !fs_map.contains_key(target.as_str()) {
                    let _ = stream.write_all(b"550 No such directory.\r\n");
                } else {
                    let _ = stream.write_all(b"150 Here comes the directory listing.\r\n");
                    let data_sock = if let Some(l) = pasv_listener.take() {
                        l.accept().map(|(s, _)| s).ok()
                    } else if let Some(target_ep) = port_endpoint.take() {
                        TcpStream::connect_timeout(&target_ep, Duration::from_secs(5)).ok()
                    } else {
                        None
                    };

                    if let Some(mut ds) = data_sock {
                        let listing = sandbox_ls(&target, cmd == "LIST", &state.hostname);
                        let _ = ds.write_all(listing.replace('\n', "\r\n").as_bytes());
                        let _ = stream.write_all(b"226 Directory send OK.\r\n");
                    } else {
                        let _ = stream.write_all(b"425 Can't open data connection.\r\n");
                    }
                }
            }
            "RETR" => {
                let target = sandbox_normalize(&cwd, &args);
                if target == "/etc/shadow" {
                    let _ = stream.write_all(b"550 Permission denied.\r\n");
                } else if let Some(content) = ftp_content(&target, &state.hostname) {
                    let _ = stream.write_all(b"150 Opening BINARY mode data connection.\r\n");
                    let data_sock = if let Some(l) = pasv_listener.take() {
                        l.accept().map(|(s, _)| s).ok()
                    } else if let Some(target_ep) = port_endpoint.take() {
                        TcpStream::connect_timeout(&target_ep, Duration::from_secs(5)).ok()
                    } else {
                        None
                    };

                    if let Some(mut ds) = data_sock {
                        let _ = ds.write_all(&content);
                        state.log_event(&format!(
                            "[ALERT] FTP BAIT EXFILTRATED by {}: {} ({} bytes) served as decoy data",
                            ip, target, content.len()
                        ));
                        let _ = stream.write_all(b"226 Transfer complete.\r\n");
                    } else {
                        let _ = stream.write_all(b"425 Can't open data connection.\r\n");
                    }
                } else {
                    let _ = stream.write_all(b"550 File not found.\r\n");
                }
            }
            "STOR" => {
                let _ = stream.write_all(b"150 Ok to send data.\r\n");
                let data_sock = if let Some(l) = pasv_listener.take() {
                    l.accept().map(|(s, _)| s).ok()
                } else if let Some(target_ep) = port_endpoint.take() {
                    TcpStream::connect_timeout(&target_ep, Duration::from_secs(5)).ok()
                } else {
                    None
                };

                if let Some(mut ds) = data_sock {
                    let mut payload = Vec::new();
                    let _ = ds.read_to_end(&mut payload);
                    if !payload.is_empty() {
                        let upload_dir = format!("{}/attacker-uploads", state.logs_dir);
                        let _ = fs::create_dir_all(&upload_dir);
                        let fname = Path::new(&args).file_name().map(|f| f.to_string_lossy().to_string()).unwrap_or_else(|| "unknown".to_string());
                        let save_path = format!("{}/{}_{}_{}", upload_dir, Local::now().format("%Y%m%d_%H%M%S"), ip, fname);
                        let _ = fs::write(&save_path, &payload);

                        state.log_event(&format!(
                            "[ALERT] ATTACKER PAYLOAD CAPTURED: {} uploaded {} ({} bytes) -> {}",
                            ip, args, payload.len(), save_path
                        ));
                        state.send_notification(&ip, &format!("FTP STOR: attacker payload {} captured", args));

                        if fname.ends_with(".php") || fname.ends_with(".phtml") || fname.ends_with(".php5") {
                            let mut shells = state.uploaded_webshells.lock().unwrap();
                            shells.insert(fname.clone(), format!("(ftp-uploaded {})", save_path));
                            state.log_event(&format!("[INFO] FTP-uploaded PHP registered as live webshell: {}", fname));
                        }
                    }
                    let _ = stream.write_all(b"226 Transfer complete.\r\n");
                } else {
                    let _ = stream.write_all(b"425 Can't open data connection.\r\n");
                }
            }
            "SIZE" => {
                let target = sandbox_normalize(&cwd, &args);
                if let Some(content) = ftp_content(&target, &state.hostname) {
                    let _ = stream.write_all(format!("213 {}\r\n", content.len()).as_bytes());
                } else {
                    let _ = stream.write_all(b"550 File not found.\r\n");
                }
            }
            "MDTM" => {
                let _ = stream.write_all(b"213 20260709120000\r\n");
            }
            "CPFR" => {
                current_cpfr = Some(args.clone());
                state.log_event(&format!("[ALERT] EXPLOIT ATTEMPT: FTP mod_copy CPFR from {} for file: {}", ip, args));
                let _ = stream.write_all(b"350 File or directory exists, ready for destination name\r\n");
            }
            "CPTO" => {
                if let Some(ref cpfr) = current_cpfr {
                    let filename = args.rsplit('/').next().unwrap_or("shell.php").to_string();
                    let mut shells = state.uploaded_webshells.lock().unwrap();
                    shells.insert(filename.clone(), cpfr.clone());
                    state.log_event(&format!(
                        "[ALERT] EXPLOIT SUCCESSFUL: FTP mod_copy CPTO from {} to path: {} (registered webshell: {})",
                        ip, args, filename
                    ));
                    let _ = stream.write_all(b"250 Copy successful\r\n");
                } else {
                    let _ = stream.write_all(b"503 Bad sequence of commands.\r\n");
                }
            }
            "SITE" => {
                if let Some((site_cmd, site_args)) = args.split_once(' ') {
                    if site_cmd.eq_ignore_ascii_case("CPFR") {
                        current_cpfr = Some(site_args.trim().to_string());
                        state.log_event(&format!("[ALERT] EXPLOIT ATTEMPT: FTP mod_copy CPFR from {} for file: {}", ip, site_args));
                        let _ = stream.write_all(b"350 File or directory exists, ready for destination name\r\n");
                    } else if site_cmd.eq_ignore_ascii_case("CPTO") {
                        if let Some(ref cpfr) = current_cpfr {
                            let filename = site_args.trim().rsplit('/').next().unwrap_or("shell.php").to_string();
                            let mut shells = state.uploaded_webshells.lock().unwrap();
                            shells.insert(filename.clone(), cpfr.clone());
                            state.log_event(&format!(
                                "[ALERT] EXPLOIT SUCCESSFUL: FTP mod_copy CPTO from {} to path: {} (registered webshell: {})",
                                ip, site_args, filename
                            ));
                            let _ = stream.write_all(b"250 Copy successful\r\n");
                        } else {
                            let _ = stream.write_all(b"503 Bad sequence of commands.\r\n");
                        }
                    } else {
                        let _ = stream.write_all(b"500 Syntax error, command unrecognized.\r\n");
                    }
                } else {
                    let _ = stream.write_all(b"500 Syntax error, command unrecognized.\r\n");
                }
            }
            "NOOP" => {
                let _ = stream.write_all(b"200 NOOP ok.\r\n");
            }
            "QUIT" => {
                let _ = stream.write_all(b"221 Goodbye.\r\n");
                break;
            }
            _ => {
                let _ = stream.write_all(b"500 Syntax error, command unrecognized.\r\n");
            }
        }
        line.clear();
    }
}

fn handle_ssh(mut stream: TcpStream, addr: SocketAddr, state: &AppState) {
    let ip = addr.ip().to_string();
    state.log_event(&format!(
        "[INFO] SSH DECOY CONNECTED: Source IP {}:{}. Tarpit Engaged.",
        ip, addr.port()
    ));
    state.send_notification(&ip, "22 (SSH Tarpit)");

    let _ = stream.write_all(b"SSH-2.0-OpenSSH_6.6.1p1 Ubuntu-2ubuntu2\r\n");
    let mut buf = [0u8; 4096];
    let start = Instant::now();

    loop {
        if start.elapsed().as_secs() > TIME_LIMIT_BEFORE_BAN {
            state.log_event(&format!("[INFO] Tarpit expired for {} on SSH.", ip));
            break;
        }

        let _ = stream.set_read_timeout(Some(Duration::from_secs(5)));
        match stream.read(&mut buf) {
            Ok(0) => break,
            Ok(n) => {
                let payload = String::from_utf8_lossy(&buf[..n]).trim().to_string();
                state.log_event(&format!("[PAYLOAD] SSH packet from {}: {}", ip, payload));
                thread::sleep(Duration::from_secs(5));
                let _ = stream.write_all(b"Protocol mismatch.\r\n");
            }
            Err(_) => {
                let _ = stream.write_all(b"\x00");
            }
        }
    }
}

fn handle_http(mut stream: TcpStream, addr: SocketAddr, state: &AppState) {
    let ip = addr.ip().to_string();
    state.log_event(&format!("[INFO] HTTP DECOY CONNECTED: Source IP {}:{}", ip, addr.port()));
    state.send_notification(&ip, "80 (HTTP)");

    let mut buf = [0u8; 4096];
    let _ = stream.set_read_timeout(Some(Duration::from_secs(5)));
    let n = match stream.read(&mut buf) {
        Ok(n) if n > 0 => n,
        _ => return,
    };

    let req_str = String::from_utf8_lossy(&buf[..n]);
    let first_line = req_str.lines().next().unwrap_or("");
    let parts: Vec<&str> = first_line.split_whitespace().collect();
    let method = parts.first().copied().unwrap_or("GET");
    let path = parts.get(1).copied().unwrap_or("/");

    let (route, query) = path.split_once('?').unwrap_or((path, ""));
    let filename = route.trim_start_matches('/');
    let basename = filename.rsplit('/').next().unwrap_or("");

    let is_webshell = {
        let shells = state.uploaded_webshells.lock().unwrap();
        shells.contains_key(basename)
    };

    if is_webshell {
        let mut params = HashMap::new();
        if !query.is_empty() {
            for pair in query.split('&') {
                if let Some((k, v)) = pair.split_once('=') {
                    params.insert(k.to_string(), v.to_string());
                }
            }
        }
        if method == "POST" {
            if let Some((_, body)) = req_str.split_once("\r\n\r\n") {
                for pair in body.split('&') {
                    if let Some((k, v)) = pair.split_once('=') {
                        params.insert(k.to_string(), v.to_string());
                    }
                }
            }
        }

        let cmd = params.get("cmd").or(params.get("c")).or(params.get("shell")).or(params.get("exec"));
        if let Some(command) = cmd {
            state.log_event(&format!(
                "[ALERT] EXPLOIT BACKDOOR EXECUTED: Source IP {} executed cmd=\"{}\" on webshell {}",
                ip, command, filename
            ));
            let out = execute_mock_command(command, &state.hostname);
            let resp = format!(
                "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                out.len(),
                out
            );
            let _ = stream.write_all(resp.as_bytes());
        } else {
            let html = format!(
                "<!DOCTYPE html><html><head><title>Web Shell Console - {}</title>\
                 <style>body{{font-family:monospace;background:#121212;color:#00ff00;padding:20px;}}\
                 input[type='text']{{width:80%;background:#222;color:#00ff00;border:1px solid #00ff00;padding:5px;}}\
                 input[type='submit']{{background:#00ff00;color:#121212;border:none;padding:5px 10px;font-weight:bold;cursor:pointer;}}</style></head>\
                 <body><h2>SafeShell v1.0 - Connected to {}</h2>\
                 <form method='GET'><span>www-data@{}:/var/www/html$ </span>\
                 <input type='text' name='cmd' autofocus placeholder='Type command...'>\
                 <input type='submit' value='Run'></form></body></html>",
                filename, state.hostname, state.hostname
            );
            let resp = format!(
                "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                html.len(),
                html
            );
            let _ = stream.write_all(resp.as_bytes());
        }
        return;
    }

    if route == "/infrastructure_passwords.txt" {
        state.log_event(&format!("[ALERT] HONEY-TOKEN TRIP: {} downloaded /infrastructure_passwords.txt", ip));
        run_notify_send("Honey-Token Tripped", &format!("Host {} downloaded /infrastructure_passwords.txt!", ip), "critical", "security-high");
        let content = "# Ubuntu Server Infrastructure Configuration\nAWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE\nAWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY\nproduction_db_host=db.ubuntu-internal.net\nproduction_db_user=sys_admin\nproduction_db_pass=UB_Admin_P@ss_2026_Secure\n";
        let resp = format!(
            "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
            content.len(), content
        );
        let _ = stream.write_all(resp.as_bytes());
        return;
    }

    if route == "/network_backup.sql" {
        state.log_event(&format!("[ALERT] HONEY-TOKEN TRIP: {} downloaded /network_backup.sql", ip));
        run_notify_send("Honey-Token Tripped", &format!("Host {} downloaded /network_backup.sql!", ip), "critical", "security-high");
        let content = "-- Ubuntu Server Decoy Database Dump\nCREATE TABLE `users` (`username` varchar(50), `password` varchar(255));\nINSERT INTO `users` VALUES ('admin','pbkdf2_sha256$260000$yX8wQ1sFp9Z0$L2qN3oP4q5r6s7t8u9v0w1x2y3z4A5B6C7D8E9F0g1h=');\n";
        let resp = format!(
            "HTTP/1.1 200 OK\r\nContent-Type: application/sql\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
            content.len(), content
        );
        let _ = stream.write_all(resp.as_bytes());
        return;
    }

    if method == "POST" && ["/login", "/login.php", "/login.html"].contains(&route) {
        let mut u = "unknown".to_string();
        let mut p = "unknown".to_string();
        if let Some((_, body)) = req_str.split_once("\r\n\r\n") {
            for part in body.split('&') {
                if let Some((k, v)) = part.split_once('=') {
                    if k == "username" {
                        u = v.to_string();
                    } else if k == "password" {
                        p = v.to_string();
                    }
                }
            }
        }
        state.log_event(&format!("[ALERT] CREDENTIALS HARVESTED (HTTP Cockpit) from {}: Username={}, Password={}", ip, u, p));
        state.send_credential_notification(&ip, "Ubuntu Cockpit Portal", &u, &p);
        let resp = b"HTTP/1.1 302 Found\r\nLocation: /admin/dashboard.html\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
        let _ = stream.write_all(resp);
        return;
    }

    if method == "GET" && ["/admin/dashboard.html", "/admin/dashboard", "/admin/"].contains(&route) {
        let html = format!(
            "<!DOCTYPE html><html><head><title>Cockpit System Console - {}</title>\
             <style>body{{font-family:sans-serif;background:#0b0c10;color:#c5c6c7;padding:20px;}}\
             .card{{background:#151922;border:1px solid #66fcf1;border-radius:8px;padding:20px;margin-bottom:20px;}}\
             h1,h3{{color:#66fcf1;}}</style></head><body><h1>Cockpit System Control</h1>\
             <div class='card'><h3>System Status</h3><p>Server: {}</p><p>OS: Ubuntu 18.04.6 LTS</p></div>\
             <div class='card'><h3>VPN Gateway</h3><p>PSK: UB_ServerCorp2026_Secure_Key!</p></div></body></html>",
            state.hostname, state.hostname
        );
        let resp = format!(
            "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
            html.len(), html
        );
        let _ = stream.write_all(resp.as_bytes());
        return;
    }

    if method == "GET" && ["", "/", "/index.html", "/index.htm", "/login", "/login.html"].contains(&route) {
        let html = format!(
            "<!DOCTYPE html><html><head><title>Cockpit Console Login</title>\
             <style>body{{background:#0b0c10;color:#66fcf1;font-family:sans-serif;display:flex;justify-content:center;align-items:center;height:100vh;margin:0;}}\
             .box{{border:1px solid #66fcf1;border-radius:8px;padding:40px;background:#151922;width:300px;text-align:center;}}\
             input{{width:100%;padding:10px;margin:10px 0;box-sizing:border-box;background:#0b0c10;border:1px solid #66fcf1;color:#fff;}}\
             button{{width:100%;padding:10px;background:#66fcf1;color:#0b0c10;border:none;font-weight:bold;cursor:pointer;}}</style></head>\
             <body><div class='box'><h2>Web Console ({})</h2><form method='POST' action='/login'>\
             <input type='text' name='username' placeholder='Username' required><br>\
             <input type='password' name='password' placeholder='Password' required><br>\
             <button type='submit'>Log In</button></form></div></body></html>",
            state.hostname
        );
        let resp = format!(
            "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
            html.len(), html
        );
        let _ = stream.write_all(resp.as_bytes());
        return;
    }

    if method == "GET" && route == "/logout" {
        let resp = b"HTTP/1.1 302 Found\r\nLocation: /\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
        let _ = stream.write_all(resp);
        return;
    }

    if SUSPICIOUS_PATH_PATTERN.is_match(route) || route.contains("..") || route.len() > 60 {
        state.log_event(&format!("[ALERT] Directory brute-force detected from {} requesting: {}", ip, first_line));
        thread::sleep(Duration::from_secs(1));
    } else {
        state.log_event(&format!("[INFO] Generic HTTP request from {}: {}", ip, first_line));
    }

    let body = format!(
        "<!DOCTYPE HTML PUBLIC \"-//IETF//DTD HTML 2.0//EN\">\n\
         <html><head><title>404 Not Found</title></head><body>\n\
         <h1>Not Found</h1><p>The requested URL {} was not found on this server.</p>\n\
         <hr><address>Apache/2.4.7 (Ubuntu) Server at {} Port 80</address></body></html>\n",
        route, state.hostname
    );
    let resp = format!(
        "HTTP/1.1 404 Not Found\r\nContent-Type: text/html\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
        body.len(), body
    );
    let _ = stream.write_all(resp.as_bytes());
}

fn handle_smtp(mut stream: TcpStream, addr: SocketAddr, state: &AppState) {
    let ip = addr.ip().to_string();
    state.log_event(&format!(
        "[INFO] SMTP DECOY CONNECTED: Source IP {}:{}. Tarpit Engaged.",
        ip, addr.port()
    ));
    state.send_notification(&ip, "25 (SMTP Tarpit)");

    let greeting = format!("220 {} ESMTP Postfix (Ubuntu)\r\n", state.hostname);
    let _ = stream.write_all(greeting.as_bytes());
    let _ = stream.set_read_timeout(Some(Duration::from_secs(15)));

    let mut reader = BufReader::new(stream.try_clone().unwrap());
    let mut line = String::new();

    while let Ok(n) = reader.read_line(&mut line) {
        if n == 0 {
            break;
        }
        let trimmed = line.trim();
        state.log_event(&format!("[SMTP] Command from {}: {}", ip, trimmed));
        let cmd = trimmed.split_whitespace().next().unwrap_or("").to_uppercase();

        match cmd.as_str() {
            "EHLO" => {
                let resp = format!(
                    "250-{}\r\n250-PIPELINING\r\n250-SIZE 10240000\r\n250-VRFY\r\n250-ENHANCEDSTATUSCODES\r\n250-8BITMIME\r\n250 DSN\r\n",
                    state.hostname
                );
                let _ = stream.write_all(resp.as_bytes());
            }
            "HELO" => {
                let resp = format!("250 {}\r\n", state.hostname);
                let _ = stream.write_all(resp.as_bytes());
            }
            "MAIL" => {
                let _ = stream.write_all(b"250 2.1.0 Ok\r\n");
            }
            "RCPT" => {
                let _ = stream.write_all(b"250 2.1.5 Ok\r\n");
            }
            "DATA" => {
                let _ = stream.write_all(b"354 End data with <CR><LF>.<CR><LF>\r\n");
                let mut data_buf = String::new();
                while let Ok(dn) = reader.read_line(&mut data_buf) {
                    if dn == 0 || data_buf.ends_with("\r\n.\r\n") || data_buf.trim() == "." {
                        break;
                    }
                }
                let _ = stream.write_all(b"250 2.0.0 Ok: queued as 198273645\r\n");
            }
            "VRFY" => {
                let _ = stream.write_all(b"550 5.1.1 <user>: Recipient address rejected\r\n");
            }
            "EXPN" => {
                let _ = stream.write_all(b"502 5.5.2 Error: command not implemented\r\n");
            }
            "STARTTLS" => {
                let _ = stream.write_all(b"454 4.7.0 TLS not available due to local problem\r\n");
            }
            "AUTH" => {
                let _ = stream.write_all(b"503 5.5.1 Error: authentication not enabled\r\n");
            }
            "NOOP" | "RSET" => {
                let _ = stream.write_all(b"250 2.0.0 Ok\r\n");
            }
            "QUIT" => {
                let _ = stream.write_all(b"221 2.0.0 Bye\r\n");
                break;
            }
            _ => {
                let _ = stream.write_all(b"500 5.5.2 Error: command not recognized\r\n");
            }
        }
        line.clear();
    }
}

fn handle_generic(mut stream: TcpStream, port: u16, addr: SocketAddr, state: &AppState) {
    let ip = addr.ip().to_string();
    state.log_event(&format!(
        "[INFO] RECON DETECTED: Source IP {}:{} connected to spoofed Port {}",
        ip, addr.port(), port
    ));
    state.send_notification(&ip, &port.to_string());

    let _ = stream.set_read_timeout(Some(Duration::from_secs(5)));
    let start = Instant::now();

    if port == 445 {
        let mut first = [0u8; 1024];
        let n = stream.read(&mut first).unwrap_or(0);
        if n >= 8 && &first[4..8] == b"\xffSMB" {
            state.log_event(&format!(
                "    - Received probe payload from {} on Port {}: {:?}",
                ip, port, &first[..n.min(100)]
            ));
            let smb_resp: &[u8] = &[
                0x00, 0x00, 0x00, 0x55, 0xff, 0x53, 0x4d, 0x42, 0x72, 0x00, 0x00, 0x00, 0x00,
                0x18, 0x01, 0x40, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x00, 0x00, 0x00, 0x00, 0xe0, 0x1f, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x03,
                0x00, 0x01, 0x00, 0x10, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00,
                0x00, 0xfd, 0xe3, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x00, 0x00, 0x4c, 0x4d, 0x31, 0x2e, 0x32, 0x00,
            ];
            let _ = stream.write_all(smb_resp);
        } else {
            return;
        }
    } else if port == 3306 {
        let mysql_banner: &[u8] = &[
            0x0a, b'5', b'.', b'5', b'.', b'5', b'4', b'-', b'l', b'o', b'g', 0x00,
            0x09, 0x9a, 0x00, 0x00, 0x2a, 0x4a, 0x36, 0x75, 0x4a, 0x3f, 0x5a, 0x34, 0x00,
            0xff, 0xff, 0x21, 0x02, 0x00, 0xff, 0x7f, 0x15, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x32, 0x4e, 0x33, 0x79, 0x2b, 0x49, 0x35, 0x6f,
            0x54, 0x77, 0x4e, 0x72, 0x00, b'm', b'y', b's', b'q', b'l', b'_', b'n', b'a',
            b't', b'i', b'v', b'e', b'_', b'p', b'a', b's', b's', b'w', b'o', b'r', b'd', 0x00,
        ];
        let _ = stream.write_all(mysql_banner);
    } else if port == 3389 {
        let rdp_banner: &[u8] = &[0x03, 0x00, 0x00, 0x13, 0x0e, 0xe0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x08, 0x00, 0x03, 0x00, 0x00, 0x00];
        let _ = stream.write_all(rdp_banner);
    } else if port == 8080 {
        let nginx_banner = b"HTTP/1.1 200 OK\r\nServer: nginx/1.18.0 (Ubuntu)\r\nConnection: close\r\n\r\n<html><body><h1>It works!</h1></body></html>\r\n";
        let _ = stream.write_all(nginx_banner);
    }

    let mut buf = [0u8; 1024];
    loop {
        if start.elapsed().as_secs() > TIME_LIMIT_BEFORE_BAN {
            break;
        }
        match stream.read(&mut buf) {
            Ok(0) => break,
            Ok(n) => {
                state.log_event(&format!(
                    "    - Received probe payload from {} on Port {}: {:?}",
                    ip, port, &buf[..n.min(100)]
                ));
            }
            Err(_) => {
                let _ = stream.write_all(b"\x00");
            }
        }
    }
}

// ---------------------------------------------------------------------------
// DNS Deception Poisoner
// ---------------------------------------------------------------------------

fn parse_dns_query(data: &[u8]) -> Option<(String, u16)> {
    if data.len() < 12 {
        return None;
    }
    let mut domain_parts = Vec::new();
    let mut idx = 12;
    while idx < data.len() {
        let len = data[idx] as usize;
        if len == 0 {
            idx += 1;
            break;
        }
        if idx + 1 + len > data.len() {
            return None;
        }
        let part = String::from_utf8_lossy(&data[idx + 1..idx + 1 + len]).to_string();
        domain_parts.push(part);
        idx += 1 + len;
    }
    if idx + 4 > data.len() {
        return None;
    }
    let qtype = ((data[idx] as u16) << 8) | (data[idx + 1] as u16);
    Some((domain_parts.join("."), qtype))
}

fn build_dns_response(data: &[u8], ip_address: &str) -> Option<Vec<u8>> {
    if data.len() < 12 {
        return None;
    }
    let tx_id = &data[0..2];
    let flags: &[u8] = &[0x81, 0x80];
    let counts: &[u8] = &[0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00];

    let mut idx = 12;
    while idx < data.len() {
        let len = data[idx] as usize;
        if len == 0 {
            idx += 1;
            break;
        }
        idx += 1 + len;
    }
    if idx + 4 > data.len() {
        return None;
    }
    let question_section = &data[12..idx + 4];

    let answer_name: &[u8] = &[0xc0, 0x0c];
    let answer_type: &[u8] = &[0x00, 0x01];
    let answer_class: &[u8] = &[0x00, 0x01];
    let answer_ttl: &[u8] = &[0x00, 0x00, 0x00, 0x3c];
    let answer_rdlength: &[u8] = &[0x00, 0x04];

    let octets: Vec<u8> = ip_address
        .split('.')
        .filter_map(|s| s.parse::<u8>().ok())
        .collect();
    if octets.len() != 4 {
        return None;
    }

    let mut resp = Vec::new();
    resp.extend_from_slice(tx_id);
    resp.extend_from_slice(flags);
    resp.extend_from_slice(counts);
    resp.extend_from_slice(question_section);
    resp.extend_from_slice(answer_name);
    resp.extend_from_slice(answer_type);
    resp.extend_from_slice(answer_class);
    resp.extend_from_slice(answer_ttl);
    resp.extend_from_slice(answer_rdlength);
    resp.extend_from_slice(&octets);
    Some(resp)
}

fn start_dns_listener(state: AppState) {
    let socket = match UdpSocket::bind("0.0.0.0:53") {
        Ok(s) => s,
        Err(e) => {
            state.log_event(&format!("[ERROR] Failed to bind DNS listener on UDP Port 53: {}", e));
            return;
        }
    };
    state.log_event("[*] Started DNS deception poisoner on UDP 0.0.0.0:53");

    let mut buf = [0u8; 2048];
    while let Ok((n, src_addr)) = socket.recv_from(&mut buf) {
        let ip = src_addr.ip().to_string();
        state.touch_tracker(&ip);
        state.scan_attacker(&ip);

        if let Some((domain, _)) = parse_dns_query(&buf[..n]) {
            state.log_event(&format!(
                "[ALERT] DNS QUERY DETECTED: Source IP {} queried '{}'",
                ip, domain
            ));

            let local_ip = "127.0.0.1";
            if let Some(resp) = build_dns_response(&buf[..n], local_ip) {
                let _ = socket.send_to(&resp, src_addr);
                state.log_event(&format!(
                    "[INFO] DNS POISONED: Sent A record for {} -> {}",
                    domain, local_ip
                ));
            }

            state.send_notification(&ip, &format!("53 (DNS query for {})", domain));
            state.ban_ip(&ip);
        }
    }
}

// ---------------------------------------------------------------------------
// Listener Spawner
// ---------------------------------------------------------------------------

fn start_listener(port: u16, state: AppState) {
    let listener = match TcpListener::bind(format!("0.0.0.0:{}", port)) {
        Ok(l) => l,
        Err(e) => {
            state.log_event(&format!("[ERROR] Failed to bind listener on Port {}: {}", port, e));
            return;
        }
    };
    state.log_event(&format!("[*] Started deception honeypot listener on Port {}", port));

    for stream in listener.incoming() {
        match stream {
            Ok(s) => {
                let s_clone = s.try_clone().unwrap();
                let addr = match s.peer_addr() {
                    Ok(a) => a,
                    Err(_) => continue,
                };
                let ip = addr.ip().to_string();
                let state_clone = state.clone();

                thread::spawn(move || {
                    state_clone.touch_tracker(&ip);
                    state_clone.scan_attacker(&ip);

                    match port {
                        21 => handle_ftp(s_clone, addr, &state_clone),
                        22 => handle_ssh(s_clone, addr, &state_clone),
                        23 => handle_telnet(s_clone, addr, &state_clone),
                        25 => handle_smtp(s_clone, addr, &state_clone),
                        80 => handle_http(s_clone, addr, &state_clone),
                        _ => handle_generic(s_clone, port, addr, &state_clone),
                    }

                    state_clone.ban_ip(&ip);
                });
            }
            Err(_) => continue,
        }
    }
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.iter().any(|a| a == "-h" || a == "--help") {
        println!("recon-deceiver - Multi-port honeypot and active defense daemon\n\nUsage: sudo recon-deceiver [COUNTER_ATTACK_THRESHOLD]\n\nOptions:\n  -h, --help    Show this help message and exit");
        return;
    }

    let is_root = unsafe { libc::geteuid() == 0 };
    if !is_root {
        eprintln!("[ERROR] Must run as root to bind ports below 1024");
        std::process::exit(1);
    }

    let home = std::env::var("HOME").unwrap_or_else(|_| "/home/netrunner".to_string());
    let logs_dir = format!("{}/logs", home);
    let hostname = get_hostname();
    let (telnet_user, telnet_pass) = generate_telnet_credentials();

    // Write honeypot credentials file
    let cred_file = format!("{}/honeypot-credentials.txt", logs_dir);
    if let Some(parent) = Path::new(&cred_file).parent() {
        let _ = fs::create_dir_all(parent);
    }
    if let Ok(mut f) = File::create(&cred_file) {
        let _ = writeln!(
            f,
            "Decoy telnet credential (generated at daemon start)\nUsername: {}\nPassword: {}",
            telnet_user, telnet_pass
        );
        let mut perms = f.metadata().unwrap().permissions();
        perms.set_mode(0o600);
        let _ = fs::set_permissions(&cred_file, perms);
    }

    let state = AppState {
        logs_dir: logs_dir.clone(),
        hostname,
        telnet_user: telnet_user.clone(),
        telnet_pass: telnet_pass.clone(),
        uploaded_webshells: Arc::new(Mutex::new(HashMap::new())),
        banned_ips: Arc::new(Mutex::new(HashSet::new())),
        first_seen: Arc::new(Mutex::new(HashMap::new())),
        last_notification: Arc::new(Mutex::new(HashMap::new())),
        last_scan: Arc::new(Mutex::new(HashMap::new())),
    };

    state.log_event("--- Recon Deception Honeypot Daemon Started ---");
    state.log_event(&format!(
        "[*] Active Ban Time Limit set to: {} seconds",
        TIME_LIMIT_BEFORE_BAN
    ));
    state.log_event(&format!(
        "[*] Decoy telnet credential set: Username={}, Password={} (saved to {})",
        telnet_user, telnet_pass, cred_file
    ));

    // Spawn DNS listener
    let dns_state = state.clone();
    thread::spawn(move || {
        start_dns_listener(dns_state);
    });

    // Ports
    let ports = [21u16, 22, 23, 25, 80, 445, 3306, 3389, 8080];
    for port in ports {
        if port == 22 && Path::new(COWRIE_ACTIVE_FILE).exists() {
            state.log_event(
                "[*] Cowrie SSH honeypot marker present; skipping banner decoy on Port 22 (handed off to cowrie container)"
            );
            continue;
        }
        let port_state = state.clone();
        thread::spawn(move || {
            start_listener(port, port_state);
        });
    }

    println!("[*] Recon Deception Honeypot Daemon running in background...");
    loop {
        thread::sleep(Duration::from_secs(3600));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_sandbox_normalize() {
        assert_eq!(sandbox_normalize("/home/ubuntu", ""), "/home/ubuntu");
        assert_eq!(sandbox_normalize("/home/ubuntu", "notes.txt"), "/home/ubuntu/notes.txt");
        assert_eq!(sandbox_normalize("/home/ubuntu", ".."), "/home");
        assert_eq!(sandbox_normalize("/home/ubuntu", "/var/www"), "/var/www");
        assert_eq!(sandbox_normalize("/home/ubuntu", "~"), "/home/ubuntu");
        assert_eq!(sandbox_normalize("/home/ubuntu", "~/../var"), "/home/var");
        assert_eq!(sandbox_normalize("/home/ubuntu", "~/../../var"), "/var");
    }

    #[test]
    fn test_protocol_probes() {
        assert!(looks_like_protocol_probe("GET / HTTP/1.1\r\n"));
        assert!(looks_like_protocol_probe("SIP/2.0\r\n"));
        assert!(!looks_like_protocol_probe("admin"));
        assert!(!looks_like_protocol_probe("mysecretpassword123"));
    }

    #[test]
    fn test_dns_parse_and_build() {
        // Query for example.com
        let query = [
            0x12, 0x34, // ID
            0x01, 0x00, // Flags
            0x00, 0x01, // QDCOUNT
            0x00, 0x00, // ANCOUNT
            0x00, 0x00, // NSCOUNT
            0x00, 0x00, // ARCOUNT
            0x07, b'e', b'x', b'a', b'm', b'p', b'l', b'e',
            0x03, b'c', b'o', b'm',
            0x00,       // End of name
            0x00, 0x01, // Type A
            0x00, 0x01, // Class IN
        ];
        let (domain, qtype) = parse_dns_query(&query).expect("should parse dns");
        assert_eq!(domain, "example.com");
        assert_eq!(qtype, 1);

        let resp = build_dns_response(&query, "192.168.1.100").expect("should build response");
        assert_eq!(&resp[0..2], &[0x12, 0x34]);
        assert_eq!(&resp[resp.len() - 4..], &[192, 168, 1, 100]);
    }

    #[test]
    fn test_mock_command() {
        assert_eq!(execute_mock_command("whoami", "ubuntu-srv"), "www-data\n");
        assert_eq!(execute_mock_command("pwd", "ubuntu-srv"), "/var/www/html\n");
        assert!(execute_mock_command("uname -a", "ubuntu-srv").contains("ubuntu-srv"));
    }
}
