# FTSRG TDK paper template

The LaTeX template of the FTSRG advisors for a TDK paper at BME VIK, with the advisors' guide
built into the draft. The source of truth is the Overleaf project; this repository mirrors it
for browsing and for its CI. Students get an Overleaf project copied from it, and Overleaf's
GitHub sync creates their paper repository, which carries this CI.

- `thesis.tex` is the draft: the paper with its todos, beats, the Checks page and the guide.
  `reviewer.tex` builds the paper as the reviewer sees it; that is the PDF to upload.
- `content/` holds the chapters, the abstract, the glossary and the AI declaration; `guide/` the
  advisors' guide; `include/` the preamble; `bib/` the bibliographies; `docs/` the review sheet.
- `scripts/lint.lua` is the lint: `texlua scripts/lint.lua list` names its rules, `make check`
  runs them, and `.github/workflows/paper.yml` runs each as its own step on every push to main
  and on every pull request that is not a draft.
- `\lintphase` in `thesis.tex` is where you are in the lifecycle; checks come due by phase.

Sibling templates: [tdk-notes-template](https://github.com/BlackLight54/tdk-notes-template) for
the notes repository and [tdk-code-template](https://github.com/BlackLight54/tdk-code-template)
for the code repository. The guide, in the draft PDF after the appendices, explains all three.

Build locally with `make all` (draft) and `make reviewer`, in a TeX Live with XeLaTeX, Inkscape
and shell escape; `make check-reviewer` runs the lint on the reviewer build.
