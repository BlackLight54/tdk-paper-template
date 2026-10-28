---
name: self-score
description: Score the TDK paper's reviewer PDF, as built by CI for one commit, on the faculty review sheet's criteria A-E in the sheet's own words, name the weakest criterion and the cheapest fix. Use before a consultation, in the polish phase, or when the student asks "how would this score". Writes nothing to the repository.
---

# Self-score

Score the reviewer PDF the way the TDK reviewer will, on the review sheet in
`docs/TDK2025_biralati_pontozolap_hallgatoi.pdf`. The sheet has five criteria and 35 points:
A form and style 0-5, B figures and literature 0-4 (average of B/1 and B/2), C topic 0-8,
D originality and soundness 0-10 (D/1 novelty 0-5 plus D/2 correctness 0-5), E introduction and
evaluation 0-8. The guide's "TDK rules and dates" chapter (`guide/06-tdk-rules-and-dates.tex`, `app:tdk:sheet`)
quotes the top of every scale.

## Procedure

1. Take the reviewer PDF from the CI bundle of one named commit, the pushed `HEAD` unless the
   student names another: `python3 scripts/review/review.py fetch --repo <owner/name> --sha <sha>`
   prints the bundle directory, and `reviewer.pdf` is in it. `fetch` verifies the bundle; when it
   refuses, say why and stop. Never score `thesis.pdf`, the draft with the notes in it.
2. Read the whole PDF once as a reader, then once per criterion.
3. For each criterion, give the score and the sheet's own sentence that fits, then the evidence:
   page numbers, a quoted phrase, a figure or table number. No evidence, no score.
4. Name the weakest criterion and the single cheapest change that would raise it, with where it
   goes. Then the second cheapest.

## Output

Chat only, in this shape, nothing else:

```
A  4/5  "jól tagolt, követhető" except: <evidence>
B  3/4  B/1 <score> <evidence>; B/2 <score> <evidence>
C  7/8  <evidence>
D  7/10 D/1 <score> <evidence>; D/2 <score> <evidence>
E  5/8  <evidence>
Total 26/35

Weakest: E. Cheapest fix: <one change, where>.
Second: <one change, where>.
```

Do not write files, do not edit the paper, do not soften a score because the author is in the
room. The consultation recording is the record.

## Reviewer personas

Objections from particular readers, such as the cryptographer or the skim reviewer, are the
`reviewer-passes` skill's job, not this one's.
