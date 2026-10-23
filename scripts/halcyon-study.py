#!/usr/bin/env python3
"""halcyon-study.py: the Study Center's library and answers (StudyCenter.qml, `>study` in the launcher, `halcyon study`).
Everything stays on this machine: the text of your files is read here and the same local Ollama model as `ai` answers.

  halcyon-study.py add <file>...                read files into the library: PDF (scans are read with tesseract), Word / PowerPoint /
                                                LibreOffice, EPUB, Markdown, text, code, HTML, and photos of pages (tesseract)
  halcyon-study.py list                         the library
  halcyon-study.py remove <id>                  forget a file (the file itself is never touched)
  halcyon-study.py ask [--docs ID,ID] [--history JSON] [--model NAME|best] <question>
                                                an answer from the files, with the pages it came from (all files when --docs is left out)
  halcyon-study.py make summary|quiz|cards [--docs ID,ID] [--pages 3-9] [--n 10] [--fresh]
                                                a revision summary, exam questions with answers, or flashcards (kept, so opening them
                                                again is instant; --fresh writes new ones)
  halcyon-study.py saved summary|quiz|cards [--docs ID,ID] [--pages A-B]
                                                what `make` kept last time, if anything
  halcyon-study.py open <id> [page]             open the file (at that page when the PDF viewer can)
  halcyon-study.py models                       the installed models, how each runs on this machine, what Auto picks, what to download
  halcyon-study.py use auto|<model> [--reason auto|always|never] [--prefer balanced|quality|speed]
                                                the Study Center's own model (the rest of Halcyon keeps its own); Auto = smart routing:
                                                quick lookups go to a fast model, explanations, reasoning and summaries to the best one
  halcyon-study.py chat [--clear]               the saved conversation (the window shows it again when it opens)
  halcyon-study.py grade --q Q --key EXPECTED --mine YOURS
                                                mark your own answer to a quiz question: right / partly / wrong, and why

--json (or --stream) prints one JSON object per line for the island:
  {"type": "progress", "msg"}  {"type": "added", "doc"}  {"type": "sources", "sources": [{"doc", "name", "page", "unit"}]}
  {"type": "tok", "t"}  {"type": "think", "t"} (the model's reasoning, apart from the answer)  {"type": "reset", "text"} (replace the
  answer so far)  {"type": "model", "model", "route", "why"}  {"type": "result", "mode", "text", "items"}  {"type": "error", "error"}
  {"type": "done", "secs"}
The library lives in ~/.local/share/halcyon/study (index.json + the text of each file). Exit code 0 ok, 1 failed, 2 usage,
3 AI switched off / Ollama not running.
"""
import contextlib
import hashlib
import html
import importlib.util
import json
import math
import os
import re
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.request
import zipfile

HOME = os.path.expanduser("~")
RICE = os.environ.get("HALCYON_DIR", os.path.join(HOME, ".config", "Halcyon"))
HERE = os.path.dirname(os.path.abspath(__file__))
DATA = os.path.join(os.environ.get("XDG_DATA_HOME") or os.path.join(HOME, ".local", "share"), "halcyon", "study")
INDEX = os.path.join(DATA, "index.json")

PAGE_CHARS = 3000           # files without real pages (text, Word, EPUB) are cut into "parts" of about this size
CHUNK = 1100                # what the search ranks: pieces of a page
CONTEXT_CHARS = 12000       # excerpts given to the model per question (about 3000 tokens, room left in NUM_CTX)
OCR_MAX_PAGES = 120         # a scanned PDF longer than this: only the first pages are read
MAX_CHARS = 2_000_000       # a whole book is fine; past this the rest of the file is left out

TEXT_EXT = {"txt", "md", "markdown", "rst", "org", "tex", "csv", "tsv", "json", "yaml", "yml", "toml", "ini", "log",
            "py", "c", "h", "cpp", "hpp", "cc", "java", "js", "ts", "rs", "go", "sh", "fish", "lua", "qml", "sql", "r", "m",
            "kt", "swift", "rb", "php", "css", "scss", "xml"}
HTML_EXT = {"html", "htm", "xhtml"}
IMAGE_EXT = {"png", "jpg", "jpeg", "webp", "tif", "tiff", "bmp", "gif"}
OFFICE_EXT = {"docx", "pptx", "odt", "odp", "epub"}
EXTS = sorted({"pdf"} | TEXT_EXT | HTML_EXT | IMAGE_EXT | OFFICE_EXT)

JSON_OUT = False


class Fail(Exception):
    pass


class AiOff(Exception):
    pass


# ------------------------------------------------------------------------------------------------ output
def emit(**o):
    if JSON_OUT:
        print(json.dumps(o, ensure_ascii=False), flush=True)
        return
    t = o.get("type")
    if t == "progress" and sys.stderr.isatty():
        print("\r\033[2K\033[2m" + o["msg"] + "\033[0m", end="", file=sys.stderr, flush=True)
    elif t == "tok":
        print(o["t"], end="", flush=True)
    elif t == "added":
        d = o["doc"]
        print(f"\r\033[2K" if sys.stderr.isatty() else "", end="", file=sys.stderr)
        print(f"Added {d['name']}: {d['pages']} {d['unit']}{'s' if d['pages'] != 1 else ''}" + (" (read with OCR)" if d.get("ocr") else ""))
    elif t == "sources" and o["sources"]:
        pass
    elif t == "result":
        print(o["text"])
    elif t == "error":
        print(("\r\033[2K" if sys.stderr.isatty() else "") + "study: " + o["error"], file=sys.stderr)


def progress(msg):
    emit(type="progress", msg=msg)


# ------------------------------------------------------------------------------------------------ the AI (halcyon-ai.py)
_ai = None


def ai():
    """halcyon-ai.py as a module: the model, the on / off switches and the summary / quiz / cards writers live there."""
    global _ai
    if _ai is None:
        for p in (os.path.join(HERE, "halcyon-ai.py"), os.path.join(RICE, "scripts", "halcyon-ai.py")):      # its own copy first
            if os.path.isfile(p):
                spec = importlib.util.spec_from_file_location("halcyon_ai", p)
                m = importlib.util.module_from_spec(spec)
                spec.loader.exec_module(m)
                m.progress = lambda msg: progress(msg) if msg else None     # its "reading part 3 of 9" reaches the window too
                _ai = m
                break
        if _ai is None:
            raise Fail("halcyon-ai.py is missing: run ./install.sh again")
    return _ai


def need_ai():
    a = ai()
    try:
        a.need_ai()
    except a.AiOff as e:
        raise AiOff(str(e))


def keep_alive():
    # Settings > Performance > Aggressive Memory Freeing: the model (2-3 GB) is let go 3 minutes after the last answer, else 30
    return "3m" if ai().opt("lazyLoad", True) is not False else "30m"


# ------------------------------------------------------------------------------------------------ library
def load_index():
    try:
        with open(INDEX, "r", encoding="utf-8") as f:
            d = json.load(f)
        return d if isinstance(d, list) else []
    except (OSError, ValueError):
        return []


def save_index(docs):
    os.makedirs(DATA, exist_ok=True)
    tmp = INDEX + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(docs, f, ensure_ascii=False, indent=1)
    os.replace(tmp, INDEX)


def text_path(doc_id):
    return os.path.join(DATA, doc_id + ".json")


def load_pages(doc_id):
    try:
        with open(text_path(doc_id), "r", encoding="utf-8") as f:
            return json.load(f).get("pages") or []
    except (OSError, ValueError, AttributeError):
        return []


def valid_id(s):
    return bool(re.fullmatch(r"[a-f0-9]{12}", s or ""))


def sh(argv, timeout=60, data=None):
    try:
        r = subprocess.run(argv, input=data, capture_output=True, timeout=timeout)
        return r.returncode, r.stdout
    except (OSError, subprocess.TimeoutExpired):
        return 1, b""


def clean(t):
    t = t.replace("\r", "")
    t = re.sub(r"[ \t ]+", " ", t)
    t = re.sub(r" *\n *", "\n", t)
    t = re.sub(r"(\w)-\n(\w)", r"\1\2", t)          # words broken over a line end
    t = re.sub(r"\n{3,}", "\n\n", t)
    return t.strip()


def split_parts(text, size=PAGE_CHARS):
    """Text with no pages of its own -> parts of about `size` characters, cut between paragraphs."""
    out, cur = [], ""
    for para in re.split(r"\n\s*\n", text):
        para = para.strip()
        if not para:
            continue
        if cur and len(cur) + len(para) > size:
            out.append(cur.strip())
            cur = ""
        while len(para) > size * 1.5:
            out.append(para[:size])
            para = para[size:]
        cur += para + "\n\n"
    if cur.strip():
        out.append(cur.strip())
    return out


def ocr_image(path):
    if not shutil.which("tesseract"):
        raise Fail("tesseract is not installed, so pictures cannot be read (sudo pacman -S tesseract tesseract-data-eng)")
    code, out = sh(["tesseract", path, "-", "--psm", "3"], timeout=180)
    return clean(out.decode("utf-8", "replace")) if code == 0 else ""


def read_pdf(path):
    if not shutil.which("pdftotext"):
        raise Fail("pdftotext is not installed (sudo pacman -S poppler)")
    code, out = sh(["pdftotext", "-enc", "UTF-8", path, "-"], timeout=300)
    if code != 0:
        raise Fail("could not read it (a damaged or password-protected PDF?)")
    pages = [clean(p) for p in out.decode("utf-8", "replace").split("\f")]
    while pages and not pages[-1]:
        pages.pop()
    real = sum(len(p) for p in pages)
    if pages and real / len(pages) >= 80:
        return pages, False
    # (almost) no text: a scan. Each page is turned into a picture and read with tesseract
    if not shutil.which("tesseract") or not shutil.which("pdftoppm"):
        raise Fail("this PDF is a scan (pictures of pages) and tesseract is not installed to read it (sudo pacman -S tesseract tesseract-data-eng)")
    n = len(pages) or 1
    if shutil.which("pdfinfo"):
        c, info = sh(["pdfinfo", path], timeout=20)
        m = re.search(rb"^Pages:\s+(\d+)", info, re.M)
        if m:
            n = int(m.group(1))
    n = min(n, OCR_MAX_PAGES)
    tmp = os.path.join(os.environ.get("XDG_RUNTIME_DIR") or "/tmp", f"halcyon-study-{os.getpid()}")
    os.makedirs(tmp, exist_ok=True)
    out_pages = []
    try:
        for i in range(1, n + 1):
            progress(f"reading the scanned pages: {i} of {n}")
            base = os.path.join(tmp, "p")
            sh(["pdftoppm", "-r", "200", "-gray", "-png", "-singlefile", "-f", str(i), "-l", str(i), path, base], timeout=120)
            img = base + ".png"
            out_pages.append(ocr_image(img) if os.path.isfile(img) else "")
            with contextlib.suppress(OSError):
                os.remove(img)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    return out_pages, True


def xml_text(raw, para_tags):
    """The text of an Office XML part: a line break after each paragraph tag, every other tag dropped."""
    s = raw.decode("utf-8", "replace")
    s = re.sub(r"<(?:%s)\b[^>]*/>" % "|".join(para_tags), "\n", s)
    s = re.sub(r"</(?:%s)>" % "|".join(para_tags), "\n", s)
    s = re.sub(r"<w:tab/>|<text:tab/>", " ", s)
    s = re.sub(r"<[^>]+>", "", s)
    return clean(html.unescape(s))


def html_text(s):
    s = re.sub(r"(?is)<(script|style|head)\b.*?</\1>", " ", s)
    s = re.sub(r"(?i)<br\s*/?>|</(p|div|h[1-6]|li|tr|section|article)>", "\n", s)
    s = re.sub(r"<[^>]+>", "", s)
    return clean(html.unescape(s))


def read_office(path, ext):
    try:
        z = zipfile.ZipFile(path)
    except (OSError, zipfile.BadZipFile):
        raise Fail("could not open it (not a real ." + ext + " file?)")
    with z:
        names = z.namelist()
        if ext == "docx":
            return split_parts(xml_text(z.read("word/document.xml"), ["w:p"])), "part"
        if ext == "pptx":
            slides = sorted((n for n in names if re.fullmatch(r"ppt/slides/slide\d+\.xml", n)), key=lambda n: int(re.findall(r"\d+", n)[-1]))
            pages = []
            for n in slides:
                t = xml_text(z.read(n), ["a:p"])
                notes = n.replace("slides/slide", "notesSlides/notesSlide")
                if notes in names:
                    nt = xml_text(z.read(notes), ["a:p"])
                    nt = re.sub(r"^\d+\s*$", "", nt, flags=re.M).strip()
                    if nt:
                        t += "\n\nSpeaker notes: " + nt
                pages.append(t)
            return pages, "slide"
        if ext in ("odt", "odp"):
            t = xml_text(z.read("content.xml"), ["text:p", "text:h", "draw:page"] if ext == "odp" else ["text:p", "text:h"])
            if ext == "odp":
                raw = z.read("content.xml").decode("utf-8", "replace")
                return [xml_text(p.encode(), ["text:p", "text:h"]) for p in re.findall(r"(?s)<draw:page\b.*?</draw:page>", raw)], "slide"
            return split_parts(t), "part"
        if ext == "epub":
            spine = [n for n in names if re.search(r"\.(x?html?)$", n, re.I)]
            opf = next((n for n in names if n.endswith(".opf")), None)
            if opf:                                         # the book's own reading order
                o = z.read(opf).decode("utf-8", "replace")
                items = dict(re.findall(r'<item\b[^>]*id="([^"]+)"[^>]*href="([^"]+)"', o))
                items.update({k: v for v, k in re.findall(r'<item\b[^>]*href="([^"]+)"[^>]*id="([^"]+)"', o)})
                base = os.path.dirname(opf)
                order = [os.path.normpath(os.path.join(base, items[i])).replace("\\", "/") for i in re.findall(r'<itemref\b[^>]*idref="([^"]+)"', o) if i in items]
                order = [n for n in order if n in names]
                if order:
                    spine = order
            text = "\n\n".join(html_text(z.read(n).decode("utf-8", "replace")) for n in spine)
            return split_parts(text), "part"
    raise Fail("not a file type the Study Center reads")


def extract(path):
    """-> (pages, unit, ocr)"""
    ext = os.path.splitext(path)[1].lower().lstrip(".")
    if ext == "pdf":
        pages, ocr = read_pdf(path)
        return pages, "page", ocr
    if ext in IMAGE_EXT:
        return [ocr_image(path)], "image", True
    if ext in OFFICE_EXT:
        pages, unit = read_office(path, ext)
        return pages, unit, False
    if ext in TEXT_EXT or ext in HTML_EXT or ext == "":
        with open(path, "rb") as f:
            raw = f.read(MAX_CHARS * 2)
        if b"\0" in raw[:4096]:
            raise Fail("this looks like a binary file, not text")
        t = raw.decode("utf-8", "replace")
        t = html_text(t) if ext in HTML_EXT else clean(t)
        return split_parts(t), "part", False
    raise Fail("the Study Center does not read ." + ext + " files (PDF, Word, PowerPoint, EPUB, text and pictures work)")


def nice_name(fname):
    """"Q__8HGJKSWKvlb..._ad50d57e..._Google-Cybersecurity-Certificate-glossary.docx" -> "Google Cybersecurity Certificate glossary"."""
    n = os.path.splitext(fname)[0]
    parts = [x for x in re.split(r"_+", n) if x]
    # download ids and hashes in front: long runs of letters + digits with no vowels pattern a person would type
    idlike = lambda x: bool(re.fullmatch(r"[A-Za-z0-9-]{16,}", x) and re.search(r"\d", x))
    while len(parts) > 1 and (idlike(parts[0]) or (len(parts[0]) <= 2 and idlike(parts[1]))):
        parts.pop(0)
    n = " ".join(parts)
    n = re.sub(r"(?<=[a-z])-(?=[A-Za-z])", " ", n) if " " not in n.strip() else n
    n = re.sub(r"\s*\((\d+)\)$", "", n)           # "notes (1)" from a second download
    return re.sub(r"\s{2,}", " ", n).strip() or os.path.splitext(fname)[0]


def file_id(path):
    st = os.stat(path)
    return hashlib.sha1(f"{os.path.realpath(path)}\0{st.st_size}\0{int(st.st_mtime)}".encode()).hexdigest()[:12]


def public(d):
    return {k: d.get(k) for k in ("id", "name", "path", "unit", "pages", "chars", "ocr", "added", "ext")}


def cmd_add(args):
    files = [os.path.abspath(os.path.expanduser(a)) for a in args if not a.startswith("--")]
    if not files:
        raise Fail("add <file>...")
    docs = load_index()
    bad = 0
    for path in files:
        name = os.path.basename(path)
        try:
            if not os.path.isfile(path):
                raise Fail("not found")
            did = file_id(path)
            old = next((d for d in docs if d.get("id") == did), None)
            if old and os.path.isfile(text_path(did)):
                emit(type="added", doc=public(old), again=True)
                continue
            # the same file changed since it was added: the old copy of its text goes
            for d in [d for d in docs if d.get("path") == path]:
                forget(d["id"])
            docs = [d for d in docs if d.get("path") != path]
            progress(f"reading {name}")
            pages, unit, ocr = extract(path)
            total, kept = 0, []
            for p in pages:
                if total >= MAX_CHARS:
                    break
                kept.append(p[: MAX_CHARS - total])
                total += len(kept[-1])
            if total < 20:
                raise Fail("there is no text in this picture" if unit == "image" else "no text could be read from it")
            os.makedirs(DATA, exist_ok=True)
            with open(text_path(did), "w", encoding="utf-8") as f:
                json.dump({"pages": kept}, f, ensure_ascii=False)
            d = {"id": did, "name": nice_name(name), "path": path, "ext": os.path.splitext(name)[1].lower().lstrip("."),
                 "unit": unit, "pages": len(kept), "chars": total, "ocr": ocr, "added": int(time.time())}
            docs.insert(0, d)
            save_index(docs)
            emit(type="added", doc=public(d))
        except Fail as e:
            bad += 1
            emit(type="error", error=f"{name}: {e}", file=path)
    return 1 if bad == len(files) else 0


def forget(doc_id):
    for f in os.listdir(DATA) if os.path.isdir(DATA) else []:
        if f.startswith(doc_id + ".") or f.startswith("made-") and doc_id in f:
            with contextlib.suppress(OSError):
                os.remove(os.path.join(DATA, f))


def cmd_remove(args):
    ids = [a for a in args if valid_id(a)]
    if not ids:
        raise Fail("remove <id>")
    docs = load_index()
    for i in ids:
        forget(i)
    save_index([d for d in docs if d.get("id") not in ids])
    emit(type="done")
    return 0


def cmd_list(args):
    docs = [public(d) for d in load_index() if os.path.isfile(text_path(d.get("id", "")))]
    if JSON_OUT:
        model = ""
        with contextlib.suppress(Exception):
            model = ai().model_name()
        print(json.dumps({"docs": docs, "model": model, "exts": EXTS}, ensure_ascii=False))
        return 0
    if not docs:
        print("The library is empty. Add a file: halcyon study add notes.pdf")
    for d in docs:
        print(f"{d['id']}  {d['name']}  ({d['pages']} {d['unit']}s{', OCR' if d.get('ocr') else ''})")
    return 0


def pick_docs(args):
    docs = load_index()
    want = argval(args, "--docs", "")
    if want:
        ids = [i for i in want.split(",") if valid_id(i)]
        docs = [d for d in docs if d.get("id") in ids]
    docs = [d for d in docs if os.path.isfile(text_path(d.get("id", "")))]
    if not docs:
        raise Fail("no files to study yet: add one first" if not want else "those files are not in the library any more")
    return docs


def page_range(args):
    r = argval(args, "--pages", "")
    m = re.fullmatch(r"\s*(\d+)\s*(?:[-–]\s*(\d+))?\s*", r)
    if not m:
        return None
    a = int(m.group(1))
    b = int(m.group(2) or a)
    return (min(a, b), max(a, b))


# ------------------------------------------------------------------------------------------------ search (BM25)
STOP = set("""a an the and or but if then else of to in on at by for with from as is are was were be been being this that these those it
its into than so such not no do does did doing have has had what which who whom whose when where why how can could should would
will shall may might must i you he she we they me him her us them my your our their about explain tell describe give show list
define please also more most some any each other there here just very use used using between""".split())


def words(t):
    return [w for w in re.findall(r"[a-z0-9][a-z0-9+#.\-]*[a-z0-9+#]|[a-z0-9]", t.lower()) if w not in STOP]


def stem(w):
    for suf in ("ations", "ation", "ings", "ing", "ies", "ied", "es", "ed", "ly", "s"):
        if len(w) > len(suf) + 3 and w.endswith(suf):
            return w[: -len(suf)] + ("y" if suf in ("ies", "ied") else "")
    return w


def pieces(docs, rng=None):
    """Every searchable piece: {doc, name, unit, page (1-based), text}"""
    out = []
    for d in docs:
        for pi, page in enumerate(load_pages(d["id"]), 1):
            if rng and not (rng[0] <= pi <= rng[1]):
                continue
            if not page.strip():
                continue
            for k in range(0, len(page), CHUNK):
                # a little overlap, so a sentence cut at the edge is still found whole in one of the two
                t = page[max(0, k - 120): k + CHUNK]
                out.append({"doc": d["id"], "name": d["name"], "unit": d["unit"], "page": pi, "text": t})
    return out


def rank(ps, query, prev=""):
    q = [stem(w) for w in words(query)]
    qp = [stem(w) for w in words(prev)] if prev else []
    if not q and not qp:
        return []
    toks = [[stem(w) for w in words(p["text"])] for p in ps]
    n = len(toks)
    avg = sum(len(t) for t in toks) / max(1, n)
    df = {}
    for t in toks:
        for w in set(t):
            df[w] = df.get(w, 0) + 1
    qw = {}
    for w in q:
        qw[w] = qw.get(w, 0) + 1.0
    for w in qp:                      # a follow-up ("and its advantages?"): the last question's words count for half
        qw[w] = qw.get(w, 0) + 0.5
    scores = []
    k1, b = 1.4, 0.75
    phrase = " ".join(words(query))
    for i, t in enumerate(toks):
        if not t:
            continue
        tf = {}
        for w in t:
            tf[w] = tf.get(w, 0) + 1
        s = 0.0
        for w, wt in qw.items():
            f = tf.get(w)
            if not f:
                continue
            idf = math.log(1 + (n - df[w] + 0.5) / (df[w] + 0.5))
            s += wt * idf * f * (k1 + 1) / (f + k1 * (1 - b + b * len(t) / avg))
        if s > 0 and len(phrase) > 6 and phrase in " ".join(words(ps[i]["text"])):
            s *= 1.4                  # the words of the question, side by side
        if s > 0:
            scores.append((s, i))
    scores.sort(reverse=True)
    return scores


GENERAL = re.compile(r"\b(summar|overview|about|main (idea|point|topic)s?|key (idea|point|concept)s?|outline|gist|tl;?dr|what is (this|it) (about|on))", re.I)


def gather(ps, question, prev, budget=CONTEXT_CHARS):
    """The excerpts for a question: the best pieces (neighbours on the same page merged), at most `budget` characters."""
    scores = rank(ps, question, prev)
    general = bool(GENERAL.search(question)) or not scores
    chosen = []
    if general:
        # "what is this about": the start of each file and an even spread through it
        by_doc = {}
        for i, p in enumerate(ps):
            by_doc.setdefault(p["doc"], []).append(i)
        per = max(1, int(budget / CHUNK / max(1, len(by_doc))))
        for idx in by_doc.values():
            step = max(1, len(idx) // per)
            chosen += idx[::step][:per]
        chosen += [i for _, i in scores[:3]]
    else:
        top = scores[0][0]
        chosen = [i for s, i in scores[:14] if s >= top * 0.25]
    out, used, seen = [], 0, set()
    for i in chosen:
        if i in seen:
            continue
        seen.add(i)
        p = ps[i]
        if used + len(p["text"]) > budget and out:
            break
        out.append(p)
        used += len(p["text"])
    # in reading order, so the model sees the material the way the file has it
    order = {d: k for k, d in enumerate(dict.fromkeys(p["doc"] for p in ps))}
    out.sort(key=lambda p: (order[p["doc"]], p["page"]))
    return out, general


def label(p):
    return f"{p['name']}, {p['unit']} {p['page']}" if p["unit"] != "image" else p["name"]


# ------------------------------------------------------------------------------------------------ models
# What is known about the models people install for this: quality for study answers (0-10, from how they do on explaining,
# reasoning and staying with the given text) and a word on each. Unknown models are judged by their size; coder / vision /
# embedding models are not good study partners and score lower or are left out.
CATALOGUE = [
    ("qwen3:32b", 9.5, "Excellent, but far too big for most laptops"),
    ("qwen3:30b", 9, "Excellent; needs lots of memory"),
    ("qwen3:14b", 9, "The best answers a laptop can run; slow without a big GPU"),
    ("gemma3:12b", 8.5, "Very good explanations"),
    ("qwen2.5:14b", 8, "Very good, steady"),
    ("phi4:14b", 8, "Strong at reasoning and maths"),
    ("phi4", 8, "Strong at reasoning and maths"),
    ("qwen3:8b", 8, "Great all-rounder: careful, cites well, thinks when asked"),
    ("deepseek-r1:8b", 7, "Reasons step by step; slow, wordy"),
    ("llama3.1:8b", 6.5, "Good, plain explanations"),
    ("qwen2.5:7b", 6.5, "Good, quick for its size"),
    ("gemma3:4b", 6, "Good small model"),
    ("qwen3:4b", 6.5, "Good small model; always thinks first, so slower than its size"),
    ("phi4-mini", 5, "Small, decent at maths"),
    ("qwen2.5:3b", 4.5, "Fast; fine for looking things up"),
    ("llama3.2:3b", 4, "Fast, simple answers"),
    ("gemma3:1b", 2, "Tiny: only for very short lookups"),
    ("llama3.2:1b", 2, "Tiny: only for very short lookups"),
    ("qwen3:1.7b", 3, "Tiny"),
]
# worth downloading for studying, best first (shown when they are not installed)
SUGGEST = ["qwen3:8b", "qwen3:14b", "gemma3:12b", "qwen3:4b"]
SIZES_GB = {"qwen3:8b": 5.2, "qwen3:14b": 9.3, "gemma3:12b": 8.1, "qwen3:4b": 2.5}
CONF = os.path.join(os.environ.get("HALCYON_STATE") or os.path.join(HOME, ".local", "state", "island"), "study.json")


def load_conf():
    try:
        with open(CONF, "r", encoding="utf-8") as f:
            c = json.load(f)
        return c if isinstance(c, dict) else {}
    except (OSError, ValueError):
        return {}


def save_conf(c):
    os.makedirs(os.path.dirname(CONF), exist_ok=True)
    tmp = CONF + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(c, f)
    os.replace(tmp, CONF)


def ollama_json(path, body=None, timeout=4):
    a = ai()
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(a.ollama_host() + path, data=data, headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read().decode("utf-8", "replace"))


def vram_gb():
    """Free-able video memory of the biggest GPU (NVIDIA through nvidia-smi, others through sysfs), 0 when there is none."""
    code, out = sh(["nvidia-smi", "--query-gpu=memory.total", "--format=csv,noheader,nounits"], timeout=5) if shutil.which("nvidia-smi") else (1, b"")
    best = 0.0
    if code == 0:
        for l in out.decode().split():
            with contextlib.suppress(ValueError):
                best = max(best, float(l) / 1024)
    if best == 0:
        import glob
        for f in glob.glob("/sys/class/drm/card*/device/mem_info_vram_total"):
            with contextlib.suppress(OSError, ValueError):
                best = max(best, int(open(f).read()) / 1024 ** 3)
    return round(best, 1)


def ram_gb():
    with contextlib.suppress(OSError, ValueError):
        for l in open("/proc/meminfo"):
            if l.startswith("MemTotal:"):
                return round(int(l.split()[1]) / 1024 ** 2, 1)
    return 0.0


def judge(name, size_gb, params, caps):
    """-> (quality 0-10, note, usable for study)"""
    n = name.lower()
    base = n.split("/")[-1]
    for key, q, note in CATALOGUE:
        if base == key or base.startswith(key + "-") or base.startswith(key + ":") or (":" in key and base.split("-")[0] == key):
            return q, note, True
    if re.search(r"embed|bge|minilm|nomic|rerank", n):
        return 0, "an embedding model (it cannot write answers)", False
    m = re.search(r"([\d.]+)\s*b", (params or "").lower()) or re.search(r":([\d.]+)b", n)
    b = float(m.group(1)) if m else size_gb / 0.62
    q = max(1.0, min(8.5, 2.2 * math.log2(max(1.0, b)) + 0.5))
    note = "Judged by its size"
    if "coder" in n:
        q -= 2.5
        note = "Made for code; weaker at explaining study material"
    elif re.search(r"vl[:\d-]|vl$|vision|llava", n):
        q -= 1.5
        note = "Made for pictures; weaker at long text"
    elif "abliterated" in n or "uncensored" in n:
        q -= 0.5
        note = "A modified (uncensored) model; quality varies"
    return round(q, 1), note, True


def speed_word(size_gb, vram, ram):
    """How it runs here: the whole model in video memory = fast; partly in RAM = slower; mostly RAM = minutes."""
    need = size_gb * 1.15 + 0.6               # weights + the context window
    if vram and need <= vram:
        return "fast", "fits on your GPU: answers in seconds"
    if vram and need <= vram * 1.8:
        return "ok", "partly on the CPU: about 10-40 s an answer"
    if need <= vram + ram * 0.5:                 # the rest of the layers in RAM, the CPU does them
        return "slow", "mostly on the CPU: about 1-3 minutes an answer"
    return "too big", "too big for this computer's memory"


def installed_models():
    try:
        tags = ollama_json("/api/tags").get("models") or []
    except (urllib.error.URLError, ConnectionError, TimeoutError, ValueError, OSError):
        return None
    vram, ram = vram_gb(), ram_gb()
    out = []
    for t in tags:
        name = t.get("name") or t.get("model") or ""
        size = (t.get("size") or 0) / 1024 ** 3
        det = t.get("details") or {}
        caps = []
        with contextlib.suppress(Exception):
            caps = ollama_json("/api/show", {"model": name}).get("capabilities") or []
        q, note, ok = judge(name, size, det.get("parameter_size", ""), caps)
        if "completion" not in caps and caps:
            ok = False
        sp, sp_note = speed_word(size, vram, ram)
        out.append({"name": name, "size": round(size, 1), "params": det.get("parameter_size", ""), "quality": q, "note": note,
                    "speed": sp, "speedNote": sp_note, "thinks": "thinking" in caps, "usable": ok and sp != "too big"})
    return out


def auto_pick(models, prefer=None):
    """-> (fast, deep): the best model for explanations, and a quick one for lookups.
    prefer: "balanced" (default: a slow model only when it is clearly better) | "quality" (the best, even at minutes an answer)
    | "speed" (nothing that runs mostly on the CPU)."""
    use = [m for m in models if m["usable"]]
    if prefer is None:
        prefer = load_conf().get("prefer", "balanced")
    if prefer == "speed":
        use = [m for m in use if m["speed"] in ("fast", "ok")] or use
    if not use:
        return None, None
    rank = {"fast": 0, "ok": 1, "slow": 2}
    slow_cost = {"quality": 0, "speed": 9}.get(prefer, 1.5)
    deep = max(use, key=lambda m: (m["quality"] - (slow_cost if m["speed"] == "slow" else 0), -rank.get(m["speed"], 3)))
    # fast: fits on the GPU, good enough (4+), does not think out loud first; the best of those
    quick = [m for m in use if m["speed"] == "fast" and m["quality"] >= 4]
    fast = max(quick, key=lambda m: (not m["thinks"], m["quality"])) if quick else deep
    return fast["name"], deep["name"]


def cmd_models(args):
    models = installed_models()
    c = load_conf()
    if models is None:
        o = {"ok": False, "error": "Ollama is not running (systemctl --user start ollama)", "choice": c.get("model", "auto")}
        print(json.dumps(o) if JSON_OUT else o["error"])
        return 3
    fast, deep = auto_pick(models)
    have = {m["name"].split(":latest")[0] for m in models}
    vram, ram = vram_gb(), ram_gb()
    sugg = []
    for n in SUGGEST:
        if n in have:
            continue
        q, note, _ = judge(n, SIZES_GB.get(n, 5), "", [])
        sp, sp_note = speed_word(SIZES_GB.get(n, 5), vram, ram)
        if sp == "too big":
            continue
        sugg.append({"name": n, "size": SIZES_GB.get(n), "quality": q, "note": note, "speed": sp, "speedNote": sp_note})
    models.sort(key=lambda m: (-m["usable"], -m["quality"]))
    o = {"ok": True, "models": models, "auto": {"fast": fast, "deep": deep}, "choice": c.get("model", "auto"),
         "reason": c.get("reason", "auto"), "prefer": c.get("prefer", "balanced"), "vram": vram, "ram": ram, "suggest": sugg}
    if JSON_OUT:
        print(json.dumps(o, ensure_ascii=False))
        return 0
    print(f"GPU memory {vram} GB, RAM {ram} GB.  Auto: quick lookups -> {fast}, explanations -> {deep}.  Now: {o['choice']}")
    for m in models:
        print(f"  {m['name']:<44} {m['quality']:>4}/10  {m['speedNote']}  ({m['note']})")
    for m in sugg:
        print(f"  get: ollama pull {m['name']}  ({m['size']} GB, {m['quality']}/10, {m['speedNote']})")
    return 0


def cmd_use(args):
    c = load_conf()
    want = next((a for a in args if not a.startswith("--")), "")
    if want:
        c["model"] = want
    r = argval(args, "--reason", "")
    if r in ("auto", "always", "never"):
        c["reason"] = r
    pr = argval(args, "--prefer", "")
    if pr in ("balanced", "quality", "speed"):
        c["prefer"] = pr
    save_conf(c)
    emit(type="done")
    if not JSON_OUT:
        print(f"Study Center model: {c.get('model', 'auto')}, step-by-step thinking: {c.get('reason', 'auto')}")
    return 0


DEEP_Q = re.compile(r"\b(why|how|explain|compare|contrast|difference|differ|versus|vs\.?|derive|prove|proof|calculate|compute|solve|"
                    r"evaluate|analy[sz]e|justify|discuss|example|examples|step|steps|advantages?|disadvantages?|relationship|"
                    r"implications?|what (would|happens|if)|summari[sz]e|in detail|elaborate|teach|exam|essay|work out)\b", re.I)
REASON_Q = re.compile(r"\b(derive|prove|proof|calculate|compute|solve|work out|how many|how much|numerical|formula|equation)\b|\d+\s*[-+*/^=]\s*\d+", re.I)


def route(q, hist, general):
    """-> (model, route, why, think) for one question."""
    c = load_conf()
    choice = c.get("model", "auto")
    reason = c.get("reason", "auto")
    models = installed_models() or []
    names = {m["name"] for m in models}
    info = {m["name"]: m for m in models}
    leaky = set(c.get("leaky", []))
    def thinks(name):
        return bool(info.get(name, {}).get("thinks"))
    want_think = reason == "always" or (reason == "auto" and bool(REASON_Q.search(q)))
    def final(m, rt, why):
        # a model that thinks whatever it is told (qwen3:4b) is asked to think apart from the answer, so none of it shows as text
        return m, rt, why, (want_think or m in leaky) and thinks(m) and reason != "never" or (m in leaky and thinks(m))
    if choice != "auto":
        if names and choice not in names and choice + ":latest" not in names:
            raise Fail(f"The model {choice} is not installed any more: pick another one at the top of the Study Center")
        return final(choice, "chosen", "the model you picked")
    fast, deep = auto_pick(models) if models else (None, None)
    if not deep:
        m = ai().model_name()
        return m, "default", "Halcyon's AI model", False
    words = len(q.split())
    deep_q = general or words > 16 or bool(DEEP_Q.search(q)) or want_think
    # a follow-up stays with the model of the conversation, so two models do not take turns loading into the GPU
    last = (hist[-1].get("model") if hist else "") or ""
    if hist and last in (fast, deep) and not (deep_q and last == fast and fast != deep):
        m = last
        why = "the same model as the rest of this conversation"
    elif deep_q:
        m, why = deep, ("an overview" if general else ("needs reasoning" if want_think else "an explanation"))
    else:
        m, why = fast, "a quick lookup"
    return final(m, ("deep" if m == deep and fast != deep else "quick"), why)


# ------------------------------------------------------------------------------------------------ ask
def chat_stream(messages, num_predict=900, model=None, think=False):
    a = ai()
    model = model or a.model_name()
    body = {"model": model, "messages": messages, "stream": True, "think": bool(think), "keep_alive": keep_alive(),
            "options": {"temperature": 0.2, "num_predict": num_predict + (1600 if think else 0), "num_ctx": a.NUM_CTX}}
    req = urllib.request.Request(a.ollama_host() + "/api/chat", data=json.dumps(body).encode(), headers={"Content-Type": "application/json"})
    out = []
    in_think = False
    try:
        with urllib.request.urlopen(req, timeout=600) as r:
            for line in r:
                try:
                    o = json.loads(line)
                except ValueError:
                    continue
                if o.get("error"):
                    raise Fail(o["error"])
                msg = o.get("message") or {}
                if msg.get("thinking"):                  # asked to think: Ollama hands the reasoning over on its own
                    emit(type="think", t=msg["thinking"])
                t = msg.get("content", "")
                if t:
                    # a <think> block inside the text is not part of the answer either
                    if "<think>" in t:
                        in_think = True
                        t = t.split("<think>")[0]
                    if not in_think and t:
                        out.append(t)
                        emit(type="tok", t=t)
                    if "</think>" in t or (in_think and "</think>" in "".join(out + [t])):
                        in_think = False
                    # some models (qwen3:4b) think even when told not to and only CLOSE the block: everything before it goes
                    joined = "".join(out)
                    if "</think>" in joined:
                        keep = joined.split("</think>")[-1].lstrip()
                        emit(type="think", t=joined.split("</think>")[0])
                        out = [keep]
                        emit(type="reset", text=keep)
                        if not think:                      # remembered: next time it is asked to think apart from the answer
                            c = load_conf()
                            c["leaky"] = sorted(set(c.get("leaky", [])) | {model})
                            save_conf(c)
                if o.get("done"):
                    break
    except urllib.error.HTTPError as e:
        detail = ""
        with contextlib.suppress(Exception):
            detail = json.loads(e.read().decode("utf-8", "replace")).get("error", "")
        if "not found" in detail:
            raise Fail(f"The model {model} is not installed. Run: ollama pull {model}")
        if "does not support thinking" in detail and think:
            return chat_stream(messages, num_predict, model, False)
        raise Fail(f"Ollama answered with an error: {detail or e}")
    except BrokenPipeError:
        raise                         # our reader went away (the window closed): not Ollama's fault
    except (urllib.error.URLError, ConnectionError):
        raise AiOff("Ollama is not running. Start it with: systemctl start ollama")
    except TimeoutError:
        raise Fail("The model took too long to answer.")
    return "".join(out)


SYSTEM_ASK = (
    "You are a calm, patient study partner. Answer the student's question using ONLY the excerpts from their files below. "
    "Explain in plain words, the way a good tutor would: start with the direct answer, then the why or the steps. Keep exact "
    "terms, numbers and formulas as the excerpts write them. Use short paragraphs, and '- ' lists for steps or several points. "
    "After each fact, name where it came from in square brackets exactly like the excerpt headings, e.g. [Lecture 3, page 12]. "
    "If the excerpts do not contain the answer, say plainly that you could not find it in these files, and say which topic "
    "they do cover nearby. Never invent page numbers, facts or sources. Speak of 'your files' or 'your notes' (or the file's "
    "name), never of 'excerpts' or 'the provided text'."
)


def cmd_ask(args):
    q = " ".join(a for a in strip_opts(args, ("--docs", "--history", "--pages", "--model"))).strip()
    if not q:
        raise Fail("ask <question>")
    docs = pick_docs(args)
    need_ai()
    hist = []
    with contextlib.suppress(ValueError, TypeError):
        hist = json.loads(argval(args, "--history", "[]")) or []
    hist = [h for h in hist if isinstance(h, dict) and h.get("q")][-3:]      # {q, a, model}
    prev = hist[-1]["q"] if hist else ""
    progress("looking through your files")
    t0 = time.time()
    ps = pieces(docs, page_range(args))
    found, general = gather(ps, q, prev)
    # "what is on page 12" / "explain slide 4": that page first, whatever the words rank
    pm = re.search(r"\b(?:page|slide|p\.|pg\.?|part)\s*(\d{1,4})\b", q, re.I)
    if pm:
        want = int(pm.group(1))
        on = [p for p in ps if p["page"] == want][:6]
        if on:
            found = on + [p for p in found if p["page"] != want][:4]
            general = False
    srcs, seen = [], set()
    for p in found:
        k = (p["doc"], p["page"])
        if k not in seen:
            seen.add(k)
            srcs.append({"doc": p["doc"], "name": p["name"], "page": p["page"], "unit": p["unit"]})
    emit(type="sources", sources=srcs)
    if not found:
        msg = "Nothing in these files mentions that. Try other words, or pick more files on the left."
        emit(type="tok", t=msg)
        emit(type="done", found=False)
        return 0
    excerpts = "\n\n".join(f"### [{label(p)}]\n{p['text'].strip()}" for p in found)
    msgs = [{"role": "system", "content": SYSTEM_ASK}]
    for h in hist:
        msgs.append({"role": "user", "content": str(h["q"])[:600]})
        if h.get("a"):
            msgs.append({"role": "assistant", "content": str(h["a"])[:900]})
    hint = ("\n(These passages are spread through the whole of each file: give an overview of what each file covers, topic by "
            "topic, in a few lines per file.)" if general else "")
    msgs.append({"role": "user", "content": f"Excerpts from my files:\n\n{excerpts}\n\n---\nMy question: {q}{hint}"})
    forced = argval(args, "--model", "")
    if forced == "best":                    # "Ask the best model": the deep pick, whatever Auto would route this to
        forced = auto_pick(installed_models() or [])[1] or ""
    if forced:
        leaky = forced in load_conf().get("leaky", [])
        model, rt, why, think = forced, "deep", "asked again with the best model", leaky
    else:
        model, rt, why, think = route(q, hist, general)
    emit(type="model", model=model, route=rt, why=why, think=think)
    progress(("thinking it through with " if think else "writing with ") + model)
    answer = chat_stream(msgs, model=model, think=think, num_predict=1200 if rt == "deep" else 900)
    secs = round(time.time() - t0)
    emit(type="done", found=True, secs=secs, model=model)
    save_turn(q, answer, srcs, model, secs, [d["id"] for d in docs] if argval(args, "--docs", "") else [])
    return 0


# ------------------------------------------------------------------------------------------------ grade your own answer
def cmd_grade(args):
    """grade --q QUESTION --key EXPECTED --mine YOUR_ANSWER: {"verdict": right|partly|wrong, "feedback"}"""
    q, key, mine = argval(args, "--q", ""), argval(args, "--key", ""), argval(args, "--mine", "")
    if not q or not mine.strip():
        raise Fail("grade --q ... --key ... --mine ...")
    need_ai()
    models = installed_models() or []
    fast, deep = auto_pick(models)
    c = load_conf()
    model = c.get("model") if c.get("model", "auto") != "auto" else (deep or fast or ai().model_name())
    leaky = model in c.get("leaky", [])
    msgs = [{"role": "system", "content": (
                "You mark a student's answer to a revision question, kindly and briefly. Compare it with the expected answer: "
                "the meaning counts, not the wording. Answer with JSON only: "
                '{"verdict": "right" | "partly" | "wrong", "feedback": "one or two sentences: what was right, what is missing or wrong"}. '
                "If it says what the expected answer says, it is right, even when it is shorter or in other words; never ask for more "
                "than the expected answer contains. Speak to the student as you.")},
            {"role": "user", "content": f"Question: {q}\nExpected answer: {key}\nMy answer: {mine}"}]
    a = ai()
    body = {"model": model, "messages": msgs, "stream": False, "think": leaky, "format": "json", "keep_alive": keep_alive(),
            "options": {"temperature": 0, "num_predict": 220 + (1200 if leaky else 0), "num_ctx": a.NUM_CTX}}
    try:
        out = ollama_json("/api/chat", body, timeout=300)
    except (urllib.error.URLError, ConnectionError):
        raise AiOff("Ollama is not running. Start it with: systemctl start ollama")
    except TimeoutError:
        raise Fail("The model took too long to answer.")
    txt = ((out.get("message") or {}).get("content") or "").split("</think>")[-1]
    m = re.search(r"\{.*\}", txt, re.S)
    try:
        d = json.loads(m.group(0) if m else txt)
    except ValueError:
        raise Fail("The model did not answer in the expected form. Try again.")
    v = str(d.get("verdict", "")).lower()
    v = "right" if v.startswith("right") or v == "correct" else ("partly" if v.startswith("part") else "wrong")
    o = {"type": "graded", "verdict": v, "feedback": str(d.get("feedback", "")).strip(), "model": model}
    print(json.dumps(o, ensure_ascii=False) if JSON_OUT else f"{v}: {o['feedback']}")
    return 0


# ------------------------------------------------------------------------------------------------ the saved conversation
CHAT = os.path.join(DATA, "chat.json")


def load_chat():
    try:
        with open(CHAT, "r", encoding="utf-8") as f:
            c = json.load(f)
        return c if isinstance(c, list) else []
    except (OSError, ValueError):
        return []


def save_turn(q, a, srcs, model, secs, docs):
    c = load_chat()
    c.append({"q": q, "a": a, "sources": srcs, "model": model, "secs": secs, "docs": docs, "at": int(time.time())})
    os.makedirs(DATA, exist_ok=True)
    tmp = CHAT + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(c[-40:], f, ensure_ascii=False)
    os.replace(tmp, CHAT)


def cmd_chat(args):
    if "--clear" in args:
        with contextlib.suppress(OSError):
            os.remove(CHAT)
        emit(type="done")
        return 0
    c = load_chat()
    if JSON_OUT:
        print(json.dumps({"turns": c}, ensure_ascii=False))
    else:
        for t in c:
            print(f"> {t['q']}\n{t['a']}\n   ({t.get('model')}, {t.get('secs')} s)\n")
    return 0


# ------------------------------------------------------------------------------------------------ summary / quiz / cards
def made_path(mode, docs, rng):
    key = ",".join(sorted(d["id"] for d in docs)) + (f"@{rng[0]}-{rng[1]}" if rng else "")
    return os.path.join(DATA, f"made-{mode}-{hashlib.sha1(key.encode()).hexdigest()[:12]}-{'-'.join(sorted(d['id'] for d in docs))[:200]}.json")


def material(docs, rng):
    parts = []
    for d in docs:
        pages = load_pages(d["id"])
        for pi, page in enumerate(pages, 1):
            if rng and not (rng[0] <= pi <= rng[1]):
                continue
            if page.strip():
                parts.append(page)
    text = "\n\n".join(parts)
    return text[:ai().STUDY_MAX], len(text) > ai().STUDY_MAX


def cmd_saved(args):
    mode = next((a for a in args if a in ("summary", "quiz", "cards")), "")
    if not mode:
        raise Fail("saved summary|quiz|cards")
    try:
        docs = pick_docs(args)
    except Fail:
        print(json.dumps({"type": "none"}))
        return 0
    p = made_path(mode, docs, page_range(args))
    try:
        with open(p, "r", encoding="utf-8") as f:
            o = json.load(f)
        o["type"] = "result"
        print(json.dumps(o, ensure_ascii=False) if JSON_OUT else o.get("text", ""))
    except (OSError, ValueError):
        print(json.dumps({"type": "none"}) if JSON_OUT else "")
    return 0


def cmd_make(args):
    mode = next((a for a in args if a in ("summary", "quiz", "cards")), "")
    if not mode:
        raise Fail("make summary|quiz|cards [--docs ID,ID] [--pages 3-9] [--n 10]")
    docs = pick_docs(args)
    rng = page_range(args)
    try:
        n = max(3, min(30, int(argval(args, "--n", "10"))))
    except ValueError:
        n = 10
    p = made_path(mode, docs, rng)
    if "--fresh" not in args and os.path.isfile(p):
        return cmd_saved(args)
    need_ai()
    a = ai()
    c = load_conf()
    m = c.get("model", "auto")
    if m == "auto":
        _, m = auto_pick(installed_models() or [])
    if m:
        os.environ["HALCYON_AI_MODEL"] = m          # halcyon-ai.py's writers read it on every request
        progress("using " + m)
    text, cut = material(docs, rng)
    if len(text) < 200:
        raise Fail("there is too little text here to study (pick more pages or another file)")
    title = docs[0]["name"] if len(docs) == 1 else f"{len(docs)} files"
    if rng:
        title += f" ({docs[0]['unit']}s {rng[0]}-{rng[1]})"
    try:
        pts = a.key_points(text, title)
        if mode == "summary":
            progress("writing the summary")
            body, items = a.study_summary(pts), []
        else:
            progress("writing the questions" if mode == "quiz" else "writing the flashcards")
            items = a.study_items(pts, mode, n)
            body = ("\n\n".join(f"Q{k}. {i['q']}\n    Answer: {i['a']}" for k, i in enumerate(items, 1)) if mode == "quiz"
                    else "\n".join(f"- {i['q']}  ::  {i['a']}" for i in items))
    except a.AiOff as e:
        raise AiOff(str(e))
    except a.Fail as e:
        raise Fail(str(e))
    head = {"summary": "Summary", "quiz": "Quiz", "cards": "Flashcards"}[mode] + ": " + title
    if cut:
        head += "  (only the first part of very long material was read)"
    o = {"mode": mode, "title": title, "text": head + "\n\n" + body, "body": body, "items": items, "made": int(time.time()), "model": m or ""}
    os.makedirs(DATA, exist_ok=True)
    with open(p, "w", encoding="utf-8") as f:
        json.dump(o, f, ensure_ascii=False)
    o["type"] = "result"
    if JSON_OUT:
        print(json.dumps(o, ensure_ascii=False), flush=True)
    else:
        print(o["text"])
    return 0


# ------------------------------------------------------------------------------------------------ open
def cmd_open(args):
    ids = [a for a in args if valid_id(a)]
    d = next((d for d in load_index() if ids and d.get("id") == ids[0]), None)
    if not d or not os.path.isfile(d.get("path", "")):
        raise Fail("that file is not there any more (moved or deleted?)")
    page = next((a for a in args if a.isdigit()), "")
    path = d["path"]
    argv = None
    if page and d.get("ext") == "pdf":
        # the default PDF viewer, at the page, when it is one that can be told the page
        _, app = sh(["xdg-mime", "query", "default", "application/pdf"], timeout=5)
        app = app.decode().strip().lower()
        for key, cmd in (("zathura", ["zathura", "-P", page, path]), ("okular", ["okular", "-p", page, path]),
                         ("evince", ["evince", "-i", page, path]), ("papers", ["papers", "-i", page, path]),
                         ("atril", ["atril", "-i", page, path]), ("firefox", ["firefox", f"file://{path}#page={page}"]),
                         ("zen", ["zen-browser", f"file://{path}#page={page}"]), ("chromium", ["chromium", f"file://{path}#page={page}"])):
            if key in app and shutil.which(cmd[0]):
                argv = cmd
                break
    subprocess.Popen(argv or ["xdg-open", path], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
    return 0


# ------------------------------------------------------------------------------------------------ main
def argval(args, name, default=""):
    for i, a in enumerate(args):
        if a == name and i + 1 < len(args):
            return args[i + 1]
        if a.startswith(name + "="):
            return a.split("=", 1)[1]
    return default


def strip_opts(args, with_value):
    out, skip = [], False
    for a in args:
        if skip:
            skip = False
            continue
        if a in with_value:
            skip = True
            continue
        if a.startswith("--"):
            continue
        out.append(a)
    return out


def main(argv):
    global JSON_OUT
    JSON_OUT = "--json" in argv or "--stream" in argv
    argv = [a for a in argv if a not in ("--json", "--stream")]
    if not argv or argv[0] in ("-h", "--help", "help"):
        print(__doc__)
        return 0 if argv else 2
    cmd, rest = argv[0], argv[1:]
    fn = {"add": cmd_add, "list": cmd_list, "ls": cmd_list, "remove": cmd_remove, "rm": cmd_remove, "ask": cmd_ask,
          "make": cmd_make, "saved": cmd_saved, "open": cmd_open, "models": cmd_models, "use": cmd_use, "chat": cmd_chat, "grade": cmd_grade}.get(cmd)
    if not fn:
        print(__doc__, file=sys.stderr)
        return 2
    try:
        return fn(rest)
    except AiOff as e:
        emit(type="error", error=str(e), off=True)
        return 3
    except Fail as e:
        emit(type="error", error=str(e))
        return 1
    except KeyboardInterrupt:
        return 130
    except BrokenPipeError:
        # the window that asked was closed while the answer streamed: stop quietly (stdout is gone, so nothing is printed)
        with contextlib.suppress(OSError):
            os.dup2(os.open(os.devnull, os.O_WRONLY), sys.stdout.fileno())
        return 0
    finally:
        if not JSON_OUT and sys.stderr.isatty():
            print("\r\033[2K", end="", file=sys.stderr)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
