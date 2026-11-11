//! hal thunar-look [small | medium | large | status | auto]: how big and how readable the icons are in Thunar.
//! Sets Thunar's own icon sizes (xfconf channel "thunar"): the side bar, the folder tree, the list / compact / icon views
//! and the toolbar. The colours and the icon theme (Papirus) come from gtk-theme.sh.
//!   small    side bar 16, lists 18 px, icon view 36 px
//!   medium   side bar 22, lists 24 px, icon view 48 px          (default)
//!   large    side bar 24, lists 36 px, icon view 72 px
//!   status   prints the saved choice
//!   auto     what gtk-theme.sh runs: applies the choice ONCE (so a size you set by hand in Thunar is not undone later)
//! The choice is saved in ~/.local/state/island/file-icons. Needs xfconf-query (the xfconf package, installed with Thunar).
//! A bad argument returns 2 without a word: the bash original (the fallback of scripts/thunar-look.sh) prints the usage.

use crate::util;
use std::fs;

/// Bump when the sizes below change: `auto` then applies them once more.
const VER: &str = "2";

struct Sizes {
    side: u32,
    tree: u32,
    list: u32,
    compact: u32,
    icons: u32,
    small_toolbar: bool,
}

fn sizes(name: &str) -> Option<Sizes> {
    match name {
        "small" => Some(Sizes {
            side: 16,
            tree: 16,
            list: 38,
            compact: 38,
            icons: 75,
            small_toolbar: true,
        }),
        "medium" => Some(Sizes {
            side: 22,
            tree: 22,
            list: 50,
            compact: 50,
            icons: 100,
            small_toolbar: true,
        }),
        "large" => Some(Sizes {
            side: 24,
            tree: 24,
            list: 75,
            compact: 75,
            icons: 150,
            small_toolbar: false,
        }),
        _ => None,
    }
}

/// xfconf-query -c thunar -p PROPERTY -n -t TYPE -s VALUE (-n creates the property when it is not there yet)
fn xset(property: &str, ty: &str, value: &str) -> bool {
    util::ok(
        "xfconf-query",
        &["-c", "thunar", "-p", property, "-n", "-t", ty, "-s", value],
    )
}

pub fn run(args: &[String]) -> i32 {
    let state = util::state_dir();
    let file = state.join("file-icons");
    let mark = state.join("file-icons-applied");
    // the saved choice; anything else (or nothing saved) is medium
    let current = || -> String {
        match util::first_line(&file) {
            Some(v) if matches!(v.as_str(), "small" | "medium" | "large") => v,
            _ => "medium".to_string(),
        }
    };
    let cmd = args
        .first()
        .map(|s| s.as_str())
        .filter(|s| !s.is_empty())
        .unwrap_or("status");
    let size: String = match cmd {
        "status" => {
            println!("{}", current());
            return 0;
        }
        "auto" => {
            if util::first_line(&mark).as_deref() == Some(VER) {
                return 0;
            }
            current()
        }
        other => other.to_string(),
    };
    let sz = match sizes(&size) {
        Some(s) => s,
        None => return 2,
    };
    let _ = fs::create_dir_all(&state);
    let _ = fs::write(&file, format!("{}\n", size));
    if !util::command_exists("xfconf-query") {
        return 0;
    }
    let applied = xset(
        "/shortcuts-icon-size",
        "string",
        &format!("THUNAR_ICON_SIZE_{}", sz.side),
    );
    xset(
        "/tree-icon-size",
        "string",
        &format!("THUNAR_ICON_SIZE_{}", sz.tree),
    );
    xset(
        "/last-details-view-zoom-level",
        "string",
        &format!("THUNAR_ZOOM_LEVEL_{}_PERCENT", sz.list),
    );
    xset(
        "/last-compact-view-zoom-level",
        "string",
        &format!("THUNAR_ZOOM_LEVEL_{}_PERCENT", sz.compact),
    );
    xset(
        "/last-icon-view-zoom-level",
        "string",
        &format!("THUNAR_ZOOM_LEVEL_{}_PERCENT", sz.icons),
    );
    xset(
        "/misc-small-toolbar-icons",
        "bool",
        if sz.small_toolbar { "true" } else { "false" },
    );
    if applied {
        let _ = fs::write(&mark, format!("{}\n", VER));
    }
    0
}

#[cfg(test)]
mod tests {
    use super::sizes;

    #[test]
    fn the_three_sizes_and_nothing_else() {
        let m =
            sizes("medium").map(|s| (s.side, s.tree, s.list, s.compact, s.icons, s.small_toolbar));
        assert_eq!(m, Some((22, 22, 50, 50, 100, true)));
        assert_eq!(sizes("large").map(|s| s.icons), Some(150));
        assert_eq!(sizes("small").map(|s| s.side), Some(16));
        assert!(sizes("huge").is_none());
        assert!(sizes("").is_none());
    }
}
