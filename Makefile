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

# The requirements table's rows with a rule name (guide, Requirements): every lint rule against the last build.
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

# The check before you upload: the reviewer build against every rule at the submit phase, whatever
# \lintphase says. The reviewer PDF hides todos and gap markers, so how it looks says nothing.
check-submit: reviewer
	$(LINT) all --doc reviewer --phase submit

# The lint's copy of the skeleton chapters (scripts/lint/skeleton), after editing content/01-07 of the template.
skeleton:
	mkdir -p scripts/lint/skeleton && cp content/0[1-7]-*.tex scripts/lint/skeleton/

# The guide's reference of the essentials (guide/essentials.tex), after editing scripts/lint/essentials.lua.
essentials:
	$(LINT) essentials --guide > guide/essentials.tex

# The guide's own reference list, guide/guide.bbl, after editing its citations or guide/guide.bib.
guide-bib:
	texlua scripts/guide-bib.lua

# The template's own tests, the same two CI runs: the lint against each mutation of the skeleton
# (scripts/lint/tests/mutations.py, after make reviewer) and review.py's unit tests.
test: test-lint test-review

test-lint:
	python3 scripts/lint/tests/mutations.py

test-review:
	python3 -m unittest scripts/review/test_review.py

.PHONY: all reviewer clean check check-reviewer check-submit fix fix-dry fix-review guide-bib skeleton essentials test test-lint test-review
