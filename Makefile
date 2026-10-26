DOCUMENT=thesis
LATEXMK=latexmk -xelatex -shell-escape -interaction=nonstopmode
LINT=texlua scripts/lint.lua

# The draft, with todos, beats and the guide.
all:
	$(LATEXMK) $(DOCUMENT).tex

# The paper as the reviewer sees it: no notes, no list of todos, no guide. This is the PDF to upload.
reviewer:
	$(LATEXMK) reviewer.tex

clean:
	latexmk -C $(DOCUMENT).tex reviewer.tex
	rm -rf _minted-$(DOCUMENT) _minted-reviewer svg-inkscape *.tdo *.lol *.thm content/*.aux guide/*.aux include/*.aux

# Last week's checklist, the mechanical rows: every lint rule against the last build.
# "make lint-<rule>" runs one; "texlua scripts/lint.lua list" names them.
check:
	$(LINT) all

lint-%:
	$(LINT) $*

# The same against the reviewer build, which is the one the page count and the todos are judged on.
check-reviewer: reviewer
	$(LINT) all --doc reviewer

.PHONY: all reviewer clean check check-reviewer
