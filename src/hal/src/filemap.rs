//! hal filemap : high-speed system filesystem mapping, categorization & instant search engine

use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime};

const IGNORED_DIRS: &[&str] = &[
    ".cache", ".git", "node_modules", "target", "__pycache__", ".cargo/registry",
    ".cargo/git", ".rustup", ".steam", ".local/share/Trash", ".local/share/containers",
    ".local/share/flatpak", ".local/share/Steam", ".local/share/lutris",
    ".wine", ".var/app", "venv", ".venv",
];

const IGNORED_NAMES: &[&str] = &[
    ".git", ".cache", "node_modules", "target", "__pycache__", "venv", ".venv",
];

/// The cached index is rebuilt when it is older than this.
const CACHE_MAX_AGE: Duration = Duration::from_secs(60 * 60);

#[derive(Debug, Clone)]
pub struct FileEntry {
    pub path: String,
    pub rel_path: String,
    pub category: String,
    pub size: u64,
    pub is_dir: bool,
}

fn home_dir() -> PathBuf {
    PathBuf::from(crate::util::home())
}

fn state_filemap_json() -> PathBuf {
    home_dir().join(".local/state/halcyon/filemap.json")
}

fn state_filemap_md() -> PathBuf {
    home_dir().join(".local/state/halcyon/filemap-summary.md")
}

fn luna_filemap_json() -> PathBuf {
    home_dir().join(".local/share/luna/filemap.json")
}

/// Is this directory one to skip? Matches whole path components (`target` must not hide `~/Projects/target-practice`).
fn should_ignore_dir(name: &str, full_path: &str) -> bool {
    if IGNORED_NAMES.contains(&name) {
        return true;
    }
    IGNORED_DIRS.iter().any(|ign| {
        if ign.contains('/') {
            full_path.strip_suffix(ign).is_some_and(|rest| rest.ends_with('/'))
        } else {
            name == *ign
        }
    })
}

/// Write via a temp file and rename, so a reader never sees a half-written file.
fn write_atomic(path: &Path, data: &str) -> std::io::Result<()> {
    let tmp = path.with_extension("tmp");
    fs::write(&tmp, data)?;
    fs::rename(&tmp, path)
}

fn rel_to_home(path_str: &str, home_str: &str) -> String {
    match path_str.strip_prefix(home_str) {
        Some(rest) if rest.is_empty() || rest.starts_with('/') => format!("~{}", rest),
        _ => path_str.to_string(),
    }
}

fn categorize(path: &str, is_dir: bool) -> &'static str {
    if is_dir {
        return "directory";
    }
    if path.contains("/.config/Halcyon/") || path.contains("/.config/hypr/") {
        return "rice_config";
    }
    if path.contains("/.config/") {
        return "user_config";
    }
    if path.contains("/Projects/") || path.contains("/src/") {
        return "project_source";
    }
    if path.contains("/.local/bin/") || path.ends_with(".sh") || path.ends_with(".py") || path.ends_with(".fish") {
        return "script";
    }
    if path.ends_with(".desktop") {
        return "desktop_entry";
    }
    if path.ends_with(".pdf") || path.ends_with(".docx") || path.ends_with(".md") || path.ends_with(".txt") {
        return "document";
    }
    if path.ends_with(".png") || path.ends_with(".jpg") || path.ends_with(".jpeg") || path.ends_with(".webp")
        || path.ends_with(".svg") || path.ends_with(".mp4") || path.ends_with(".mkv") || path.ends_with(".mp3")
        || path.ends_with(".flac") {
        return "media";
    }
    if path.ends_with(".rs") || path.ends_with(".toml") || path.ends_with(".json") || path.ends_with(".lua")
        || path.ends_with(".qml") || path.ends_with(".c") || path.ends_with(".cpp") || path.ends_with(".h") {
        return "source_code";
    }
    "file"
}

fn scan_directory(root: &Path, max_depth: usize, current_depth: usize, out: &mut Vec<FileEntry>) {
    if current_depth > max_depth {
        return;
    }
    let entries = match fs::read_dir(root) {
        Ok(e) => e,
        Err(_) => return,
    };

    let home_str = home_dir().to_string_lossy().to_string();

    for entry in entries.flatten() {
        let path = entry.path();
        let name = entry.file_name().to_string_lossy().to_string();
        let path_str = path.to_string_lossy().to_string();

        let file_type = match entry.file_type() {
            Ok(t) => t,
            Err(_) => continue,
        };
        // A symlink (stow / dotfile managers use them for ~/.config) is classified by what it points to.
        // Linked directories are listed but not entered, which also rules out symlink loops.
        let (is_dir, is_file, followed) = if file_type.is_symlink() {
            match fs::metadata(&path) {
                Ok(m) => (m.is_dir(), m.is_file(), true),
                Err(_) => continue, // dangling link
            }
        } else {
            (file_type.is_dir(), file_type.is_file(), false)
        };

        if is_dir {
            if should_ignore_dir(&name, &path_str) {
                continue;
            }
            out.push(FileEntry {
                rel_path: rel_to_home(&path_str, &home_str),
                path: path_str,
                category: "directory".to_string(),
                size: 0,
                is_dir: true,
            });
            if !followed {
                scan_directory(&path, max_depth, current_depth + 1, out);
            }
        } else if is_file {
            let size = if followed {
                fs::metadata(&path).map(|m| m.len()).unwrap_or(0)
            } else {
                entry.metadata().map(|m| m.len()).unwrap_or(0)
            };
            let cat = categorize(&path_str, false).to_string();
            out.push(FileEntry {
                rel_path: rel_to_home(&path_str, &home_str),
                path: path_str,
                category: cat,
                size,
                is_dir: false,
            });
        }
    }
}

pub fn generate_filemap() -> Vec<FileEntry> {
    let mut files = Vec::new();
    let home = home_dir();

    // 1. Scan key home areas with specific tuned depths
    let scans = [
        (home.join(".config"), 5),
        (home.join("Projects"), 6),
        (home.join("Documents"), 5),
        (home.join("Downloads"), 4),
        (home.join(".local/bin"), 2),
        (home.join(".local/share/applications"), 2),
        (home.join(".local/share/luna"), 3),
        (home.join("Desktop"), 3),
        (home.join("Pictures"), 3),
    ];

    for (dir, depth) in scans {
        if dir.is_dir() {
            scan_directory(&dir, depth, 1, &mut files);
        }
    }

    // 2. Scan system desktop applications
    let sys_apps = Path::new("/usr/share/applications");
    if sys_apps.is_dir() {
        scan_directory(sys_apps, 2, 1, &mut files);
    }

    // Save JSON
    save_json(&files);

    // Save Markdown summary
    save_markdown(&files);

    // Sync to Luna
    sync_to_luna(&files);

    files
}

fn save_json(files: &[FileEntry]) {
    let p = state_filemap_json();
    if let Some(parent) = p.parent() {
        let _ = fs::create_dir_all(parent);
    }

    let mut json = String::from("[\n");
    for (i, f) in files.iter().enumerate() {
        json.push_str("  {\n");
        json.push_str(&format!("    \"path\": {},\n", serde_escape(&f.path)));
        json.push_str(&format!("    \"rel\": {},\n", serde_escape(&f.rel_path)));
        json.push_str(&format!("    \"category\": \"{}\",\n", f.category));
        json.push_str(&format!("    \"size\": {},\n", f.size));
        json.push_str(&format!("    \"is_dir\": {}\n", f.is_dir));
        json.push_str(if i + 1 < files.len() { "  },\n" } else { "  }\n" });
    }
    json.push_str("]\n");

    let _ = write_atomic(&p, &json);

    // Also mirror to Luna directory
    let lp = luna_filemap_json();
    if let Some(parent) = lp.parent() {
        let _ = fs::create_dir_all(parent);
        let _ = write_atomic(&lp, &json);
    }
}

fn save_markdown(files: &[FileEntry]) {
    let p = state_filemap_md();
    let mut counts: BTreeMap<&str, usize> = BTreeMap::new();
    for f in files {
        if !f.is_dir {
            *counts.entry(&f.category).or_insert(0) += 1;
        }
    }

    let mut md = String::new();
    md.push_str("# System Filemap & Asset Directory\n\n");
    md.push_str(&format!("*Total Indexed Entities: {}*\n\n", files.len()));

    md.push_str("## 1. Asset Breakdown\n");
    for (cat, count) in &counts {
        md.push_str(&format!("- **{}**: {} files\n", cat, count));
    }

    md.push_str("\n## 2. Key Anchor Directories\n");
    md.push_str("- **Halcyon Rice & Configs**: `~/.config/Halcyon/` (Hyprland, Island, Helpers, Scripts)\n");
    md.push_str("- **Hyprland Direct Configs**: `~/.config/hypr/` (Loads Halcyon)\n");
    md.push_str("- **Projects & Code**: `~/Projects/` (Luna-stable, local repos)\n");
    md.push_str("- **Local Executables**: `~/.local/bin/` (`luna`, `ollama`, custom scripts)\n");
    md.push_str("- **Halcyon Binaries**: `~/.config/Halcyon/bin/` (`hal`, `hx`, `hgl`, etc.)\n");
    md.push_str("- **Desktop Applications**: `/usr/share/applications/` and `~/.local/share/applications/`\n");
    md.push_str("- **Documents & Study**: `~/Documents/` and `~/Downloads/`\n");

    md.push_str("\n## 3. Rice & Desktop Configuration Files\n");
    for f in files.iter().filter(|f| f.category == "rice_config" && !f.is_dir).take(40) {
        md.push_str(&format!("- `{}`\n", f.rel_path));
    }

    md.push_str("\n## 4. Installed Scripts & Tooling\n");
    for f in files.iter().filter(|f| f.category == "script" && !f.is_dir).take(30) {
        md.push_str(&format!("- `{}`\n", f.rel_path));
    }

    md.push_str("\n## 5. Active Projects\n");
    for f in files.iter().filter(|f| f.category == "project_source" && f.is_dir).take(20) {
        md.push_str(&format!("- `{}`\n", f.rel_path));
    }

    let _ = write_atomic(&p, &md);
}

fn sync_to_luna(files: &[FileEntry]) {
    let luna_mem_file = home_dir().join(".local/share/luna/permanent_memory.json");
    let rice_count = files.iter().filter(|f| f.category == "rice_config" && !f.is_dir).count();
    let script_count = files.iter().filter(|f| f.category == "script" && !f.is_dir).count();
    let proj_count = files.iter().filter(|f| f.path.contains("/Projects/") && f.is_dir).count();

    let fact = format!(
        "System filemap indexed: {} total files mapped. Rice configs ({} files in ~/.config/Halcyon), Scripts ({} scripts in bin/scripts), Projects ({} repos in ~/Projects). Fast file lookup is available via filemap.",
        files.len(), rice_count, script_count, proj_count
    );

    let date_str = crate::util::out("date", &["+%Y-%m-%d"]);
    let date_clean = date_str.trim();

    // Never rewrite a memory file we cannot read as a JSON array: LUNA would lose everything it remembers.
    let mut existing_mem: Vec<crate::json::Json> = Vec::new();
    if let Ok(content) = fs::read_to_string(&luna_mem_file) {
        match crate::json::parse(&content) {
            Some(crate::json::Json::Arr(items)) => existing_mem = items,
            _ => return,
        }
    }
    if let Some(parent) = luna_mem_file.parent() {
        let _ = fs::create_dir_all(parent);
    }

    existing_mem.retain(|item| {
        if let Some(c) = item.str("content") {
            !c.starts_with("System filemap indexed:")
        } else {
            true
        }
    });

    let obj = vec![
        ("content".to_string(), crate::json::Json::Str(fact)),
        ("added".to_string(), crate::json::Json::Str(date_clean.to_string())),
        ("category".to_string(), crate::json::Json::Str("filemap".to_string())),
    ];
    existing_mem.push(crate::json::Json::Obj(obj));

    // Save JSON
    let mut json_out = String::from("[\n");
    for (i, item) in existing_mem.iter().enumerate() {
        let content = item.str("content").unwrap_or("");
        let added_dt = item.str("added").unwrap_or(date_clean);
        let category = item.str("category").unwrap_or("system");
        json_out.push_str("  {\n");
        json_out.push_str(&format!("    \"content\": {},\n", serde_escape(content)));
        json_out.push_str(&format!("    \"added\": {},\n", serde_escape(added_dt)));
        json_out.push_str(&format!("    \"category\": {}\n", serde_escape(category)));
        json_out.push_str(if i + 1 < existing_mem.len() { "  },\n" } else { "  }\n" });
    }
    json_out.push_str("]\n");

    let _ = write_atomic(&luna_mem_file, &json_out);
}

fn load_or_generate() -> Vec<FileEntry> {
    let p = state_filemap_json();
    let fresh = fs::metadata(&p)
        .and_then(|m| m.modified())
        .ok()
        .and_then(|t| SystemTime::now().duration_since(t).ok())
        .is_some_and(|age| age < CACHE_MAX_AGE);
    if !fresh {
        return generate_filemap();
    }
    if let Ok(content) = fs::read_to_string(&p) {
        if let Some(crate::json::Json::Arr(items)) = crate::json::parse(&content) {
            let mut list = Vec::new();
            for item in items {
                let path = item.str("path").unwrap_or("").to_string();
                let rel_path = item.str("rel").unwrap_or("").to_string();
                let category = item.str("category").unwrap_or("file").to_string();
                let size = item.num("size").unwrap_or(0.0) as u64;
                let is_dir = item.bool("is_dir").unwrap_or(false);
                list.push(FileEntry {
                    path,
                    rel_path,
                    category,
                    size,
                    is_dir,
                });
            }
            if !list.is_empty() {
                return list;
            }
        }
    }
    generate_filemap()
}

pub fn search(query: &str) -> String {
    let files = load_or_generate();
    let q = query.to_lowercase();
    let matches: Vec<&FileEntry> = files
        .iter()
        .filter(|f| f.path.to_lowercase().contains(&q) || f.rel_path.to_lowercase().contains(&q))
        .collect();

    if matches.is_empty() {
        return format!("No files found matching query '{}'.", query);
    }

    let mut out = format!("### Filemap Search Results for '{}' ({} found):\n", query, matches.len());
    for f in matches.iter().take(40) {
        let kind = if f.is_dir { "DIR" } else { &f.category };
        out.push_str(&format!("- `[{}]` {} ({})\n", kind, f.rel_path, format_size(f.size)));
    }
    if matches.len() > 40 {
        out.push_str(&format!("\n... and {} more matching files.\n", matches.len() - 40));
    }
    out
}

pub fn locate_category(cat: &str) -> String {
    let files = load_or_generate();
    let c = cat.to_lowercase();
    let matches: Vec<&FileEntry> = files
        .iter()
        .filter(|f| !f.is_dir && (f.category.to_lowercase().contains(&c) || (c == "rice" && f.category == "rice_config")))
        .collect();

    if matches.is_empty() {
        return format!("No files found in category '{}'. Available: rice_config, user_config, project_source, script, document, media, desktop_entry.", cat);
    }

    let mut out = format!("### Category '{}' Files ({} found):\n", cat, matches.len());
    for f in matches.iter().take(40) {
        out.push_str(&format!("- `{}` ({})\n", f.rel_path, format_size(f.size)));
    }
    if matches.len() > 40 {
        out.push_str(&format!("\n... and {} more files in this category.\n", matches.len() - 40));
    }
    out
}

pub fn summary() -> String {
    let p = state_filemap_md();
    if let Ok(c) = fs::read_to_string(&p) {
        return c;
    }
    let _ = generate_filemap();
    fs::read_to_string(&p).unwrap_or_else(|_| "Filemap generated.".to_string())
}

fn format_size(bytes: u64) -> String {
    if bytes == 0 {
        return "dir/0B".to_string();
    }
    if bytes < 1024 {
        format!("{} B", bytes)
    } else if bytes < 1024 * 1024 {
        format!("{:.1} KB", bytes as f64 / 1024.0)
    } else {
        format!("{:.1} MB", bytes as f64 / (1024.0 * 1024.0))
    }
}

fn serde_escape(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    out.push('"');
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            other => out.push(other),
        }
    }
    out.push('"');
    out
}

pub fn run(args: &[String]) -> i32 {
    let mode = args.first().map(|s| s.as_str()).unwrap_or("summary");
    match mode {
        "generate" | "refresh" | "build" | "scan" => {
            let files = generate_filemap();
            println!("System filemap generated: {} files indexed across rice, projects, scripts, and docs.", files.len());
            0
        }
        "search" | "find" => {
            let q = args.get(1).map(|s| s.as_str()).unwrap_or("");
            if q.is_empty() {
                println!("Usage: hal filemap search <pattern>");
                return 1;
            }
            println!("{}", search(q));
            0
        }
        "locate" | "category" | "cat" => {
            let cat = args.get(1).map(|s| s.as_str()).unwrap_or("rice");
            println!("{}", locate_category(cat));
            0
        }
        "summary" | "info" => {
            println!("{}", summary());
            0
        }
        _ => {
            if !mode.is_empty() && !mode.starts_with('-') {
                println!("{}", search(mode));
                0
            } else {
                println!("{}", summary());
                0
            }
        }
    }
}
