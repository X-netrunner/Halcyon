"""scripts/halcyon-study.py chats: python3 tests/test_study_chats.py   (a temporary HOME; no Ollama, nothing real is touched)
One chat per material, several files added together = one chat, every chat reads only its own files and keeps its own conversation."""
import contextlib
import importlib.util
import io
import json
import os
import sys
import tempfile

here = os.path.dirname(os.path.abspath(__file__))
tmp = tempfile.mkdtemp(prefix="halcyon-study-test-")
os.environ.update({"HOME": tmp, "XDG_DATA_HOME": os.path.join(tmp, "data")})
spec = importlib.util.spec_from_file_location("st", os.path.join(here, "..", "scripts", "halcyon-study.py"))
st = importlib.util.module_from_spec(spec)
spec.loader.exec_module(st)
st.JSON_OUT = True
bad = n = 0


def check(label, got, want):
    global bad, n
    n += 1
    if got != want:
        bad += 1
        print(f"FAIL {label}: {got!r} (want {want!r})")


def run(fn, *args):
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        rc = fn(list(args))
    return rc, [json.loads(l) for l in buf.getvalue().splitlines() if l.strip().startswith("{")]


def write(name, text):
    p = os.path.join(tmp, name)
    with open(p, "w", encoding="utf-8") as f:
        f.write((text + "\n") * 8)
    return p


a = write("graphs.txt", "A graph has vertices and edges; trees are connected graphs without cycles.")
b = write("prob.txt", "Conditional probability and Bayes theorem relate prior and posterior beliefs.")
c = write("linalg.txt", "Eigenvalues and eigenvectors describe how a matrix stretches vectors.")

# --- add: one file = one chat; two files in one call = ONE chat; the same file again = the chat it already has
rc, ev = run(st.cmd_add, a)
ca = [e for e in ev if e["type"] == "chat"][0]
check("one file gets a chat of its own", (ca["chat"]["title"], len(ca["chat"]["docs"]), ca["again"]), ("graphs", 1, False))
rc, ev = run(st.cmd_add, b, c)
cbc = [e for e in ev if e["type"] == "chat"][0]
check("two files added together share one chat", (len(cbc["chat"]["docs"]), cbc["again"]), (2, False))
check("its title names the first file and counts the rest", cbc["chat"]["title"], "prob + 1 more")
rc, ev = run(st.cmd_add, a)
again = [e for e in ev if e["type"] == "chat"][0]
check("adding a file again opens its chat, no duplicate", (again["chat"]["id"], again["again"]), (ca["chat"]["id"], True))
check("so there are two chats", len(run(st.cmd_chats)[1][0]["chats"]), 2)

# --- ask: a chat reads only its own files and remembers only its own conversation
seen = []
st.need_ai = lambda: None
st.chat_stream = lambda msgs, num_predict=900, model=None, think=False: (seen.append(msgs), "an answer")[1]
st.route = lambda q, h, g: ("fake-model", "quick", "test", False)
run(st.cmd_ask, "--chat", cbc["chat"]["id"], "what", "are", "eigenvalues")
run(st.cmd_ask, "--chat", cbc["chat"]["id"], "and", "Bayes", "theorem")
run(st.cmd_ask, "--chat", ca["chat"]["id"], "what", "is", "a", "graph")
last_user = [m["content"] for m in seen[-1] if m["role"] == "user"]
check("a chat never sees another chat's earlier questions", any("eigenvalues" in u for u in last_user), False)
check("the graphs chat is answered from the graphs file", "vertices" in last_user[-1] and "Bayes" not in last_user[-1], True)
second = [m["content"] for m in seen[1] if m["role"] == "user"]
check("a chat remembers its own earlier question", any("eigenvalues" in u for u in second), True)
chats = {c["title"]: c["turns"] for c in run(st.cmd_chats)[1][0]["chats"]}
check("turns are kept per chat", chats, {"graphs": 1, "prob + 1 more": 2})
check("the conversation is readable back", [t["q"] for t in run(st.cmd_chat, cbc["chat"]["id"])[1][0]["turns"]],
      ["what are eigenvalues", "and Bayes theorem"])

# --- rename, clear, remove
rc, ev = run(st.cmd_chat_rename, cbc["chat"]["id"], "Maths", "revision")
check("a chat can be renamed", ev[0]["chat"]["title"], "Maths revision")
run(st.cmd_chat_rename, cbc["chat"]["id"])
check("an empty name goes back to the file's", run(st.cmd_chats)[1][0]["chats"][0]["title"] in ("prob + 1 more", "graphs"), True)
run(st.cmd_chat, cbc["chat"]["id"], "--clear")
check("clearing a chat keeps its files", [(c["turns"], len(c["docs"])) for c in run(st.cmd_chats)[1][0]["chats"] if c["id"] == cbc["chat"]["id"]], [(0, 2)])

docs = {d["name"]: d["id"] for d in run(st.cmd_list)[1][0]["docs"]}
run(st.cmd_remove, docs["linalg"])
check("removing one file of a shared chat shrinks it", [len(c["docs"]) for c in run(st.cmd_chats)[1][0]["chats"] if c["id"] == cbc["chat"]["id"]], [1])
run(st.cmd_remove, docs["prob"])
check("a chat left without files goes", len(run(st.cmd_chats)[1][0]["chats"]), 1)
run(st.cmd_chat_remove, ca["chat"]["id"])
check("deleting a chat forgets the files only it used", (run(st.cmd_chats)[1][0]["chats"], run(st.cmd_list)[1][0]["docs"]), ([], []))
check("the file itself is never touched", os.path.isfile(a), True)

# --- the single conversation of the earlier version moves into the chat it was about; every other file gets its own chat
os.remove(st.CHATS)
rc, ev = run(st.cmd_add, a)
os.remove(st.CHATS)                                                        # as if chats.json had never existed
docs = {d["name"]: d["id"] for d in run(st.cmd_list)[1][0]["docs"]}
json.dump([{"q": "old question", "a": "old answer", "sources": [], "model": "m", "secs": 2, "docs": [docs["graphs"]], "at": 1}],
          open(st.OLD_CHAT, "w"))
got = run(st.cmd_chats)[1][0]["chats"]
check("legacy: a chat per file", [c["title"] for c in got], ["graphs"])
check("legacy: the old conversation is in it", [t["q"] for t in run(st.cmd_chat, got[0]["id"])[1][0]["turns"]], ["old question"])
check("legacy: the old file is set aside", (os.path.exists(st.OLD_CHAT), os.path.exists(st.OLD_CHAT + ".migrated")), (False, True))

# --- bad input
try:
    run(st.cmd_ask, "--chat", "0" * 12, "hello")
    check("ask with an unknown chat is refused", "no error", "Fail")
except st.Fail:
    check("ask with an unknown chat is refused", "Fail", "Fail")
print(f"{n - bad}/{n} checks passed")
sys.exit(1 if bad else 0)
