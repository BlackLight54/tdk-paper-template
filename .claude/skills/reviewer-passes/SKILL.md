---
name: reviewer-passes
description: Read the TDK paper the way its reviewers will, before they do, on the CI bundle of one named commit. The skim reviewer reads the skim view, and a panel of disjoint expert personas reads the reviewer PDF, each owning one slice of the paper. Answers in chat and writes nothing, unless asked to record the run as one issue. Use on the spine as the premortem, on the draft before the full draft goes to the advisors, as a hill climb in the polish phase, or when the student asks "what would the cryptographer say".
---

# Reviewer passes

Two reviewers read a TDK paper in an evening each, and a section jury that is mostly out of field
hears the talk. A pass is one reading by one simulated reader with a narrow brief. Passes are cheap,
so run them early and repeat them. A persona is not a reviewer, though: it misses things and invents
things, and what it produces is a list of objections to check, not a score.

## The panel

Each file in `personas/` is one reader. They are disjoint: every concern of the paper has exactly
one owner, so an objection comes back once and has one place to be answered.

| Persona | Owns | Runs when |
|---|---|---|
| `skim` | whether the skim view alone earns the maximum on every criterion | always |
| `out-of-field` | the problem, the terms, the leading figure and the conclusion, read by a non-specialist | always |
| `reviewer-two` | novelty, the gap matrix, the positioning figure, the literature | always |
| `champion` | results reported weaker than the evidence allows | always |
| `mean-mathematician` | definitions, notation, theorem statements, pen-and-paper proofs | definitions, theorems or proofs |
| `formal-methods` | what a formal model leaves out, what its properties say, and what its tool trusts | a model checker, prover or formal semantics |
| `cryptographer` | the adversary in the model, primitives, security definitions | cryptography, credentials, privacy claims |
| `systems-modeling` | the metamodel or system model, the modelling language, traceability | a metamodel, DSL, system or architecture model |
| `distributed-systems` | timing and fault models, safety and liveness, the robustness scenarios | more than one node: ledgers, consensus, replication, clocks |
| `network-security` | attacks outside the model: network, keys, deployment, metadata | anything deployed: networks, smart contracts, keys |
| `process-modeling` | BPMN and other behavioural models: notation, soundness, exception paths | BPMN, workflow, choreography, sequence or state diagrams |
| `empiricist` | how the evaluation measures: setup, baselines, repetitions, reproducibility | any measurement or tool evaluation |

Five rules draw the borders between them.

- Inside the formal model or outside it. The cryptographer and the formal methods expert own what
  is proven in the model; the networking and cybersecurity expert owns what happens outside it.
- On paper or in a tool. The mean mathematician owns pen-and-paper proofs; the formal methods
  expert owns machine-checked ones.
- Structure or behaviour. The systems modeling expert owns the structure of the system; the process
  modeling expert owns its behaviour.
- Which faults and scales, or how they are measured. The distributed systems expert owns the first;
  the empiricist owns the second.
- Claiming too much or too little. Every persona checks overclaiming in its own slice; only the
  champion checks underclaiming.

## Inputs

A persona's `reads` field lists what it may see. Hand it nothing else. All of it comes from the CI
bundle of one commit (`scripts/review/README.md` describes the bundle).

- `reviewer-pdf` is `reviewer.pdf` of the bundle, built by CI from `reviewer.tex`. The bundle also
  holds `thesis.pdf`, the draft with the notes in it; no persona reads that.
- `skim-view` is `skim/skim.md` and `skim/assets/` of the bundle: the reviewer PDF reduced to what a
  skimmer sees.
- `spine` is a file the student names, usually `notes/anchors/spine.md` in their notes repository.
  It is optional. Overclaiming is judged against the claims and the scope agreed there, not against
  taste. Without a spine the persona judges overclaiming against the abstract and the introduction.

## Procedure

1. Name the commit: the one the student names, otherwise `git rev-parse HEAD`, which must be
   pushed, because CI builds on push. Fetch its bundle, with the repository as `<owner/name>`:

   ```
   python3 scripts/review/review.py fetch --repo <owner/name> --sha <sha>
   ```

   It prints the directory of the verified bundle. When it refuses, because a hash does not match,
   the run is missing or the artifact has expired, say what it printed and stop. Do not review a
   bundle that did not verify, and do not build a PDF locally in its place.
2. Decide the mode. When the student has a spine and the chapters are still template text, this is
   the premortem: each persona predicts its likeliest objections against the spine's claims, and
   `where` cites the claim. Once a draft exists, every finding points at a page of the reviewer PDF.
3. Pick the panel: the four that always run, plus every persona whose "runs when" the paper meets,
   judged from the abstract and the table of contents. A persona the student names runs regardless.
4. Build the inputs, one directory per persona, with the spine file when there is one. Save the
   output in a temporary directory outside the repository (`mktemp -d`):

   ```
   python3 scripts/review/review.py inputs <bundle-dir> <persona>... [--spine FILE] > <tmp>/inputs.json
   ```

   `inputs.json` maps each persona to its directory, the SHA-256 of each file in it, and whether a
   spine is in it.
5. Run each persona apart from the others. Where the agent has subagents, use one per persona, in
   parallel; otherwise run them one after another and reread the persona file each time. Give a
   subagent the text of its persona file and the path of its input directory, and tell it to read
   no file outside that directory. Where a persona lists `spine` in `reads` and its entry has
   `"spine": false`, also tell it: there is no spine; judge overclaiming against the abstract and
   the introduction. No persona sees another's findings, the bundle's other files, or the
   repository.
6. Each persona returns its findings in the persona format below. They stay in the conversation.
7. Answer in the chat format below. Do not merge or reword findings. When two personas raised the
   same point, or one argued outside its slice, say so under borders: the persona files need
   fixing, not the finding.
8. When the student asks what else a persona found, give its other findings from step 6. Do not
   run it again.

## Record mode

The default is the chat answer, which writes nothing. Record the run only when asked to: the
advisor records at three milestones (the spine premortem, the full draft, before upload), and a
student may choose to record any run. A recorded run becomes one issue on the paper repository. Wait
until every persona has returned, then:

1. Write `findings.json` next to `inputs.json`. Its fields are in `scripts/review/README.md`:
   `sha`, `bundle`, `mode`, `panel`, `skipped`, `model`, `scores` and `findings`. Leave `inputs`
   out; `record` takes the hashes from `inputs.json`.
2. Put every finding of every persona in `findings`, not only the worst one, numbered `F1`, `F2`, ...
   in the order of the chat answer. Copy the persona's words. For the skim persona, `where` is its
   location, `objection` its issue and `answer` its suggested fix, and `scores` holds its score and
   maximum for each of A, B/1, B/2, C, D/1, D/2 and E. Leave `scores` out when the skim pass did
   not run.
3. Run `python3 scripts/review/review.py record findings.json --bundle <bundle-dir> --inputs inputs.json`.
   Add `--dry-run` first when the student wants to read the issue before it is filed. Give the
   student the issue URL it prints.

`record` files the issue and nothing else. Do not write findings.json or anything else into the
repository, and do not edit the paper. The student proposes a disposition per finding in a comment,
and the advisor confirms them with the `review-confirmed` label; the skill has no part in that.

## Persona format

The skim persona has its own format, in its file. Every other persona returns this:

```
<Persona>
1. <the objection in one line>
   severity: blocker | major | minor
   criterion: A | B/1 | B/2 | C | D/1 | D/2 | E
   where: page and label, or a quoted phrase
   answer: the cheapest change that closes it and where it goes, or the sentence in the
   limitations that concedes it
2. ...
Handed on: one line per thing noticed outside this slice, each with its owner.
```

At most three findings, most costly first. A blocker costs the top band of a criterion on the review
sheet (`docs/TDK2025_biralati_pontozolap_hallgatoi.pdf`), a major finding costs a point, and
a minor one costs only the reviewer's goodwill. A persona with nothing above minor says so in one
line and does not pad.

## Chat format

Chat only, in this shape, nothing else:

```
Panel: <personas run>. Skipped: <persona: reason>, ...
Skim: <the skim reviewer's score per criterion, or "not run: <why>">

cryptographer       D/2 blocker  p. 14 "<phrase>": <worst objection>. Answer: <change, where>.
out-of-field        C   major    p. 2: <worst objection>. Answer: <change, where>.
<one line per persona that ran, its worst finding, blockers first, then by criterion A to E>

Cheapest three: <change, where>; <change, where>; <change, where>.
Borders: <none, or which personas overlapped>.
```

## Rules

- Without a request to record, the skill writes nothing into the repository: no file, no review
  folder, no edit to the paper. The student decides what to fix, and the consultation is the
  record. The bundle and the persona directories live in temporary directories outside it.
- There is no memory between runs; the paper is the state. Never read or compare earlier runs, and
  never read earlier issues, recorded or not. Recording a run does not change this: a persona
  reads only its inputs, so a finding that was fixed does not come back, and one that was not fixed
  is found again.
- A finding that does not point at a page, a label or a quoted phrase is dropped.
- A persona names a paper or a system only after opening it and checking that it exists and says
  what is claimed. When it suspects a neighbour but cannot find one, it writes "search for <what>".
- Do not soften a finding because the author is in the room. Only the skim persona gives scores, and
  only for what the skim view shows; the self-score skill scores the reviewer PDF.
