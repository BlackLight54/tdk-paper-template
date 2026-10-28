-- The essentials: the elements every paper of this kind contains, in reading order. The
-- essentials rule (rules-essentials.lua) finds each in the paper and places it on a five-level
-- ladder; the Checks page, the CI job summary and the guide's reference section
-- (`make essentials`) are all printed from this list, so a row changes here and nowhere else.
--
-- Fields:
--   id, role         the row's name and the chapter role it belongs to (front: the abstract file)
--   title, criterion the name printed on the page, and the review-sheet criterion it earns
--   why              one line for a reader new to the method: what it is and why it is asked for
--   kind             text (a paragraph or section), tags (a tagged list), float (a figure or
--                    table), example (the running example), front (the two abstracts)
--   key              text rows: the canonical label is <prefix>:<key>, prefix par, sec or subsec
--   label            the canonical label the template carries (text and float rows)
--   prefix           tags rows: the label prefix of the list's items
--   headings         text rows: words of a heading that also find the row when it has no label
--   words            text and front rows: own words that make the row written
--   used             when the row is used where the argument needs it; empty when written is enough
--   add              the next step when the row is missing
--   example          the label of the row in action in the guide (guide/05-chapter-by-chapter.tex, or
--                    the abstract's section); `make essentials` fails when no guide file defines it
-- A paper that misses a row gets it from the template's own chapter files: work/essentials-labels.py
-- cuts the row's block out of them, so the skeleton is written once, in content/.
return {
  { id = "abstract", role = "front", kind = "front", title = "Abstract and Kivonat", criterion = "E", example = "app:writing:abstract", words = 100,
    why = "the paper in one paragraph, in English and in Hungarian; the reviewer reads it first and the registration carries it",
    add = "add content/00-abstract.tex with \\chapter*{Kivonat} and \\chapter*{Abstract}" },

  { id = "context", role = "intro", kind = "text", title = "Context", criterion = "C, E", example = "app:chapters:context", key = "context", label = "par:context",
    headings = { "context", "motivation" }, words = 40,
    why = "why the topic matters now: a trend, a regulation or an incident, cited; relevance is scored in C",
    add = "add a paragraph \\paragraph{Context.}\\label{par:context} to the introduction" },

  { id = "problem", role = "intro", kind = "text", title = "Problem statement", criterion = "E", example = "app:chapters:problem", key = "problem", label = "par:problem",
    headings = { "problem" }, words = 40,
    why = "the concrete problem, ending in a one-sentence statement; the sheet's E names the problem statement as a must",
    add = "add a paragraph \\paragraph{Problem.}\\label{par:problem} to the introduction" },

  { id = "example", role = "intro", kind = "example", title = "Running example", criterion = "A", example = "app:chapters:problem",
    why = "one small scenario, named once in thesis.tex (\\exname) and revisited in a box in every chapter, so the reader can follow each step",
    used = "an example box in every main chapter",
    add = "add a running-example box to the introduction and name the example with \\exname in thesis.tex" },

  { id = "requirements", role = "intro", kind = "tags", title = "Requirements", criterion = "D/1", example = "app:chapters:requirements", prefix = "req",
    why = "what a solution must do, one checkable item each; they are the rows of the gap matrix and the yardstick of the evaluation",
    used = "each requirement is referenced in the related work and in the evaluation, and each derived requirement (dr:) in the evaluation",
    add = "add a requirements list (\\begin{requirements}, items labelled req:)" },

  { id = "introgap", role = "intro", kind = "text", title = "Gap, in brief", criterion = "D/1", example = "app:chapters:introgap", key = "gap", label = "par:gap",
    headings = { "gap" }, words = 40,
    why = "that no existing approach meets the requirements together; the novelty claim, made before the full comparison",
    used = "it points to the full comparison: the related-work chapter, the gap matrix or the positioning figure",
    add = "add a paragraph \\paragraph{Gap.}\\label{par:gap} to the introduction" },

  { id = "overview", role = "intro", kind = "float", title = "Leading figure", criterion = "B/1", example = "fig:guide:overview", label = "fig:overview",
    why = "the problem, the contributions and the headline result in one picture; the reviewer looks here first",
    used = "it is referenced from the text",
    add = "add the leading figure, \\label{fig:overview}, to the introduction" },

  { id = "contributions", role = "intro", kind = "tags", title = "Contributions", criterion = "E", example = "app:chapters:contributions", prefix = "c",
    why = "what this work claims, as checkable items; the sheet's E names stating the main contribution as a must",
    used = "each contribution points to the chapter that delivers it and is referenced in the conclusion",
    add = "add a contributions list (\\begin{contributions}, items labelled c:)" },

  { id = "architecture", role = "approach", kind = "float", title = "Architecture figure", criterion = "B/1", example = "fig:guide:architecture", label = "fig:architecture",
    why = "the approach end to end, with what is yours set apart from what is reused",
    used = "it is referenced from the text",
    add = "add an architecture figure, \\label{fig:architecture}, to the approach" },

  { id = "threats", role = "approach", kind = "tags", title = "Threats", criterion = "D/2", example = "app:chapters:adversary", prefix = "thr",
    why = "who the adversary is and what it can do; a reviewer of a security topic looks for it first",
    used = "each threat is referenced in the approach, where a guarantee or an assumption meets it",
    add = "add a threats list (\\begin{threats}, items labelled thr:)" },

  { id = "assumptions", role = "approach", kind = "tags", title = "Assumptions", criterion = "D/2", example = "app:chapters:assumptions", prefix = "asm",
    why = "who is trusted and which properties the guarantees rest on, stated so a reviewer can check them",
    used = "each assumption is referenced in the approach, by a guarantee or a proof",
    add = "add an assumptions list (\\begin{assumptions}, items labelled asm:)" },

  { id = "guarantees", role = "approach", kind = "tags", title = "Guarantees", criterion = "D/2", example = "app:chapters:guarantees", prefix = "g",
    why = "what the approach guarantees under the assumptions, against the threats; each is what the evaluation checks",
    used = "each guarantee is referenced in the evaluation, as a row of the correctness table",
    add = "add a guarantees list (\\begin{guarantees}, items labelled g:)" },

  { id = "rqs", role = "evaluation", kind = "tags", title = "Research questions", criterion = "E", example = "app:chapters:research-questions", prefix = "rq",
    why = "the questions the evaluation answers: correctness, scale and robustness at least",
    used = "each research question is referenced in the evaluation, where it is answered",
    add = "add a research-question list (\\begin{rqlist}, items labelled rq:)" },

  { id = "setup", role = "evaluation", kind = "text", title = "Setup and artifact", criterion = "D/2", example = "app:chapters:setup", key = "setup", label = "sec:setup",
    headings = { "setup" }, words = 100,
    why = "how the measurements were made, so each can be checked, and where the archived artifact is",
    used = "the evaluation cites the archived artifact by its Zenodo DOI",
    add = "add a section \\section{Setup}\\label{sec:setup} to the evaluation" },

  { id = "correctness", role = "evaluation", kind = "float", title = "Correctness", criterion = "D/2", example = "tab:guide:correctness", label = "tab:correctness",
    why = "how each guarantee and requirement was checked: proved, tested or model-checked, with the result",
    used = "it is referenced from the text, and every guarantee (g:) has a row in it",
    add = "add the correctness table, \\label{tab:correctness}, to the evaluation" },

  { id = "scalability", role = "evaluation", kind = "text", title = "Scalability", criterion = "E", example = "app:chapters:scalability", key = "scalability", label = "sec:scalability",
    headings = { "scalab", "scaling", "performance" }, words = 100,
    why = "how the cost grows with the input; the review sheet scores the evaluation's depth in E",
    used = "the section holds a figure or table that the text references",
    add = "add a section \\section{Scalability}\\label{sec:scalability} to the evaluation" },

  { id = "robustness", role = "evaluation", kind = "text", title = "Robustness", criterion = "E", example = "app:chapters:robustness", key = "robustness", label = "sec:robustness",
    headings = { "robust" }, words = 100,
    why = "how the system behaves when its assumptions are stressed; scored apart from scalability",
    used = "the section holds a figure or table that the text references",
    add = "add a section \\section{Robustness}\\label{sec:robustness} to the evaluation" },

  { id = "validity", role = "evaluation", kind = "text", title = "Threats to validity", criterion = "D/2", example = "app:chapters:validity", key = "validity", label = "sec:validity",
    headings = { "validity" }, words = 100,
    why = "what could make the results wrong or not generalise, and what was done about each",
    add = "add a section \\section{Threats to validity}\\label{sec:validity} to the evaluation" },

  { id = "positioning", role = "related", kind = "float", title = "Positioning figure", criterion = "B/2", example = "fig:guide:positioning", label = "fig:positioning",
    why = "the related work on the two properties that separate it most, with this work in the cell no one else reaches",
    used = "it is referenced from the text",
    add = "add the positioning figure, \\label{fig:positioning}, to the related work" },

  { id = "gapmatrix", role = "related", kind = "float", title = "Gap matrix", criterion = "D/1", example = "tab:guide:related", label = "tab:related",
    why = "each requirement against the closest approaches: every other approach misses something, this work meets all",
    used = "each requirement has exactly one row, this work meets every one with a pointer to a result, and every other approach misses one",
    add = "add the gap matrix, \\label{tab:related}, to the related work" },

  { id = "gap", role = "related", kind = "text", title = "The gap", criterion = "D/1", example = "app:chapters:gap", key = "gap", label = "sec:gap",
    headings = { "gap" }, words = 100,
    why = "the gap in one sentence, shown closed by this work's results",
    used = "it is based on the gap matrix (references tab:related)",
    add = "add a section \\section{Gap}\\label{sec:gap} to the related work" },

  { id = "summary", role = "conclusion", kind = "text", title = "Summary with evidence", criterion = "E", example = "app:chapters:summary", key = "summary", label = "sec:summary",
    headings = { "summary" }, words = 100,
    why = "each contribution restated with the result behind it; the reviewer checks here that the promises were kept",
    used = "it cites an evaluation result: the evaluation chapter, a research question, a figure, a table or a theorem",
    add = "add a section \\section{Summary}\\label{sec:summary} to the conclusion" },

  { id = "limitations", role = "conclusion", kind = "tags", title = "Limitations", criterion = "E", example = "app:chapters:future", prefix = "lim",
    why = "what this work does not do, stated before a reviewer finds it",
    add = "add a limitations list (\\begin{limitations}, items labelled lim:)" },

  { id = "future", role = "conclusion", kind = "text", title = "Future work", criterion = "E", example = "app:chapters:future", key = "future", label = "sec:future",
    headings = { "future" }, words = 100,
    why = "what is still open, and the next step that would lift each limitation",
    add = "add a section \\section{Future work}\\label{sec:future} to the conclusion" },
}
