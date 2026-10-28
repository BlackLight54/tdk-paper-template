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
--   placeholder      what work/essentials-labels.py inserts into a paper that misses the row
return {
  { id = "abstract", role = "front", kind = "front", title = "Abstract and Kivonat", criterion = "E", words = 100,
    why = "the paper in one paragraph, in English and in Hungarian; the reviewer reads it first and the registration carries it",
    add = "add content/00-abstract.tex with \\chapter*{Kivonat} and \\chapter*{Abstract}" },

  { id = "context", role = "intro", kind = "text", title = "Context", criterion = "C, E", key = "context", label = "par:context",
    headings = { "context", "motivation" }, words = 40,
    why = "why the topic matters now: a trend, a regulation or an incident, cited; relevance is scored in C",
    add = "add a paragraph \\paragraph{Context.}\\label{par:context} to the introduction",
    placeholder = [[
\paragraph{Context.}\label{par:context}
\beat{why the field matters now}{a trend, a regulation or an incident, cited}{not yet introduced}{the problem}
\atodo[inline]{Essentials: the context, why the topic matters now.}
TODO]] },

  { id = "problem", role = "intro", kind = "text", title = "Problem statement", criterion = "E", key = "problem", label = "par:problem",
    headings = { "problem" }, words = 40,
    why = "the concrete problem, ending in a one-sentence statement; the sheet's E names the problem statement as a must",
    add = "add a paragraph \\paragraph{Problem.}\\label{par:problem} to the introduction",
    placeholder = [[
\paragraph{Problem.}\label{par:problem}
\beat{the concrete problem, ending in a one-sentence problem statement}{the running example}{introduced here: who the actors are, what they want to do, and what goes wrong}{the requirements}
\atodo[inline]{Essentials: the problem statement, ending in one sentence.}
TODO]] },

  { id = "example", role = "intro", kind = "example", title = "Running example", criterion = "A",
    why = "one small scenario, named once in thesis.tex (\\exname) and revisited in a box in every chapter, so the reader can follow each step",
    used = "an example box in every main chapter",
    add = "add a running-example box to the introduction and name the example with \\exname in thesis.tex",
    placeholder = [[
\begin{runningexample}
\atodo[inline]{Essentials: the running example. Name it with \texttt{\textbackslash exname} in thesis.tex and return to it in every chapter.}
TODO Two or three sentences: the actors, what they want to do, and what goes wrong today.
\end{runningexample}]] },

  { id = "requirements", role = "intro", kind = "tags", title = "Requirements", criterion = "D/1", prefix = "req",
    why = "what a solution must do, one checkable item each; they are the rows of the gap matrix and the yardstick of the evaluation",
    used = "each requirement is referenced in the related work and in the evaluation, and each derived requirement (dr:) in the evaluation",
    add = "add a requirements list (\\begin{requirements}, items labelled req:)",
    placeholder = [[
\paragraph{Requirements.}
\beat{what a solution must do}{one requirement per failure of the example; they are the rows of the gap matrix and the yardstick of the evaluation}{the part of the scenario each requirement comes from}{the gap}
\atodo[inline]{Essentials: the requirements, one checkable property each.}
\begin{requirements}
  \item\label{req:todo} \textbf{TODO Short name.} A property the running example needs, stated so it can be checked.
\end{requirements}]] },

  { id = "introgap", role = "intro", kind = "text", title = "Gap, in brief", criterion = "D/1", key = "gap", label = "par:gap",
    headings = { "gap" }, words = 40,
    why = "that no existing approach meets the requirements together; the novelty claim, made before the full comparison",
    used = "it points to the full comparison: the related-work chapter, the gap matrix or the positioning figure",
    add = "add a paragraph \\paragraph{Gap.}\\label{par:gap} to the introduction",
    placeholder = [[
\paragraph{Gap.}\label{par:gap}
\beat{that no existing approach meets the requirements together; the full comparison comes after the evaluation, so this paragraph carries the novelty claim on its own}{the closest approaches, cited}{what the closest approach does with the example, and where it fails}{the contributions}
\atodo[inline]{Essentials: the gap in brief, pointing to the related-work chapter.}
TODO]] },

  { id = "overview", role = "intro", kind = "float", title = "Leading figure", criterion = "B/1", label = "fig:overview",
    why = "the problem, the contributions and the headline result in one picture; the reviewer looks here first",
    used = "it is referenced from the text",
    add = "add the leading figure, \\label{fig:overview}, to the introduction",
    placeholder = [[
\begin{figure}[!ht]
  \centering
  \fbox{\parbox{0.8\linewidth}{\centering\small Placeholder: the leading figure.}}
  \caption{TODO The problem, the contributions and the headline result in one picture.}
  \label{fig:overview}
\end{figure}
\atodo[inline]{Essentials: the leading figure, \cref{fig:overview}.}]] },

  { id = "contributions", role = "intro", kind = "tags", title = "Contributions", criterion = "E", prefix = "c",
    why = "what this work claims, as checkable items; the sheet's E names stating the main contribution as a must",
    used = "each contribution points to the chapter that delivers it and is referenced in the conclusion",
    add = "add a contributions list (\\begin{contributions}, items labelled c:)",
    placeholder = [[
\paragraph{Contributions.}
\beat{what this work claims, as checkable items with pointers to their support}{the chapters behind each contribution}{the leading figure shows the example solved}{the structure of the paper}
\atodo[inline]{Essentials: the contributions, each with the chapter that delivers it.}
\begin{contributions}
  \item\label{c:todo} \textbf{TODO Short name.} A contribution, with a pointer to the chapter that delivers it.
\end{contributions}]] },

  { id = "architecture", role = "approach", kind = "float", title = "Architecture figure", criterion = "B/1", label = "fig:architecture",
    why = "the approach end to end, with what is yours set apart from what is reused",
    used = "it is referenced from the text",
    add = "add an architecture figure, \\label{fig:architecture}, to the approach",
    placeholder = [[
\begin{figure}[!ht]
  \centering
  \fbox{\parbox{0.8\linewidth}{\centering\small Placeholder: the architecture of the approach.}}
  \caption{TODO Architecture of the approach; what is yours in blue.}
  \label{fig:architecture}
\end{figure}
\atodo[inline]{Essentials: the architecture figure, \cref{fig:architecture}.}]] },

  { id = "threats", role = "approach", kind = "tags", title = "Threats", criterion = "D/2", prefix = "thr",
    why = "who the adversary is and what it can do; a reviewer of a security topic looks for it first",
    used = "each threat is referenced in the approach, where a guarantee or an assumption meets it",
    add = "add a threats list (\\begin{threats}, items labelled thr:)",
    placeholder = [[
\paragraph{Adversary.}
\atodo[inline]{Essentials: the threats, what the adversary controls and can do.}
\begin{threats}
  \item\label{thr:todo} \textbf{TODO Short name.} What this adversary controls and can do.
\end{threats}]] },

  { id = "assumptions", role = "approach", kind = "tags", title = "Assumptions", criterion = "D/2", prefix = "asm",
    why = "who is trusted and which properties the guarantees rest on, stated so a reviewer can check them",
    used = "each assumption is referenced in the approach, by a guarantee or a proof",
    add = "add an assumptions list (\\begin{assumptions}, items labelled asm:)",
    placeholder = [[
\paragraph{Trust and cryptographic assumptions.}
\atodo[inline]{Essentials: the assumptions the guarantees rest on.}
\begin{assumptions}
  \item\label{asm:todo} \textbf{TODO Short name.} A trust or cryptographic assumption.
\end{assumptions}]] },

  { id = "guarantees", role = "approach", kind = "tags", title = "Guarantees", criterion = "D/2", prefix = "g",
    why = "what the approach guarantees under the assumptions, against the threats; each is what the evaluation checks",
    used = "each guarantee is referenced in the evaluation, as a row of the correctness table",
    add = "add a guarantees list (\\begin{guarantees}, items labelled g:)",
    placeholder = [[
\paragraph{Guarantees.}
\atodo[inline]{Essentials: the guarantees, each checked in the evaluation.}
\begin{guarantees}
  \item\label{g:todo} \textbf{TODO Short name.} Under the assumptions, against the threats, what holds.
\end{guarantees}]] },

  { id = "rqs", role = "evaluation", kind = "tags", title = "Research questions", criterion = "E", prefix = "rq",
    why = "the questions the evaluation answers: correctness, scale and robustness at least",
    used = "each research question is referenced in the evaluation, where it is answered",
    add = "add a research-question list (\\begin{rqlist}, items labelled rq:)",
    placeholder = [[
\section{Research questions}
\atodo[inline]{Essentials: the research questions the evaluation answers.}
\begin{rqlist}
  \item\label{rq:todo} \textbf{TODO Short name.} A question the evaluation answers.
\end{rqlist}]] },

  { id = "setup", role = "evaluation", kind = "text", title = "Setup and artifact", criterion = "D/2", key = "setup", label = "sec:setup",
    headings = { "setup" }, words = 100,
    why = "how the measurements were made, so each can be checked, and where the archived artifact is",
    used = "the evaluation cites the archived artifact with a real DOI",
    add = "add a section \\section{Setup}\\label{sec:setup} to the evaluation",
    placeholder = [[
\section{Setup}\label{sec:setup}
\beat{how the measurements were made, so that each can be checked}{hardware, software versions, workloads, repetitions, the rerun command}{the example as the base workload}{the results}
\atodo[inline]{Essentials: the setup, and the archived artifact cited with its DOI.}
TODO]] },

  { id = "correctness", role = "evaluation", kind = "float", title = "Correctness", criterion = "D/2", label = "tab:correctness",
    why = "how each guarantee and requirement was checked: proved, tested or model-checked, with the result",
    used = "it is referenced from the text, and every guarantee (g:) has a row in it",
    add = "add the correctness table, \\label{tab:correctness}, to the evaluation",
    placeholder = [[
\begin{table}[!ht]
  \centering
  \caption{TODO Correctness: how each guarantee and requirement was checked.}
  \label{tab:correctness}
  \fbox{\parbox{0.8\linewidth}{\centering\small Placeholder: one row per guarantee and requirement.}}
\end{table}
\atodo[inline]{Essentials: the correctness table, \cref{tab:correctness}.}]] },

  { id = "scalability", role = "evaluation", kind = "text", title = "Scalability", criterion = "E", key = "scalability", label = "sec:scalability",
    headings = { "scalab", "scaling", "performance" }, words = 100,
    why = "how the cost grows with the input; the review sheet scores the evaluation's depth in E",
    used = "the section holds a figure or table that the text references",
    add = "add a section \\section{Scalability}\\label{sec:scalability} to the evaluation",
    placeholder = [[
\section{Scalability}\label{sec:scalability}
\beat{how the cost grows with the input}{a figure of the measurements}{the example multiplied to $n$ participants or items}{robustness}
\atodo[inline]{Essentials: scalability, with a figure the text references.}
TODO]] },

  { id = "robustness", role = "evaluation", kind = "text", title = "Robustness", criterion = "E", key = "robustness", label = "sec:robustness",
    headings = { "robust" }, words = 100,
    why = "how the system behaves when its assumptions are stressed; scored apart from scalability",
    used = "the section holds a figure or table that the text references",
    add = "add a section \\section{Robustness}\\label{sec:robustness} to the evaluation",
    placeholder = [[
\section{Robustness}\label{sec:robustness}
\beat{how the system behaves when its assumptions are stressed: faults, attacks, load spikes, parameter changes}{a table of the perturbations, with the setup of each}{the example under attack}{the threats to validity}
\atodo[inline]{Essentials: robustness, with a figure or table the text references.}
TODO]] },

  { id = "validity", role = "evaluation", kind = "text", title = "Threats to validity", criterion = "D/2", key = "validity", label = "sec:validity",
    headings = { "validity" }, words = 100,
    why = "what could make the results wrong or not generalise, and what was done about each",
    add = "add a section \\section{Threats to validity}\\label{sec:validity} to the evaluation",
    placeholder = [[
\section{Threats to validity}\label{sec:validity}
\beat{what could make the results wrong or not generalise, and what was done about each}{the mitigations}{whether the example is representative of real use}{related work}
\atodo[inline]{Essentials: the threats to validity.}
TODO]] },

  { id = "positioning", role = "related", kind = "float", title = "Positioning figure", criterion = "B/2", label = "fig:positioning",
    why = "the related work on the two properties that separate it most, with this work in the cell no one else reaches",
    used = "it is referenced from the text",
    add = "add the positioning figure, \\label{fig:positioning}, to the related work",
    placeholder = [[
\begin{figure}[!ht]
  \centering
  \fbox{\parbox{0.8\linewidth}{\centering\small Placeholder: the related work on two axes, this work in the empty cell.}}
  \caption{TODO Positioning: the related work on the two properties that separate it most.}
  \label{fig:positioning}
\end{figure}
\atodo[inline]{Essentials: the positioning figure, \cref{fig:positioning}.}]] },

  { id = "gapmatrix", role = "related", kind = "float", title = "Gap matrix", criterion = "D/1", label = "tab:related",
    why = "each requirement against the closest approaches: every other approach misses something, this work meets all",
    used = "rows are the requirements, this work's column is all met with pointers to results, and every other approach misses one",
    add = "add the gap matrix, \\label{tab:related}, to the related work",
    placeholder = [[
\begin{table}[!ht]
  \centering
  \caption{TODO Gap matrix: each requirement against the closest approaches.}
  \label{tab:related}
  \fbox{\parbox{0.8\linewidth}{\centering\small Placeholder: one row per requirement, one column per approach and this work.}}
\end{table}
\atodo[inline]{Essentials: the gap matrix, \cref{tab:related}.}]] },

  { id = "gap", role = "related", kind = "text", title = "The gap", criterion = "D/1", key = "gap", label = "sec:gap",
    headings = { "gap" }, words = 100,
    why = "the gap in one sentence, shown closed by this work's results",
    used = "it is based on the gap matrix (references tab:related)",
    add = "add a section \\section{Gap}\\label{sec:gap} to the related work",
    placeholder = [[
\section{Gap}\label{sec:gap}
\beat{the gap in one sentence, closed by this work}{the gap matrix and the results of the evaluation}{the scenario as the case only this work handles}{the conclusion}
\atodo[inline]{Essentials: the gap, based on the gap matrix.}
TODO]] },

  { id = "summary", role = "conclusion", kind = "text", title = "Summary with evidence", criterion = "E", key = "summary", label = "sec:summary",
    headings = { "summary" }, words = 100,
    why = "each contribution restated with the result behind it; the reviewer checks here that the promises were kept",
    used = "it cites an evaluation result: the evaluation chapter, a research question, a figure, a table or a theorem",
    add = "add a section \\section{Summary}\\label{sec:summary} to the conclusion",
    placeholder = [[
\section{Summary}\label{sec:summary}
\beat{each contribution and its evidence}{the chapters behind the contributions}{the example, now solved}{the limitations}
\atodo[inline]{Essentials: the summary, each contribution with its evidence.}
TODO]] },

  { id = "limitations", role = "conclusion", kind = "tags", title = "Limitations", criterion = "E", prefix = "lim",
    why = "what this work does not do, stated before a reviewer finds it",
    add = "add a limitations list (\\begin{limitations}, items labelled lim:)",
    placeholder = [[
\begin{limitations}
  \item\label{lim:todo} \textbf{TODO Short name.} What this work does not do.
\end{limitations}
\atodo[inline]{Essentials: the limitations.}]] },

  { id = "future", role = "conclusion", kind = "text", title = "Future work", criterion = "E", key = "future", label = "sec:future",
    headings = { "future" }, words = 100,
    why = "what is still open, and the next step that would lift each limitation",
    add = "add a section \\section{Future work}\\label{sec:future} to the conclusion",
    placeholder = [[
\section{Future work}\label{sec:future}
\beat{what is still open, and the next step that would lift each limitation}{the threats to validity}{what the example does not cover}{the venue to target next}
\atodo[inline]{Essentials: future work.}
TODO]] },
}
