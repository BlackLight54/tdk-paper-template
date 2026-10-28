# Working on this paper

This repository is a TDK paper built from the FTSRG template. The paper belongs to the student.
This file tells an agent how to build, check and change it, and where the rules are. Students
can read it too. The rules themselves are in the guide, which `thesis.tex` builds after the
paper's appendices; the table at the end points into it.

## Build and check

- `make all` builds the draft, `thesis.pdf`: the paper with its notes, the Checks page and the guide.
- `make reviewer` builds `reviewer.pdf`, the submission format, with no notes and no guide. On
  Overleaf, open `reviewer.tex` and choose *Recompile from this file*.
- `make check-reviewer` builds the reviewer PDF and runs every lint rule on it. CI
  (`.github/workflows/paper.yml`) judges this build. Prefer it to `make check`, which lints
  whatever was built last. `make check-submit` does the same at the `submit` phase whatever
  `\lintphase` says: the check before upload.
- `texlua scripts/lint.lua list` lists the rules with their severity and phase; `make lint-<rule>`
  runs one.
- The toolchain is TeX Live with XeLaTeX and shell escape, Inkscape for SVG figures, and
  poppler-utils for the PDF rules.

## The phase

`\lintphase` in `thesis.tex` is the student's phase in the lifecycle: `topic`, `setup`,
`research`, `plan`, `draft`, `polish` or `submit`. Checks become required as the phase
advances, and any other value stops the lint. Change it only when the student asks. The phases
and their steps are in `guide/02-lifecycle.tex` (`tab:lifecycle`).

## Files

- The student's: `content/` (chapters, abstract, glossary, AI declaration), `bib/references.bib`,
  `figures/`, `include/macros.tex` and `include/tdk-variables.tex`. `thesis.tex` is shared: the
  student sets the title, `\lintphase` and the chapter list; template updates change the rest.
- `bib/zotero.bib` comes from the Zotero group library through Overleaf, and *Refresh*
  overwrites it. Correct entries in Zotero, not in this file.
- The template's, replaced by template updates: `guide/`, the rest of `include/`, `scripts/`,
  `.github/`, `.claude/skills/`, `docs/`, `reviewer.tex`, `Makefile`, `tdkieee.bst`, `README.md`
  and this file.
- Generated, never edited by hand: `guide/essentials.tex`, `guide/guide.bbl`, `lint-checks.tex`
  and `scripts/lint/skeleton/`.
- Maintainer targets, never run in a paper repository: `make skeleton`, `make essentials` and
  `make guide-bib`. `make skeleton` would make the lint treat the student's text as the template's.
- Never commit build output such as PDFs, logs or `.aux` files; the `repo-hygiene` rule fails on it.
- The student edits on Overleaf, which syncs with this repository only when someone pulls or
  pushes from Overleaf's GitHub menu. After you push, the student pulls in Overleaf before
  editing there.

## Changing the student's text

- The person running you decides what you may change in their own text.
- In a template update, apply only named mechanical changes, such as a renamed macro. Show every
  other deletion or rewrite for review instead of applying it.
- Keep the notes. `\todo` (orange) is for the student, `\advisortodo` (blue) for the advisors, and
  `\atodo` (green) is an advisor's review comment that the student resolves and then deletes.
- Mark a gap with `\tbd{...}` or `\citeneeded[...]`, never with a typed TBD, [CITE] or XXX.
- Check every source you suggest before it is cited. By the advisors' rule, an AI answer never goes in the
  bibliography; it goes in the AI declaration (`guide/04-writing.tex`, `app:writing:ai`).

## Markup the lint reads

- Chapters are found by their labels, such as `ch:intro` and `ch:conclusion`, not by file name.
- Tagged lists and their label prefixes: `requirements` (`req:`), `derivedrequirements` (`dr:`),
  `contributions` (`c:`), `threats` (`thr:`), `assumptions` (`asm:`), `guarantees` (`g:`),
  `rqlist` (`rq:`) and `limitations` (`lim:`).
- Abbreviations, symbols and terms go through `\gls` (`guide/09-latex-template.tex`, `app:latex:acro`).

## Where the guidance is

| To find | Look in |
| --- | --- |
| Where to start, by situation | `guide/00-start-here.tex` (`app:here`) |
| What each chapter must contain, with a worked example | `guide/05-chapter-by-chapter.tex` (`app:chapters`) |
| The elements the lint measures in every paper | `guide/04-writing.tex` (`app:writing:essentials`) |
| What must hold before upload | `guide/02-lifecycle.tex` (`tab:polish`) |
| What each lint rule checks | `guide/07-code-tools-checks.tex` (`app:code:paperci`) |
| Reviewer passes and self-score | `guide/07-code-tools-checks.tex` (`app:lifecycle:reviewers`) |
| AI use and the declaration | `guide/04-writing.tex` (`app:writing:ai`) |
| The faculty's dates, form rules and review sheet | `guide/06-tdk-rules-and-dates.tex` (`app:tdk`) |
| LaTeX syntax: notes, glossary, citations, figures, listings | `guide/09-latex-template.tex` (`app:latex`) |
