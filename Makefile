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
	rm -rf _minted-$(DOCUMENT) _minted-reviewer svg-inkscape *.tdo *.lol *.thm lint-checks.tex content/*.aux guide/*.aux include/*.aux

# Last week's checklist, the mechanical rows: every lint rule against the last build.
# "make lint-<rule>" runs one; "texlua scripts/lint.lua list" names them.
check:
	$(LINT) all

lint-%:
	$(LINT) $*

# The fixes the lint suggests (scripts/lint/fixes.lua): fix writes the safe ones and prints the
# diff, fix-dry only prints it, fix-review writes the ones to read first as well. Placeholders are
# never written: the lint prints them, you fill in their holes.
fix:
	$(LINT) fix

fix-dry:
	$(LINT) fix --dry-run

fix-review:
	$(LINT) fix --review

# The same against the reviewer build, which is the one the page count and the todos are judged on.
check-reviewer: reviewer
	$(LINT) all --doc reviewer

# The lint's copy of the skeleton chapters (scripts/lint/skeleton), after editing content/01-07 of the template.
skeleton:
	mkdir -p scripts/lint/skeleton && cp content/0[1-7]-*.tex scripts/lint/skeleton/

# The guide's reference of the essentials (guide/essentials.tex), after editing scripts/lint/essentials.lua.
essentials:
	$(LINT) essentials --guide > guide/essentials.tex

# The guide's own reference list, guide/guide.bbl, after editing its citations or guide/guide.bib.
guide-bib:
	texlua scripts/guide-bib.lua

.PHONY: all reviewer clean check check-reviewer fix fix-dry fix-review guide-bib skeleton essentials
