# FTSRG TDK paper template

This is the FTSRG advisors' LaTeX template for a TDK paper at BME VIK. The advisors'
guide is included in the draft PDF. **This repository is the canonical source.** The
template's Overleaf project is synced with it through Overleaf's GitHub integration.
Students receive a copy of that Overleaf project; its GitHub integration creates each
student's paper repository, including the build and lint workflow.

- `thesis.tex` builds the draft with notes, the Checks page and the guide.
  The chapter files contain headings, stubs and notes linking to
  "The paper, chapter by chapter" in `guide/chapter-by-chapter.tex`, where the
  instructions and worked examples live. `reviewer.tex` builds the submission-format PDF;
  the final checks and advisor review determine whether it is ready to upload.
- `content/` holds the chapters, abstract, glossary and AI declaration; `guide/` holds
  the advisors' guide; `include/` the preamble; `bib/` the bibliographies; and `docs/`
  the review sheet.
- `scripts/lint.lua` checks the paper. `texlua scripts/lint.lua list` lists the rules,
  and `make check` runs them. `.github/workflows/paper.yml` runs each rule as a
  separate step on every push to main and every pull request that is not a draft.
- Set `\lintphase` in `thesis.tex` to your current lifecycle phase. Checks become
  required as you reach each phase.

The companion templates are [tdk-notes-template](https://github.com/BlackLight54/tdk-notes-template)
for the notes repository and [tdk-code-template](https://github.com/BlackLight54/tdk-code-template)
for the code repository. The guide explains all three after the draft's appendices.

Build locally with `make all` for the draft and `make reviewer` for the reviewer PDF.
Use TeX Live with XeLaTeX, Inkscape and shell escape enabled.
`make check-reviewer` runs the lint on the reviewer build, and `make check-final` runs it
at the final phase: the check before you upload.
