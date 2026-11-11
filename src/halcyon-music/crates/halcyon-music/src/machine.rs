//! What this computer can run, and which Smart suggestions setup suits it.
//!
//! The advice is by size and hardware only. Nobody has benchmarked the models on a real machine yet
//! (see `docs/model-choice.md`), so the card says "suggested", not "best". Everything here that
//! decides something is a pure function; only [`Machine::detect`] touches the system.

use std::path::Path;

/// The parts of the computer that matter for a small language model.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct Machine {
    /// Installed memory, in megabytes (0 when it could not be read).
    pub ram_mb: u64,
    /// Logical CPU threads.
    pub threads: usize,
    /// An NVIDIA driver is loaded (Ollama can use it).
    pub nvidia: bool,
    /// An `ollama` program is installed (it may or may not be running).
    pub ollama_installed: bool,
}

/// `MemTotal` from `/proc/meminfo`, in megabytes.
pub fn parse_meminfo_mb(text: &str) -> Option<u64> {
    let line = text.lines().find(|l| l.starts_with("MemTotal:"))?;
    let kb: u64 = line.split_whitespace().nth(1)?.parse().ok()?;
    Some(kb / 1024)
}

fn on_path(program: &str) -> bool {
    std::env::var_os("PATH")
        .map(|paths| std::env::split_paths(&paths).any(|d| d.join(program).is_file()))
        .unwrap_or(false)
}

impl Machine {
    /// A few small reads; call it once at start-up, not from `view`.
    pub fn detect() -> Self {
        Machine {
            ram_mb: std::fs::read_to_string("/proc/meminfo")
                .ok()
                .and_then(|t| parse_meminfo_mb(&t))
                .unwrap_or(0),
            threads: std::thread::available_parallelism()
                .map(|n| n.get())
                .unwrap_or(1),
            nvidia: Path::new("/proc/driver/nvidia").exists() || Path::new("/dev/nvidia0").exists(),
            ollama_installed: on_path("ollama"),
        }
    }

    /// "16 GB memory, 8 threads, NVIDIA GPU" for the card.
    pub fn describe(&self) -> String {
        let mut parts = Vec::new();
        if self.ram_mb > 0 {
            parts.push(format!("{} GB memory", (self.ram_mb + 512) / 1024));
        }
        parts.push(format!("{} CPU threads", self.threads));
        if self.nvidia {
            parts.push("NVIDIA GPU".to_string());
        }
        parts.join(", ")
    }
}

/// What the card suggests and why.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Advice {
    /// `local` or `ollama`.
    pub backend: &'static str,
    /// Built-in model id (when `backend` is `local`).
    pub local_model: Option<&'static str>,
    /// Ollama model tag (when `backend` is `ollama`).
    pub ollama_model: Option<&'static str>,
    /// Short name shown on the card, e.g. "Built-in: Qwen2.5 0.5B".
    pub title: &'static str,
    pub why: &'static str,
}

/// Suggest a setup. `engine` is whether this build has the built-in model engine.
pub fn advise(m: &Machine, engine: bool) -> Advice {
    // A strong GPU and plenty of memory: a 3B model through Ollama is fast and writes noticeably better.
    if m.nvidia && m.ram_mb >= 12_000 && m.ollama_installed {
        return Advice {
            backend: "ollama",
            local_model: None,
            ollama_model: Some("llama3.2:3b"),
            title: "Ollama: llama3.2:3b",
            why: "Your NVIDIA GPU and memory can run a 3B model quickly, and its wording is better than the small built-in ones. Keep Ollama running.",
        };
    }
    // No built-in engine in this build: Ollama is the only way to get Smart suggestions.
    if !engine {
        return Advice {
            backend: "ollama",
            local_model: None,
            ollama_model: Some(if m.ram_mb >= 6_000 { "qwen2.5:3b" } else { "qwen2.5:1.5b" }),
            title: "Ollama",
            why: "This build has no built-in engine, so Ollama is the way to use Smart suggestions here. Install Ollama and pull the model named in the box.",
        };
    }
    // Small machine: the smallest model, so playback keeps the CPU.
    if m.ram_mb < 3_500 || m.threads <= 2 {
        return Advice {
            backend: "local",
            local_model: Some("qwen2.5-0.5b-instruct"),
            ollama_model: None,
            title: "Built-in: Qwen2.5 0.5B",
            why: "The smallest model (about 0.5 GB). It needs the least memory and leaves the processor to the music.",
        };
    }
    // Comfortable machine: one step up in size, still built in.
    if m.ram_mb >= 7_000 && m.threads >= 4 {
        return Advice {
            backend: "local",
            local_model: Some("llama3.2-1b-instruct"),
            ollama_model: None,
            title: "Built-in: Llama 3.2 1B",
            why: "About 0.8 GB, still built in with nothing else to run, and a little better at wording than the 0.5B model. It has its own licence (see the list).",
        };
    }
    Advice {
        backend: "local",
        local_model: Some("qwen2.5-0.5b-instruct"),
        ollama_model: None,
        title: "Built-in: Qwen2.5 0.5B",
        why: "A good fit for this memory: small, Apache-2.0, and nothing else to install.",
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn m(ram_mb: u64, threads: usize, nvidia: bool, ollama_installed: bool) -> Machine {
        Machine {
            ram_mb,
            threads,
            nvidia,
            ollama_installed,
        }
    }

    #[test]
    fn meminfo_is_read_in_megabytes() {
        let t = "MemTotal:       16384000 kB\nMemFree:  1 kB\n";
        assert_eq!(parse_meminfo_mb(t), Some(16_000));
        assert_eq!(parse_meminfo_mb("nothing"), None);
    }

    #[test]
    fn a_small_machine_gets_the_smallest_built_in_model() {
        let a = advise(&m(2_000, 2, false, false), true);
        assert_eq!(
            (a.backend, a.local_model),
            ("local", Some("qwen2.5-0.5b-instruct"))
        );
        // Few threads alone is enough to stay small, however much memory there is.
        assert_eq!(
            advise(&m(16_000, 2, false, false), true).local_model,
            Some("qwen2.5-0.5b-instruct")
        );
    }

    #[test]
    fn a_comfortable_machine_steps_up_but_stays_built_in() {
        let a = advise(&m(16_000, 8, false, true), true);
        assert_eq!(
            (a.backend, a.local_model),
            ("local", Some("llama3.2-1b-instruct"))
        );
        assert_eq!(
            advise(&m(5_000, 4, false, false), true).local_model,
            Some("qwen2.5-0.5b-instruct")
        );
    }

    #[test]
    fn a_gpu_machine_with_ollama_installed_gets_ollama() {
        let a = advise(&m(32_000, 16, true, true), true);
        assert_eq!((a.backend, a.ollama_model), ("ollama", Some("llama3.2:3b")));
        // The GPU alone is not enough when Ollama is not there: stay built in.
        assert_eq!(advise(&m(32_000, 16, true, false), true).backend, "local");
    }

    #[test]
    fn without_the_engine_the_advice_is_ollama() {
        let a = advise(&m(8_000, 8, false, false), false);
        assert_eq!(a.backend, "ollama");
        assert_eq!(a.ollama_model, Some("qwen2.5:3b"));
        assert_eq!(
            advise(&m(4_000, 4, false, false), false).ollama_model,
            Some("qwen2.5:1.5b")
        );
    }

    #[test]
    fn the_machine_reads_naturally() {
        assert_eq!(
            m(16_000, 8, true, false).describe(),
            "16 GB memory, 8 CPU threads, NVIDIA GPU"
        );
        assert_eq!(m(0, 1, false, false).describe(), "1 CPU threads");
    }
}
