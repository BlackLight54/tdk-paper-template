#!/usr/bin/env python3
"""Mutation tests for the TDK template's lint: break one thing, expect the rule to say so.

  python3 scripts/lint/tests/mutations.py [<built-dir>] [--only NAME]

<built-dir> is the template after a reviewer build (`make reviewer`), by default the checkout this
file is in. For each mutation: copy the build, put this checkout's scripts/ in, apply the edit,
run the one rule that should catch it, and check that the expected text is in that rule's output
and not in the output of the unmutated copy. The rule must have run: its exit is 0 or 1 and its
summary line is printed (with --json: the output is one JSON document holding its result), so a
negative case ("!text") cannot pass on a lint that crashed. A case may name another exit ("exit":
2), other lint arguments ("args") or extra environment ("env"). Exits non-zero when a rule misses
its mutation.

The template's CI runs it after the reviewer build. It calls texlua directly when it is on the
PATH (the CI container), and otherwise runs it in the docker image LINT_IMAGE (default
danteev/texlive:latest, the CI's image). These cases test the template's own skeleton; a
student's paper keeps the file but never runs it.
"""
import argparse
import datetime
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

TEMPLATE = Path(__file__).resolve().parents[3]
IMAGE = os.environ.get("LINT_IMAGE", "danteev/texlive:latest")


def sub(rel, old, new, count=1):
    def f(d):
        p = d / rel
        s = p.read_text()
        if old not in s:
            raise SystemExit(f"mutation anchor not found in {rel}: {old[:60]!r}")
        p.write_text(s.replace(old, new, count))
    return f


def drop_line(rel, needle):
    def f(d):
        p = d / rel
        lines = p.read_text().splitlines(keepends=True)
        keep = [l for l in lines if needle not in l]
        if len(keep) == len(lines):
            raise SystemExit(f"mutation anchor not found in {rel}: {needle!r}")
        p.write_text("".join(keep))
    return f


def append(rel, text):
    def f(d):
        p = d / rel
        p.write_text(p.read_text() + "\n" + text + "\n")
    return f


def rename(old, new):
    def f(d):
        (d / old).rename(d / new)
        t = d / "thesis.tex"
        t.write_text(t.read_text().replace("{" + old[:-4] + "}", "{" + new[:-4] + "}"))
    return f


def second_evaluation(d):
    """The guarantee's rows move out of 05-evaluation into a second evaluation chapter."""
    drop_line("content/05-evaluation.tex", "\\ref{g:example} &")(d)
    (d / "content/05-more.tex").write_text("\\chapter{More results}\\label{ch:evaluation:more}\n\\Cref{g:example} holds in every run.\n")
    sub("thesis.tex", "\\include{content/05-evaluation}\n", "\\include{content/05-evaluation}\n\\include{content/05-more}\n")(d)


def track(rel):
    """A git checkout that tracks a build output."""
    def f(d):
        subprocess.run(["git", "init", "-q", str(d)], check=True)
        subprocess.run(["git", "-C", str(d), "add", "-f", "--", rel, "thesis.tex"], check=True)
    return f


def replace_line(rel, needle, new):
    """The line holding needle becomes new."""
    def f(d):
        p = d / rel
        lines = p.read_text().splitlines(keepends=True)
        hit = [i for i, l in enumerate(lines) if needle in l]
        if not hit:
            raise SystemExit(f"mutation anchor not found in {rel}: {needle!r}")
        lines[hit[0]] = new + "\n"
        p.write_text("".join(lines))
    return f


def words(n):
    """n words of prose the template does not contain."""
    base = ("Every operator of a shared ledger must convince an auditor that revoked credentials stop "
            "working within seconds without learning who holds them or how often they are used").split()
    return " ".join((base * (n // len(base) + 1))[:n]) + "."


def own_items(rel, prefix, only=None):
    """The items of a tagged list in the author's own words: the TODO goes from their names."""
    def f(d):
        p = d / rel
        out = []
        for l in p.read_text().splitlines(keepends=True):
            if f"\\label{{{prefix}:" in l and (only is None or only in l):
                l = l.replace("TODO ", "")
            out.append(l)
        p.write_text("".join(out))
    return f


def both(*edits):
    def f(d):
        for e in edits:
            e(d)
    return f


def tag_line(rel, n, comment):
    """Line n of the file gets a comment, for a lint-ignore where the build log points."""
    def f(d):
        p = d / rel
        lines = p.read_text().splitlines(keepends=True)
        lines[n - 1] = lines[n - 1].rstrip("\n") + " % " + comment + "\n"
        p.write_text("".join(lines))
    return f


def pdf_with(rel, lines):
    """A one-page PDF of the given (y, text) lines in 12 pt Helvetica, for the PDF rules, which
    read what pdftotext and pdftohtml see: a built PDF cannot be mutated in place."""
    def f(d):
        body = "".join(f"BT /F1 12 Tf 72 {y} Td ({t.replace('(', '').replace(')', '')}) Tj ET\n" for y, t in lines)
        objs = ["<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
                "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>",
                f"<< /Length {len(body)} >>\nstream\n{body}endstream", "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"]
        out, offsets = "%PDF-1.4\n", []
        for i, o in enumerate(objs, 1):
            offsets.append(len(out))
            out += f"{i} 0 obj\n{o}\nendobj\n"
        xref = len(out)
        out += f"xref\n0 {len(objs) + 1}\n0000000000 65535 f \n" + "".join(f"{o:010d} 00000 n \n" for o in offsets)
        out += f"trailer\n<< /Size {len(objs) + 1} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n"
        (d / rel).write_bytes(out.encode("latin-1"))
    return f


def pitched(deltas):
    """Full-width lines down one page, each the given distance below the last."""
    lines, y = [], 780
    for dt in [0] + deltas:
        y -= dt
        lines.append((y, "The holder presents the credential and the verifier checks the status."))
    return lines


GAP = r"""\begin{table}[!ht]
  \centering
  \caption{The closest approaches against the requirements: only this work meets all three, each backed by an evaluation result.}
  \label{tab:related}
  \begin{tabularx}{\linewidth}{l X c c c}
    \toprule
    & \textbf{Requirement} & \makecell{\textbf{Ledger audit}\\\cite{lamport1978time}} & \makecell{\textbf{Status lists}\\\cite{w3c2025vcdm}} & \textbf{This work} \\
    \midrule
    \ref{req:first}  & Fast revocation & \gapyes & \gappartial & \gapyes\,(\cref{rq:correct}) \\
    \ref{req:second} & Unlinkable checks & \gapno & \gapyes & \gapyes\,(\cref{sec:scalability}) \\
    \ref{req:third}  & Auditable history & \gappartial & \gapno & \gapyes\,(\cref{sec:robustness}) \\
    \bottomrule
  \end{tabularx}
\end{table}"""


def three_reqs(d):
    """Three requirements in the introduction, where the skeleton has one."""
    sub("content/01-introduction.tex", "  \\item\\label{req:first} \\textbf{TODO Short name.} A property the running example needs, stated so it can be checked.\n",
        "  \\item\\label{req:first} \\textbf{TODO Short name.} A property the running example needs, stated so it can be checked.\n"
        "  \\item\\label{req:second} \\textbf{TODO Second.} Another property of the running example.\n"
        "  \\item\\label{req:third} \\textbf{TODO Third.} A third property of the running example.\n")(d)


def filled_gap(d):
    """Three requirements, and the gap matrix in the author's own words, arguing a gap."""
    three_reqs(d)
    p = d / "content/06-related-work.tex"
    s = p.read_text()
    at = s.index("\\label{tab:related}")
    a = s.rindex("\\begin{table}", 0, at)
    b = s.index("\\end{table}", at) + len("\\end{table}")
    p.write_text(s[:a] + GAP + s[b:])


NAMED = sub("thesis.tex", "\\newcommand{\\exname}{TODO name of the running example}", "\\newcommand{\\exname}{the shared ledger}")
OWN_BOX = replace_line("content/01-introduction.tex", "TODO Two or three sentences: the actors", words(20))


BG = "content/02-background.tex"
EVAL = "content/05-evaluation.tex"
CONTEXT = "\\guidetodo{Context}{app:chapters:context}"
SETUP = "\\guidetodo{Setup}{app:chapters:setup}"
YEAR = datetime.date.today().year  # the template's \tdkev is \the\year
ZENODO = sub("bib/references.bib", "10.5281/zenodo.TODO", "10.5281/zenodo.1234567", 2)


CITED = f"The model is the one of~\\cite{{student{YEAR}companion}}."  # the sentence tdk_entry(YEAR) adds


# the template asks for the development repository in the implementation chapter's overview
OWN_REPO = sub("content/04-implementation.tex", "\\url{https://github.com/TODO}", f"\\url{{https://github.com/someone/tdk{YEAR % 100:02d}-code}}")


def tdk_entry(year, venue="Tudom{\\'a}nyos Di{\\'a}kk{\\\"o}ri Konferencia, BME VIK", url=None):
    """A bibliography entry for a TDK paper, cited from the background chapter."""
    link = f",\n  url = {{{url}}}" if url else ""
    return both(append("bib/references.bib", f"@misc{{student{year}companion,\n  author = {{Di{{\\'a}}k, D{{\\'o}}ra}},\n  title = {{A Companion Topic}},\n  howpublished = {{{venue}}},\n  year = {{{year}}}{link}\n}}"),
                append(BG, f"The model is the one of~\\cite{{student{year}companion}}."))


MUTATIONS = [
    # (name, rule, edit, text the rule must print)
    ("gap matrix rows short", "essentials", both(filled_gap, drop_line("content/06-related-work.tex", "\\ref{req:third}  & Auditable")), "req:third has no row in the gap matrix"),
    ("a gap matrix row twice", "essentials", both(filled_gap, sub("content/06-related-work.tex", "\\ref{req:second} & Unlinkable", "\\ref{req:first} & Unlinkable")), "req:first has two rows"),
    ("this work without a result pointer", "essentials", both(filled_gap, sub("content/06-related-work.tex", "\\gapyes\\,(\\cref{sec:scalability})", "\\gapyes")), "points at no evaluation result"),
    ("guarantee not in the correctness table", "essentials", both(own_items("content/03-approach.tex", "g"), drop_line("content/05-evaluation.tex", "\\ref{g:example} &")), "g:example is not checked in the evaluation"),
    ("contribution not restated", "essentials", own_items("content/01-introduction.tex", "c"), "c:method is not restated"),
    ("a restated contribution", "essentials", both(own_items("content/01-introduction.tex", "c"), append("content/07-conclusion.tex", "\\Cref{c:method} holds in every run.")), "!c:method is not restated"),
    ("this work misses a requirement", "essentials", both(filled_gap, sub("content/06-related-work.tex", "\\gapyes\\,(\\cref{rq:correct})", "\\gapno")), "this work does not meet"),
    ("another approach meets everything", "essentials", both(filled_gap, sub("content/06-related-work.tex", "Unlinkable checks & \\gapno", "Unlinkable checks & \\gapyes"),
        sub("content/06-related-work.tex", "Auditable history & \\gappartial", "Auditable history & \\gapyes")), "meets every requirement"),
    ("a filled gap matrix is used", "essentials", filled_gap, "related ◔●◔"),
    ("a float without its label is missing", "essentials", drop_line("content/06-related-work.tex", "\\label{fig:positioning}"), "○ Positioning figure"),
    ("text below the threshold is started", "essentials", replace_line("content/01-introduction.tex", CONTEXT, words(15)), "◑ Context\n    help: 14 own words"),
    ("text above the threshold is written and enough", "essentials", replace_line("content/01-introduction.tex", CONTEXT, words(50)), "intro ●◔◔◔◔◔◔"),
    ("some items own is started", "essentials", both(three_reqs, own_items("content/01-introduction.tex", "req", only="req:first")), "◑ Requirements\n    help: 1 of 3 items written"),
    ("an own figure with a TODO caption is started", "essentials", replace_line("content/03-approach.tex", "\\missingfigure[figheight=2cm]{Architecture:",
        "  \\begin{tikzpicture}\\node[draw] (h) {Holder}; \\node[draw, right=of h] {Registry};\\end{tikzpicture}"), "◑ Architecture figure\n    help: the caption is still a TODO"),
    ("a section found by its heading", "essentials", sub("content/05-evaluation.tex", "\\section{Threats to validity}\\label{sec:validity}", "\\section{Threats to validity}"), "add \\label{sec:validity}"),
    ("a written setup without the artifact's DOI", "essentials", replace_line(EVAL, SETUP, words(120)), "◕ Setup and artifact\n    help: cite the archived artifact"),
    ("a written setup with the artifact's DOI", "essentials", both(replace_line(EVAL, SETUP, words(120) + " The code is archived~\\cite{artifact}."), ZENODO), "evaluation ◔●◔◔◔◔"),
    ("a paper's DOI is not the artifact", "essentials", both(replace_line(EVAL, SETUP, words(120) + " Clocks follow~\\cite{lamport1978time}."), ZENODO), "◕ Setup and artifact\n    help: cite the archived artifact"),
    ("both abstracts written", "essentials", both(replace_line("content/00-abstract.tex", "[1 Field", words(120)), sub("content/00-abstract.tex", "TODO\n\n\\vfill\n\\selectenglish", words(120) + "\n\n\\vfill\n\\selectenglish")), "front ●"),
    ("a paragraph label is par:", "labels", append(BG, "\\paragraph{Extra.}\\label{par:extra} Some text."), "!par:extra"),
    ("figure never referenced", "figures", append(BG, "\\begin{figure}\\centering x\\caption{An orphan figure for the test.}\\label{fig:orphan}\\end{figure}"), "fig:orphan is never referenced"),
    ("typed reference", "crefs", append(BG, "As Figure~\\ref{fig:overview} shows, it works."), "typed reference"),
    ("autoref", "crefs", append(BG, "As \\autoref{fig:overview} shows, it works."), "\\autoref"),
    ("lint-ignore silences one finding", "crefs", append(BG, "As Figure~\\ref{fig:overview} shows. % lint-ignore: crefs test"), "!typed reference"),
    ("acronym typed by hand", "acronyms", append(BG, "We use ZKP here."), "ZKP typed by hand"),
    ("two-letter abbreviation typed by hand", "acronyms", append(BG, "Every VC is signed."), "VC typed by hand"),
    ("plural abbreviation typed by hand", "acronyms", append(BG, "Both VCs are signed."), "VC typed by hand"),
    ("a longer word is not the abbreviation", "acronyms", append(BG, "The VCS keeps the history."), "!VC typed by hand"),
    ("all-caps word not declared", "acronyms", append(BG, "The QWXZ protocol runs."), "QWXZ is not in the glossary"),
    ("a comment environment is not prose", "acronyms", append(BG, "\\begin{comment}\nEvery VC is signed.\n\\end{comment}"), "!VC typed by hand"),
    ("glossary key undeclared", "acronyms", append(BG, "We use \\gls{nosuchkey} here."), "nosuchkey is not declared"),
    # the common glossary, include/glossary-common.tex
    ("common abbreviation typed by hand", "acronyms", append(BG, "Every DID resolves."), "DID typed by hand\n    help: write \\gls{did}"),
    ("common key needs no declaration", "acronyms", append(BG, "Every \\gls{did} resolves."), "!did is not declared"),
    ("unused common entries are silent", "acronyms", append(BG, "Nothing to see."), "!bpmn is declared but never used"),
    ("own entry under a common short form", "acronyms", append("content/glossary.tex", "\\newabbreviation{dids}{DID}{decentralized identifier}"), "DID is also the common glossary's did"),
    ("own entry replaces the common one", "acronyms", both(append("content/glossary.tex", "\\newabbreviation{did}{DID}{decentralised identifier}"), append(BG, "Every \\gls{did} resolves.")), "!DID is also the common glossary"),
    ("common glossary deleted", "frame", lambda d: (d / "include/glossary-common.tex").unlink(), "missing from the template: include/glossary-common.tex"),
    ("a paper glossary with no entries yet", "frame", lambda d: (d / "content/glossary.tex").write_text("% no entries yet\n"), "!no glossary file"),
    ("approach role missing", "frame", sub("content/03-approach.tex", "\\label{ch:approach}", "\\label{ch:method}"), "no approach chapter"),
    ("file not NN-name", "frame", rename("content/02-background.tex", "content/background.tex"), "NN-name.tex"),
    ("bib entry without title", "bib", drop_line("bib/references.bib", "{Time, Clocks, and the Ordering"), "lamport1978time: no title"),
    ("cited key missing", "bib", append(BG, "See~\\cite{nosuchref}."), "nosuchref is in no .bib file"),
    ("unicode lstinline", "code", append(BG, "The rule \\lstinline{∀x} holds."), "ASCII"),
    ("label prefix wrong", "labels", append(BG, "\\begin{table}\\caption{A table for the test.}\\label{fig:wrong}\\end{table}"), "expected prefix tab:"),
    ("running example missing from a chapter", "essentials", both(NAMED, OWN_BOX, lambda d: (d / BG).write_text(re.sub(r"\\begin\{runningexample\}.*?\\end\{runningexample\}", "", (d / BG).read_text(), flags=re.S))), "no example box in 02-background"),
    ("own example box not used", "essentials", sub("thesis.tex", "\\newcommand{\\lintexamplebox}{runningexample}", "\\newcommand{\\lintexamplebox}{cvd}"), "○ Running example"),
    ("own example box counts", "essentials", both(NAMED, OWN_BOX, sub("thesis.tex", "\\newcommand{\\lintexamplebox}{runningexample}", "\\newcommand{\\lintexamplebox}{cvd}"),
        lambda d: [(f).write_text(f.read_text().replace("{runningexample}", "{cvd}")) for f in (d / "content").glob("0[1-7]-*.tex")]), "intro ◔◔●◔◔◔◔"),
    ("hyphen range", "typography", append(BG, "This holds for pages 12-18 of the book."), "with a hyphen"),
    ("a name is not a range", "typography", append(BG, "The curve BLS12-381 on an i7-9750H."), "!range 12-381"),
    ("two chapters in one file", "chapters", append(BG, "\\chapter{Second}\nMore text."), "a second chapter in one file"),
    ("a file nothing includes", "orphans", lambda d: (d / "content/notes.tex").write_text("Some notes the author forgot to include in a chapter.\n"), "included nowhere"),
    ("own prose ends a stub", "stubs", append(BG, " ".join(["Own words of the author, written for this chapter."] * 25)), "!content/02-background.tex"),
    ("faculty placeholder text", "stock", append(BG, "A bevezető tartalmazza a diplomaterv-kiírás elemzését."), "placeholder text is still here"),
    ("a chapter after the conclusion", "spine", lambda d: ((d / "content/08-extra.tex").write_text("\\chapter{Future Work}\nText.\n"),
        sub("thesis.tex", "\\include{content/07-conclusion}\n", "\\include{content/07-conclusion}\n\\include{content/08-extra}\n")(d)), "after the conclusion"),
    ("amssymb in the own preamble", "preamble", append("include/macros.tex", "\\usepackage{amssymb}"), "amssymb next to unicode-math"),
    ("a template theorem defined again", "preamble", append("include/macros.tex", "\\newtheorem{lemma}{Lemma}"), "defines the lemma environment"),
    ("an option clash", "preamble", append("include/macros.tex", "\\usepackage[noend]{algpseudocode}"), "option clash"),
    ("Hungarian prose", "language", append(BG, "Ez a fejezet azt mutatja be, hogy a módszer hogyan működik és mit ad."), "Hungarian prose"),
    ("a numbered label", "labels", append(BG, "\\section{Extra}\\label{sec:3.4}"), "encodes a number"),
    ("a chapter label that names no role", "roles", sub("content/04-implementation.tex", "\\label{ch:implementation}", "\\label{ch:impl}"), "names no role"),
    ("a chapter without a label", "roles", sub(BG, "\\chapter{Background}\\label{ch:background}", "\\chapter{Background}"), "no role label"),
    ("a named role label counts", "frame", sub("content/03-approach.tex", "\\label{ch:approach}", "\\label{ch:approach:method}"), "!no approach chapter"),
    ("a role spans two chapters", "essentials", both(own_items("content/03-approach.tex", "g"), second_evaluation), "!g:example is not checked"),
    ("tracked build output", "repo-hygiene", track("reviewer.pdf"), "reviewer.pdf: FAIL build output is tracked"),
    ("a typed TBD", "markers", append(BG, "The proving time is TBD for now."), "a typed TBD"),
    ("a typed citation marker", "markers", append(BG, "This is well known [CITE: the survey]."), "a typed [CITE"),
    ("a gap marker left at the submit phase", "markers", append(BG, "Proving takes \\tbd{the proving time}."), "is still here"),
    ("a TBD inside a todo is not typed into the text", "markers", append(BG, "Text.\\todo{TBD later}"), "!a typed TBD"),
    # a TDK paper of the same year is a companion paper: never cited or linked
    ("a TDK paper of this year cited", "companion", tdk_entry(YEAR), "is a TDK paper of"),
    ("a TDK paper of an earlier year cited", "companion", tdk_entry(YEAR - 1, venue="Scientific Students' Association Report"), "!is a TDK paper of"),
    ("a TDK paper of this year cited across a line break", "companion", both(tdk_entry(YEAR),
        sub(BG, f"~\\cite{{student{YEAR}companion}}", f"~\\citep[Section 2]\n  {{student{YEAR}companion}}")), f"student{YEAR}companion is a TDK paper of"),
    ("a TDK paper of this year in a comment environment", "companion", both(tdk_entry(YEAR),
        sub(BG, CITED, f"\\begin{{comment}}\n{CITED}\n\\end{{comment}}")), "!is a TDK paper of"),
    ("a TDK paper of this year in a todo note", "companion", both(tdk_entry(YEAR),
        sub(BG, CITED, f"Text.\\todo{{Read~\\cite{{student{YEAR}companion}} again.}}")), "!is a TDK paper of"),
    ("a cited entry links an Overleaf project", "companion", tdk_entry(YEAR, venue="Manuscript", url="https://www.overleaf.com/read/abcdefghijkl"), "points at an Overleaf project"),
    ("an Overleaf link in the text", "companion", append(BG, "The draft is at \\url{https://www.overleaf.com/read/abcdefghijkl}."), "links an Overleaf project"),
    ("Overleaf's documentation is no draft", "companion", append(BG, "See \\url{https://www.overleaf.com/learn/latex/Bibliography_management_with_natbib}."), "!Overleaf"),
    ("a same-year TDK repository linked", "companion", append(BG, f"The code is at \\url{{https://github.com/someone/tdk{YEAR % 100:02d}-code}}."), "links the repository of a"),
    ("this paper's own repository, linked in the implementation chapter", "companion", OWN_REPO, "!companion paper"),
    ("this paper's own repository, cited in the implementation chapter", "companion", both(append("bib/references.bib", f"@misc{{owncode, title = {{The Code}}, year = {{{YEAR}}}, url = {{https://github.com/someone/tdk{YEAR % 100:02d}-code}}}}"),
        sub("content/04-implementation.tex", "\\url{https://github.com/TODO}", "\\cite{owncode}")), "!companion paper"),
    ("another same-year repository next to this paper's own", "companion", both(OWN_REPO, append(BG, f"The model is at \\url{{https://github.com/someone/tdk{YEAR % 100:02d}-model}}.")), "links the repository of a"),
    ("the thesis profile skips the companion rule", "companion", tdk_entry(YEAR), "skipped", {"args": "--doc reviewer --phase submit --profile thesis", "exit": 0, "fresh": True}),
    ("a companion paper cited", "companion", append(BG, "A companion paper~\\cite{lamport1978time} verifies the protocol."), "attached to a companion paper"),
    ("a companion paper linked", "companion", append(BG, "The protocol is verified in \\href{https://example.org/paper.pdf}{a companion paper}."), "attached to a companion paper"),
    ("a companion paper named, its tool cited", "companion", append(BG, "A companion paper verifies the protocol in Tamarin~\\cite{lamport1978time}."), "!attached to a companion paper"),
    # the citation reader: spaces and line breaks where TeX allows them, nothing from notes
    ("cited key missing after a space", "bib", append(BG, "See~\\cite {nosuchref}."), "nosuchref is in no .bib file"),
    ("cited key missing after a line break", "bib", append(BG, "See~\\cite\n{nosuchref}."), "nosuchref is in no .bib file"),
    ("cited key missing on the next line", "bib", append(BG, "See~\\cite{lamport1978time,\n  nosuchref}."), "nosuchref is in no .bib file"),
    ("cited key missing after an optional argument and a space", "bib", append(BG, "See~\\citep[Section 2] {nosuchref}."), "nosuchref is in no .bib file"),
    ("a citation in a comment environment is not read", "bib", append(BG, "\\begin{comment}\nSee~\\cite{nosuchref}.\n\\end{comment}"), "!nosuchref"),
    ("a citation in a picture is read", "bib", append(BG, "\\begin{tikzpicture}\\node {Prior work~\\cite{nosuchref}};\\end{tikzpicture}"), "nosuchref is in no .bib file"),
    ("a citation in a code listing is not read", "bib", append(BG, "\\begin{lstlisting}\n\\cite{nosuchref}\n\\end{lstlisting}"), "!nosuchref"),
    # the phase is one of the lifecycle's seven, wherever it comes from; final is no alias of submit
    ("an old phase name is no alias", "markers", append(BG, "Proving takes \\tbd{the proving time}."), "unknown phase 'final'", {"args": "--doc reviewer --phase final", "exit": 2, "fresh": True}),
    ("the first four phases share a level", "markers", append(BG, "Proving takes \\tbd{the proving time}."), "!is still here", {"args": "--doc reviewer --phase research", "fresh": True}),
    ("an unknown phase stops the lint", "markers", append(BG, "Proving takes \\tbd{the proving time}."), "unknown phase 'fnial'", {"args": "--doc reviewer --phase fnial", "exit": 2, "fresh": True}),
    ("an unknown phase in thesis.tex stops the lint", "markers", sub("thesis.tex", "\\newcommand{\\lintphase}{plan}", "\\newcommand{\\lintphase}{fnial}"), "from \\lintphase in thesis.tex", {"args": "--doc reviewer", "exit": 2}),
    ("an unknown phase on the Checks page", "markers", sub("thesis.tex", "\\newcommand{\\lintphase}{plan}", "\\newcommand{\\lintphase}{fnial}"), "The lint did not run", {"args": "overleaf --tex", "exit": 2}),
    # a rule that cannot run says skipped, and --json carries every rule's result
    ("an offline link check is skipped, not passed", "links", lambda d: None, "links         advice  skipped", {"fresh": True}),
    ("a PDF rule without a PDF is skipped", "pdf-margins", lambda d: None, "skipped", {"args": "--doc nosuchdoc --phase submit", "fresh": True}),
    ("json carries the findings of every rule", "bib", append(BG, "See~\\cite{nosuchref}."), '"msg":"cited key nosuchref is in no .bib file","rule":"bib"', {"args": "all --doc reviewer --phase submit --json", "exit": 1}),
    # fixes never edit literal text: code listings, inline verbatim, links, maths
    ("a code listing's Figure~\\ref is the program's text", "crefs", append(BG, "\\begin{lstlisting}\nFigure~\\ref{fig:overview}\n\\end{lstlisting}"), "!typed reference"),
    ("inline verbatim is the program's text", "crefs", append(BG, "The macro \\verb|Figure~\\ref{fig:overview}| is typed as text."), "!typed reference"),
    ("a quote inside verbatim is not rewritten", "typography", append(BG, 'The string \\verb|"abc"| is a literal; "quoted" text follows.'), '!\\verb|\\enquote{abc}|'),
    ("a quote outside verbatim is rewritten", "typography", append(BG, 'The string \\verb|"abc"| is a literal; "quoted" text follows.'), '\\enquote{quoted} text follows'),
    ("a range inside maths is a formula", "typography", append(BG, "The bound $12-18$ holds."), "!with a hyphen"),
    ("that that is grammar, not a doubled word", "typography", append(BG, "The protocol that that process uses is sound."), "!doubled word"),
    ("a doubled word", "typography", append(BG, "The protocol the the process uses is sound."), "doubled word: the the"),
    # the phase declaration is read as TeX reads it
    ("a phase declared across two lines is read", "markers", both(append(BG, "Proving takes \\tbd{the proving time}."), sub("thesis.tex", "\\newcommand{\\lintphase}{plan}", "\\newcommand{\\lintphase}\n  {submit}")), "is still here", {"args": "--doc reviewer"}),
    ("a starred declaration is read", "markers", both(append(BG, "Proving takes \\tbd{the proving time}."), sub("thesis.tex", "\\newcommand{\\lintphase}{plan}", "\\newcommand*{\\lintphase}{submit}")), "is still here", {"args": "--doc reviewer"}),
    ("a typo across two lines stops the lint", "markers", sub("thesis.tex", "\\newcommand{\\lintphase}{plan}", "\\newcommand{\\lintphase}\n  {fnial}"), "unknown phase 'fnial'", {"args": "--doc reviewer", "exit": 2}),
    # links are read as citations are: across line breaks, in the printed text only
    ("an Overleaf link across a line break", "companion", append(BG, "The draft is at \\url\n{https://www.overleaf.com/read/abcdefghijkl}."), "links an Overleaf project"),
    ("an Overleaf link in a comment environment is not read", "companion", append(BG, "\\begin{comment}\n\\url{https://www.overleaf.com/read/abcdefghijkl}\n\\end{comment}"), "!Overleaf"),
    ("an Overleaf link in a todo note is not read", "companion", append(BG, "Text.\\todo{Read \\url{https://www.overleaf.com/read/abcdefghijkl}.}"), "!Overleaf"),
    ("a companion paper in emphasis, cited", "companion", append(BG, "A \\emph{companion paper}~\\cite{lamport1978time} verifies it."), "attached to a companion paper"),
    ("a citation in a todo whose text follows a space", "companion", both(tdk_entry(YEAR), sub(BG, CITED, f"Text.\\todo[inline] {{Read~\\cite{{student{YEAR}companion}} again.}}")), "!is a TDK paper of"),
    # the artifact is an artifact's entry with the DOI in its doi or url field
    ("a publication's Zenodo DOI is not the artifact", "essentials", both(replace_line(EVAL, SETUP, words(120) + " A survey discusses clocks~\\cite{unrelated}."),
        append("bib/references.bib", "@article{unrelated,\n  author = {Other, Author},\n  title = {A survey},\n  journal = {Reports},\n  year = {2025},\n  doi = {10.5281/zenodo.1234567}\n}")), "◕ Setup and artifact\n    help: unrelated is an @article entry with a Zenodo DOI"),
    ("a Zenodo DOI only in a note is not the artifact", "essentials", both(replace_line(EVAL, SETUP, words(120) + " We discuss~\\cite{unrelated}."),
        append("bib/references.bib", "@misc{unrelated,\n  author = {Other, Author},\n  title = {A survey},\n  year = {2025},\n  note = {The archive was once 10.5281/zenodo.1234567}\n}")), "◕ Setup and artifact\n    help: cite the archived artifact"),
    # the gap matrix: every row is a declared requirement, and this work's cells point at results that exist
    ("a gap matrix row that names no requirement", "essentials", both(filled_gap, sub("content/06-related-work.tex", "\\ref{req:third}  & Auditable", "\\ref{req:fourth} & Extra & \\gapno & \\gapno & \\gapyes\\,(\\cref{rq:correct}) \\\\\n    \\ref{req:third}  & Auditable")), "req:fourth is a row of the gap matrix but no requirement carries that label"),
    ("this work points at a chapter, not a result", "essentials", both(filled_gap, sub("content/06-related-work.tex", "\\gapyes\\,(\\cref{sec:scalability})", "\\gapyes\\,(\\cref{ch:background})")), "ch:background is not an evaluation result"),
    ("this work points at a label that does not exist", "essentials", both(filled_gap, sub("content/06-related-work.tex", "\\gapyes\\,(\\cref{sec:scalability})", "\\gapyes\\,(\\cref{fig:does-not-exist})")), "fig:does-not-exist, which no label defines"),
    ("a pointer with a space after \\cref counts", "essentials", both(filled_gap, sub("content/06-related-work.tex", "\\gapyes\\,(\\cref{sec:scalability})", "\\gapyes\\,(\\cref {sec:scalability})")), "related ◔●◔"),
    # a rule whose own code fails did not run: exit 2, status error, never ok
    ("a crashed rule stops the lint with exit 2", "sources", sub("scripts/lint/rules-source.lua", 'local bbl = C.readfile(C.bpath(C.opts.doc .. ".bbl"))', 'error("injected by the mutation suite") local bbl = C.readfile(C.bpath(C.opts.doc .. ".bbl"))'), "the rule itself failed", {"args": "--doc reviewer --phase submit", "exit": 2}),
    ("a crashed rule is not ok in the JSON", "sources", sub("scripts/lint/rules-source.lua", 'local bbl = C.readfile(C.bpath(C.opts.doc .. ".bbl"))', 'error("injected by the mutation suite") local bbl = C.readfile(C.bpath(C.opts.doc .. ".bbl"))'), '"ok":false', {"args": "--doc reviewer --phase submit --json", "exit": 2}),
    ("a misspelt title", "spelling", sub("thesis.tex", "\\newcommand{\\vikcim}{TODO Title of the paper}", "\\newcommand{\\vikcim}{Revocation and revovation of credentials}"), "revovation"),
    # code is the program's text: no typography slip in \texttt, \lstinline or a verbatim block, and no
    # marker or abbreviation in a verbatim block, an \iffalse region or \verb
    ("a space before a colon in \\texttt is code", "typography", append(BG, "The kernel \\texttt{x : Nat} is typed."), "!space before punctuation"),
    ("a space before a colon in \\lstinline is code", "typography", append(BG, "The signature \\lstinline{f : A -> B} is typed."), "!space before punctuation"),
    ("a range in a verbatim block is the program's text", "typography", append(BG, "\\begin{verbatim}\npages 3-4\n\\end{verbatim}"), "!with a hyphen"),
    ("a space before the full stop that ends the line", "typography", append(BG, "The kernel ."), "space before punctuation"),
    ("a TBD in a verbatim block is the program's text", "markers", append(BG, "\\begin{verbatim}\nTBD\n\\end{verbatim}"), "!a typed TBD"),
    ("a TBD in a fancyvrb Verbatim block is the program's text", "markers", append(BG, "\\begin{Verbatim}\nTBD\n\\end{Verbatim}"), "!a typed TBD"),
    ("an XXX under \\iffalse never prints", "markers", append(BG, "\\iffalse\nXXX hidden\n\\fi"), "!a typed XXX"),
    ("a TBD in inline verbatim is the program's text", "markers", append(BG, "The value \\verb|TBD| is literal."), "!a typed TBD"),
    ("an abbreviation in a verbatim block is the program's text", "acronyms", append(BG, "\\begin{verbatim}\nZKP\n\\end{verbatim}"), "!ZKP typed by hand"),
    ("an abbreviation under \\iffalse never prints", "acronyms", append(BG, "\\iffalse\nEvery ZKP is short.\n\\fi"), "!ZKP typed by hand"),
    # glossaries-extra accepts \newacronym next to \newabbreviation
    ("an entry declared with \\newacronym", "acronyms", both(append("content/glossary.tex", "\\newacronym{mpc}{MPC}{multi-party computation}"), append(BG, "We use \\gls{mpc} here.")), "!mpc is not declared"),
    ("a \\newacronym short form typed by hand", "acronyms", both(append("content/glossary.tex", "\\newacronym{mpc}{MPC}{multi-party computation}"), append(BG, "Every MPC run ends.")), "MPC typed by hand"),
    # the job summary: the plain run writes it; --tex (every XeLaTeX pass) and --json do not
    ("the plain run writes the job summary", "markers", lambda d: None, "| Group | Status | Check | Rule | Findings |", {"args": "all --doc reviewer --phase submit", "env": {"GITHUB_STEP_SUMMARY": "/dev/stdout"}, "fresh": True}),
    ("the Checks page run leaves the job summary alone", "markers", lambda d: None, "!| Group | Status |", {"args": "overleaf --tex --doc reviewer", "env": {"GITHUB_STEP_SUMMARY": "/dev/stdout"}, "fresh": True}),
    ("the JSON run leaves the job summary alone", "markers", lambda d: None, "!| Group | Status |", {"args": "all --doc reviewer --phase submit --json", "env": {"GITHUB_STEP_SUMMARY": "/dev/stdout"}, "exit": 1, "fresh": True}),
    # the main text's first page comes from the .toc's first numbered chapter, whatever its title;
    # without a .toc the outline's titles still find it
    ("the main text is counted without a .toc", "pdf-pages", lambda d: (d / "reviewer.toc").unlink(), "main text is", {"fresh": True}),
    # the PDF rules on a PDF of known text (pdf_with): a placeholder is a whole word, and no PDF is a skip
    ("a placeholder word printed in the PDF", "pdf-parts", pdf_with("tiny.pdf", [(700, "The proving time is TBD for now.")]), "TBD is printed in the PDF", {"args": "--doc tiny --phase submit"}),
    ("a roman numeral is not the XXX placeholder", "pdf-parts", pdf_with("tiny.pdf", [(700, "XXXVI. OTDK, Vol. TBDX")]), "!is printed in the PDF", {"args": "--doc tiny --phase submit"}),
    ("pdf-parts without a PDF is skipped", "pdf-parts", lambda d: None, "skipped", {"args": "--doc nosuchdoc --phase submit", "fresh": True}),
    # the line pitch is the most common one (14 here: 8 of 14, 7 of 20, 6 of 26, whose median is 20), and too few lines are a warning
    ("the line pitch is the most common pitch, not the median", "pdf-spacing", pdf_with("tiny.pdf", pitched([14, 14, 20, 26, 14, 20, 26, 14, 14, 20, 26, 14, 20, 26, 14, 20, 26, 14, 20, 26, 20])), "pitch=14.0pt", {"args": "--doc tiny --phase submit", "exit": 0}),
    ("too few lines to measure the pitch is a warning", "pdf-spacing", pdf_with("tiny.pdf", pitched([20, 20, 20, 20, 20])), "only 5 line pitches to measure", {"args": "--doc tiny --phase submit", "exit": 0}),
    # an overfull box is placed at the source lines the log names, so a lint-ignore there silences it; under a point it is invisible
    ("an overfull box at its source lines", "overfull", append("reviewer.log", "(./content/02-background.tex\nOverfull \\hbox (12.5pt too wide) in paragraph at lines 7--9\n[]\\TU/TeXGyreTermes(0)/m/n/12 Some text\n)"), "content/02-background.tex:7: FAIL overfull by 12.5pt at lines 7-9"),
    ("an overfull box silenced where it is", "overfull", both(append("reviewer.log", "(./content/02-background.tex\nOverfull \\hbox (12.5pt too wide) in paragraph at lines 7--9\n[]\\TU/TeXGyreTermes(0)/m/n/12 Some text\n)"),
        tag_line(BG, 7, "lint-ignore: overfull the long identifier stays")), "!overfull by"),
    ("an overfull box under a point is invisible", "overfull", append("reviewer.log", "(./content/02-background.tex\nOverfull \\hbox (0.4pt too wide) in paragraph at lines 7--9\n[]\\TU/TeXGyreTermes(0)/m/n/12 Some text\n)"), "!overfull by"),
    # the phase declaration is trimmed wherever it is read
    ("a phase with spaces around it is the phase", "markers", both(append(BG, "Proving takes \\tbd{the proving time}."), sub("thesis.tex", "\\newcommand{\\lintphase}{plan}", "\\newcommand{\\lintphase}{ submit }")), "is still here", {"args": "--doc reviewer"}),
    ("a phase with spaces around it keeps the frame", "frame", sub("thesis.tex", "\\newcommand{\\lintphase}{plan}", "\\newcommand{\\lintphase}{ draft }"), "!no \\lintphase", {"args": "--doc reviewer"}),
]


ARGS = "--doc reviewer --phase submit"


def lint(d, rule, args=ARGS, env=None):
    """The rule's output and exit. args starting with a subcommand (overleaf, all) replace the rule.
    The cases read the lint's plain output, so GitHub's variables are kept from it: under
    GITHUB_ACTIONS the lint prints workflow commands instead, with the help on the annotation."""
    cmd = args if args.split()[0] in ("overleaf", "all", "source") else f"{rule} {args}"
    plain = {k: v for k, v in os.environ.items() if not k.startswith("GITHUB_")}
    plain.update(env or {})
    if shutil.which("texlua"):
        r = subprocess.run(["sh", "-c", f"LINT_OFFLINE=1 texlua scripts/lint.lua {cmd} 2>&1"], cwd=d, text=True, capture_output=True, env=plain)
    else:
        envargs = [x for k, v in (env or {}).items() for x in ("-e", f"{k}={v}")]
        r = subprocess.run(["docker", "run", "--rm", "-u", f"{os.getuid()}:{os.getgid()}", "-e", "HOME=/tmp", *envargs, "-v", f"{d}:/w", "-w", "/w", IMAGE,
                            "sh", "-c", f"LINT_OFFLINE=1 texlua scripts/lint.lua {cmd} 2>&1"],
                           text=True, capture_output=True)
    return r.stdout, r.returncode


def ran(out, code, rule, opts):
    """None when the lint ran as the case expects, else what went wrong."""
    want = opts.get("exit")
    if want is not None and code != want:
        return f"exit {code}, expected {want}"
    if want is None and code not in (0, 1):
        return f"exit {code}: the lint did not run"
    if want == 2:
        return None
    if "the rule itself failed" in out:
        return "the rule itself failed"
    if "--tex" in opts.get("args", ""):
        return None if "\\section*{Other checks}" in out else "no Checks page"
    if "--json" in opts.get("args", ""):
        try:
            rules = json.loads(out)["rules"]
        except (ValueError, KeyError):
            return "the output is not one JSON document"
        return None if any(r["rule"] == rule for r in rules) else "no JSON result for the rule"
    if not re.search(rf"^(?:ok  |FAIL|    ) {re.escape(rule)} +(?:check|advice|count) ", out, re.M):
        return "no summary line for the rule"
    return None


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("built", type=Path, nargs="?", default=TEMPLATE)
    ap.add_argument("--only")
    a = ap.parse_args()
    if not (a.built / "reviewer.aux").exists():
        sys.exit(f"error: {a.built} has no reviewer build (run make reviewer first)")
    work = Path(tempfile.mkdtemp(prefix="lint-mut-"))
    base = work / "base"
    shutil.copytree(a.built, base, ignore=shutil.ignore_patterns(".git", "_minted-*", "svg-inkscape", "review-bundle", "skim"))
    shutil.rmtree(base / "scripts"); shutil.copytree(TEMPLATE / "scripts", base / "scripts")
    baseline = {}
    missed = 0
    for name, rule, edit, expect, *rest in MUTATIONS:
        opts = rest[0] if rest else {}
        if a.only and a.only != name:
            continue
        args = opts.get("args", ARGS)
        negate = expect.startswith("!")
        if not opts.get("fresh"):
            if (rule, args) not in baseline:
                baseline[rule, args] = lint(base, rule, args, opts.get("env"))
            out, code = baseline[rule, args]
            why = ran(out, code, rule, {k: v for k, v in opts.items() if k != "exit"}) if opts.get("exit") != 2 else None
            if why:
                missed += 1
                print(f"BROKE {rule:13s} {name}: the unmutated template: {why}")
                continue
            if not negate and expect in out:
                print(f"SKIP  {name}: the unmutated template already prints {expect!r}")
                continue
        d = work / re.sub(r"\W+", "-", name)
        shutil.copytree(base, d)
        try:
            edit(d)
        except (SystemExit, Exception) as e:  # the template moved under the mutation: report it, run the rest
            missed += 1
            print(f"STALE {rule:13s} {name}: {e}")
            shutil.rmtree(d)
            continue
        out, code = lint(d, rule, args, opts.get("env"))
        why = ran(out, code, rule, opts)
        ok = why is None and ((expect[1:] not in out) if negate else (expect in out))
        missed += not ok
        print(f"{'ok  ' if ok else 'MISS'}  {rule:13s} {name}")
        if not ok:
            print(f"      {why or 'expected ' + repr(expect)}; exit {code}; the rule printed:\n" + "\n".join("        " + l for l in out.splitlines()[-8:]))
        shutil.rmtree(d)
    shutil.rmtree(work)
    print(f"{missed} missed")
    sys.exit(1 if missed else 0)


if __name__ == "__main__":
    main()
