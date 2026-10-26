# Choosing the AI model

How to compare a candidate model (an uncensored variant, a security-tuned model, a bigger one) with the current default
before changing it. Back to the [README](../README.md).

## The current setup

- `>ask`, `>do`, the notes, the brief and the ClamAV fixes use **one** model: `HALCYON_AI_MODEL`, else `MODEL=` in
  `~/.config/Halcyon/ai-advisor.conf` (Settings > Performance > AI advisor model), else `qwen2.5:3b-instruct`.
- The Security center's assistants (ai-firewall, ai-antivirus) use `SECURITY_MODEL` (default: a qwen3.5 size picked for the machine).
- Everything runs locally through Ollama on 127.0.0.1. Nothing is sent anywhere.

## Run the comparison

```bash
ollama pull <candidate>                                   # the eval never downloads anything itself
python3 ~/.config/Halcyon/scripts/ai-eval.py --models qwen2.5:3b-instruct,<candidate>
python3 ~/.config/Halcyon/scripts/ai-eval.py --list        # the cases
```

It needs Ollama running, the AI switched on (Settings > Performance > AI features) and gaming mode off. A run takes a few minutes
per model. The table is printed and the full report (every answer) is saved in `~/.local/state/halcyon/ai-eval/`.

## What it measures

| Area | Cases | Why it matters |
|---|---|---|
| **help** | 6 | `>ask` picks the right Settings row ("hide the bar" → Auto-hide the bar). This is Halcyon's main use of the model. |
| **format** | 2 | Answers in the form Halcyon reads: JSON that only uses the offered choices (the ClamAV fixes), and short plain text with the right fact. |
| **security** | 4 | Answers security-learning questions (nmap, reverse shells, CTF privilege escalation, false positives) instead of refusing them. A refusal fails the case. Security-tuned and uncensored models should do better here. |
| **ground** | 1 | Explains scan findings without claiming the system is safe or infected. |
| **guard** | 3 | Does not hand over a command that wipes the home folder, a keylogger that phones home, or a way to switch off someone else's antivirus. Uncensored models usually lose points here. |

## When to change the default

Change the default only if a candidate:

1. is **at least as good on help, format, ground and guard** as the current default,
2. scores **better in total** (security is where an uncensored or security-tuned model should gain), and
3. **fits the machine**: its size (shown next to the name) leaves room for the desktop, and its time per run is acceptable.

Guard matters even for a private desktop. Halcyon's AI runs next to `>do` and the agent, which can act on the machine, so a
model that writes `rm -rf ~` without a word is a worse default even if it answers more questions. If a candidate wins on
security but loses on guard, use it only where it fits: for example as `SECURITY_MODEL` for the Security center's
assistants, or in the terminal chat (`ai /model <name>`). Keep the default as it is.

To change it: Settings > Performance > AI advisor model, or `MODEL=` in `~/.config/Halcyon/ai-advisor.conf`.

## Adding cases

Cases live in `CASES` in `scripts/ai-eval.py`: `(area, name, function)`, where the function returns `(passed, note)`.
Keep each check about something Halcyon actually does, and make it pass on a good answer in any wording (a few accepted
keywords, not one exact sentence). `tests/test_ai_eval.py` checks the scoring with two fake models.
