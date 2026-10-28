#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = ["pymupdf>=1.24"]
# ///
"""Skim view of a TDK paper: what a reviewer sees when only skimming.

  uv run scripts/skim/skim.py build <built-dir> -o <outdir> [--lint lint.json] [--debug]
  uv run scripts/skim/skim.py compare <before-outdir> <after-outdir> -o <outdir>

build reads the PDF a reviewer gets (reviewer.pdf, else thesis.pdf) of a built paper together with
its .aux and .toc, and the lint's JSON export for the chapter roles and the tag lists. It writes
skim.html, skim.md (the skim persona's only input), skim.json (for compare) and assets/. Kept
verbatim: title, abstract, outline, tagged items, coloured boxes, captions with figure crops.
Everything else becomes counts. Every piece of evidence is detected, placeholder, unsure or missing
(scripts/review/README.md). See scripts/skim/README.md for the heuristics and their limits.

Exit 1 when the build cannot be read (no PDF, no .aux labels, no outline); exit 0 whenever a view
was written, however incomplete the paper.
"""
import argparse
import html
import json
import os
import re
import shutil
import subprocess
import sys
from collections import Counter, defaultdict
from dataclasses import dataclass, field
from pathlib import Path

import pymupdf

SHEET_NAME = "TDK2025_biralati_pontozolap_hallgatoi.pdf"
GUIDE = "guide/02-tdk-essentials.tex"
# The template's tag lists in reading order; a paper's own lists follow them, then "other" (a
# prefix no list declares, counted when at least two items share it).
LIST_ORDER = ["contributions", "rqlist", "requirements", "derivedrequirements", "assumptions", "threats",
              "guarantees", "limitations"]
STATES = ("detected", "placeholder", "unsure", "missing")
# Template text a reader can see: the template's TODOs (also \tbd's "[TODO: ...]"), its placeholder
# rows and data, "replace with your own", todonotes' missing figure, and an illustration marked as
# such in its caption ("Illustrative numbers ..."). "placeholder" alone is too common in prose.
PLACEHOLDER_RE = re.compile(r"\bTODO\b|\bPlaceholder\s+(?:rows?|data|scenario|figure|table|text|values|results)\b"
                            r"|\b[Rr]eplace\s+(?:it\s+|them\s+|this\s+)?with\s+your\b|\bMissing figure\b"
                            r"|\bIllustrative\s+(?:numbers|data|values|results|measurements)\b|\bfor illustration only\b"
                            r"|\bLorem ipsum\b")
THEOREMS = "Definition|Theorem|Lemma|Proposition|Corollary|Invariant|Property|Claim|Example|Remark|Notation|Axiom|Conjecture"
TAG_RE = re.compile(r"^([A-Z]{1,4})(\d{1,2})([a-z]?)(?![\w])")
TAG_WORD = re.compile(r"^([A-Z]{1,4})(\d{1,2}[a-z]?)$")
THM_RE = re.compile(rf"^({THEOREMS})\s+([A-Z]?\d+(?:\.\d+)*)")
CAP_RE = re.compile(r"^(Figure|Table|Listing|Algorithm)\s+([A-Z](?:\.\d+)+|[A-Z]?\d+(?:\.\d+)*[a-z]?)")
FLOAT_WORDS = {"Figure": "Figure", "Figures": "Figure", "Fig.": "Figure", "Table": "Table", "Tables": "Table",
               "Listing": "Listing", "Listings": "Listing", "Algorithm": "Algorithm"}
DEST_PREFIX = {"Figure": "figure.", "Table": "table.", "Listing": "lstlisting.", "Algorithm": "algorithm."}
BULLETS = "•◦▪▸►∗·–—"
ENUM_RE = re.compile(r"^(\(?\d{1,2}[.)]|\([a-z]{1,4}\)|[a-z]\))\s")
MATH_FONT = re.compile(r"Math|^CMMI|^CMSY|^CMEX|^CMBSY|^MSAM|^MSBM|^LMMath|STIX|XITS|^Euler|^EU[SF]|^RSFS|^rsfs", re.I)
MONO_FONT = re.compile(r"Mono|Courier|Typewriter|^CMTT|Inconsolata|Consol|Menlo|^SFTT|SourceCode", re.I)
ANCHOR_KINDS = {"heading", "float", "box", "item", "theorem", "rows"}


def die(msg):
    print(f"skim: error: {msg}", file=sys.stderr)
    sys.exit(1)


def norm(s):
    return re.sub(r"\s+", " ", s).strip()


def esc(s):
    return html.escape(str(s), quote=True)


def slug(s):
    return re.sub(r"[^A-Za-z0-9_.-]+", "-", str(s)).strip("-")


def marks(text):
    """The template text visible in a piece of text, as the matched phrases."""
    return [m.group(0) for m in PLACEHOLDER_RE.finditer(text or "")]


def worst(states):
    """One state for a row of evidence: placeholder over unsure over detected; missing if empty."""
    for s in ("placeholder", "unsure", "detected"):
        if s in states:
            return s
    return "missing"


# ----------------------------------------------------------------------------------------------
# LaTeX side: .aux labels, .toc entries, sources for the cross-check, criteria and chapter roles
# ----------------------------------------------------------------------------------------------

def groups(s, i=0):
    """Top-level {...} groups of s from index i, as strings without the outer braces."""
    out, depth, start = [], 0, None
    while i < len(s):
        c = s[i]
        if c == "\\":
            i += 2
            continue
        if c == "{":
            if depth == 0:
                start = i + 1
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                out.append(s[start:i])
        i += 1
    return out


def unbrace(s):
    return s.replace("{", "").replace("}", "").strip()


def parse_aux(path, labels=None, seen=None):
    """\\newlabel{name}{{printed}{page}{title}{anchor}{}} and name@cref {[type][n][parent]printed}."""
    labels = {} if labels is None else labels
    seen = set() if seen is None else seen
    if path in seen or not path.exists():
        return labels
    seen.add(path)
    for line in path.read_text(errors="replace").splitlines():
        m = re.match(r"\\@input\{(.+?)\}", line)
        if m:
            parse_aux(path.parent / m.group(1), labels, seen)
            continue
        m = re.match(r"\\newlabel\{(.+?)\}(.*)$", line)
        if not m:
            continue
        name, rest = m.groups()
        g = groups(rest)
        if not g:
            continue
        inner = groups(g[0])
        if name.endswith("@cref"):
            t = re.match(r"\[([^\]]*)\]", inner[0] if inner else "")
            labels.setdefault(name[:-5], {})["type"] = t.group(1) if t else ""
            continue
        if len(inner) < 4:
            continue
        d = labels.setdefault(name, {})
        d.update(printed=unbrace(inner[0]), page=unbrace(inner[1]), title=inner[2], anchor=inner[3])
    return labels


def chapters_by_file(built, stem):
    """Source file -> the anchors of the chapters it starts, from the toc lines each included file's
    .aux writes (\\@writefile{toc}{\\contentsline {chapter}{...}{page}{chapter.3}})."""
    out = {}
    aux = built / f"{stem}.aux"
    if not aux.exists():
        return out
    for m in re.finditer(r"\\@input\{(.+?)\.aux\}", aux.read_text(errors="replace")):
        f = built / f"{m.group(1)}.aux"
        if not f.exists():
            continue
        anchors = []
        for line in f.read_text(errors="replace").splitlines():
            i = line.find("\\contentsline {chapter}")
            if i >= 0:
                g = groups(line, i)
                if len(g) >= 4:
                    anchors.append(g[3])
        out[f"{m.group(1)}.tex"] = anchors
    return out


def load_lint(built, given):
    """The lint's JSON export: from --lint, else <built>/lint.json, else `texlua scripts/lint.lua
    chapters --json` run in the built directory when texlua is on the PATH. Returns (export, where it
    came from) or (None, why not)."""
    if given:
        p = Path(given)
        if not p.exists():
            die(f"--lint {p}: no such file")
        try:
            return json.loads(p.read_text()), str(p)
        except json.JSONDecodeError as e:
            die(f"--lint {p}: not JSON ({e})")
    p = built / "lint.json"
    if p.exists():
        try:
            return json.loads(p.read_text()), "lint.json"
        except json.JSONDecodeError as e:
            return None, f"{p} is not JSON ({e})"
    if shutil.which("texlua") and (built / "scripts/lint.lua").exists():
        # the lint exits 1 when a check fails; its JSON is complete either way
        r = subprocess.run(["texlua", "scripts/lint.lua", "chapters", "--json"], cwd=built, capture_output=True, text=True)
        try:
            return json.loads(r.stdout), "texlua scripts/lint.lua chapters --json"
        except json.JSONDecodeError:
            return None, f"texlua scripts/lint.lua chapters --json printed no JSON (exit {r.returncode}): {r.stderr.strip()[:200]}"
    return None, "no lint.json in the build directory and no texlua to run scripts/lint.lua (give --lint)"


def parse_toc(path):
    """\\contentsline {level}{title}{page}{anchor}: level, number, raw title, page label, anchor."""
    out = []
    if not path.exists():
        return out
    for line in path.read_text(errors="replace").splitlines():
        i = line.find("\\contentsline")
        if i < 0:
            continue
        g = groups(line, i)
        if len(g) < 4:
            continue
        level, title, page, anchor = g[0].strip(), g[1], g[2], g[3]
        num = re.search(r"\\numberline\s*\{([^}]*)\}", title)
        out.append(dict(level=level, number=num.group(1) if num else "", raw=title, page=page, anchor=anchor))
    return out


def strip_tex(s):
    s = re.sub(r"\\numberline\s*\{[^}]*\}", "", s)
    s = re.sub(r"\\enquote\s*\{([^{}]*)\}", r"“\1”", s)
    s = re.sub(r"\\(?:gls|glsxtrtitleshort|Gls|acrshort|textsc|emph|textbf|textit|texttt)\s*\{([^{}]*)\}", r"\1", s)
    s = re.sub(r"\\(?:cref|Cref|ref|label|cite)\s*\{[^{}]*\}", "", s)
    s = s.replace("---", "—").replace("--", "–").replace("~", " ")
    s = re.sub(r"\\[a-zA-Z@]+\s*", "", s)
    return norm(s.replace("{", "").replace("}", ""))


def included_sources(built, stem):
    """The content files that went into this build: the .tex of every \\@input aux, plus thesis.tex."""
    files = []
    aux = built / f"{stem}.aux"
    if aux.exists():
        for m in re.finditer(r"\\@input\{(.+?)\.aux\}", aux.read_text(errors="replace")):
            f = built / f"{m.group(1)}.tex"
            if f.exists():
                files.append(f)
    return files


def source_counts(built, stem, taglists):
    """What the included sources declare, for the cross-check against the PDF."""
    box_envs = {"runningexample", "infobox", "warnbox", "keybox", "tcolorbox"}
    for f in [built / "include/macros.tex", built / "include/preamble.tex"]:
        if f.exists():
            box_envs |= set(re.findall(r"\\newtcolorbox\{(\w+)\}", f.read_text(errors="replace")))
            box_envs |= {e for e in re.findall(r"\\newenvironment\{(\w+)\}.*?(?:MakeFramed|tcolorbox|mdframed)",
                                                 f.read_text(errors="replace"), re.S) if len(e) < 20}
    c = Counter()
    for f in included_sources(built, stem):
        text = "\n".join(l.split("%")[0] if not l.lstrip().startswith("%") else "" for l in
                         f.read_text(errors="replace").splitlines())
        text = re.sub(r"\\begin\{comment\}.*?\\end\{comment\}", "", text, flags=re.S)
        for env, key in (("figure", "figure"), ("table", "table"), ("xltabular", "table"), ("longtable", "table")):
            c[key] += sum(1 for body in re.findall(rf"\\begin\{{{env}\*?\}}(.*?)\\end\{{{env}\*?\}}", text, re.S) if "\\caption" in body)
        c["box"] += sum(len(re.findall(rf"\\begin\{{{e}\}}", text)) for e in box_envs)
        for env in taglists:
            for body in re.findall(rf"\\begin\{{{env}\}}(.*?)\\end\{{{env}\}}", text, re.S):
                c["tag item"] += len(re.findall(r"\\item\b", body))
        c["tag item"] += len(re.findall(r"\\tagrow\{", text))
        c["tag item"] += len(re.findall(r"\\item\[\s*(?:\\textbf\{)?[A-Z]{1,4}\d{1,2}[a-z]?\b", text))
        c["theorem-like"] += len(re.findall(rf"\\begin\{{({THEOREMS.lower()})\}}", text))
    return c


def load_criteria(guide, sheet, notes):
    """The criteria from the guide's review-sheet section, with every band from the sheet PDF, and the
    parts of the written review the sheet asks for. A missing guide leaves the view without criteria."""
    crit, textual = [], None
    if not guide.exists():
        notes.append(f"guide not found at {guide}: no review criteria in this view (give --guide)")
        return crit, []
    text = guide.read_text(errors="replace")
    if "\\section{The review sheet}" not in text:
        notes.append(f"{guide} has no \\section{{The review sheet}}: no review criteria in this view")
        return crit, []
    sec = text.split("\\section{The review sheet}", 1)[1].split("\\end{description}", 1)[0]
    for m in re.finditer(r"\\item\[([^\]]+)\]\s*(.*?)(?=\\item\[|\Z)", sec, re.S):
        head, body = m.group(1), m.group(2)
        cid = re.match(r"([A-E](?:/\d)?)", head).group(1)
        crit.append(dict(id=cid, name=strip_tex(re.sub(r"^[A-E](?:/\d)?\.\s*", "", head)),
                         top=strip_tex(body), bands=[], notes=[]))
    by_id = {c["id"]: c for c in crit}
    if sheet and sheet.exists():
        txt = "\n".join(p.get_text("text", sort=True) for p in pymupdf.open(sheet))
        cur, band, textual = None, None, None
        for line in txt.splitlines():
            s = line.strip()
            if s.startswith("Szöveges értékelés"):
                textual = [s]
                continue
            if textual is not None:
                if s.startswith("•"):
                    textual.append(s.lstrip("• ").strip())
                continue
            if not s or s.startswith("BME VIK TDK") or re.fullmatch(r"\d+", s):
                band = None
                continue
            h = re.match(r"^(A|B/1|B/2|C|D/1|D/2|E|B|D)\s*(?:\.|::?)\s*(.*)", s)
            if h and not re.match(r"^[A-E]\s+[a-z]", s):
                cur = by_id.get(h.group(1)) or (by_id.get("E") if h.group(1) == "E" else None)
                band = None
                continue
            b = re.match(r"^(?:[•o]\s*)?(\d(?:\s*-\s*\d)?)\s*:\s*(.+)", s)
            if cur and b:
                band = [b.group(1).replace(" ", ""), b.group(2)]
                cur["bands"].append(band)
            elif cur and band:
                band[1] += " " + s
            elif cur:
                cur["notes"].append(s)
    for c in crit:
        c["bands"] = [[b[0], norm(b[1])] for b in c["bands"]]
        tops = [int(b[0].split("-")[-1]) for b in c["bands"]]
        c["max"] = max(tops) if tops else int((re.search(r"0[–-]+(\d+)", c["name"]) or [0, 0])[1] or 0)
        c["name"] = re.sub(r"\s*\(0[–-]+\d+\)", "", c["name"])
    return crit, (textual or [])


# ----------------------------------------------------------------------------------------------
# PDF side: lines with fonts, page metrics, regions
# ----------------------------------------------------------------------------------------------

def is_bold(s):
    return bool(s["flags"] & 16) or bool(re.search(r"Bold|-Bd|Black|Heavy|Semibold", s["font"]))


def is_italic(s):
    return bool(s["flags"] & 2) or bool(re.search(r"Italic|Oblique|-It", s["font"]))


def is_mono(s):
    return bool(s["flags"] & 8) or bool(MONO_FONT.search(s["font"]))


def is_math(s):
    return bool(MATH_FONT.search(s["font"]))


@dataclass
class Line:
    page: int
    x0: float
    y0: float
    x1: float
    y1: float
    spans: list
    words: list = field(default_factory=list)
    role: str = ""        # set when something claims the line: float, box, footer, heading, ...
    runin: str = ""       # a \paragraph head starts here (from the .toc)
    block: int = -1

    @property
    def text(self):
        return norm("".join(s["text"] for s in self.spans))

    @property
    def size(self):
        c = Counter()
        for s in self.spans:
            c[round(s["size"], 1)] += len(s["text"].strip())
        return c.most_common(1)[0][0] if c else 0

    def frac(self, pred):
        n = sum(len(s["text"].strip()) for s in self.spans)
        return sum(len(s["text"].strip()) for s in self.spans if pred(s)) / n if n else 0

    def bold_prefix(self):
        out = []
        for s in self.spans:
            if not s["text"].strip():
                out.append(" ")
            elif is_bold(s):
                out.append(s["text"])
            else:
                break
        return norm("".join(out))

    def rect(self):
        return (self.x0, self.y0, self.x1, self.y1)


@dataclass
class Block:
    kind: str
    page: int
    y0: float
    y1: float
    lines: list = field(default_factory=list)
    id: str = ""
    data: dict = field(default_factory=dict)

    @property
    def nlines(self):
        return len(self.lines)

    @property
    def last_page(self):
        return self.lines[-1].page if self.lines else self.data.get("last_page", self.page)

    @property
    def end_y(self):
        return self.lines[-1].y1 if self.lines else self.y1

    def text(self, skip=""):
        t = ""
        for l in self.lines:
            s = l.text
            if t.endswith("-") and s[:1].islower():
                t = t[:-1] + s
            else:
                t += (" " if t else "") + s
        t = re.sub(r"\s*[⋅∎□■]$", "", norm(t))
        return t[len(skip):].strip() if skip and t.startswith(skip) else t


class Paper:
    """Everything read from one built paper."""

    def __init__(self, built, name, guide, sheet, lint):
        self.built, self.name = built, name
        stem = "reviewer" if (built / "reviewer.pdf").exists() else "thesis"
        self.stem = stem
        self.pdf_path = built / f"{stem}.pdf"
        if not self.pdf_path.exists():
            die(f"no reviewer.pdf or thesis.pdf in {built}; build it first")
        try:
            self.doc = pymupdf.open(self.pdf_path)
        except Exception as e:  # PyMuPDF raises its own error types for a damaged file
            die(f"cannot read {self.pdf_path}: {e}")
        if len(self.doc) == 0:
            die(f"{self.pdf_path} has no pages")
        self.labels = parse_aux(built / f"{stem}.aux")
        if not self.labels:
            die(f"no labels in {built / (stem + '.aux')}: is this a finished LaTeX build?")
        self.toc = parse_toc(built / f"{stem}.toc")
        self.anchor_labels = defaultdict(list)
        for k, v in self.labels.items():
            if "anchor" in v:
                self.anchor_labels[v["anchor"]].append(k)
        self.names = self.doc.resolve_names()
        self.notes = []          # extraction notes shown at the top of the view
        self.guide = guide if guide else built / GUIDE
        self.sheet = Path(sheet) if sheet else built / "docs" / SHEET_NAME
        if not self.sheet.exists():
            self.notes.append(f"scoring sheet not found at {self.sheet}: criteria without the sheet's bands")
            self.sheet = None
        self.criteria, self.textual = load_criteria(self.guide, self.sheet, self.notes)
        # the lint's export: each chapter role with its criteria and files, and the paper's tag lists
        export, self.lint_source = load_lint(built, lint)
        if export is None:
            self.notes.append(f"no lint export ({self.lint_source}): no chapter → criterion map and no tag lists, "
                              "so tagged items are read by their printed prefix only")
            export = {}
        roles = export.get("chapter_roles") or {}
        self.chapter_roles = roles if isinstance(roles, dict) else {}   # an empty Lua table prints as []
        tl = export.get("tag_lists") or {}
        self.tag_lists = tl if isinstance(tl, dict) else {}
        if export and not self.chapter_roles:
            self.notes.append(f"the lint export ({self.lint_source}) has no chapter_roles: no chapter → criterion map")
        self.list_order = [e for e in LIST_ORDER if e in self.tag_lists] + sorted(e for e in self.tag_lists if e not in LIST_ORDER)
        self.env_of_prefix = {v["tag"]: e for e, v in self.tag_lists.items()}
        self.chapter_files = chapters_by_file(built, stem)
        self.src_counts = source_counts(built, stem, self.tag_lists)

    def list_env(self, cref_type):
        """The tag list a cleveref type names: the environment itself, or its counter (`assumptionsi`)."""
        if not cref_type:
            return None
        if cref_type in self.tag_lists:
            return cref_type
        if cref_type.endswith("i") and cref_type[:-1] in self.tag_lists:
            return cref_type[:-1]
        return None

    def kind_name(self, env):
        return self.tag_lists[env]["name"].lower() if env in self.tag_lists else "other"

    # positions ---------------------------------------------------------------------------
    def dest(self, name):
        d = self.names.get(name)
        if not d:
            return None
        h = self.doc[d["page"]].rect.height
        return d["page"], h - d["to"][1]

    def pos(self, page, y):
        """A position in page units over the text area: page 12 halfway down is 12.5."""
        f = (y - self.top) / max(1, self.bottom - self.top)
        return page + min(1, max(0, f))


# ----------------------------------------------------------------------------------------------
# Extraction
# ----------------------------------------------------------------------------------------------

def read_lines(P):
    """Visual lines per page (PyMuPDF lines merged by vertical overlap), page metrics, words."""
    raw = []
    size_c, x0_c, x1_c = Counter(), Counter(), Counter()
    for pno, page in enumerate(P.doc):
        d = page.get_text("dict")
        for b in d["blocks"]:
            if b["type"] != 0:
                continue
            for l in b["lines"]:
                if abs(l["dir"][1]) > 0.1:
                    continue
                spans = [dict(text=s["text"], font=s["font"], size=s["size"], flags=s["flags"], bbox=s["bbox"])
                         for s in l["spans"] if s["text"]]
                if not "".join(s["text"] for s in spans).strip():
                    continue
                raw.append((pno, l["bbox"], spans))
                for s in spans:
                    size_c[round(s["size"], 1)] += len(s["text"].strip())
    P.body = size_c.most_common(1)[0][0]
    for pno, bb, spans in raw:
        n = sum(len(s["text"]) for s in spans)
        if n > 50 and all(abs(s["size"] - P.body) < 0.3 for s in spans if s["text"].strip()):
            x0_c[round(bb[0])] += 1
            x1_c[round(bb[2])] += 1
    P.left, P.right = x0_c.most_common(1)[0][0], x1_c.most_common(1)[0][0]
    P.width = P.right - P.left
    P.lines = defaultdict(list)
    for pno, bb, spans in raw:
        x0, y0, x1, y1 = bb
        rows = P.lines[pno]
        for r in reversed(rows[-6:]):
            ov = min(r.y1, y1) - max(r.y0, y0)
            if ov >= 0.5 * min(r.y1 - r.y0, y1 - y0) and not (x0 > P.right + 2 or x1 < P.left - 2) \
                    and not (r.x0 > P.right + 2 or r.x1 < P.left - 2):
                if x0 < r.x0:
                    r.spans = spans + [dict(text=" ", font="", size=0, flags=0, bbox=bb)] + r.spans
                else:
                    r.spans = r.spans + [dict(text=" ", font="", size=0, flags=0, bbox=bb)] + spans
                r.x0, r.y0, r.x1, r.y1 = min(r.x0, x0), min(r.y0, y0), max(r.x1, x1), max(r.y1, y1)
                break
        else:
            rows.append(Line(pno, x0, y0, x1, y1, spans))
    for pno in P.lines:
        P.lines[pno].sort(key=lambda l: (round(l.y0), l.x0))
    # header, footer, margin notes
    for pno, page in enumerate(P.doc):
        h, label = page.rect.height, page.get_label()
        for l in P.lines[pno]:
            t = l.text
            if l.y0 > 0.88 * h and (t == label or re.fullmatch(r"[ivxlcdm\d]+", t)):
                l.role = "footer"
            elif l.x0 > P.right + 3 or l.x1 < P.left - 3:
                l.role = "margin"
    body_lines = [l for p in P.lines.values() for l in p if not l.role and abs(l.size - P.body) < 0.3]
    P.top = sorted(l.y0 for l in body_lines)[max(0, len(body_lines) // 200)]
    P.bottom = sorted(l.y1 for l in body_lines)[-max(1, len(body_lines) // 200)]
    gaps = Counter()
    for p in P.lines.values():
        prev = None
        for l in p:
            if prev and not l.role and not prev.role and abs(l.size - P.body) < 0.3 and abs(prev.size - P.body) < 0.3:
                g = l.y0 - prev.y1
                if 0 <= g < 2 * P.body:
                    gaps[round(g)] += 1
            prev = l
    P.line_gap = gaps.most_common(1)[0][0] if gaps else 2
    P.gap_thr = P.line_gap + 0.25 * P.body
    # words: each word to its line; (x0, y0, x1, y1, text, block, line, n) as PyMuPDF gives them
    P.words = {}
    for pno, page in enumerate(P.doc):
        ws = [tuple(w) for w in page.get_text("words")]
        P.words[pno] = ws
        rows = P.lines[pno]
        for w in ws:
            cy, cx = (w[1] + w[3]) / 2, (w[0] + w[2]) / 2
            for l in rows:
                if l.y0 - 0.5 <= cy <= l.y1 + 0.5 and l.x0 - 1 <= cx <= l.x1 + 1:
                    l.words.append(w)
                    break
    P.drawings = {pno: page.get_drawings() for pno, page in enumerate(P.doc)}
    P.images = {pno: [b["bbox"] for b in page.get_text("dict")["blocks"] if b["type"] == 1]
                for pno, page in enumerate(P.doc)}


def near_white(c, thr):
    return c is not None and min(c) >= thr


def near_black(c):
    return c is not None and max(c) < 0.25


def body_like(P, l):
    return abs(l.size - P.body) < 0.6 and abs(l.x0 - P.left) < 4 and l.x1 > P.right - 30 and l.frac(is_mono) < 0.3


def find_floats(P):
    """Captioned floats. Extent: from the float's hyperref anchor (top of the float, hypcap) to the
    caption for content above it; for content below the caption (tables), grow down over rules,
    drawings, images and non-body lines."""
    P.floats = []
    used = set()
    for pno, page in enumerate(P.doc):
        lines = P.lines[pno]
        dests = [(n, P.dest(n)[1]) for n, d in P.names.items() if d["page"] == pno]
        hrules = [d["rect"] for d in P.drawings[pno] if d["rect"].height <= 1.6 and d["rect"].width >= 0.25 * P.width]
        elems = [("draw", d["rect"]) for d in P.drawings[pno]] + [("img", pymupdf.Rect(b)) for b in P.images[pno]]
        for i, l in enumerate(lines):
            if l.role:
                continue
            m = CAP_RE.match(l.bold_prefix())
            # a caption starts near the left margin, or is one short line centred on the column
            if not m or (l.x0 > P.left + 0.4 * P.width and abs((l.x0 + l.x1) - (P.left + P.right)) > 20):
                continue
            cap = [l]
            for nxt in lines[i + 1:]:
                if nxt.role or nxt.y0 - cap[-1].y1 > 0.45 * P.body:
                    break
                if nxt.x0 < l.x0 - 3 or nxt.x1 > max(c.x1 for c in cap) + 3 or CAP_RE.match(nxt.bold_prefix()):
                    break
                cap.append(nxt)
            kind, num = m.groups()
            cands = [(y, n) for n, y in dests if n.startswith(DEST_PREFIX[kind]) and n not in used and y <= l.y0 + 3]
            anchor, ay = (max(cands)[1], max(cands)[0]) if cands else (None, None)
            if anchor:
                used.add(anchor)
            if anchor and l.y0 - ay > 2.5 * P.body:  # content above the caption, from the float's top
                band = [r.y0 for k, r in elems if r.y0 >= ay - 1 and r.y1 <= l.y0 + 1] + \
                       [x.y0 for x in lines if not x.role and x.y0 >= ay - 1 and x.y1 <= l.y0 + 1]
                top, bottom = (min(band) if band else ay), cap[-1].y1
            elif kind != "Figure" or anchor:  # content below the caption (a table)
                top, bottom = l.y0, cap[-1].y1
                # booktabs: down to the last rule before body text or the next caption resumes
                stop = min([x.y0 for x in lines[i + len(cap):] if not x.role and (body_like(P, x) or CAP_RE.match(x.bold_prefix()))]
                           + [page.rect.height])
                rules = [h.y1 for h in hrules if bottom < h.y0 < stop]
                if rules and min(rules) - bottom < 2.5 * P.body:
                    bottom = max(rules)
                for e in sorted([("line", pymupdf.Rect(x.rect()), x) for x in lines if not x.role and x not in cap and x.y0 >= bottom - 1]
                                + [(k, r, None) for k, r in elems if r.y0 >= bottom - 2], key=lambda e: e[1].y0):
                    k, r, x = e
                    if r.y0 > bottom + 9:
                        break
                    if x is not None and body_like(P, x) and not any(x.y1 < h.y0 < x.y1 + 3 * P.body for h in hrules):
                        break
                    bottom = max(bottom, r.y1)
            else:  # a figure without an anchor: grow up from the caption
                top, bottom = l.y0, cap[-1].y1
                for e in sorted([("line", pymupdf.Rect(x.rect()), x) for x in lines if not x.role and x.y1 <= top + 1]
                                + [(k, r, None) for k, r in elems if r.y1 <= top + 2], key=lambda e: -e[1].y1):
                    k, r, x = e
                    if r.y1 < top - 9:
                        break
                    if x is not None and body_like(P, x):
                        break
                    top = min(top, r.y0)
            inside = [x for x in lines if not x.role and top - 1 <= (x.y0 + x.y1) / 2 <= bottom + 1]
            xs = [x.x0 for x in inside] + [r.x0 for k, r in elems if r.y0 >= top - 2 and r.y1 <= bottom + 2]
            xe = [x.x1 for x in inside] + [r.x1 for k, r in elems if r.y0 >= top - 2 and r.y1 <= bottom + 2]
            rect = pymupdf.Rect(min([P.left] + xs) - 3, top - 2, max([P.right] + xe) + 3, bottom + 2) & page.rect
            for x in inside:
                x.role = "float"
            f = Block("float", pno, rect.y0, rect.y1, id="")
            f.data = dict(kind=kind, number=num, caption=Block("x", pno, 0, 0, lines=cap).text(), anchor=anchor,
                          rect=tuple(rect), labels=P.anchor_labels.get(anchor, []) if anchor else [],
                          words=[w for w in P.words[pno] if rect.contains(pymupdf.Point((w[0] + w[2]) / 2, (w[1] + w[3]) / 2))],
                          cap_lines=len(cap))
            f.id = slug(f"{kind}-{num}")
            P.floats.append(f)
    P.float_rects = defaultdict(list)
    for f in P.floats:
        P.float_rects[f.page].append(pymupdf.Rect(f.data["rect"]))


def find_boxes(P):
    """Coloured boxes: a light tinted fill at least half the text width, or a coloured bar at the left
    of the column (tcolorbox borderline west, framed's \\vrule). Mostly-monospace content is a listing."""
    pieces = []
    for pno in range(len(P.doc)):
        cands = []
        for d in P.drawings[pno]:
            r = d["rect"]
            if any(fr.contains(r) or (fr & r).get_area() > 0.5 * max(1, r.get_area()) for fr in P.float_rects[pno]):
                continue
            if r.x1 < P.left - 20 or r.x0 > P.right + 20:
                continue
            fill, col = d.get("fill"), d.get("color")
            if fill and r.width >= 0.5 * P.width and r.height >= 6 and not near_white(fill, 0.985) and not near_black(fill):
                cands.append((pymupdf.Rect(r), fill))
            elif r.width <= 4.5 and r.height >= 8 and r.x0 <= P.left + 12:
                c = fill if d["type"] == "f" else col
                if c and not near_black(c) and not near_white(c, 0.9):
                    cands.append((pymupdf.Rect(r), c))
        groups_ = []
        for r, c in sorted(cands, key=lambda x: x[0].y0):
            for g in groups_:
                if r.y0 <= g[0].y1 + 4 and r.x0 <= g[0].x1 + 2 and r.x1 >= g[0].x0 - 2:
                    g[0] |= r
                    g[1].add(tuple(round(x, 2) for x in c))
                    break
            else:
                groups_.append([pymupdf.Rect(r), {tuple(round(x, 2) for x in c)}])
        for g, c in groups_:
            box = pymupdf.Rect(g.x0, g.y0, max(g.x1, P.right + 2), g.y1)
            inside = [l for l in P.lines[pno] if not l.role and box.contains(pymupdf.Point((l.x0 + l.x1) / 2, (l.y0 + l.y1) / 2))]
            if not inside:
                continue
            mono = sum(l.frac(is_mono) for l in inside) / len(inside)
            if mono > 0.5:
                continue
            for l in inside:
                l.role = "box"
            pieces.append(dict(page=pno, rect=box, color=c, lines=inside))
    # boxes broken across pages
    P.boxes = []
    for pc in pieces:
        prev = P.boxes[-1] if P.boxes else None
        if prev and pc["page"] == prev.last_page + 1 and prev.data["pieces"][-1]["rect"].y1 >= P.bottom - 25 \
                and pc["rect"].y0 <= P.top + 25 and pc["color"] & prev.data["pieces"][-1]["color"]:
            prev.lines += pc["lines"]
            prev.data["pieces"].append(pc)
            prev.data["last_page"] = pc["page"]
            continue
        b = Block("box", pc["page"], pc["rect"].y0, pc["rect"].y1, lines=list(pc["lines"]))
        b.data = dict(pieces=[pc], last_page=pc["page"])
        P.boxes.append(b)
    for i, b in enumerate(P.boxes, 1):
        b.id = f"box-{i}"
        title = b.lines[0].bold_prefix() if b.lines else ""
        # a draft build prints todonotes as untitled coloured boxes: report them as notes, not boxes
        note = not title and P.stem != "reviewer"
        b.data.update(title=title, text=b.text(skip=title), note=note, rects=[(pc["page"], tuple(pc["rect"])) for pc in b.data["pieces"]])


def find_footnotes(P):
    P.footnotes = Counter()
    for pno in range(len(P.doc)):
        rules = [d["rect"] for d in P.drawings[pno] if d["rect"].height <= 1.5 and abs(d["rect"].x0 - P.left) < 4
                 and 0.15 * P.width <= d["rect"].width <= 0.5 * P.width and d["rect"].y0 > 0.4 * P.doc[pno].rect.height
                 and not any(fr.contains(d["rect"]) for fr in P.float_rects[pno])]
        if not rules:
            continue
        y = min(r.y0 for r in rules)
        for l in P.lines[pno]:
            if not l.role and l.y0 > y and l.size < P.body - 0.5:
                l.role = "footnote"
                first = next((s for s in l.spans if s["text"].strip()), None)
                if first and (first["flags"] & 1 or (re.fullmatch(r"\d+", first["text"].strip()) and first["size"] < P.body - 2)):
                    P.footnotes[pno] += 1


def place_outline(P):
    """Outline entries from the .toc, placed by their named destinations; claims heading lines and
    marks run-in \\paragraph heads. PDF outline titles are used where they exist (clean text)."""
    pdf_titles = {}
    for lvl, title, pg, dest in P.doc.get_toc(simple=False):
        if isinstance(dest, dict) and dest.get("nameddest"):
            pdf_titles[dest["nameddest"]] = title
    levels = {"part": 0, "chapter": 1, "section": 2, "subsection": 3, "subsubsection": 4, "paragraph": 5, "subparagraph": 6}
    P.outline = []
    for e in P.toc:
        d = P.dest(e["anchor"])
        if not d or e["level"] not in levels:
            continue
        title = pdf_titles.get(e["anchor"]) or strip_tex(e["raw"])
        if e["number"] and title.startswith(e["number"] + " "):
            title = title[len(e["number"]) + 1:]
        P.outline.append(dict(level=levels[e["level"]], number=e["number"], title=norm(title), page=d[0], y=d[1],
                              label=e["page"], anchor=e["anchor"]))
    if not P.outline:
        die("no outline: the .toc has no entries with named destinations (hyperref missing?)")
    P.outline.sort(key=lambda o: (o["page"], o["y"]))
    for o in P.outline:
        lines = [l for l in P.lines[o["page"]] if not l.role and l.y0 >= o["y"] - 4]
        if not lines:
            continue
        if o["level"] >= 5:  # a run-in head: its anchor sits near the baseline, match by title
            key = o["title"].lower()[:6]
            near = [l for l in P.lines[o["page"]] if not l.role and o["y"] - 22 <= l.y0 <= o["y"] + 8
                    and l.bold_prefix().lower().startswith(key)]
            if near:
                near[0].runin = o["title"]
            continue
        first = lines[0]
        claimed = [first]
        for l in lines[1:]:
            if l.y0 - claimed[-1].y1 > 1.5 * max(P.body, claimed[-1].size) or not (l.size > P.body + 0.5 and l.bold_prefix()):
                break
            claimed.append(l)
        if first.size <= P.body + 0.5 and not first.bold_prefix():
            continue
        for l in claimed:
            l.role = "heading"
    # parts of the document
    lvl1 = [o for o in P.outline if o["level"] == 1]
    start = next((i for i, o in enumerate(lvl1) if o["number"]), None)
    if start is None:
        die("no numbered chapter in the .toc")
    stop = next((i for i in range(start + 1, len(lvl1)) if not lvl1[i]["number"]), len(lvl1))
    for i, o in enumerate(lvl1):
        t = o["title"].lower()
        if start <= i < stop:
            o["part"] = "main"
        elif o["number"]:
            o["part"] = "appendix"
        elif "kivonat" in t or "összefoglal" in t:
            o["part"] = "kivonat"
        elif "abstract" in t:
            o["part"] = "abstract"
        elif re.search(r"appendi|függelék", t):
            o["part"] = "appendix"
        else:
            o["part"] = "back"
    P.lvl1 = lvl1
    P.main_first = lvl1[start]["page"]
    P.main_last = lvl1[stop]["page"] - 1 if stop < len(lvl1) else len(P.doc) - 1
    P.main_pages = P.main_last - P.main_first + 1
    P.outline_keys = [(o["page"], o["y"]) for o in P.outline]
    # chapter roles, as the lint assigns them: a role's files (chapter_roles) start the chapters their
    # .aux writes into the toc. Without the export, the ch:<role> labels, which is the lint's own rule.
    roles_of = defaultdict(list)
    if P.chapter_roles:
        for role, v in P.chapter_roles.items():
            for f in v.get("files") or []:
                anchors = P.chapter_files.get(f)
                if anchors is None:
                    P.notes.append(f"the lint gives {f} the {role} role, but the build's .aux does not include it")
                for a in anchors or []:
                    if role not in roles_of[a]:
                        roles_of[a].append(role)
    else:
        for lab, v in P.labels.items():
            m = re.fullmatch(r"ch:([a-z]+)(?::.+)?", lab)
            if m and v.get("anchor") in P.names:
                ch = chapter_of(P, *P.dest(v["anchor"]))
                if ch and m.group(1) not in roles_of[ch["anchor"]]:
                    roles_of[ch["anchor"]].append(m.group(1))
    for o in lvl1:
        o["roles"] = roles_of.get(o["anchor"], []) if o["part"] == "main" else []
        o["criteria"] = sorted({c for r in o["roles"] for c in (P.chapter_roles.get(r, {}).get("criteria") or [])})


def chapter_of(P, page, y):
    best = None
    for o in P.lvl1:
        if (o["page"], o["y"]) <= (page, y + 1):
            best = o
    return best


def classify(P, l):
    if l.frac(is_mono) >= 0.6 and len(l.text) > 1:
        return "mono"
    if len(l.text) <= 3 and l.x0 > P.left + 0.6 * P.width:
        return "tiny"
    if l.frac(is_math) >= 0.45 and (l.x0 > P.left + 15 or re.search(r"\(\d+(\.\d+)*\)$", l.text)):
        return "math"
    if re.fullmatch(r"\(\d+(\.\d+)*[a-z]?\)", l.text) and l.x0 > P.left + 0.7 * P.width:
        return "math"
    return "text"


def item_start(l):
    t = l.text
    return bool(l.bold_prefix()) or (t[:1] in BULLETS) or bool(ENUM_RE.match(t))


def build_blocks(P):
    """Chunks of unclaimed lines -> typed blocks, merged with floats and boxes in reading order."""
    part_of_page = {}
    for o in P.lvl1:
        part_of_page.setdefault(o["page"], o["part"])
    chunks = []
    first_page = P.lvl1[0]["page"] if P.lvl1 else 0
    for pno in range(len(P.doc)):
        for l in P.lines[pno]:
            ch = chapter_of(P, pno, l.y0)
            part = ch["part"] if ch else "front"
            if pno < first_page or part == "back":
                if not l.role:
                    l.role = part if pno >= first_page else "front"
                continue
            if l.role and l.role != "heading":
                continue
            if l.role == "heading":
                if chunks and chunks[-1]["kind"] == "heading" and chunks[-1]["lines"][-1].page == pno \
                        and l.y0 - chunks[-1]["lines"][-1].y1 < 1.5 * max(l.size, chunks[-1]["lines"][-1].size) \
                        and not any(abs(o["y"] - l.y0) < 6 and o["page"] == pno for o in P.outline if o["level"] <= 4
                                    and o["y"] > chunks[-1]["lines"][-1].y1):
                    chunks[-1]["lines"].append(l)
                else:
                    chunks.append(dict(kind="heading", lines=[l]))
                continue
            cls = classify(P, l)
            prev = chunks[-1] if chunks else None
            pl = prev["lines"][-1] if prev else None
            if cls == "tiny" and prev and prev["kind"] != "heading" and pl.page == pno:
                prev["lines"].append(l)
                continue
            if cls == "mono" and prev and prev["kind"] != "heading" and prev["cls"] == "text" and pl.page == pno \
                    and l.y0 - pl.y1 <= P.line_gap + 1 and l.x1 > P.right - 40:
                prev["lines"].append(l)
                continue
            new = (prev is None or prev["kind"] == "heading" or pl.page != pno or l.y0 - pl.y1 > P.gap_thr
                   or cls != prev["cls"] or bool(l.runin)
                   or (item_start(l) and l.x0 < pl.x0 - 5)
                   or (l.text[:1] in BULLETS)
                   or (cls == "text" and item_start(l) and (TAG_RE.match(l.bold_prefix()) or THM_RE.match(l.bold_prefix())))
                   or (cls == "text" and pl.x1 < P.right - 25 and abs(l.x0 - P.left) < 25 and not prev["kind"] == "heading"
                       and abs(l.x0 - pl.x0) > 4 and prev["cls"] == "text"))
            # interrupted by a float or box between the two lines on the same page
            if not new and any(pl.y1 <= r.y0 and r.y1 <= l.y0 for r in P.float_rects[pno]):
                new = True
            if new:
                chunks.append(dict(kind="chunk", cls=cls, lines=[l]))
            else:
                prev["lines"].append(l)
    # which tag prefixes form lists (an unknown prefix needs two items)
    prefix_count = Counter()
    for c in chunks:
        if c["kind"] == "chunk" and c["cls"] == "text":
            m = TAG_RE.match(c["lines"][0].bold_prefix())
            if m:
                prefix_count[m.group(1)] += 1
    blocks = []
    for c in chunks:
        L = c["lines"]
        first = L[0]
        b = Block("para", first.page, first.y0, L[-1].y1, lines=L)
        if c["kind"] == "heading":
            b.kind = "heading"
        elif c["cls"] == "mono":
            b.kind = "listing"
        elif c["cls"] == "math":
            b.kind = "math"
        else:
            bp = first.bold_prefix()
            mt, mh = TAG_RE.match(bp), THM_RE.match(bp)
            if first.runin:
                b.data["runin"] = bp if bp.lower().startswith(first.runin.lower()[:6]) else first.runin
            elif mt and (mt.group(1) in P.env_of_prefix or prefix_count[mt.group(1)] >= 2):
                b.kind = "item"
                tag = mt.group(0)
                rest = bp[len(tag):].strip(" ,.:;—–-")
                name = rest
                if not name:  # \item[AS1] \emph{Name.} or the first italic run
                    spans = [s for s in first.spans if s["text"].strip()]
                    k = 0
                    while k < len(spans) and is_bold(spans[k]):
                        k += 1
                    run = []
                    while k < len(spans) and is_italic(spans[k]) and not is_math(spans[k]):
                        run.append(spans[k]["text"])
                        k += 1
                    name = norm(" ".join(run)).strip(" ,.:;")
                    if name:
                        bp = norm(bp + " " + "".join(run))
                b.data.update(tag=tag, prefix=mt.group(1), name=name, head=bp)
            elif mh:
                b.kind = "theorem"
                nm = re.search(r"\(([^)]*)\)", bp)
                b.data.update(tag=f"{mh.group(1)} {mh.group(2)}", env=mh.group(1), name=nm.group(1) if nm else "", head=bp)
            elif re.match(r"^Proof\b", first.text) and first.spans and (is_italic(first.spans[0]) or is_bold(first.spans[0])):
                b.kind = "proof"
            elif first.text[:1] in BULLETS or (ENUM_RE.match(first.text) and first.x0 > P.left + 4):
                b.kind = "li"
            elif bp and len(bp.split()) <= 10 and not CAP_RE.match(bp) and re.search(r"[.:?)]$", bp):
                if len(L) > 1 and L[1].x0 > first.x0 + 6:
                    b.kind = "li"
                    b.data["label"] = bp
                else:
                    b.kind = "desc?"
                    b.data["label"] = bp
        blocks.append(b)
    # one-line bold-led chunks: list items next to list items, run-in heads otherwise
    for i, b in enumerate(blocks):
        if b.kind == "desc?":
            nb = [blocks[j] for j in (i - 1, i + 1) if 0 <= j < len(blocks)]
            if any(x.kind in ("li", "desc?") and x.data.get("label") for x in nb) and b.nlines <= 2:
                b.kind = "li"
            else:
                b.kind = "para"
                b.data["runin"] = b.data.pop("label")
    # merge: list items into lists, indented follow-ups into the item/list above, paragraphs over page breaks
    merged = []
    for b in blocks:
        prev = merged[-1] if merged else None
        if b.kind == "li":
            if prev and prev.kind == "list" and b.page - prev.last_page <= 1:
                prev.lines += b.lines
                prev.data["items"] += 1
                if b.data.get("label"):
                    prev.data["labels"].append(b.data["label"])
                continue
            nb = Block("list", b.page, b.y0, b.y1, lines=list(b.lines))
            nb.data = dict(items=1, labels=[b.data["label"]] if b.data.get("label") else [])
            merged.append(nb)
            continue
        if prev and b.kind == "para" and not b.data.get("runin") and prev.kind in ("list", "item", "theorem") \
                and b.lines[0].x0 > P.left + 10 and b.page - prev.last_page <= 1:
            prev.lines += b.lines
            continue
        if prev and b.kind in ("math", "listing") and prev.kind == b.kind and b.page - prev.last_page <= 1:
            prev.lines += b.lines
            continue
        if prev and b.kind == "para" and not b.data.get("runin") and prev.kind in ("para", "item", "theorem", "proof") \
                and b.page == prev.last_page + 1 and prev.lines[-1].x1 >= P.right - 4 \
                and not any(x.page == b.page and x.y1 <= b.y0 for x in P.floats + P.boxes) \
                and not any(l.page == b.page and l.y1 <= b.y0 and l.role == "heading" for l in P.lines[b.page]):
            prev.lines += b.lines
            continue
        merged.append(b)
    for b in merged:
        b.y1 = max(l.y1 for l in b.lines if l.page == b.page)
    allb = merged + P.floats + P.boxes
    allb.sort(key=lambda b: (b.page, b.y0))
    for i, b in enumerate(allb):
        if not b.id:
            b.id = f"b{i}"
        for l in b.lines:
            l.block = i
        ch = chapter_of(P, b.page, b.y0)
        b.data["chapter"] = ch["anchor"] if ch else ""
        b.data["part"] = ch["part"] if ch else "front"
    P.blocks = allb
    # heading blocks carry their outline entry
    for b in P.blocks:
        if b.kind == "heading":
            o = min((o for o in P.outline if o["page"] == b.page and o["level"] <= 4),
                    key=lambda o: abs(o["y"] - b.y0), default=None)
            if o:
                b.data.update(level=o["level"], number=o["number"], title=o["title"], anchor=o["anchor"])
                b.id = "h-" + slug(o["anchor"])
            else:
                b.data.update(level=4, number="", title=b.text(), anchor="")


def join_lines(texts):
    t = ""
    for s in texts:
        if t.endswith("-") and s[:1].islower():
            t = t[:-1] + s
        else:
            t += (" " if t else "") + s
    return norm(t)


def read_tagged(P, e, stops):
    """Read the item a tag-list label points to, at its anchor: the printed tag just below the anchor,
    then the rest of its table row, cell by cell (a \\tagrow), or the rest of its item (a list item
    inside a float or a box). stops: y positions on the page where the next tagged item starts.
    Returns a Block, or None when the tag is not printed there."""
    pno, ay, tag = e["pno"], e["y"], e["tag"]
    words = P.words[pno]
    cands = [w for w in words if w[4].strip("()[],.;:") == tag and ay - 6 <= w[1] <= ay + 3 * P.body]
    if not cands:
        return None
    tw = min(cands, key=lambda w: (abs(w[1] - ay), w[0]))
    top = tw[1] - 1
    bottom = min([y for y in stops if y > tw[3]]
                 + [w[1] - 0.5 for w in words if abs(w[0] - tw[0]) < 2 and w[1] > tw[3] + 1]   # the next row's first cell
                 + [d["rect"].y0 for d in P.drawings[pno] if d["rect"].height <= 1.6 and d["rect"].width >= 0.25 * P.width
                    and d["rect"].y0 > tw[3]]                                                    # a table rule
                 + [P.bottom + 2])
    band = [w for w in words if top <= (w[1] + w[3]) / 2 < bottom and w[0] >= tw[0] - 0.5 and w is not tw]
    raw = defaultdict(list)
    for w in band:
        raw[(w[5], w[6])].append(w)
    rows = []   # raw lines: x0, y0, text, (block, line), y1
    for key, ws in raw.items():
        ws.sort(key=lambda w: w[7])
        rows.append((min(w[0] for w in ws), min(w[1] for w in ws), " ".join(w[4] for w in ws), key, max(w[3] for w in ws)))
    own = (tw[5], tw[6])
    if any(r[3] == own for r in rows):
        # the tag shares its line with the text: a list item; the short name is the bold run after it.
        # It ends at a gap wider than a line's, at a line that starts left of its text, or at a float
        # it is not part of.
        rows.sort(key=lambda r: (round(r[1]), r[0]))
        text_x = next(r[0] for r in rows if r[3] == own)
        tagc = pymupdf.Point(tw[0] + 1, (tw[1] + tw[3]) / 2)
        others = [r for r in P.float_rects[pno] if not r.contains(tagc)]
        kept, last = [], tw[3]
        for r in rows:
            if r[3] != own and (r[1] > last + P.gap_thr + 1 or r[0] < text_x - 2
                                or any(fr.contains(pymupdf.Point(r[0] + 1, r[1] + 1)) for fr in others)):
                break
            kept.append(r)
            last = max(last, r[4])
        rows = kept
        band = [w for w in band if (w[5], w[6]) in {r[3] for r in rows}]
        text = join_lines(r[2] for r in rows)
        line = next((l for l in P.lines[pno] if l.y0 - 1 <= (tw[1] + tw[3]) / 2 <= l.y1 + 1 and l.x0 - 1 <= tw[0] <= l.x1), None)
        bp = line.bold_prefix() if line else ""
        name = bp[len(tag):].strip(" ,.:;—–-") if bp.startswith(tag) else ""
        if name and text.startswith(name):
            text = text[len(name):].lstrip(" .:")
        how = "item"
    else:
        # a table row: one cell per column, the columns told apart by where their lines start
        cols = []
        for r in sorted(rows, key=lambda r: r[0]):
            if cols and r[0] - cols[-1][0] < 4:
                cols[-1][1].append(r)
            else:
                cols.append([r[0], [r]])
        cells = [join_lines(r[2] for r in sorted(c[1], key=lambda r: r[1])) for c in cols]
        name, text = (cells[0], " | ".join(cells[1:])) if cells else ("", "")
        how = "row"
    if not name and not text:
        return None
    x1 = max([w[2] for w in band] + [tw[2]])
    y1 = max([w[3] for w in band] + [tw[3]])
    b = Block("item", pno, tw[1], y1, id="")
    host = next((f for f in P.floats if f.page == pno and pymupdf.Rect(f.data["rect"]).contains(pymupdf.Point(tw[0] + 1, (tw[1] + tw[3]) / 2))), None)
    if host is None:
        host = next((x for x in P.boxes for pg, r in x.data["rects"] if pg == pno and pymupdf.Rect(r).contains(pymupdf.Point(tw[0] + 1, (tw[1] + tw[3]) / 2))), None)
    b.data = dict(tag=tag, prefix=TAG_RE.match(tag).group(1) if TAG_RE.match(tag) else tag, name=name, head=tag, text=text,
                  read=how, rect=(tw[0] - 1, top, x1 + 1, y1 + 1), tag_box=tuple(tw[:4]), host=host.id if host else "")
    return b


def item_ids(P):
    """Ids, kinds and labels of tagged items and theorem-likes. The .aux is the inventory of tagged
    items: every label whose cleveref type is a tag list has a printed tag and an anchor. A label is
    matched to an item read from the paragraphs by its anchor's position; failing that, the item is
    read at its anchor (a \\tagrow table row, or an item inside a float or box); failing that, it is
    unsure, with its page. Theorem-likes keep their labels by position as before."""
    inventory = []
    item_dests = defaultdict(list)
    for lab, v in P.labels.items():
        env = P.list_env(v.get("type"))
        if env and "printed" in v:
            e = dict(label=lab, env=env, tag=unbrace(v["printed"]), page_label=v.get("page", "?"), anchor=v.get("anchor", ""),
                     pno=None, y=None)
            if e["anchor"] in P.names:
                e["pno"], e["y"] = P.dest(e["anchor"])
            inventory.append(e)
        if "anchor" in v and v["anchor"] in P.names and (env or re.match(r"(Item|theorem|definition|lemma|invariant)", v["anchor"])):
            pg, y = P.dest(v["anchor"])
            item_dests[pg].append((y, lab, v))
    seen = Counter()
    used = set()
    P.items = []
    # a \tagrow steps the list's counter outside the list, so its anchor is <list>i.N, never Item.N: it
    # is always a table row and is read cell by cell below; a paragraph that took its tag is that
    # table's rows run together (a continuation without caption, which no float claims)
    rowtags = {(e["pno"], e["tag"]): e["y"] for e in inventory if e["pno"] is not None and e["anchor"].startswith(e["env"] + "i.")}
    printed = {e["tag"] for e in inventory}
    for b in P.blocks:
        if b.kind not in ("item", "theorem"):
            continue
        tag = b.data["tag"]
        ry = rowtags.get((b.page, tag))
        if b.kind == "item" and ry is not None and b.y0 - 22 <= ry <= b.y0 + 8:
            b.kind = "rows"
            continue
        labs = [(lab, v) for y, lab, v in item_dests.get(b.page, []) if b.y0 - 22 <= y <= b.y0 + 8 and lab not in used
                and not v.get("anchor", "").startswith(f"{P.list_env(v.get('type'))}i.")
                and (unbrace(v.get("printed", "")) == tag or (b.kind == "theorem" and not P.list_env(v.get("type"))))]
        if labs:
            lab, v = labs[0]
            used.add(lab)
            b.data.update(label=lab, anchor=v["anchor"])
            if P.list_env(v.get("type")):
                b.data["kind"] = P.list_env(v["type"])
        elif b.kind == "item" and tag in printed:
            # a bold head that starts with a tag some label prints ("RQ1 on the fixed vectors") is a
            # run-in head about that item; the item itself is read at its own label
            b.kind = "para"
            b.data["runin"] = b.data["head"]
            continue
        if b.kind == "item":
            b.data.setdefault("kind", P.env_of_prefix.get(b.data["prefix"], "other"))
            b.data["read"] = "paragraph"
        else:
            b.data["kind"] = "theorem"
        b.data["text"] = b.text(skip=b.data["head"])
        P.items.append(b)
    # labels no paragraph claimed: read them at their anchors, else they are unsure
    P.unsure = []
    P.row_items = []
    left = [e for e in inventory if e["label"] not in used]
    stops = defaultdict(list)
    for e in inventory:
        if e["pno"] is not None:
            stops[e["pno"]].append(e["y"] + 2)
    for e in sorted(left, key=lambda e: (e["pno"] if e["pno"] is not None else 1e9, e["y"] or 0)):
        b = read_tagged(P, e, stops[e["pno"]]) if e["pno"] is not None else None
        if b is None:
            where = f"p. {P.doc[e['pno']].get_label()}" if e["pno"] is not None else f"p. {e['page_label']} (no link target in the PDF)"
            P.unsure.append(dict(tag=e["tag"], label=e["label"], kind=e["env"], page=e["page_label"] if e["pno"] is None else P.doc[e["pno"]].get_label(),
                                 why=f"the .aux places {e['label']} on {where}, but the skim could not read its printed tag there"))
            continue
        b.data.update(label=e["label"], anchor=e["anchor"], kind=e["env"])
        P.row_items.append(b)
        P.items.append(b)
    P.items.sort(key=lambda b: (b.page, b.y0))
    for b in P.items:
        tag = b.data["tag"]
        seen[tag] += 1
        b.id = "it-" + slug(tag) + (f"-{seen[tag]}" if seen[tag] > 1 else "")
        ch = chapter_of(P, b.page, b.y0)
        b.data.setdefault("chapter", ch["anchor"] if ch else "")
        b.data.setdefault("part", ch["part"] if ch else "front")
        b.data["marks"] = marks(b.data["head"] + " " + b.data.get("name", "") + " " + b.data["text"])
    P.inventory = inventory
    dup = [t for t, n in seen.items() if n > 1]
    if dup:
        P.notes.append("duplicate tags (two items print the same tag): " + ", ".join(sorted(dup)))
    P.item_by_anchor = {b.data["anchor"]: b for b in P.items if b.data.get("anchor")}
    P.items_by_tag = defaultdict(list)
    for b in P.items:
        P.items_by_tag[b.data["tag"]].append(b)
    for f in P.floats:
        f.data["key"] = f"{f.data['kind']} {f.data['number']}"
    P.float_by_key = {f.data["key"]: f for f in P.floats}
    P.float_by_anchor = {f.data["anchor"]: f for f in P.floats if f.data["anchor"]}


# ----------------------------------------------------------------------------------------------
# Links and mentions
# ----------------------------------------------------------------------------------------------

def read_links(P):
    P.links = defaultdict(list)
    P.cites = Counter()
    P.cite_by_chapter = Counter()
    P.broken = []
    for pno, page in enumerate(P.doc):
        for lk in page.get_links():
            if lk["kind"] not in (pymupdf.LINK_NAMED, pymupdf.LINK_GOTO):
                continue
            name = lk.get("nameddest") or lk.get("name") or ""
            r = pymupdf.Rect(lk["from"])
            text = norm(" ".join(w[4] for w in P.words[pno] if r.contains(pymupdf.Point((w[0] + w[2]) / 2, (w[1] + w[3]) / 2))))
            rec = dict(page=pno, rect=r, dest=name, text=text, ok=bool(name in P.names or lk["kind"] == pymupdf.LINK_GOTO))
            P.links[pno].append(rec)
            if name.startswith("cite."):
                P.cites[name[5:]] += 1
                ch = chapter_of(P, pno, r.y0)
                if ch:
                    P.cite_by_chapter[ch["anchor"]] += 1
            elif name and name not in P.names:
                P.broken.append(dict(page=pno, text=text, why=f"link to a missing destination {name}"))
        for w in P.words[pno]:
            if "??" in w[4]:
                P.broken.append(dict(page=pno, text=w[4], why="undefined reference (??)"))
            elif "[?]" in w[4] or w[4].startswith("[?"):
                P.broken.append(dict(page=pno, text=w[4], why="undefined citation ([?])"))
    log = P.built / f"{P.stem}.log"
    if log.exists():
        t = log.read_text(errors="replace")
        u = Counter(re.findall(r"(Reference|Citation) `[^']*' on page", t))
        if u:
            P.notes.append(f"LaTeX log: {u['Reference']} undefined reference(s), {u['Citation']} undefined citation(s)")
    bbl = P.built / f"{P.stem}.bbl"
    P.bib_entries = len(re.findall(r"\\bibitem\b", bbl.read_text(errors="replace"))) if bbl.exists() else 0


def link_at(P, pno, w):
    c = pymupdf.Point((w[0] + w[2]) / 2, (w[1] + w[3]) / 2)
    return next((lk for lk in P.links[pno] if lk["rect"].contains(c)), None)


def owner_of(P, pno, w):
    c = pymupdf.Point((w[0] + w[2]) / 2, (w[1] + w[3]) / 2)
    for b in P.row_items:   # a tagged item read inside a float or box owns the mentions in its row
        if b.page == pno and pymupdf.Rect(b.data["rect"]).contains(c):
            return b
    for f in P.floats:
        if f.page == pno and pymupdf.Rect(f.data["rect"]).contains(c):
            return f
    for l in P.lines[pno]:
        if l.y0 - 0.5 <= c.y <= l.y1 + 0.5 and l.x0 - 1 <= c.x <= l.x1 + 1:
            return P.blocks[l.block] if l.block >= 0 else None
    return None


def find_mentions(P):
    """Every printed tag, figure/table number and theorem-like reference: linked to its target,
    linked elsewhere, or plain text."""
    vocab = set(P.items_by_tag)
    P.mentions = []
    for pno in range(len(P.doc)):
        ws = P.words[pno]
        for i, w in enumerate(ws):
            t = w[4].strip("()[],.;:")
            targets = []
            parts = re.split(r"[–—-]", t)
            if len(parts) == 2 and all(TAG_WORD.match(p) for p in parts):
                a, b = TAG_WORD.match(parts[0]), TAG_WORD.match(parts[1])
                if a.group(1) == b.group(1) and a.group(2).isdigit() and b.group(2).isdigit():
                    targets = [f"{a.group(1)}{n}" for n in range(int(a.group(2)), int(b.group(2)) + 1)]
            elif TAG_WORD.match(t):
                targets = [t]
            targets = [x for x in targets if x in vocab and P.items_by_tag[x][0].kind == "item"]
            if not targets:
                prev = ws[i - 1][4].lstrip("([{") if i else ""
                if prev in FLOAT_WORDS and re.fullmatch(r"[A-Z]?\d+(\.\d+)*[a-z]?", t):
                    key = f"{FLOAT_WORDS[prev]} {t}"
                    if key in P.float_by_key:
                        targets = [key]
                elif prev in THEOREMS.split("|") and re.fullmatch(r"[A-Z]?\d+(\.\d+)*", t) and f"{prev} {t}" in P.items_by_tag:
                    targets = [f"{prev} {t}"]
                if not targets:
                    continue
            own = owner_of(P, pno, w)
            lk = link_at(P, pno, w) or (link_at(P, pno, ws[i - 1]) if i and not TAG_WORD.match(t) else None)
            for tg in targets:
                tblocks = P.items_by_tag.get(tg) or [P.float_by_key[tg]]
                if own is not None and own in tblocks:
                    head = own.lines[0] if own.lines else None
                    if own.kind == "float" or (head and head.y0 <= (w[1] + w[3]) / 2 <= head.y1 and w[0] < head.x0 + 60) \
                            or tuple(w[:4]) == own.data.get("tag_box"):
                        continue  # the item's own head, its row's tag, or the caption's own number
                if lk is None:
                    status = "plain"
                else:
                    tanchors = {x.data.get("anchor") for x in tblocks}
                    status = "linked" if lk["dest"] in tanchors else "linked-elsewhere"
                    if status == "linked-elsewhere" and tblocks[0].kind == "float":
                        status = "linked" if lk["dest"] in {x.data.get("anchor") for x in tblocks} else status
                ch = chapter_of(P, pno, w[1])
                P.mentions.append(dict(target=tg, page=pno, y=w[1], status=status, owner=own.id if own else "",
                                       chapter=ch["anchor"] if ch else "", link_dest=lk["dest"] if lk else ""))
    P.incoming = defaultdict(list)
    for m in P.mentions:
        P.incoming[m["target"]].append(m)
    by_owner = defaultdict(list)
    for m in P.mentions:
        by_owner[m["owner"]].append(m)
    P.cites_of_block = by_owner


# ----------------------------------------------------------------------------------------------
# Panels: walls, chains, rubric, reference quality, checks
# ----------------------------------------------------------------------------------------------

def incoming_of(P, b):
    """Mentions that refer to this item or float. When two items print the same tag, a link counts
    only for the item it points to; a plain mention is ambiguous and counts for each of them."""
    key = b.data["key"] if b.kind == "float" else b.data["tag"]
    ms = P.incoming.get(key, [])
    if b.kind == "float" or len(P.items_by_tag.get(key, [])) < 2:
        return ms
    a = b.data.get("anchor")
    return [m for m in ms if m["status"] != "linked" or (a and m["link_dest"] == a)]


def is_anchor(b):
    if b.kind == "box" and b.data.get("note"):
        return False
    return b.kind in ANCHOR_KINDS or (b.kind == "para" and b.data.get("runin"))


def walls(P):
    out = []
    for o in P.lvl1:
        if o["part"] != "main":
            continue
        bl = [b for b in P.blocks if b.data.get("chapter") == o["anchor"]]
        runs, cur = [], []
        for b in bl + [None]:
            if b is None or is_anchor(b):
                if cur:
                    lines = sum(x.nlines for x in cur)
                    height = sum(r.height + P.gap_thr for x in cur for _, r in block_rects(P, x))
                    runs.append(dict(lines=lines, pages=round(height / (P.bottom - P.top), 2), first=cur[0].id,
                                     from_label=P.doc[cur[0].page].get_label(), to_label=P.doc[cur[-1].last_page].get_label(),
                                     blocks=len(cur)))
                cur = []
            elif b.kind != "footnotes":
                cur.append(b)
        runs.sort(key=lambda r: -r["pages"])
        out.append(dict(chapter=o["anchor"], number=o["number"], title=o["title"], longest=runs[0] if runs else None,
                        over=[r for r in runs if r["pages"] > 1.0]))
    return out


GAP_RE = r"gap matrix|related work|closest approaches|existing approaches|state of the art"
CORR_RE = r"correct"


def find_table(P, label, pattern):
    """The table with this label, else the first table whose caption matches (never the other key table)."""
    v = P.labels.get(label)
    if v and v.get("anchor") in P.float_by_anchor:
        return P.float_by_anchor[v["anchor"]]
    other = "tab:related" if label == "tab:correctness" else "tab:correctness"
    ov = P.labels.get(other, {}).get("anchor")
    return next((f for f in P.floats if f.data["kind"] == "Table" and f.data["anchor"] != ov
                 and re.search(pattern, f.data["caption"], re.I)
                 and not (label == "tab:related" and re.search(CORR_RE, f.data["caption"], re.I))), None)


def float_has(f, tag):
    return f is not None and any(w[4].strip("()[],.;:") == tag for w in f.data["words"])


def in_role(P, m, roles):
    ch = next((o for o in P.lvl1 if o["anchor"] == m["chapter"]), None)
    return ch is not None and any(r in roles for r in ch.get("roles", []))


def edge(status_list):
    """linked if any mention is linked, plain if only plain ones, missing if none."""
    if not status_list:
        return "missing"
    return "linked" if "linked" in status_list else "plain"


def chains(P):
    corr = find_table(P, "tab:correctness", CORR_RE)
    gap = find_table(P, "tab:related", GAP_RE)
    out = dict(correctness=corr.id if corr else "", correctness_key=corr.data["key"] if corr else "",
               gap=gap.id if gap else "", gap_key=gap.data["key"] if gap else "", guarantees=[], requirements=[],
               contributions=[], rqs=[])
    items = [b for b in P.items if b.kind == "item"]

    def cited_in(b, kinds):
        res = defaultdict(list)
        for m in P.cites_of_block.get(b.id, []):
            tb = P.items_by_tag.get(m["target"])
            if tb and tb[0].kind == "item" and tb[0].data["kind"] in kinds:
                res[m["target"]].append(m["status"])
        return {t: edge(s) for t, s in res.items()}

    for b in items:
        tag, kind = b.data["tag"], b.data["kind"]
        if kind == "guarantees":
            out["guarantees"].append(dict(id=b.id, tag=tag, name=b.data["name"],
                                          assumptions=cited_in(b, {"assumptions"}), adversaries=cited_in(b, {"threats"}),
                                          correctness_row=float_has(corr, tag) if corr else None))
        elif kind == "requirements":
            ev = [m["status"] for m in incoming_of(P, b) if in_role(P, m, {"evaluation"})]
            out["requirements"].append(dict(id=b.id, tag=tag, name=b.data["name"],
                                            gap_row=float_has(gap, tag) if gap else None,
                                            evaluation=edge(ev) if ev else ("table" if float_has(corr, tag) else "missing")))
        elif kind == "contributions":
            ms = [m["status"] for m in incoming_of(P, b) if in_role(P, m, {"conclusion"})]
            st = edge(ms)
            if st == "missing" and b.data["name"]:
                concl = " ".join(w[4].lower() for o in P.lvl1 if "conclusion" in o.get("roles", [])
                                 for pno in range(o["page"], len(P.doc))
                                 for w in P.words[pno] if (chapter_of(P, pno, w[1]) or {}).get("anchor") == o["anchor"])
                words = [w for w in re.findall(r"[a-z][a-z-]{3,}", b.data["name"].lower()) if w not in ("with", "that", "from", "this", "todo")]
                if words and sum(w in concl for w in words) / len(words) >= 0.6:
                    st = "by name (fuzzy)"
            out["contributions"].append(dict(id=b.id, tag=tag, name=b.data["name"], conclusion=st))
        elif kind == "rqlist":
            ev = [m["status"] for m in incoming_of(P, b) if in_role(P, m, {"evaluation", "conclusion"})]
            out["rqs"].append(dict(id=b.id, tag=tag, name=b.data["name"], answered=edge(ev)))
    return out


def ref_quality(P):
    rows = []
    for kind in P.list_order + ["other", "theorem"]:
        its = [b for b in P.items if b.data["kind"] == kind]
        if not its:
            continue
        ms = [m for b in its for m in incoming_of(P, b)]
        rows.append(dict(kind=P.kind_name(kind) if kind != "theorem" else "theorem-like", items=len(its), labelled=sum(1 for b in its if b.data.get("label")),
                         mentions=len(ms), linked=sum(m["status"] == "linked" for m in ms),
                         plain=sum(m["status"] == "plain" for m in ms),
                         elsewhere=sum(m["status"] == "linked-elsewhere" for m in ms)))
    for kind in ("Figure", "Table", "Listing", "Algorithm"):
        fs = [f for f in P.floats if f.data["kind"] == kind]
        if not fs:
            continue
        ms = [m for f in fs for m in P.incoming.get(f.data["key"], [])]
        rows.append(dict(kind=kind.lower(), items=len(fs), labelled=sum(1 for f in fs if f.data["labels"]),
                         mentions=len(ms), linked=sum(m["status"] == "linked" for m in ms),
                         plain=sum(m["status"] == "plain" for m in ms),
                         elsewhere=sum(m["status"] == "linked-elsewhere" for m in ms)))
    targets = [(b.data["tag"], b) for b in P.items] + [(f.data["key"], f) for f in P.floats]
    no_link = [(k, b) for k, b in targets if not any(m["status"] == "linked" for m in incoming_of(P, b))]
    no_mention = [(k, b) for k, b in targets if not incoming_of(P, b)]
    unlinkable = [b for b in P.items if b.kind == "item" and not b.data.get("label")]
    return dict(rows=rows, no_link=[(k, b.id) for k, b in no_link], no_mention=[(k, b.id) for k, b in no_mention],
                unlinkable=[(b.data["tag"], b.id) for b in unlinkable])


def shows(ms):
    """The template text a structure shows, each phrase once."""
    return "template text " + ", ".join(f'"{m}"' for m in dict.fromkeys(ms))


def rubric(P, ch, wl, rq):
    """Criterion -> evidence rows (state, text, link target). The state is detected, placeholder,
    unsure or missing (scripts/review/README.md); it says what the skim found, never whether it is good."""
    ev = defaultdict(list)
    main = [o for o in P.lvl1 if o["part"] == "main"]
    role = defaultdict(list)
    for o in main:
        for r in o["roles"]:
            role[r].append(o)
    size = {r["anchor"]: r for r in outline_rows(P) if r["level"] == 1}
    spots = Counter(b.data.get("chapter") for b in P.blocks + P.row_items if b.data.get("marks"))

    def chap_row(r, what, missing_text):
        """The chapters of a role, with size, citations and the template text they show."""
        os_ = role.get(r, [])
        if not os_:
            return ("missing", missing_text, "")
        parts, n = [], 0
        for o in os_:
            z = size.get(o["anchor"], {})
            parts.append(f"ch. {o['number']} {o['title']}, {z.get('pages', '?')} page{'' if z.get('pages') == 1 else 's'}, {z.get('lines', '?')} text lines, "
                         f"{P.cite_by_chapter[o['anchor']]} citation links")
            n += spots[o["anchor"]]
        t = f"{what}: " + "; ".join(parts) + (f"; template text in {n} place(s)" if n else "")
        return ("placeholder" if n else "detected", t, "h-" + slug(os_[0]["anchor"]))

    def items(kind):
        return [b for b in P.items if b.data["kind"] == kind]

    def tags(bs):
        return ", ".join(b.data["tag"] for b in bs)

    def plural(env):
        n = P.kind_name(env)
        return n[:-1] + "ies" if n.endswith("y") else n + "s"

    def item_row(env, missing_text):
        """A tag list: its items as read, the ones showing template text, and the unsure ones."""
        bs, us = items(env), [u for u in P.unsure if u["kind"] == env]
        if not bs and not us:
            return ("missing", missing_text, "")
        ph = [b for b in bs if b.data["marks"]]
        t = f"{plural(env)}: {tags(bs) or 'none read'}"
        if ph:
            t += "; " + ("all show" if len(ph) == len(bs) > 1 else f"{tags(ph)} {'shows' if len(ph) == 1 else 'show'}") \
                + " " + shows(m for b in ph for m in b.data["marks"])
        if us:
            t += "; unsure (in the .aux, not read from the PDF): " + ", ".join(f"{u['tag']} p. {u['page']}" for u in us)
        st = worst((["detected"] if bs else []) + (["placeholder"] if ph else []) + (["unsure"] if us else []))
        return (st, t, bs[0].id if bs else "notes")

    def float_row(f, what, label, missing_text, extra=""):
        if f:
            ms = f.data["marks"]
            return ("placeholder" if ms else "detected", f"{what}: {f.data['key']}{extra}" + (f"; shows {shows(ms)}" if ms else ""), f.id)
        v = P.labels.get(label) if label else None
        if v:
            return ("unsure", f"{what}: the .aux has {label} on p. {v.get('page', '?')}, but the skim read no captioned float for it", "notes")
        return ("missing", missing_text, "")

    n = P.main_pages
    dev = max(0, 30 - n, n - 35)
    ev["A"].append(("detected", f"main text {n} pages (p. {P.doc[P.main_first].get_label()}–{P.doc[P.main_last].get_label()}); the sheet: 30–35"
                    + (f", {dev} pages outside: about {dev // 3} point(s) off (1 per 3 pages)" if dev else ""), ""))
    lv = Counter(o["level"] for o in P.outline if (chapter_of(P, o["page"], o["y"]) or {}).get("part") == "main")
    ev["A"].append(("detected", f"outline: {lv[1]} chapters, {lv[2]} sections, {lv[3]} subsections, {lv[4]} subsubsections, {lv[5]} run-in heads", "outline"))
    walls_over = [(w, r) for w in wl for r in w["over"]]
    if walls_over:
        big = max(walls_over, key=lambda x: x[1]["pages"])
        ev["A"].append(("detected", f"{len(walls_over)} wall(s) of text over 1 page; longest {big[1]['pages']} pages in ch. {big[0]['number']}", "walls"))
    else:
        ev["A"].append(("detected", "no stretch of plain text over 1 page without an anchor", "walls"))
    if P.broken:
        ev["A"].append(("missing", f"{len(P.broken)} reference(s) print ?? or [?] or link to no target", "refs"))
    if P.placeholders["spots"]:
        ev["A"].append(("placeholder", f"template text visible in {P.placeholders['spots']} place(s); TODO printed {P.placeholders['TODO']}×", "top"))
    tag_ms = [m for m in P.mentions if m["target"] in P.items_by_tag and P.items_by_tag[m["target"]][0].kind == "item"]
    if tag_ms:
        k = sum(m["status"] == "linked" for m in tag_ms)
        ev["A"].append(("detected", f"tag references clickable: {k} of {len(tag_ms)}", "refs"))
    figs = [f for f in P.floats if f.data["kind"] == "Figure" and f.data["part"] == "main"]
    tabs = [f for f in P.floats if f.data["kind"] == "Table" and f.data["part"] == "main"]
    per = Counter((f.data["chapter"], f.data["kind"]) for f in figs + tabs)
    phf = [f for f in figs + tabs if f.data["marks"]]
    ev["B/1"].append((worst((["detected"] if figs or tabs else []) + (["placeholder"] if phf else [])),
                      f"{len(figs)} figures, {len(tabs)} tables in the main text; per chapter: "
                      + "; ".join(f"{o['number']}: {per[(o['anchor'], 'Figure')]}F/{per[(o['anchor'], 'Table')]}T" for o in main)
                      + (f"; template text in {', '.join(f.data['key'] for f in phf)}" if phf else ""), ""))
    intro = [o["anchor"] for o in role.get("intro", [])]
    lead = next((f for f in figs if f.data["chapter"] in intro), None)
    aux_fig = next((lab for lab, v in P.labels.items() if v.get("type") == "figure" and v.get("anchor") in P.names
                    and (chapter_of(P, *P.dest(v["anchor"])) or {}).get("anchor") in intro), None)
    lead_row = float_row(lead, "leading figure", aux_fig, "no figure in the introduction (no leading figure)" if intro
                         else "no leading figure: no chapter has the intro role")
    ev["B/1"].append(lead_row)
    unref = [k for k, i in rq["no_mention"] if k.split(" ")[0] in FLOAT_WORDS.values()]
    if unref:
        ev["B/1"].append(("missing", "floats the text never mentions: " + ", ".join(unref), "refs"))
    ev["B/1"].append(("detected" if P.cites else "missing", f"{len(P.cites)} sources cited ({sum(P.cites.values())} citation links); bibliography {P.bib_entries} entries", ""))
    ev["B/2"].append(chap_row("related", "related work", "no chapter has the related role"))
    if role.get("background"):
        ev["B/2"].append(chap_row("background", "background", ""))
    gapf = find_table(P, "tab:related", GAP_RE)
    ev["B/2"].append(float_row(gapf, "gap matrix", "tab:related", "no gap matrix table"))
    ev["B/2"].append(("detected" if P.bib_entries else "missing", f"bibliography: {P.bib_entries} entries", ""))
    abstract_words = len(P.abstract.split())
    am = marks(P.abstract)
    ev["C"].append((worst((["detected"] if abstract_words else []) + (["placeholder"] if am else [])),
                    f"abstract: {abstract_words} words" + (f"; shows {shows(am)}" if am else ""), "abstract"))
    if intro:
        heads = [b.data["runin"] for b in P.blocks if b.data.get("chapter") in intro and b.data.get("runin")]
        secs = [o["title"] for o in P.outline if o["level"] == 2 and (chapter_of(P, o["page"], o["y"]) or {}).get("anchor") in intro]
        st, t, ref = chap_row("intro", "introduction", "")
        ev["C"].append((st, t + f"; sections {secs or '—'}; run-in heads {heads or '—'}", ref))
    else:
        ev["C"].append(("missing", "no chapter has the intro role", ""))
    ev["C"].append(item_row("rqlist", "no research questions"))
    ev["C"].append(lead_row)
    cs_row = item_row("contributions", "no contribution list (C1, C2, ...)")
    ev["D/1"].append(cs_row)
    ev["D/1"].append(float_row(gapf, "gap matrix", "tab:related", "no gap matrix positioning the contributions"))
    for env in ("guarantees", "assumptions", "threats"):
        ev["D/2"].append(item_row(env, f"no {plural(env)}"))
    thm = [b for b in P.items if b.kind == "theorem"]
    proofs = sum(1 for b in P.blocks if b.kind == "proof")
    if thm or proofs:
        phm = [b for b in thm if b.data["marks"]]
        ev["D/2"].append(("placeholder" if phm else "detected",
                          "theorem-like statements: " + ", ".join(f"{v} {k}" for k, v in Counter(b.data["env"] for b in thm).items())
                          + f"; {proofs} proof{'' if proofs == 1 else 's'}"
                          + (f"; {tags(phm)} {'shows' if len(phm) == 1 else 'show'} {shows(m for b in phm for m in b.data['marks'])}" if phm else ""), ""))
    corr = find_table(P, "tab:correctness", CORR_RE)
    gs = ch["guarantees"]
    ev["D/2"].append(float_row(corr, "correctness table", "tab:correctness", "no correctness table",
                               extra=f", rows for {sum(1 for g in gs if g['correctness_row'])} of {len(gs)} guarantees"))
    ev["E"].append(cs_row)
    ev["E"].append(chap_row("evaluation", "evaluation", "no chapter has the evaluation role"))
    rqs = items("rqlist")
    if rqs:
        k = sum(1 for r in ch["rqs"] if r["answered"] != "missing")
        ev["E"].append(("detected", f"research questions mentioned in the evaluation or conclusion: {k} of {len(rqs)}", "chains"))
    for what, pat in (("scalability", r"scal"), ("robustness", r"robust")):
        fs = [f for f in P.floats if re.search(pat, f.data["caption"], re.I)]
        if fs:
            ph = [f for f in fs if f.data["marks"]]
            ev["E"].append(("placeholder" if ph else "detected", f"{what}: " + ", ".join(f.data["key"] for f in fs)
                            + (f"; {', '.join(f.data['key'] for f in ph)} {'shows' if len(ph) == 1 else 'show'} "
                               f"{shows(m for f in ph for m in f.data['marks'])}" if ph else ""), fs[0].id))
        else:
            ev["E"].append(("missing", f"no figure or table about {what} (by caption)", ""))
    ev["E"].append(item_row("limitations", "no limitation items"))
    cs = items("contributions")
    if cs:
        k = sum(1 for c in ch["contributions"] if c["conclusion"] != "missing")
        ev["E"].append(("detected", f"contributions restated in the conclusion: {k} of {len(cs)}", "chains"))
    return ev


def checks(P):
    """Detected vs declared in the included sources: a large gap means an extraction miss."""
    det = Counter()
    det["figure"] = sum(1 for f in P.floats if f.data["kind"] == "Figure")
    det["table"] = sum(1 for f in P.floats if f.data["kind"] == "Table")
    det["box"] = sum(1 for b in P.boxes if not b.data["note"])
    det["tag item"] = sum(1 for b in P.items if b.kind == "item")
    det["theorem-like"] = sum(1 for b in P.items if b.kind == "theorem")
    rows = []
    for k in ("figure", "table", "box", "tag item", "theorem-like"):
        rows.append(dict(what=k, pdf=det[k], source=P.src_counts.get(k, 0)))
    # the .aux inventory: every tag-list label read from the PDF, or unsure
    rows.append(dict(what="tag-list label in the .aux", pdf=len(P.inventory) - len(P.unsure), source=len(P.inventory)))
    unclassified = Counter()
    for pno, ls in P.lines.items():
        for l in ls:
            ch = chapter_of(P, pno, l.y0)
            if (not l.role or l.role == "heading") and l.block < 0 and ch and ch["part"] in ("main", "appendix", "abstract"):
                unclassified[pno] += 1
    return dict(rows=rows, unsure=P.unsure, mismatches=[r for r in rows if r["pdf"] != r["source"]],
                unclassified=sum(unclassified.values()),
                unclassified_pages=sorted(unclassified), margin=sum(1 for ls in P.lines.values() for l in ls if l.role == "margin"))


# ----------------------------------------------------------------------------------------------
# build
# ----------------------------------------------------------------------------------------------

def analyse(P):
    read_lines(P)
    find_floats(P)
    find_boxes(P)
    find_footnotes(P)
    place_outline(P)
    build_blocks(P)
    item_ids(P)
    P.block_by_id = {b.id: b for b in P.blocks + P.row_items}
    read_links(P)
    find_mentions(P)
    ab = next((o for o in P.lvl1 if o["part"] == "abstract"), None)
    kv = next((o for o in P.lvl1 if o["part"] == "kivonat"), None)
    P.abstract = " ".join(b.text() for b in P.blocks if ab and b.data["chapter"] == ab["anchor"] and b.kind != "heading")
    P.kivonat_lines = sum(b.nlines for b in P.blocks if kv and b.data["chapter"] == kv["anchor"] and b.kind != "heading")
    P.title = norm(P.doc.metadata.get("title") or "") or P.name
    # template text on every structure a reader sees (items got theirs in item_ids); a todo note
    # printed by a draft build is template text by itself
    for b in P.blocks:
        if b.kind in ("item", "theorem"):
            continue
        if b.kind == "float":
            b.data["marks"] = marks(b.data["caption"] + " " + " ".join(w[4] for w in b.data["words"]))
        elif b.kind == "heading":
            b.data["marks"] = marks(b.data.get("title", ""))
        elif b.kind == "box":
            b.data["marks"] = marks(b.data["title"] + " " + b.data["text"]) or (["todo note"] if b.data["note"] else [])
        else:
            b.data["marks"] = marks(b.text())
    marked = {b.id for b in P.blocks if b.data["marks"]}
    spots = [b.kind for b in P.blocks if b.data["marks"]] \
        + [b.kind for b in P.row_items if b.data["marks"] and b.data["host"] not in marked]   # a row of a marked table is that table's
    # outside the blocks: front and back matter (the AI declaration), footnotes and margin notes, one per
    # page each; a draft build's margin notes are todo notes whatever they say
    spots += [role for pno, role in sorted({(l.page, l.role) for ls in P.lines.values() for l in ls
                                           if l.role in ("front", "back", "footnote", "margin")
                                           and (marks(l.text) or (l.role == "margin" and P.stem != "reviewer"))})]
    P.placeholders = dict(spots=len(spots), by_kind=Counter(spots),
                          TODO=sum(1 for ws in P.words.values() for w in ws if re.search(r"\bTODO\b", w[4])))
    P.walls = walls(P)
    P.chains = chains(P)
    P.refq = ref_quality(P)
    P.rubric = rubric(P, P.chains, P.walls, P.refq)
    P.checks = checks(P)


def render_assets(P, out, debug):
    a = out / "assets"
    if a.exists():
        shutil.rmtree(a)
    a.mkdir(parents=True)
    for f in P.floats:
        dpi = 110 if f.data["kind"] == "Figure" else 60
        pix = P.doc[f.page].get_pixmap(clip=pymupdf.Rect(f.data["rect"]), dpi=dpi)
        f.data["img"] = f"assets/{f.id}.png"
        pix.save(out / f.data["img"])
    P.thumbs = []
    for pno, page in enumerate(P.doc):
        p = f"assets/page-{pno + 1:03d}.png"
        page.get_pixmap(dpi=28).save(out / p)
        P.thumbs.append(p)
    if debug:
        dd = out / "debug"
        if dd.exists():
            shutil.rmtree(dd)
        dd.mkdir()
        doc = pymupdf.open(P.pdf_path)
        colors = dict(float=(0, 0, 1), box=(0.22, 0.29, 0.67), item=(0.33, 0.43, 0.48), theorem=(0.43, 0.3, 0.25), heading=(0.6, 0, 0.6),
                      para=(0.6, 0.6, 0.6), math=(0.4, 0.4, 0.9), listing=(0.5, 0.3, 0), list=(0.9, 0, 0.5), proof=(0.3, 0.3, 0.3))
        for b in P.blocks:
            for pno, r in block_rects(P, b):
                doc[pno].draw_rect(r, color=colors.get(b.kind, (1, 0, 0)), width=0.8)
                doc[pno].insert_text((r.x0 + 1, r.y0 + 6), f"{b.kind}{'/' + b.data.get('tag', '') if b.data.get('tag') else ''}"
                                     f"{' runin' if b.data.get('runin') else ''} {b.nlines}", fontsize=5, color=(1, 0, 0))
        for pno, ls in P.lines.items():
            for l in ls:
                if l.block < 0 and l.role in ("", "heading"):
                    doc[pno].draw_rect(pymupdf.Rect(l.rect()), color=(1, 0, 0), width=1.5)
        for pno in range(len(doc)):
            doc[pno].get_pixmap(dpi=60).save(dd / f"page-{pno + 1:03d}.png")


def block_rects(P, b):
    if b.kind == "float":
        return [(b.page, pymupdf.Rect(b.data["rect"]))]
    if b.kind == "box":
        return [(pno, pymupdf.Rect(r)) for pno, r in b.data["rects"]]
    out = defaultdict(lambda: pymupdf.Rect())
    for l in b.lines:
        out[l.page] |= pymupdf.Rect(l.rect())
    return list(out.items())


def outline_rows(P):
    """Outline entries with length in pages and in text lines (up to the next entry at the same or a higher level)."""
    rows = []
    ents = [o for o in P.outline if o["level"] <= 4 or o["level"] == 5]
    for i, o in enumerate(ents):
        nxt = next((x for x in ents[i + 1:] if x["level"] <= o["level"]), None)
        end = (nxt["page"], nxt["y"]) if nxt else (len(P.doc) - 1, P.bottom)
        pages = round(P.pos(*end) - P.pos(o["page"], o["y"]), 1)
        lines = sum(1 for b in P.blocks if b.kind != "float" for l in b.lines
                    if (o["page"], o["y"]) <= (l.page, l.y0) < end)
        ch = chapter_of(P, o["page"], o["y"])
        rows.append(dict(o, pages=pages, lines=lines, part=ch["part"] if ch else "", page_label=P.doc[o["page"]].get_label()))
    return rows


KIND_LABEL = {"para": "¶", "math": "math", "listing": "listing", "list": "list", "proof": "proof", "rows": "table rows"}
KIND_NOUN = {"para": ("paragraph", "paragraphs"), "float": ("figure or table", "figures and tables"),
             "item": ("tagged item", "tagged items"), "theorem": ("theorem-like", "theorem-likes"), "heading": ("heading", "headings"),
             "box": ("box", "boxes"), "list": ("list", "lists"), "math": ("display math", "display math"),
             "listing": ("listing", "listings"), "proof": ("proof", "proofs"), "rows": ("table rows", "table rows"),
             "front": ("front-matter page", "front-matter pages"), "back": ("back-matter page", "back-matter pages"),
             "footnote": ("page of footnotes", "pages of footnotes"), "margin": ("page of margin notes", "pages of margin notes")}


def chip_list(P, b):
    ms = P.cites_of_block.get(b.id, [])
    seen = {}
    for m in ms:
        if m["target"] not in seen or m["status"] == "linked":
            seen[m["target"]] = m["status"]
    return seen


def target_id(P, key):
    if key in P.items_by_tag:
        return P.items_by_tag[key][0].id
    f = P.float_by_key.get(key)
    return f.id if f else ""


def summary(P):
    kinds = Counter(b.data["kind"] for b in P.items)
    return {
        "PDF pages": len(P.doc), "main text pages": P.main_pages, "figures": sum(f.data["kind"] == "Figure" for f in P.floats),
        "tables": sum(f.data["kind"] == "Table" for f in P.floats), "boxes": sum(1 for b in P.boxes if not b.data["note"]),
        "placeholders visible": P.placeholders["spots"], "TODO printed": P.placeholders["TODO"],
        "tagged items": sum(1 for b in P.items if b.kind == "item"), "tagged items unsure": len(P.unsure),
        "theorem-likes": kinds.get("theorem", 0),
        "paragraphs": sum(b.kind == "para" for b in P.blocks if b.data["part"] == "main"),
        "footnotes": sum(P.footnotes.values()), "citation links": sum(P.cites.values()), "bibliography entries": P.bib_entries,
    }


def summary_lines(P):
    """The summary as text: the placeholder count with where a reader sees them."""
    out = []
    for k, v in summary(P).items():
        if k == "placeholders visible" and v:
            v = f"{v} ({', '.join(f'{n} {KIND_NOUN.get(k_, (k_, k_))[n != 1]}' for k_, n in P.placeholders['by_kind'].most_common())})"
        out.append((k, v))
    return out


def metrics(P):
    tag_ms = [m for m in P.mentions if m["target"] in P.items_by_tag and P.items_by_tag[m["target"]][0].kind == "item"]
    wl = [r for w in P.walls for r in w["over"]]
    ch = P.chains
    m = dict(summary(P))
    m.update({
        "tag references clickable %": round(100 * sum(x["status"] == "linked" for x in tag_ms) / len(tag_ms)) if tag_ms else 0,
        "unlabelled (unlinkable) items": len(P.refq["unlinkable"]),
        "targets nothing links to": len(P.refq["no_link"]),
        "walls over 1 page": len(wl),
        "longest wall (pages)": max([w["longest"]["pages"] for w in P.walls if w["longest"]] or [0]),
        "guarantees with a correctness row": sum(1 for g in ch["guarantees"] if g["correctness_row"]),
        "requirements with gap row": sum(1 for r in ch["requirements"] if r["gap_row"]),
        "requirements evaluated": sum(1 for r in ch["requirements"] if r["evaluation"] != "missing"),
        "contributions in conclusion": sum(1 for c in ch["contributions"] if c["conclusion"] != "missing"),
        "criteria without detected evidence": sum(1 for c in P.criteria if not any(s == "detected" for s, _, _ in P.rubric.get(c["id"], []))),
        "broken references": len(P.broken), "unclassified lines": P.checks["unclassified"],
    })
    return m


# Direction of each metric for compare: +1 higher is better, -1 lower is better, 0 neutral.
METRIC_DIR = {"tag references clickable %": 1, "unlabelled (unlinkable) items": -1, "targets nothing links to": -1,
              "walls over 1 page": -1, "longest wall (pages)": -1, "guarantees with a correctness row": 1,
              "requirements with gap row": 1, "requirements evaluated": 1, "contributions in conclusion": 1,
              "criteria without detected evidence": -1, "broken references": -1, "placeholders visible": -1,
              "TODO printed": -1, "tagged items unsure": -1, "unclassified lines": -1, "figures": 1, "tables": 1,
              "boxes": 1, "tagged items": 1}


def status_word(s):
    return {"linked": "linked", "plain": "plain text", "linked-elsewhere": "linked elsewhere", "missing": "MISSING",
            "table": "via correctness table", "by name (fuzzy)": "by name (fuzzy)"}.get(s, str(s))


def ph_tag(b):
    """The marker a structure showing template text gets in the view."""
    ms = b.data.get("marks")
    return f" [placeholder: {', '.join(chr(34) + m + chr(34) for m in dict.fromkeys(ms))}]" if ms else ""


def carried_by(P, cid):
    """The chapters that carry a criterion, with their roles, as the lint's chapter_roles assign them."""
    if cid == "A":
        return ["the whole paper"]
    return [f"{o['number']} {o['title']} ({', '.join(r for r in o['roles'] if cid in (P.chapter_roles.get(r, {}).get('criteria') or []))})"
            for o in P.lvl1 if cid in o.get("criteria", [])]


def placed_items(P):
    """Block id -> the tagged items read inside it (table rows, items in a float or box) or, for one
    read outside any, right after the block it follows."""
    after = defaultdict(list)
    for it in P.row_items:
        host = it.data["host"]
        if not host:
            prev = [b for b in P.blocks if (b.page, b.y0) <= (it.page, it.y0)]
            host = prev[-1].id if prev else ""
        after[host].append(it)
    return after


def write_md(P, out):
    buf = []
    w = buf.append
    w(f"# Skim view: {P.title}\n")
    w(f"Paper `{P.name}`, built from `{P.stem}.tex`"
      + (" (no reviewer.tex: this is the draft build, todos included)" if P.stem != "reviewer" else "")
      + f"; {len(P.doc)} PDF pages; main text {P.main_pages} pages "
        f"(p. {P.doc[P.main_first].get_label()}–{P.doc[P.main_last].get_label()}).\n")
    w("This is what a reviewer sees when skimming: headings, figures, tables, tagged items and coloured boxes "
      "verbatim; every paragraph only as `¶ N lines`, display math, listings and plain lists only as counts. "
      "`[cites: ...]` after a paragraph lists the tags it refers to (↗ = clickable link, plain = hand-typed). "
      "`[placeholder: ...]` marks a structure that shows template text, with the text it shows. "
      "Evidence is detected, placeholder, unsure (declared in the sources, not read from the PDF) or missing; "
      "detected says only that the structure is there, not that it is good.\n")
    w("## Summary\n")
    for k, v in summary_lines(P):
        w(f"- {k}: {v}")
    w("")
    w("## Extraction notes\n")
    w(extraction_notes_md(P))
    w("## Review criteria (scoring sheet)\n")
    w(f"From the guide (`{GUIDE}`, the review sheet section) and the sheet PDF (`{P.sheet.name if P.sheet else 'not found'}`). "
      f"Chapters carry criteria by their role, as the lint assigns them ({'`' + P.lint_source + '`' if P.chapter_roles else 'no lint export'}).\n")
    for c in P.criteria:
        w(f"### {c['id']}. {c['name']} (0–{c['max']})\n")
        w(f"Top score, in the sheet's words: {c['top']}\n")
        for n in c["notes"]:
            w(f"> {n}")
        for b in c["bands"]:
            w(f"- {b[0]}: {b[1]}")
        w(f"\nCarried by: {'; '.join(carried_by(P, c['id'])) or '—'}\n")
    if P.textual:
        w(f"The sheet also asks for a written review ({P.textual[0].split('(')[0].strip()}): " + "; ".join(P.textual[1:]) + ".\n")
    w("## Rubric map: evidence in this skim\n")
    for c in P.criteria:
        evs = P.rubric.get(c["id"], [])
        empty = not any(s == "detected" for s, _, _ in evs)
        w(f"### {c['id']}{' (nothing detected without template text)' if empty else ''}\n")
        for s, t, ref in evs:
            w(f"- [{s}] {t}")
        w("")
    w("## Outline\n")
    w("| | heading | page | pages | lines |\n|---|---|---|---|---|")
    for r in outline_rows(P):
        if r["level"] > 4:
            continue
        ind = "&nbsp;&nbsp;" * (r["level"] - 1)
        w(f"| {r['part']} | {ind}{r['number']} {r['title']}{' [placeholder]' if marks(r['title']) else ''} | {r['page_label']} | {r['pages']} | {r['lines']} |")
    w("")
    w("## The paper as skimmed\n")
    w("### Abstract\n")
    w(P.abstract or "(no abstract found)")
    w(f"\nKivonat (Hungarian abstract), {P.kivonat_lines} lines.\n")
    after = placed_items(P)
    for b in P.blocks:
        if b.data["part"] in ("front", "abstract", "kivonat", "back"):
            continue
        w(md_block(P, b))
        for it in after.get(b.id, []):
            w(md_block(P, it))
    back = [o for o in P.lvl1 if o["part"] == "back"]
    if back:
        w("\n### Back matter\n")
        for o in back:
            nx = next((x for x in P.lvl1 if (x["page"], x["y"]) > (o["page"], o["y"])), None)
            pages = (nx["page"] if nx else len(P.doc)) - o["page"]
            extra = f", {P.bib_entries} entries" if re.search(r"bibliograph|reference|irodalom", o["title"], re.I) else ""
            w(f"- {o['title']}: {pages} page(s){extra}, p. {P.doc[o['page']].get_label()}")
    w("\n## Walls of text\n")
    w("Per chapter, the longest stretch of plain paragraphs (and math, lists, listings) with no anchor: no heading, "
      "run-in head, figure, table, box, tagged item or theorem-like. Over 1 page is flagged.\n")
    w("| chapter | longest stretch | lines | pages | over 1 page |\n|---|---|---|---|---|")
    for x in P.walls:
        lg = x["longest"]
        w(f"| {x['number']} {x['title']} | " + (f"p. {lg['from_label']}–{lg['to_label']} | {lg['lines']} | {lg['pages']} | "
                                                  + ("**" + str(len(x['over'])) + "**" if x["over"] else "0") if lg else "— | | | ") + " |")
    w("\n## Argument chains\n")
    ch = P.chains
    w(f"Correctness table: {ch['correctness_key'] or 'NONE'}; gap matrix: {ch['gap_key'] or 'NONE'}. "
      "Edges: linked = clickable reference, plain text = hand-typed tag, MISSING = no mention.\n")
    if ch["guarantees"]:
        w("**Guarantees → assumptions / adversaries cited → correctness row**\n")
        for g in ch["guarantees"]:
            a = ", ".join(f"{t} ({status_word(s)})" for t, s in g["assumptions"].items()) or "none cited"
            v = ", ".join(f"{t} ({status_word(s)})" for t, s in g["adversaries"].items()) or "none cited"
            row = "no table" if g["correctness_row"] is None else ("row" if g["correctness_row"] else "NO ROW")
            w(f"- {g['tag']} {g['name'] or '(no short name)'}: assumptions {a}; adversaries {v}; correctness: {row}")
        w("")
    else:
        w("No guarantee items read.\n")
    if ch["requirements"]:
        w("**Requirements → gap-matrix row → evaluation**\n")
        for r in ch["requirements"]:
            gr = "no gap matrix" if r["gap_row"] is None else ("row" if r["gap_row"] else "NO ROW")
            w(f"- {r['tag']} {r['name'] or '(no short name)'}: gap matrix {gr}; evaluation {status_word(r['evaluation'])}")
        w("")
    if ch["contributions"]:
        w("**Contributions → restated in the conclusion**\n")
        for c in ch["contributions"]:
            w(f"- {c['tag']} {c['name'] or '(no short name)'}: {status_word(c['conclusion'])}")
        w("")
    if ch["rqs"]:
        w("**Research questions → mentioned in the evaluation or conclusion**\n")
        for r in ch["rqs"]:
            w(f"- {r['tag']} {r['name'] or '(no short name)'}: {status_word(r['answered'])}")
        w("")
    w("## Reference quality\n")
    w("| target kind | items | with \\label | mentions | linked | plain text | linked elsewhere |\n|---|---|---|---|---|---|---|")
    for r in P.refq["rows"]:
        w(f"| {r['kind']} | {r['items']} | {r['labelled']} | {r['mentions']} | {r['linked']} | {r['plain']} | {r['elsewhere']} |")
    w("")
    if P.refq["unlinkable"]:
        w("Hand-typed items without a \\label, which cannot be linked: " + ", ".join(t for t, _ in P.refq["unlinkable"]) + "\n")
    if P.refq["no_link"]:
        w("Nothing links to: " + ", ".join(t for t, _ in P.refq["no_link"]) + "\n")
    if P.refq["no_mention"]:
        w("Nothing even mentions: " + ", ".join(t for t, _ in P.refq["no_mention"]) + "\n")
    if P.broken:
        w("Broken references: " + "; ".join(f"p. {P.doc[x['page']].get_label()} {x['text']} ({x['why']})" for x in P.broken[:30]) + "\n")
    (out / "skim.md").write_text("\n".join(buf) + "\n")


def extraction_notes_md(P):
    """Where this view may be wrong, first: unsure items and counts that differ from the sources."""
    c = P.checks
    s = []
    if c["unsure"]:
        s.append(f"Unsure: {len(c['unsure'])} tagged item(s) the .aux declares but the skim could not read from the PDF. "
                 "This is an extraction gap, not missing text; look at the page.\n")
        for u in c["unsure"]:
            s.append(f"- [unsure] {u['tag']} ({P.kind_name(u['kind'])}, label `{u['label']}`), p. {u['page']}")
        s.append("")
    if c["mismatches"]:
        s.append("Counts that differ between the PDF and the sources: "
                 + "; ".join(f"{r['what']} {r['pdf']} in the PDF, {r['source']} in the sources" for r in c["mismatches"]) + ".\n")
    s += ["| detected in the PDF | count | declared in the included sources |", "|---|---|---|"]
    for r in c["rows"]:
        s.append(f"| {r['what']} | {r['pdf']} | {r['source']} |")
    s.append("")
    s.append(f"- lines not assigned to any block: {c['unclassified']}" + (f" (pages {', '.join(str(p + 1) for p in c['unclassified_pages'][:15])})" if c["unclassified"] else ""))
    if c["margin"]:
        s.append(f"- margin-note lines ignored: {c['margin']}")
    for n in P.notes:
        s.append(f"- {n}")
    return "\n".join(s) + "\n"


def item_where(P, b):
    """Where a tagged item was read: page, and the table or box it sits in."""
    pl = P.doc[b.page].get_label()
    host = P.block_by_id.get(b.data.get("host", ""))
    if b.data.get("read") == "row" and host is not None and host.kind == "float":
        return f"row of {host.data['key']}, p. {pl}"
    if host is not None:
        return f"in {host.data['key'] if host.kind == 'float' else 'box ' + repr(host.data['title'])}, p. {pl}"
    return f"p. {pl}"


def md_block(P, b):
    k = b.kind
    pl = P.doc[b.page].get_label()
    if k == "heading":
        lvl = b.data.get("level", 4)
        return f"\n{'#' * min(6, lvl + 2)} {b.data.get('number', '')} {b.data.get('title', '')}  (p. {pl}){ph_tag(b)}\n"
    if k == "float":
        d = b.data
        refs = Counter(m["status"] for m in incoming_of(P, b))
        rs = f"referenced {refs['linked']}× linked, {refs['plain']}× plain" if refs else "NOT referenced in the text"
        img = f"![{d['key']}]({d['img']})" if d.get("img") else ""
        return f"\n{img}\n**{d['key']}** (p. {pl}, {rs}){ph_tag(b)}: {d['caption'][len(d['key']):].lstrip(':. ')}\n"
    if k == "box" and b.data["note"]:
        return f"[todo note, p. {pl}: {b.data['text']}]"
    if k == "box":
        d = b.data
        body = d["text"]
        return f"\n> **[box] {d['title']}** (p. {pl}{'–' + P.doc[b.last_page].get_label() if b.last_page != b.page else ''}){ph_tag(b)}\n> {body}\n"
    if k in ("item", "theorem"):
        d = b.data
        refs = Counter(m["status"] for m in incoming_of(P, b))
        flag = "" if k == "theorem" else (f" {{label `{d['label']}`}}" if d.get("label") else " {no \\label: cannot be linked}")
        rs = f"{refs['linked']} linked / {refs['plain']} plain references in" if refs else "nothing refers to it"
        cites = chip_list(P, b)
        cs = (" [cites: " + ", ".join(f"{t}{'↗' if s == 'linked' else ' plain'}" for t, s in cites.items()) + "]") if cites else ""
        nm = f" **{d['name']}**" if d["name"] else " (no short name)"
        kind = d["env"].lower() if k == "theorem" else P.kind_name(d["kind"])
        return f"\n- **{d['tag']}**{nm} ({kind}, {item_where(P, b)}{flag}; {rs}){cs}{ph_tag(b)}\n  {d['text']}"
    cites = chip_list(P, b)
    cs = (" [cites: " + ", ".join(f"{t}{'↗' if s == 'linked' else ' plain'}" for t, s in cites.items()) + "]") if cites else ""
    if k == "para":
        head = f"**{b.data['runin']}** " if b.data.get("runin") else ""
        return f"{head}¶ {b.nlines} lines{cs}{ph_tag(b)}"
    if k == "list":
        lab = (": " + " · ".join(b.data["labels"])) if b.data["labels"] else ""
        return f"list, {b.data['items']} items{lab}{cs}{ph_tag(b)}"
    return f"{KIND_LABEL.get(k, k)}, {b.nlines} lines{cs}{ph_tag(b)}"


CSS = """
body{font:14px/1.45 system-ui,sans-serif;margin:0;color:#222;background:#fafafa}
nav{position:fixed;top:0;left:0;bottom:0;width:230px;overflow:auto;background:#fff;border-right:1px solid #ddd;padding:8px;font-size:12px}
nav a{display:block;color:#333;text-decoration:none;padding:1px 0}nav .l2{padding-left:10px}nav .l3{padding-left:20px;color:#777}
main{margin-left:250px;max-width:980px;padding:10px 20px}
h1{font-size:20px}h2{border-bottom:2px solid #333;margin-top:28px}
a{color:#1a3e8c}
.meta{color:#555}.chips span{display:inline-block;background:#eee;border-radius:8px;padding:1px 7px;margin:2px;font-size:12px}
.strip{display:flex;overflow-x:auto;gap:4px;padding:6px;background:#eee}
.pg{position:relative;flex:0 0 auto;width:96px}.pg img{width:96px;display:block;border:1px solid #bbb;background:#fff}
.pg .ov{position:absolute;border:1.5px solid;box-sizing:border-box}.pg .n{font-size:10px;text-align:center}
.pg.main img{border-color:#333}
.ov.float,.ov.rows{border-color:#1565c0}.ov.box{border-color:#3949ab;background:rgba(57,73,171,.12)}.ov.item,.ov.theorem{border-color:#546e7a}
.ov.heading{border-color:#424242;background:rgba(66,66,66,.15)}.ov.ph{border-color:#e65100;background:rgba(230,81,0,.35)}
.blk{margin:3px 0}.para,.cnt{color:#888;font-size:12px}.runin{color:#222;font-weight:600}
.cite{font-size:11px;color:#999}.cite a{color:#999}.cite .plain{color:#c77}
.hd{margin-top:18px}.hd .pl{color:#888;font-size:12px;font-weight:normal}
.crit{font-size:11px;background:#e3f2fd;border-radius:6px;padding:0 5px;margin-left:6px;font-weight:normal}
.item{background:#f5f7f8;border-left:4px solid #546e7a;padding:4px 8px;margin:6px 0}
.item .tag{font-weight:700}.item .meta{font-size:11px}
.theorem{background:#f7f3f1;border-left:4px solid #6d4c41;padding:4px 8px;margin:6px 0}
.box{background:#eef0fa;border-left:4px solid #3949ab;padding:6px 10px;margin:8px 0}
.float{background:#fff;border:1px solid #ddd;padding:6px;margin:8px 0}.float img{max-width:100%}
.float.Table img,.float.Algorithm img,.float.Listing img{max-width:340px}
.ph{outline:2px dashed #e65100;outline-offset:1px}
.badge{display:inline-block;font-size:11px;border-radius:6px;padding:0 5px;margin-left:4px;font-weight:600}
.detected{color:#444}.placeholder{color:#e65100;font-weight:600}.unsure{color:#6a1b9a;font-weight:600}
.missing,.bad{color:#c62828;font-weight:600}.warn{color:#b26a00}
.badge.placeholder{background:#fff3e0;border:1px solid #e65100}.badge.unsure{background:#f3e5f5;border:1px solid #6a1b9a}
table.t{border-collapse:collapse;font-size:12px;margin:6px 0}table.t td,table.t th{border:1px solid #ccc;padding:2px 6px;vertical-align:top}
.e-linked{color:#333}.e-plain{color:#e65100}.e-missing,.e-NO{color:#c62828;font-weight:600}
.empty{background:#ffebee}
.notes{border:1px solid #ccc;background:#fff;padding:4px 12px;margin:8px 0}
"""


def h_ph(b):
    ms = b.data.get("marks")
    if not ms:
        return ""
    return f"<span class='badge placeholder' title='shows template text'>placeholder: {esc(', '.join(dict.fromkeys(ms)))}</span>"


def h_cites(P, b):
    cites = chip_list(P, b)
    if not cites:
        return ""
    parts = []
    for t, s in cites.items():
        tid = target_id(P, t)
        cls = "" if s == "linked" else " class='plain'"
        parts.append(f"<a href='#{esc(tid)}'{cls} title='{esc(status_word(s))}'>{esc(t)}{'↗' if s == 'linked' else ''}</a>")
    return " <span class='cite'>→ " + " ".join(parts) + "</span>"


def h_block(P, b):
    k, d = b.kind, b.data
    pl = P.doc[b.page].get_label()
    ph = " ph" if d.get("marks") else ""
    if k == "heading":
        lvl = min(6, d.get("level", 4) + 2)
        ch = next((o for o in P.lvl1 if o["anchor"] == d.get("anchor")), None)
        crit = "".join(f"<span class='crit'>{esc(c)}</span>" for c in (ch or {}).get("criteria", []))
        return (f"<h{lvl} class='hd' id='{esc(b.id)}'>{esc(d.get('number', ''))} {esc(d.get('title', ''))} "
                f"<span class='pl'>p. {esc(pl)}</span>{crit}{h_ph(b)}</h{lvl}>")
    if k == "float":
        refs = Counter(m["status"] for m in incoming_of(P, b))
        rs = (f"{refs['linked']}× linked, <span class='{'warn' if refs['plain'] else ''}'>{refs['plain']}× plain</span>" if refs
              else "<span class='bad'>not referenced</span>")
        cap = esc(d["caption"][len(d["key"]):].lstrip(":. "))
        return (f"<div class='float {esc(d['kind'])}{ph}' id='{esc(b.id)}'><img src='{esc(d['img'])}' loading='lazy'><div><b>{esc(d['key'])}</b> "
                f"<span class='meta'>(p. {esc(pl)}; {rs})</span>{h_ph(b)}: {cap}</div></div>")
    if k == "box" and d["note"]:
        return f"<div class='blk cnt{ph}' id='{esc(b.id)}'>[todo note, p. {esc(pl)}: {esc(d['text'])}]{h_ph(b)}</div>"
    if k == "box":
        return f"<div class='box{ph}' id='{esc(b.id)}'><b>{esc(d['title'])}</b> <span class='meta'>p. {esc(pl)}</span>{h_ph(b)}<br>{esc(d['text'])}</div>"
    if k in ("item", "theorem"):
        refs = Counter(m["status"] for m in incoming_of(P, b))
        lab = "" if k == "theorem" else (f"label <code>{esc(d['label'])}</code>" if d.get("label") else "<span class='warn'>no \\label: cannot be linked</span>")
        rs = (f"{refs['linked']} linked / <span class='{'warn' if refs['plain'] else ''}'>{refs['plain']} plain</span> refs in" if refs
              else "<span class='bad'>nothing refers to it</span>")
        kind = d["env"].lower() if k == "theorem" else P.kind_name(d["kind"])
        return (f"<div class='{k}{ph}' id='{esc(b.id)}'><span class='tag'>{esc(d['tag'])}</span> <b>{esc(d['name'])}</b> "
                f"<span class='meta'>({esc(kind)}, {esc(item_where(P, b))}; {lab}{'; ' if lab else ''}{rs})</span>{h_cites(P, b)}{h_ph(b)}<br>{esc(d['text'])}</div>")
    if k == "para":
        head = f"<span class='runin'>{esc(d['runin'])}</span> " if d.get("runin") else ""
        return f"<div class='blk para{ph}' id='{esc(b.id)}'>{head}¶ {b.nlines} lines{h_cites(P, b)}{h_ph(b)}</div>"
    if k == "list":
        lab = (": " + " · ".join(esc(x) for x in d["labels"])) if d["labels"] else ""
        return f"<div class='blk cnt{ph}' id='{esc(b.id)}'>list, {d['items']} items{lab}{h_cites(P, b)}{h_ph(b)}</div>"
    return f"<div class='blk cnt{ph}' id='{esc(b.id)}'>{esc(KIND_LABEL.get(k, k))}, {b.nlines} lines{h_cites(P, b)}{h_ph(b)}</div>"


def h_notes(P):
    """The extraction notes, unsure items and differing counts first."""
    c = P.checks
    buf = ["<div class='notes'>"]
    if c["unsure"]:
        buf.append(f"<p><span class='badge unsure'>unsure</span> {len(c['unsure'])} tagged item(s) the .aux declares but the skim could not "
                   "read from the PDF. This is an extraction gap, not missing text; look at the page.</p><ul>")
        buf += [f"<li><span class='unsure'>{esc(u['tag'])}</span> ({esc(P.kind_name(u['kind']))}, label <code>{esc(u['label'])}</code>), p. {esc(u['page'])}</li>"
                for u in c["unsure"]]
        buf.append("</ul>")
    if c["mismatches"]:
        buf.append("<p class='warn'>Counts that differ between the PDF and the sources: "
                   + esc("; ".join(f"{r['what']} {r['pdf']} in the PDF, {r['source']} in the sources" for r in c["mismatches"])) + ".</p>")
    buf.append("<table class='t'><tr><th>detected in the PDF</th><th>count</th><th>declared in the included sources</th></tr>")
    for r in c["rows"]:
        bad = " class='warn'" if r["pdf"] != r["source"] else ""
        buf.append(f"<tr{bad}><td>{esc(r['what'])}</td><td>{r['pdf']}</td><td>{r['source']}</td></tr>")
    buf.append("</table><ul>")
    buf.append(f"<li>lines not assigned to any block: {c['unclassified']}</li>")
    if c["margin"]:
        buf.append(f"<li>margin-note lines ignored: {c['margin']}</li>")
    for n in P.notes:
        buf.append(f"<li>{esc(n)}</li>")
    buf.append("</ul></div>")
    return "".join(buf)


def write_html(P, out):
    buf = []
    w = buf.append
    w(f"<!doctype html><html><head><meta charset='utf-8'><title>Skim: {esc(P.name)}</title><style>{CSS}</style></head><body>")
    w("<nav><b>" + esc(P.name) + "</b>")
    for sec, lab in (("top", "Summary"), ("notes", "Extraction notes"), ("pages", "Page grid"), ("rubric", "Rubric map"),
                     ("outline", "Outline"), ("abstract", "Skim"), ("walls", "Walls of text"), ("chains", "Argument chains"),
                     ("refs", "Reference quality")):
        w(f"<a href='#{sec}'>{lab}</a>")
    w("<hr>")
    for b in P.blocks:
        if b.kind == "heading" and b.data["part"] in ("main", "appendix") and b.data.get("level", 9) <= 3:
            w(f"<a class='l{b.data['level']}' href='#{esc(b.id)}'>{esc(b.data.get('number', ''))} {esc(b.data.get('title', ''))}</a>")
    w("</nav><main>")
    w(f"<h1 id='top'>{esc(P.title)}</h1>")
    w(f"<p class='meta'>{esc(P.name)} · built from <code>{esc(P.stem)}.tex</code>"
      + (" <b class='warn'>(no reviewer.tex: draft build, todos included)</b>" if P.stem != "reviewer" else "")
      + f" · {len(P.doc)} PDF pages · main text <b>{P.main_pages}</b> pages (p. {esc(P.doc[P.main_first].get_label())}–{esc(P.doc[P.main_last].get_label())})</p>")
    w("<div class='chips'>" + "".join(f"<span>{esc(k)}: <b>{esc(v)}</b></span>" for k, v in summary_lines(P)) + "</div>")
    w("<p class='meta'>Evidence is <span class='detected'>detected</span> (the structure is there; this says nothing about whether it is good), "
      "<span class='placeholder'>placeholder</span> (it shows template text), <span class='unsure'>unsure</span> (the sources declare it, "
      "the skim could not read it from the PDF) or <span class='missing'>missing</span>. A dashed orange frame marks a structure that shows template text.</p>")
    w("<h2 id='notes'>Extraction notes</h2>" + h_notes(P))
    # page grid
    w("<h2 id='pages'>Page grid</h2><p class='meta'>Every page; outlines: blue figure/table, indigo box, slate tagged item, grey heading; "
      "orange fill: shows template text. Dark frame: main text.</p><div class='strip'>")
    anchors = defaultdict(list)
    for b in P.blocks + P.row_items:
        if (is_anchor(b) and b.kind != "para") or b.data.get("marks"):
            for pno, r in (block_rects(P, b) if b.lines or b.kind in ("float", "box") else [(b.page, pymupdf.Rect(b.data["rect"]))]):
                anchors[pno].append((b.kind + (" ph" if b.data.get("marks") else ""), r, b.id))
    first_block = {}
    for b in P.blocks:
        first_block.setdefault(b.page, b.id)
    for pno, page in enumerate(P.doc):
        W, H = page.rect.width, page.rect.height
        ovs = "".join(f"<a class='ov {k}' href='#{esc(bid)}' style='left:{100 * r.x0 / W:.1f}%;top:{100 * r.y0 / H:.1f}%;"
                      f"width:{100 * r.width / W:.1f}%;height:{max(0.8, 100 * r.height / H):.1f}%'></a>" for k, r, bid in anchors[pno])
        main = " main" if P.main_first <= pno <= P.main_last else ""
        href = first_block.get(pno, "")
        w(f"<div class='pg{main}'><a href='#{esc(href)}'><img src='{esc(P.thumbs[pno])}' loading='lazy'></a>{ovs}<div class='n'>{esc(page.get_label())}</div></div>")
    w("</div>")
    # rubric
    w("<h2 id='rubric'>Rubric map</h2><p class='meta'>Criteria from the guide's review-sheet section and the sheet PDF; "
      f"the chapters that carry each, by their role ({esc(P.lint_source) if P.chapter_roles else 'no lint export'}). "
      "Red rows: nothing detected without template text.</p>")
    w("<table class='t'><tr><th>criterion</th><th>top score (sheet)</th><th>carried by</th><th>evidence in this skim</th></tr>")
    for c in P.criteria:
        evs = P.rubric.get(c["id"], [])
        empty = not any(s == "detected" for s, _, _ in evs)
        carried = carried_by(P, c["id"])
        evh = "<br>".join(f"<span class='{s}'>[{s}]</span> " + (f"<a href='#{esc(ref)}'>{esc(t)}</a>" if ref else esc(t)) for s, t, ref in evs)
        bands = "".join(f"<li>{esc(b[0])}: {esc(b[1])}</li>" for b in c["bands"])
        w(f"<tr class='{'empty' if empty else ''}'><td><b>{esc(c['id'])}</b> {esc(c['name'])} (0–{c['max']})</td>"
          f"<td>{esc(c['top'])}<details><summary>all bands</summary><ul>{bands}</ul>{'<br>'.join(esc(n) for n in c['notes'])}</details></td>"
          f"<td>{esc('; '.join(carried)) or '—'}</td><td>{evh}</td></tr>")
    w("</table>")
    # outline
    w("<h2 id='outline'>Outline</h2><table class='t'><tr><th>part</th><th>heading</th><th>page</th><th>pages</th><th>lines</th></tr>")
    for r in outline_rows(P):
        if r["level"] > 4:
            continue
        pad = 14 * (r["level"] - 1)
        mk = " <span class='placeholder'>[placeholder]</span>" if marks(r["title"]) else ""
        w(f"<tr><td>{esc(r['part'])}</td><td style='padding-left:{pad + 6}px'><a href='#h-{esc(slug(r['anchor']))}'>{esc(r['number'])} {esc(r['title'])}</a>{mk}</td>"
          f"<td>{esc(r['page_label'])}</td><td>{r['pages']}</td><td>{r['lines']}</td></tr>")
    w("</table>")
    # body
    am = marks(P.abstract)
    w(f"<h2 id='abstract'>The paper as skimmed</h2><h3>Abstract{h_ph(Block('x', 0, 0, 0, data=dict(marks=am)))}</h3><p>{esc(P.abstract or '(no abstract found)')}</p>"
      f"<p class='cnt'>Kivonat (Hungarian abstract), {P.kivonat_lines} lines</p>")
    after = placed_items(P)
    for b in P.blocks:
        if b.data["part"] in ("main", "appendix"):
            w(h_block(P, b))
            for it in after.get(b.id, []):
                w(h_block(P, it))
    back = [o for o in P.lvl1 if o["part"] == "back"]
    if back:
        w("<h3>Back matter</h3><ul>" + "".join(f"<li>{esc(o['title'])}, p. {esc(P.doc[o['page']].get_label())}"
                                               + (f", {P.bib_entries} entries" if re.search(r'bibliograph|reference', o['title'], re.I) else "")
                                               + "</li>" for o in back) + "</ul>")
    # walls
    w("<h2 id='walls'>Walls of text</h2><p class='meta'>Longest stretch per chapter with no heading, run-in head, figure, table, box, tagged item or theorem-like. Over 1 page in red.</p>")
    w("<table class='t'><tr><th>chapter</th><th>longest stretch</th><th>lines</th><th>pages</th><th>stretches over 1 page</th></tr>")
    for x in P.walls:
        lg = x["longest"]
        if not lg:
            w(f"<tr><td>{esc(x['number'])} {esc(x['title'])}</td><td colspan=4>—</td></tr>")
            continue
        bad = " class='bad'" if lg["pages"] > 1 else ""
        over = ", ".join(f"<a href='#{esc(r['first'])}'>{r['pages']} p (p. {esc(r['from_label'])})</a>" for r in x["over"]) or "0"
        w(f"<tr><td>{esc(x['number'])} {esc(x['title'])}</td><td><a href='#{esc(lg['first'])}'>p. {esc(lg['from_label'])}–{esc(lg['to_label'])}</a></td>"
          f"<td>{lg['lines']}</td><td{bad}>{lg['pages']}</td><td>{over}</td></tr>")
    w("</table>")
    # chains
    ch = P.chains

    def e(t, s):
        cls = {"linked": "e-linked", "plain": "e-plain", "missing": "e-missing"}.get(s, "")
        tid = target_id(P, t)
        return f"<a class='{cls}' href='#{esc(tid)}' title='{esc(status_word(s))}'>{esc(t)}</a>" + ("" if s == "linked" else f" <small class='{cls}'>({esc(status_word(s))})</small>")

    corr_l = f"<a href='#{esc(ch['correctness'])}'>{esc(ch['correctness_key'])}</a>" if ch["correctness"] else "<span class='bad'>none</span>"
    gap_l = f"<a href='#{esc(ch['gap'])}'>{esc(ch['gap_key'])}</a>" if ch["gap"] else "<span class='bad'>none</span>"
    w(f"<h2 id='chains'>Argument chains</h2><p class='meta'>Correctness table: {corr_l}; gap matrix: {gap_l}. "
      "Plain: clickable link; orange: hand-typed; red: missing.</p>")
    if ch["guarantees"]:
        w("<h3>Guarantees</h3><table class='t'><tr><th>guarantee</th><th>assumptions cited</th><th>adversaries cited</th><th>correctness row</th></tr>")
        for g in ch["guarantees"]:
            row = "—" if g["correctness_row"] is None else ("row" if g["correctness_row"] else "<span class='bad'>no row</span>")
            w(f"<tr><td><a href='#{esc(g['id'])}'>{esc(g['tag'])}</a> {esc(g['name'])}</td><td>{' '.join(e(t, s) for t, s in g['assumptions'].items()) or '<span class=bad>none</span>'}</td>"
              f"<td>{' '.join(e(t, s) for t, s in g['adversaries'].items()) or '<span class=bad>none</span>'}</td><td>{row}</td></tr>")
        w("</table>")
    else:
        w("<p class='bad'>No guarantee items read.</p>")
    if ch["requirements"]:
        w("<h3>Requirements</h3><table class='t'><tr><th>requirement</th><th>gap-matrix row</th><th>evaluation</th></tr>")
        for r in ch["requirements"]:
            gr = "—" if r["gap_row"] is None else ("row" if r["gap_row"] else "<span class='bad'>no row</span>")
            ev = r["evaluation"]
            w(f"<tr><td><a href='#{esc(r['id'])}'>{esc(r['tag'])}</a> {esc(r['name'])}</td><td>{gr}</td><td class='e-{esc(ev.split()[0])}'>{esc(status_word(ev))}</td></tr>")
        w("</table>")
    if ch["contributions"]:
        w("<h3>Contributions → conclusion</h3><table class='t'><tr><th>contribution</th><th>restated in the conclusion</th></tr>")
        for c in ch["contributions"]:
            st = c["conclusion"]
            w(f"<tr><td><a href='#{esc(c['id'])}'>{esc(c['tag'])}</a> {esc(c['name'])}</td><td class='e-{esc(st.split()[0])}'>{esc(status_word(st))}</td></tr>")
        w("</table>")
    if ch["rqs"]:
        w("<h3>Research questions → evaluation or conclusion</h3><table class='t'><tr><th>RQ</th><th>mentioned</th></tr>")
        for r in ch["rqs"]:
            w(f"<tr><td><a href='#{esc(r['id'])}'>{esc(r['tag'])}</a> {esc(r['name'])}</td><td class='e-{esc(r['answered'])}'>{esc(status_word(r['answered']))}</td></tr>")
        w("</table>")
    # reference quality
    w("<h2 id='refs'>Reference quality</h2><table class='t'><tr><th>target kind</th><th>items</th><th>with \\label</th><th>mentions</th><th>linked</th><th>plain text</th><th>linked elsewhere</th></tr>")
    for r in P.refq["rows"]:
        w(f"<tr><td>{esc(r['kind'])}</td><td>{r['items']}</td><td>{r['labelled']}</td><td>{r['mentions']}</td><td>{r['linked']}</td>"
          f"<td class='{'warn' if r['plain'] else ''}'>{r['plain']}</td><td>{r['elsewhere']}</td></tr>")
    w("</table>")
    for title, lst in (("Hand-typed items without a \\label (cannot be linked)", P.refq["unlinkable"]),
                       ("Nothing links to", P.refq["no_link"]), ("Nothing even mentions", P.refq["no_mention"])):
        if lst:
            w(f"<p><b>{esc(title)}:</b> " + ", ".join(f"<a href='#{esc(i)}'>{esc(t)}</a>" for t, i in lst) + "</p>")
    if P.broken:
        w("<p class='bad'>Broken references:</p><ul>" + "".join(f"<li>p. {esc(P.doc[x['page']].get_label())}: {esc(x['text'])} ({esc(x['why'])})</li>" for x in P.broken[:50]) + "</ul>")
    w("</main></body></html>")
    (out / "skim.html").write_text("\n".join(buf))


def write_json(P, out):
    data = dict(
        name=P.name, title=P.title, stem=P.stem, metrics=metrics(P),
        items=[dict(id=b.id, tag=b.data["tag"], name=b.data["name"], kind=b.data["kind"], label=b.data.get("label", ""),
                    page=P.doc[b.page].get_label(), read=b.data.get("read", ""),
                    state="placeholder" if b.data["marks"] else "detected", marks=b.data["marks"]) for b in P.items],
        unsure=P.unsure, placeholders=P.placeholders, lint=P.lint_source if P.chapter_roles else None,
        floats=[dict(id=f.id, key=f.data["key"], caption=f.data["caption"], page=P.doc[f.page].get_label(), labels=f.data["labels"],
                     state="placeholder" if f.data["marks"] else "detected", marks=f.data["marks"]) for f in P.floats],
        boxes=[dict(id=b.id, title=b.data["title"], page=P.doc[b.page].get_label(), lines=b.nlines) for b in P.boxes if not b.data["note"]],
        walls=P.walls, chains=P.chains,
        rubric={k: [list(x) for x in v] for k, v in P.rubric.items()},
        outline=[{k: v for k, v in r.items()} for r in outline_rows(P)],
        checks=P.checks, criteria=P.criteria,
    )
    (out / "skim.json").write_text(json.dumps(data, indent=1, ensure_ascii=False, default=str))


def cmd_build(args):
    built = Path(args.built).resolve()
    if not built.is_dir():
        die(f"not a directory: {built}")
    out = Path(args.out).resolve()
    out.mkdir(parents=True, exist_ok=True)
    P = Paper(built, args.name or built.name, Path(args.guide) if args.guide else None, args.sheet, args.lint)
    analyse(P)
    render_assets(P, out, args.debug)
    write_md(P, out)
    write_html(P, out)
    write_json(P, out)
    c = P.checks
    print(f"{P.name}: {len(P.doc)} pages, main {P.main_pages}; " + ", ".join(f"{r['what']} {r['pdf']}/{r['source']}" for r in c["rows"])
          + f"; unsure {len(P.unsure)}; placeholders {P.placeholders['spots']}; unclassified lines {c['unclassified']}; -> {out / 'skim.html'}")


# ----------------------------------------------------------------------------------------------
# compare
# ----------------------------------------------------------------------------------------------

def cmd_compare(args):
    a, b = Path(args.before).resolve(), Path(args.after).resolve()
    for d in (a, b):
        if not (d / "skim.json").exists():
            die(f"{d} has no skim.json; run skim.py build first")
    A, B = (json.loads((d / "skim.json").read_text()) for d in (a, b))
    out = Path(args.out).resolve()
    out.mkdir(parents=True, exist_ok=True)
    buf = [f"<!doctype html><html><head><meta charset='utf-8'><title>Compare: {esc(A['name'])} → {esc(B['name'])}</title><style>{CSS}"
         "main{margin-left:0;max-width:none}.dup{display:flex;gap:8px}.dup iframe{flex:1;height:85vh;border:1px solid #ccc}"
         ".better{background:#e3f2fd}.worse{background:#ffebee}</style></head><body><main>"]
    w = buf.append
    w(f"<h1>Skim compare: {esc(A['name'])} → {esc(B['name'])}</h1><p class='meta'>{esc(A['title'])}</p>")
    w("<table class='t'><tr><th>metric</th><th>before</th><th>after</th><th>Δ</th></tr>")
    for k in A["metrics"]:
        va, vb = A["metrics"].get(k), B["metrics"].get(k)
        try:
            d = vb - va
        except TypeError:
            d = ""
        cls = ""
        if isinstance(d, (int, float)) and d:
            if k == "main text pages":
                good = abs(min(max(vb, 30), 35) - vb) < abs(min(max(va, 30), 35) - va)
                worse = abs(min(max(vb, 30), 35) - vb) > abs(min(max(va, 30), 35) - va)
                cls = "better" if good else ("worse" if worse else "")
            elif METRIC_DIR.get(k):
                cls = "better" if d * METRIC_DIR[k] > 0 else "worse"
        w(f"<tr class='{cls}'><td>{esc(k)}</td><td>{esc(va)}</td><td>{esc(vb)}</td><td>{'+' if isinstance(d, (int, float)) and d > 0 else ''}{esc(d)}</td></tr>")
    w("</table>")
    # criteria evidence
    w("<h2>Rubric evidence</h2><table class='t'><tr><th>criterion</th><th>before</th><th>after</th></tr>")
    for c in A["criteria"]:
        cid = c["id"]
        fmt = lambda evs: "<br>".join(f"<span class='{s}'>[{s}]</span> {esc(t)}" for s, t, _ in evs)
        w(f"<tr><td><b>{esc(cid)}</b> {esc(c['name'])}</td><td>{fmt(A['rubric'].get(cid, []))}</td><td>{fmt(B['rubric'].get(cid, []))}</td></tr>")
    w("</table>")
    # added / removed
    def keyset(D, what, key):
        return {key(x): x for x in D[what]}
    for what, key, show in (("items", lambda x: (x["tag"], x["name"]), lambda x: f"{x['tag']} {x['name']} ({x['kind']})"),
                            ("floats", lambda x: x["caption"][:70], lambda x: f"{x['key']}: {x['caption'][:90]}"),
                            ("boxes", lambda x: x["title"], lambda x: f"{x['title']} (p. {x['page']})")):
        ka, kb = keyset(A, what, key), keyset(B, what, key)
        added = [show(kb[k]) for k in kb if k not in ka]
        removed = [show(ka[k]) for k in ka if k not in kb]
        w(f"<h3>{esc(what)}: {len(ka)} → {len(kb)}</h3>")
        if added:
            w("<p>added:</p><ul>" + "".join(f"<li>{esc(x)}</li>" for x in added) + "</ul>")
        if removed:
            w("<p class='bad'>removed:</p><ul>" + "".join(f"<li>{esc(x)}</li>" for x in removed) + "</ul>")
    ra, rb = os.path.relpath(a / "skim.html", out), os.path.relpath(b / "skim.html", out)
    w(f"<h2>Both skim views</h2><div class='dup'><iframe src='{esc(ra)}'></iframe><iframe src='{esc(rb)}'></iframe></div>")
    w("</main></body></html>")
    (out / "compare.html").write_text("\n".join(buf))
    print(f"-> {out / 'compare.html'}")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    b = sub.add_parser("build", help="skim view of one built paper")
    b.add_argument("built", help="build directory with reviewer.pdf (or thesis.pdf), .aux and .toc")
    b.add_argument("-o", "--out", required=True, help="output directory")
    b.add_argument("--name", help="paper name shown in the view (default: the build directory's name)")
    b.add_argument("--guide", help=f"guide chapter with the review sheet section (default: {GUIDE} of the build)")
    b.add_argument("--sheet", help=f"the scoring sheet PDF (default: docs/{SHEET_NAME} of the build)")
    b.add_argument("--lint", help="the lint's JSON export (default: lint.json of the build, else texlua scripts/lint.lua chapters --json)")
    b.add_argument("--debug", action="store_true", help="also write debug/page-NNN.png with the detected blocks drawn on")
    c = sub.add_parser("compare", help="before/after comparison of two skim outputs")
    c.add_argument("before")
    c.add_argument("after")
    c.add_argument("-o", "--out", required=True)
    args = ap.parse_args()
    (cmd_build if args.cmd == "build" else cmd_compare)(args)


if __name__ == "__main__":
    main()
