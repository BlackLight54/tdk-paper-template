DOCUMENT=thesis

# Build with latexmk, the way Overleaf does: XeLaTeX with shell escape (minted, svg) and BibTeX.
all:
	latexmk -xelatex -shell-escape -interaction=nonstopmode $(DOCUMENT).tex

clean:
	latexmk -C $(DOCUMENT).tex
	rm -rf _minted-$(DOCUMENT) svg-inkscape $(DOCUMENT).tdo $(DOCUMENT).lol $(DOCUMENT).thm content/*.aux guide/*.aux include/*.aux

# Last week's checklist, the mechanical rows (see the lifecycle chapter of the guide):
# undefined or multiply defined labels and citations, overfull boxes, missing files,
# and the page count of the main text between the page:main:start and page:main:end labels.
check:
	@test -f $(DOCUMENT).log || { echo "no $(DOCUMENT).log: build first"; exit 1; }
	@status=0; \
	for pat in "Reference .* undefined" "Citation .* undefined" "multiply defined" "Overfull" "File .* not found" "There were undefined"; do \
	  n=$$(grep -c "$$pat" $(DOCUMENT).log); \
	  if [ "$$n" -gt 0 ]; then echo "FAIL $$n x $$pat"; grep -m3 "$$pat" $(DOCUMENT).log | sed 's/^/     /'; status=1; else echo "ok   $$pat"; fi; \
	done; \
	s=$$(sed -n 's/^\\newlabel{page:main:start}{{[^}]*}{\([0-9]*\)}.*/\1/p' $(DOCUMENT).aux content/*.aux | head -1); \
	e=$$(sed -n 's/^\\newlabel{page:main:end}{{[^}]*}{\([0-9]*\)}.*/\1/p' $(DOCUMENT).aux content/*.aux | head -1); \
	if [ -n "$$s" ] && [ -n "$$e" ]; then p=$$((e-s+1)); \
	  if [ $$p -ge 30 ] && [ $$p -le 35 ]; then echo "ok   main text $$p pages ($$s-$$e)"; else echo "FAIL main text $$p pages ($$s-$$e), the call asks for 30-35"; status=1; fi; \
	else echo "FAIL page:main:start or page:main:end label missing"; status=1; fi; \
	grep -q '\\listoftodos' $(DOCUMENT).tex && { echo "FAIL \\listoftodos is still in $(DOCUMENT).tex"; status=1; } || echo "ok   no \\listoftodos"; \
	grep -q 'include{guide/' $(DOCUMENT).tex && { echo "FAIL the guide is still included in $(DOCUMENT).tex"; status=1; } || echo "ok   guide removed"; \
	exit $$status

.PHONY: all clean check
