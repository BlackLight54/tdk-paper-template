DOCUMENT=thesis
#MODE=-interaction=batchmode

all: clean xelatex
	echo

xelatex: compile_xelatex
	mv $(DOCUMENT)-xelatex.pdf ../pdf/$(DOCUMENT).pdf

compile_xelatex:
	xelatex $(MODE) $(DOCUMENT)
	bibtex $(DOCUMENT)
	xelatex $(MODE) $(DOCUMENT)
	xelatex $(MODE) $(DOCUMENT)
	mv $(DOCUMENT).pdf $(DOCUMENT)-xelatex.pdf

pdflatex: compile_pdflatex
	mv $(DOCUMENT)-pdflatex.pdf ../pdf/$(DOCUMENT).pdf

compile_pdflatex:
	pdflatex $(MODE) $(DOCUMENT)
	bibtex $(DOCUMENT)
	pdflatex $(MODE) $(DOCUMENT)
	pdflatex $(MODE) $(DOCUMENT)
	mv $(DOCUMENT).pdf $(DOCUMENT)-pdflatex.pdf

lualatex: compile_lualatex
	mv $(DOCUMENT)-lualatex.pdf ../pdf/$(DOCUMENT).pdf

compile_lualatex:
	lualatex $(MODE) $(DOCUMENT)
	bibtex $(DOCUMENT)
	lualatex $(MODE) $(DOCUMENT)
	lualatex $(MODE) $(DOCUMENT)
	mv $(DOCUMENT).pdf $(DOCUMENT)-lualatex.pdf

switch_to_hungarian:
	sed -i "s|^\\\input{include/thesis-en}|%\\\input{include/thesis-en}|" $(DOCUMENT).tex
	sed -i "s|^%\\\input{include/thesis-hu}|\\\input{include/thesis-hu}|" $(DOCUMENT).tex

test_hu:
	${MAKE} clean compile_xelatex
	${MAKE} clean compile_pdflatex
	${MAKE} clean compile_lualatex
	mv $(DOCUMENT)-xelatex.pdf ../pdf/$(DOCUMENT)-xelatex-hu.pdf
	mv $(DOCUMENT)-pdflatex.pdf ../pdf/$(DOCUMENT)-pdflatex-hu.pdf
	mv $(DOCUMENT)-lualatex.pdf ../pdf/$(DOCUMENT)-lualatex-hu.pdf

switch_to_english:
	sed -i "s|^\\\input{include/thesis-hu}|%\\\input{include/thesis-hu}|" $(DOCUMENT).tex
	sed -i "s|^%\\\input{include/thesis-en}|\\\input{include/thesis-en}|" $(DOCUMENT).tex

test_en:
	${MAKE} switch_to_english
	${MAKE} clean compile_xelatex
	${MAKE} clean compile_pdflatex
	${MAKE} clean compile_lualatex
	mv $(DOCUMENT)-xelatex.pdf ../pdf/$(DOCUMENT)-xelatex-en.pdf
	mv $(DOCUMENT)-pdflatex.pdf ../pdf/$(DOCUMENT)-pdflatex-en.pdf
	mv $(DOCUMENT)-lualatex.pdf ../pdf/$(DOCUMENT)-lualatex-en.pdf
	${MAKE} switch_to_hungarian

test: test_hu test_en
	echo

clean:
	echo Cleaning temporary files...
	rm -f *.aux *.dvi *.thm *.lof *.log *.lot *.fls *.out *.toc *.bbl *.blg

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
