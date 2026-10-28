# Review runs: the contract

A review run reads one revision of the paper the way its reviewers will. Paper CI builds the
evidence on every push. An agent then runs the reviewer personas on the evidence of one named
commit. Each persona reads only its own inputs. When the run is recorded, its findings go into
one issue on the paper repository. This file fixes the formats those steps exchange. The skim
(`scripts/skim/`), the runner (`review.py`) and the CI (`.github/workflows/paper.yml`) are built
against it, so a change here comes first.

## The bundle

Every push to the paper repository uploads one Actions artifact, `review-<sha7>`, kept 14 days.
The commit SHA is the run's identity: the paper repository carries the template's scripts, so the
SHA also fixes the lint, the skim and the personas that ran. Two builds of one commit give PDFs
with different bytes, because XeLaTeX stamps the creation date, so a PDF hash identifies a
bundle, never a revision. When a bundle has expired, rerun the workflow of that commit.

```text
review-<sha7>/
  manifest.json      what ran, on what, with what result (below)
  thesis.pdf         the draft, with notes, Checks page and guide
  reviewer.pdf       what the reviewer gets
  logs/thesis.log    the LaTeX logs of both builds
  logs/reviewer.log
  lint.json          texlua scripts/lint.lua all --doc reviewer --json
  skim/skim.md       the skim view, the skim persona's only input
  skim/skim.html     the same for a human, with the panels
  skim/skim.json     for skim.py compare
  skim/assets/       figure crops, table thumbnails and page thumbnails
```

## manifest.json

```json
{
  "schema": 1,
  "repo": "BlackLight54/TDK26-Example",
  "sha": "<40 hex digits>",
  "ref": "main",
  "built": { "by": "ci", "run_url": "https://github.com/.../actions/runs/<id>", "run_attempt": 1 },
  "image": { "ref": "danteev/texlive:latest", "digest": "sha256:..." },
  "phase": "polish", "phase_source": "thesis.tex", "profile": "tdk",
  "builds": [
    { "doc": "thesis",   "engine": "xelatex", "latexmk_exit": 0, "errors": 0, "undefined": 0, "pages": 98 },
    { "doc": "reviewer", "engine": "xelatex", "latexmk_exit": 0, "errors": 0, "undefined": 0, "pages": 19 }
  ],
  "lint": { "exit": 1 },
  "skim": { "exit": 0 },
  "files": { "reviewer.pdf": "<sha256>", "skim/skim.md": "<sha256>", "...": "..." }
}
```

- `built.by` is `ci` or `local`. A local bundle has no `run_url` and names the host instead. It
  is evidence only when its source tree was clean, so `review.py bundle` refuses a dirty tree
  unless given `--allow-dirty`, and then writes `"dirty": true` into `built`.
- An exit that was not passed to `review.py bundle` (`--exit lint=N`, `--exit skim=N`) is `null`,
  never a made-up 0; so are `image.ref` and `image.digest` when not given. CI passes them all.
- `image.digest` is the digest that actually ran. CI uses `latest` on purpose; the digest is how a
  later reader knows which TeX Live built the PDFs.
- `builds[].errors` counts `! ` lines in the log, and `undefined` counts undefined references
  and citations. A build with `latexmk_exit` other than 0 is a failed build even when it produced
  a PDF; the PDF stays in the bundle for diagnosis.
- `files` holds the SHA-256 of every file in the bundle except the manifest. `review.py fetch`
  refuses a bundle whose files do not match.

## What the lint exports

`texlua scripts/lint.lua <rules> --json` prints one JSON document. The skim reads three parts of
it besides the rule results and findings:

- `chapter_roles`: for each of the seven chapter roles (intro, background, approach,
  implementation, evaluation, related, conclusion) its label, its name, the review-sheet criteria
  it carries, the guide section that explains it and the paper's chapters that have it:
  `{"approach": {"label": "ch:approach", "name": "approach chapter", "criteria": ["D/1", "D/2"], "guide": "app:chapters:approach", "files": ["content/03-approach.tex"]}}`.
  The table lives in `scripts/lint/lintcore.lua` (`ROLE_CRITERIA`), beside the role labels.
  Criterion A is scored on the whole paper and belongs to no role. `texlua scripts/lint.lua
  criteria`, a template-only CI step, fails when the bold `\textbf{Criteri...}` heads of a role's
  section in `guide/chapter-by-chapter.tex` name other criteria. (`roles`, role → files, stays as
  it was for `work/essentials-labels.py`.)
- `tag_lists`: every tag list the paper declares with `\NewTagList{<environment>}{<tag>}{<Name>}{<Names>}`,
  the template's eight and any the paper adds:
  `{"contributions": {"tag": "C", "name": "Contribution"}, "assumptions": {"tag": "AS", "name": "Assumption"}, ...}`.
  The `.aux` names an item's list through its cleveref type, so the skim needs no letters of
  its own.
- `rows`: the essentials, as before, each with its `criterion`.

## What the skim reports

The skim reads the reviewer PDF with its `.aux` and `.toc`, and `lint.json` for the roles and
tags above. It never reaches outside the paper repository. Every piece of evidence it reports has
exactly one of four states:

| State | Meaning |
|---|---|
| `detected` | The structure is in the PDF. This says nothing about whether it is good. |
| `placeholder` | Detected, but it shows template text: TODO, a placeholder figure or table, "replace with your own", an illustration marked as such. |
| `unsure` | The source or the `.aux` declares it, but the skim could not read it from the PDF. This is an extraction gap, not missing text. |
| `missing` | Neither the PDF nor the sources have it. |

No state is shown in green, because the skim checks nothing; colour marks only `placeholder`,
`unsure` and `missing`. A tagged item is found through the `.aux`: every label of a tag list
(including `\tagrow` rows of a table) has a page there, and the skim reads the printed item or
table row on that page. A label the skim cannot read on its page is `unsure`, listed with the page
at the top of the view. The summary counts the placeholders a reader can see, not the todo notes
the reviewer build hides.

## Persona inputs

A persona's `reads` field names what it may see. `review.py inputs` copies exactly those into a
fresh directory per persona, outside every repository:

| `reads` | Copied from |
|---|---|
| `reviewer-pdf` | `reviewer.pdf` of the bundle |
| `skim-view` | `skim/skim.md` and `skim/assets/` of the bundle |
| `spine` | the file given with `--spine`; without one, the persona is told there is no spine and judges overclaiming against the abstract and the introduction |

Nothing else enters: no earlier findings, no issues, no sources, no other persona's output. The
SHA-256 of every input file goes into the record.

## findings.json

The skill collects the personas' answers into one file for `review.py record`:

```json
{
  "sha": "<40 hex digits>",
  "bundle": "review-<sha7>",
  "mode": "draft",
  "panel": ["skim", "out-of-field", "reviewer-two", "champion", "cryptographer"],
  "skipped": { "process-modeling": "no BPMN or behavioural diagram in the contents" },
  "inputs": { "cryptographer": { "reviewer.pdf": "<sha256>" } },
  "model": "claude-opus-5-5",
  "scores": { "A": [4, 5], "B/1": [3, 4], "B/2": [2, 4], "C": [7, 8], "D/1": [3, 5], "D/2": [3, 5], "E": [5, 8] },
  "findings": [
    { "id": "F1", "persona": "cryptographer", "criterion": "D/2", "severity": "blocker",
      "where": "p. 14 \"the verifier learns nothing\"", "objection": "...", "answer": "..." }
  ]
}
```

`scores` holds the skim persona's score and maximum per criterion; it is absent when the skim
pass did not run. `mode` is `premortem` (a spine, no draft) or `draft`.

## The record

`inputs` may be left out of findings.json: `record --inputs inputs.json` takes the hashes from the
saved output of `review.py inputs`, and an `inputs` field in findings.json wins over it.

`review.py record findings.json --bundle <dir> [--inputs inputs.json]` verifies the bundle again,
checks that its manifest names the commit findings.json names and that the persona input hashes
are the bundle's, and opens one issue on the paper repository (the manifest's `repo` unless
`--repo` says otherwise), titled
`Review <YYYY-MM-DD> <sha7>`. Its body has the panel, the skim scores, one task-list entry per
finding (`F1 cryptographer · D/2 · blocker · p. 14 "...": objection. Answer: ...`), the manifest
and the persona input hashes in collapsed blocks, and a link to the CI run that holds the
bundle. Nothing is written into any repository.

The student proposes a disposition per finding in a comment: `F3 fixed in <sha>`,
`F4 rejected: <reason>` or `F5 deferred`. The advisor confirms them with the `review-confirmed`
label. The next blind run never sees the issue: its personas read only the inputs above.

Recorded runs are the advisor's milestones (the spine premortem, the full draft, before upload)
and any run a student chooses to record. Without `record`, the skill answers in chat and writes
nothing.
