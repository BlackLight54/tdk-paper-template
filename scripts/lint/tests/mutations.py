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


GAP = r"""\begin{table}[!ht]
  \centering
  \caption{The closest approaches against the requirements: only this work meets all three, each backed by an evaluation result.}
  \label{tab:related}
  \begin{tabularx}{\linewidth}{l X c c c}
    \toprule
    & \textbf{Requirement} & \makecell{\textbf{Ledger audit}\\\cite{lamport1978time}} & \makecell{\textbf{Status lists}\\\cite{w3c2025vcdm}} & \textbf{This work} \\
    \midrule
    \ref{req:first}  & Fast revocation & \gapyes & \gappartial & \gapyes\,(\cref{rq:correct}) \\
    \ref{req:second} & Unlinkable checks & \gapno & \gapyes & \gapyes\,(\cref{rq:scale}) \\
    \ref{req:third}  & Auditable history & \gappartial & \gapno & \gapyes\,(\cref{rq:robust}) \\
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
    ("this work without a result pointer", "essentials", both(filled_gap, sub("content/06-related-work.tex", "\\gapyes\\,(\\cref{rq:scale})", "\\gapyes")), "points at no evaluation result"),
    ("guarantee not in the correctness table", "essentials", both(own_items("content/03-approach.tex", "g"), drop_line("content/05-evaluation.tex", "\\ref{g:example} &")), "g:example is not checked in the evaluation"),
    ("contribution not restated", "essentials", own_items("content/01-introduction.tex", "c"), "c:method is not restated"),
    ("a restated contribution", "essentials", both(own_items("content/01-introduction.tex", "c"), append("content/07-conclusion.tex", "\\Cref{c:method} holds in every run.")), "!c:method is not restated"),
    ("this work misses a requirement", "essentials", both(filled_gap, sub("content/06-related-work.tex", "\\gapyes\\,(\\cref{rq:correct})", "\\gapno")), "this work does not meet"),
    ("another approach meets everything", "essentials", both(filled_gap, sub("content/06-related-work.tex", "Unlinkable checks & \\gapno", "Unlinkable checks & \\gapyes"),
        sub("content/06-related-work.tex", "Auditable history & \\gappartial", "Auditable history & \\gapyes")), "meets every requirement"),
    ("a filled gap matrix is used", "essentials", filled_gap, "!Gap matrix\n    help:"),
    ("a float without its label is missing", "essentials", drop_line("content/06-related-work.tex", "\\label{fig:positioning}"), "○ Positioning figure"),
    ("text below the threshold is started", "essentials", replace_line("content/01-introduction.tex", CONTEXT, words(15)), "◑ Context\n    help: 14 own words"),
    ("text above the threshold is written and enough", "essentials", replace_line("content/01-introduction.tex", CONTEXT, words(50)), "intro ●◔◔◔◔◔◔"),
    ("some items own is started", "essentials", both(three_reqs, own_items("content/01-introduction.tex", "req", only="req:first")), "◑ Requirements\n    help: 1 of 3 items written"),
    ("an own figure with a TODO caption is started", "essentials", replace_line("content/03-approach.tex", "\\missingfigure[figheight=2cm]{Architecture:",
        "  \\begin{tikzpicture}\\node[draw] (h) {Holder}; \\node[draw, right=of h] {Registry};\\end{tikzpicture}"), "◑ Architecture figure\n    help: the caption is still a TODO"),
    ("a section found by its heading", "essentials", sub("content/05-evaluation.tex", "\\section{Threats to validity}\\label{sec:validity}", "\\section{Threats to validity}"), "add \\label{sec:validity}"),
    ("a written setup without the artifact's DOI", "essentials", replace_line(EVAL, SETUP, words(120)), "◕ Setup and artifact\n    help: cite the archived artifact"),
    ("a written setup with the artifact's DOI", "essentials", both(replace_line(EVAL, SETUP, words(120) + " The code is archived~\\cite{artifact}."), ZENODO), "!Setup and artifact\n    help:"),
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
        lambda d: [(f).write_text(f.read_text().replace("{runningexample}", "{cvd}")) for f in (d / "content").glob("0[1-7]-*.tex")]), "!Running example\n    help:"),
    ("hyphen range", "typography", append(BG, "This holds for pages 12-18 of the book."), "with a hyphen"),
    ("a name is not a range", "typography", append(BG, "The curve BLS12-381 on an i7-9750H."), "!range 12-381"),
    ("two chapters in one file", "chapters", append(BG, "\\chapter{Second}\nMore text."), "a second chapter in one file"),
    ("a file nothing includes", "orphans", lambda d: (d / "content/notes.tex").write_text("Some notes the author forgot to include in a chapter.\n"), "included nowhere"),
    ("own prose ends a stub", "stubs", append(BG, " ".join(["Own words of the author, written for this chapter."] * 25)), "!content/02-background.tex:1: FAIL"),
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
    ("a misspelt title", "spelling", sub("thesis.tex", "\\newcommand{\\vikcim}{TODO Title of the paper}", "\\newcommand{\\vikcim}{Revocation and revovation of credentials}"), "revovation"),
]


ARGS = "--doc reviewer --phase submit"


def lint(d, rule, args=ARGS):
    """The rule's output and exit. args starting with a subcommand (overleaf, all) replace the rule."""
    cmd = args if args.split()[0] in ("overleaf", "all", "source") else f"{rule} {args}"
    if shutil.which("texlua"):
        r = subprocess.run(["sh", "-c", f"LINT_OFFLINE=1 texlua scripts/lint.lua {cmd} 2>&1"], cwd=d, text=True, capture_output=True)
    else:
        r = subprocess.run(["docker", "run", "--rm", "-u", f"{os.getuid()}:{os.getgid()}", "-e", "HOME=/tmp", "-v", f"{d}:/w", "-w", "/w", IMAGE,
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
                baseline[rule, args] = lint(base, rule, args)
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
        out, code = lint(d, rule, args)
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
