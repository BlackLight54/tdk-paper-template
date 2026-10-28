# Skim view

The template is built so that a reviewer can give the maximum score after skimming: the outline,
the figures, the tagged items (C1, REQ1, AS1, SG1, ADV1, DR1, RQ1, LIM1) and the coloured boxes.
`skim.py` shows a paper the way that reviewer sees it: those parts verbatim, everything else as
counts. The skim persona reads only `skim.md` and the images in `assets/`, and scores the paper
against the review sheet. The formats it exchanges with the lint, the CI and the review runner are
fixed in `scripts/review/README.md`; this file explains how the skim reads a paper and where it is
weak.

## Run it

Build the reviewer PDF and the lint's export first, then skim the build. From the paper
repository:

```fish
make reviewer
texlua scripts/lint.lua all --doc reviewer --json > lint.json
uv run scripts/skim/skim.py build . -o /tmp/skim/my-paper
uv run scripts/skim/skim.py build . -o /tmp/skim/my-paper --debug   # also debug/page-NNN.png
```

`uv run` reads the one dependency, PyMuPDF, from the script's header. CI runs
`pip install pymupdf` and `python3 scripts/skim/skim.py` instead; the script needs nothing else.

Without a local TeX Live, use the image CI uses:

```fish
docker run --rm -u (id -u):(id -g) -e HOME=/tmp -e LINT_OFFLINE=1 -v $PWD:/w -w /w tdk-texlive-ci \
    texlua scripts/lint.lua all --doc reviewer --json > lint.json
```

`build` takes the built paper directory: `reviewer.pdf` (else `thesis.pdf`, with a warning in the
view) with its `.aux`, `.toc`, `.log` and `.bbl`. It writes `skim.md`, `skim.html`, `skim.json` and
`assets/` into the output directory and prints one line with the cross-check counts (PDF/sources),
the unsure items and the visible placeholders. Everything it reads is inside the paper
repository:

| input | default | option |
|---|---|---|
| the review sheet's criteria | `guide/06-tdk-rules-and-dates.tex`, section "The review sheet" | `--guide` |
| every band of the sheet | `docs/TDK2025_biralati_pontozolap_hallgatoi.pdf` | `--sheet` |
| chapter roles and tag lists | `lint.json`, else `texlua scripts/lint.lua chapters --json` | `--lint` |

It exits 1 when it cannot read the build: no PDF, a PDF it cannot open, an `.aux` without labels,
a `.toc` without link targets, or a `--lint` file that is missing or not JSON. It exits 0 whenever
it wrote a view, however incomplete the paper is. A missing guide, sheet or lint export is a note
at the top of the view, not a failure.

### Where the chapter map and the tags come from

The lint's export (`scripts/review/README.md`, "What the lint exports") is the only source:

- `chapter_roles` gives each role its criteria and its files. Each included file's `.aux` writes
  the toc entries of the chapters it starts, so a role's files name its chapters. A chapter may
  have two roles, and a role may span chapters. The view lists, per criterion, the chapters that
  carry it and the role they carry it by. Criterion A belongs to the whole paper.
- `tag_lists` gives every list the paper declares with `\NewTagList`, the template's eight and
  the paper's own. The `.aux` names an item's list through its cleveref type (`assumptions`, or
  the counter `assumptionsi` of a `\tagrow`). An empty table serialises as `[]`; the skim accepts
  that.

Without an export the skim still writes a view, with a note at the top: no criterion is carried by
any chapter, roles come from the `ch:<role>` labels, and a tagged item is recognised by its printed
prefix only when two items share it.

## Evidence states

Every piece of evidence in the rubric map has one of four states:

| state | meaning |
|---|---|
| `detected` | The structure is in the PDF. This says nothing about whether it is good. |
| `placeholder` | Detected, but it shows template text. |
| `unsure` | The `.aux` or the sources declare it, but the skim could not read it from the PDF; or the build file that would say is missing (no `.bbl`: the bibliography's size is unknown, not zero). |
| `missing` | Neither the PDF nor the sources have it. |

Nothing is shown in green, because the skim checks nothing. Colour marks only `placeholder`
(orange), `unsure` (purple) and `missing` (red). A criterion whose rows are all placeholder,
unsure or missing has a red row in the HTML.

Template text is one of these phrases, wherever a reader sees it: `TODO` (also `\tbd`'s
`[TODO: ...]`), "Placeholder rows", "Placeholder data" and the like, "replace with your own",
todonotes' "Missing figure", and an illustration marked as such in its caption ("Illustrative
numbers ..."). The word "placeholder" alone is not enough, since papers use it in their own prose.
A structure that shows template text is `placeholder` on its own row: a contribution list whose
items read "TODO Short name", a leading figure captioned "TODO leading figure", a correctness table
with "Placeholder rows". In the view, such a structure carries `[placeholder: "TODO", ...]` in
`skim.md` and a dashed orange frame in `skim.html`, and the page grid fills it orange.

The summary counts the placeholders a reader can see: every block of the main text, the appendix
and the abstracts that shows template text (a heading, paragraph, tagged item, figure, table, box,
list, listing or theorem-like), plus each page of front matter, back matter (the AI declaration),
footnotes or margin notes that does. A table counts once, however many of its rows say TODO. The
summary also gives how often `TODO` is printed. The reviewer build hides todo notes, so they are
not counted there. A draft build prints them: each inline note counts, and each page with margin
notes counts once.

## Compare before and after

```fish
uv run scripts/skim/skim.py compare /tmp/skim/before /tmp/skim/after -o /tmp/skim/compare
```

`compare.html` has the metrics side by side with each change marked (blue better, red worse; for
the page count, closer to 30–35 is better), the rubric evidence of both, the items, floats and
boxes added or removed, and both skim views in two frames. It also reads `skim.json` files written
before the four states, whose evidence is ok, warn or missing.

## What the view shows

At the top: the summary, then the extraction notes, so that a reader knows where the view may be
wrong before reading it. The notes list first the unsure items with their pages, then the counts
that differ between the PDF and the sources, then the full cross-check table and the rest.

Kept verbatim: title, abstract (the Kivonat as "Kivonat, N lines"), the outline with page and
length in pages and text lines, every tagged item (tag, short name, text, its `\label` or the lack
of one, where it was read, how often it is referred to), theorem-like statements, every coloured
box, every figure (crop and caption) and table (thumbnail and caption). A tagged item kept in a
table row follows its table, with the row's cells after the short name, separated by `|`.

As counts: each paragraph as `¶ N lines`, with a run-in head (`\paragraph`) kept in bold and the
tags it refers to after it (`↗` clickable, `plain` typed by hand); display math, listings and lists
as `math, N lines`, `listing, N lines` and `list, N items` (description lists keep their bold
labels); footnotes in the summary.

Panels:
- **Rubric map**: each criterion from the guide's review-sheet section with every band from the
  sheet PDF; the chapters that carry it, from the lint's roles; and the evidence found in the
  skim, each row in one of the four states.
- **Page grid**: every page as a thumbnail, with the anchors outlined and template text filled.
- **Walls of text**: per chapter, the longest run with no heading, run-in head, figure, table, box,
  tagged item or theorem-like statement; math, lists and listings do not break a run. Over one page
  is flagged.
- **Argument chains**: guarantee → assumptions and adversaries it cites → row in the correctness
  table; requirement → row in the gap matrix → mentioned in the evaluation; contribution →
  mentioned in the conclusion; research question → mentioned in the evaluation or conclusion. Each
  edge is linked, plain (typed by hand) or missing. A guarantee kept in a table row cites what its
  row mentions.
- **Reference quality**: per kind, mentions that are links, links to something else, or plain text;
  items without `\label`, which cannot be linked; targets nothing links to or mentions; broken
  references (`??`, `[?]`, a link to a missing destination).

## How it reads the PDF, and where it is weak

Everything is read from the PDF the reviewer gets. The `.aux`, the `.toc`, the lint's export and
the sources give positions and cross-checks.

- **Outline**: from the `.toc`, placed by the hyperref named destinations; titles from the PDF
  bookmarks. Main-text pages follow the template lint: from the first numbered chapter to the page
  before the first unnumbered chapter after it.
- **Chapter roles**: from the lint's export, as above. A role whose file the build's `.aux` does
  not include gets a note.
- **Tagged items**: the `.aux` is the inventory. Every label whose cleveref type is a tag list has
  a printed tag and a link target, so the skim knows the page and the height of every item before
  it reads the PDF. A list item is matched to the paragraph or list item whose bold head starts
  with its tag, at its target. A `\tagrow` (its target is `<list>i.N`, never `Item.N`) is always
  read as a table row: the tag just below the target, then each cell, the columns told apart by
  where their lines start, down to the next row, the next table rule or the next tagged item. An
  item inside a figure, table or box is read the same way. A label whose tag the skim cannot find
  at its target is `unsure`, listed with its page at the top of the view; it is never reported
  as missing. A bold head without a label that starts with a tag some label prints ("RQ1 on the
  fixed vectors") is a run-in head about that item, not a second item. A prefix no list declares
  (Tamarin's H1–H3 and V1–V5) counts only when at least two items share it.
- **Figures and tables**: a bold caption label (`Figure 3.1:`) near the left margin, or a one-line
  caption centred on the column. The extent runs from the float's hyperref anchor (the top of the
  float) to the caption; for a table captioned above, down to the last booktabs rule before body
  text resumes. A table without horizontal rules is grown over the small-font lines below its
  caption and can come out too short or too long. Hungarian captions (`3.1. ábra`) are not
  recognised. A table continued on the next page without a caption is not a float. Its tagged rows
  are still read at their labels; the lines the skim would otherwise have taken for an item show
  as `table rows, N lines`.
- **Boxes**: a light tinted fill at least half the text width, or a coloured bar at the left of the
  column (tcolorbox `borderline west`, `framed`'s `\vrule`), with text inside; a box broken over a
  page is joined. Mostly monospace content is a listing, not a box. In a build without
  `reviewer.tex`, an untitled box is reported as a todo note. A box style with neither fill nor
  left bar would be missed; the cross-check would show it.
- **Theorem-like statements**: a bold `Definition|Theorem|Lemma|...|Invariant N.M` head. Only the
  first paragraph of the statement is kept; display math or a list inside it follows as counts.
- **Paragraphs**: lines grouped by the vertical gap (the English template sets `\parskip`), a short
  last line, or a change of kind. A paragraph broken by a page turn is joined; one interrupted by a
  float is not, which matches what the reader sees. Run-in heads come from the `.toc`
  (`\paragraph`), or from a short bold lead-in ending in `.`, `:` or `?`.
- **Display math**: a line set off from the margin and mostly in a math font, or carrying an
  equation number. **Listings**: mostly monospace lines.
- **Mentions and links**: every printed tag, `Figure N.M`, `Table N.M` and `Theorem N` is checked
  against the PDF's internal link annotations, whose named destinations resolve through the `.aux`
  to labels. A range (`AS1–AS3`) counts for each tag.
- **Chains**: the correctness table is `tab:correctness`, the gap matrix `tab:related`; without
  those labels, a table whose caption says "correct", or "gap matrix", "related work" or "closest
  approaches". A row means the tag appears in the table. "Restated in the conclusion" means the tag
  appears there; failing that, most words of the contribution's short name, shown as
  `by name (fuzzy)`. When the `.aux` has the label but no float was read for it, the row is
  `unsure`.
- **Scalability and robustness evidence**: by caption words only (`scal`, `robust`).
- **Template text**: by the phrases above. A student's own "TODO" counts, as it should; template
  text phrased otherwise ("Approach A", "Lorem" without "ipsum", an unmarked made-up number) does
  not.
- **Footnotes**: small lines under the footnote rule; counted, not shown.

Every skim cross-checks what the PDF gave against what the included sources declare: captioned
figures and tables, box environments (including the `\newtcolorbox` and framed environments a
paper defines), tag-list items, `\tagrow` rows and `\item[TAG...]` heads, theorem-like
environments, and the tag-list labels of the `.aux`. It also lists the undefined references and
citations in the LaTeX log and the lines no block claimed. On the six papers and the template of
2026-10-28 every count agrees and no item is unsure, except two Farkas rows: tables (15 in the PDF,
12 in the sources), because appendix tables come from no table environment, and theorem-likes (29
and 23), because statements are restated in the appendix.
