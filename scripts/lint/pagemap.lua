-- How the Checks page and the CI job summary present the rules: each rule's family on the page
-- and its title in plain words. The rule id stays visible next to the title, because
-- "% lint-ignore: <id> <reason>" needs it. A rule missing here falls under "Other" with its id.
local M = {}

M.GROUPS = {
  { id = "argument", title = "The argument" },
  { id = "structure", title = "Structure" },
  { id = "refs", title = "Figures, tables and references" },
  { id = "language", title = "Language" },
  { id = "form", title = "Submission form" },
  { id = "other", title = "Other" },
}

M.RULES = {
  essentials = { "argument", "The essentials" },
  outline = { "argument", "Headings are final" },
  numbers = { "argument", "Headline numbers agree with the evaluation" },

  frame = { "structure", "The template's frame is intact" },
  roles = { "structure", "Every chapter has a role" },
  chapters = { "structure", "One chapter per file" },
  orphans = { "structure", "Every file is included" },
  stubs = { "structure", "Chapters without an essential are written" },
  spine = { "structure", "Chapters in spine order" },
  preamble = { "structure", "The own preamble does not fight the template" },
  build = { "structure", "The build log is clean" },
  overfull = { "structure", "No text runs into the margin" },
  ["repo-hygiene"] = { "structure", "No build output in the repository" },

  figures = { "refs", "Every float is referenced" },
  captions = { "refs", "Captions explain" },
  axes = { "refs", "Plots label their axes" },
  tables = { "refs", "Tables use booktabs" },
  labels = { "refs", "Labels match what they label" },
  crefs = { "refs", "References go through \\cref" },
  bib = { "refs", "Bibliography entries are complete" },
  code = { "refs", "Listings are captioned and ASCII-safe" },
  links = { "refs", "Every link answers" },
  checkcites = { "refs", "Uncited entries and missing keys" },
  ["bibtex-log"] = { "refs", "BibTeX warnings" },

  acronyms = { "language", "Abbreviations come from the glossary" },
  typography = { "language", "Typography" },
  terms = { "language", "One name per concept" },
  language = { "language", "Written in English" },
  spelling = { "language", "Spelling" },
  chktex = { "language", "chktex" },
  lacheck = { "language", "lacheck" },

  stock = { "form", "No text of the faculty template" },
  pages = { "form", "30--35 pages of main text" },
  aidecl = { "form", "AI declaration filled in" },
  titlepage = { "form", "Title page filled in" },
  ["pdf-file"] = { "form", "The PDF file" },
  ["pdf-font"] = { "form", "Body font" },
  ["pdf-spacing"] = { "form", "Line spacing" },
  ["pdf-margins"] = { "form", "Margins" },
  ["pdf-smalltext"] = { "form", "Text large enough to read" },
  ["pdf-pages"] = { "form", "30--35 pages, from the PDF" },
  ["pdf-parts"] = { "form", "Required parts of the PDF" },

  placeholders = { "other", "Placeholders" },
  beats = { "other", "Beats and notes" },
  words = { "other", "Words" },
  burndown = { "other", "Burn-down record" },
}

function M.group(id) return (M.RULES[id] or { "other" })[1] end
function M.title(id) return (M.RULES[id] or { nil, id })[2] end
function M.group_title(gid) for _, g in ipairs(M.GROUPS) do if g.id == gid then return g.title end end; return gid end
function M.group_index(gid) for i, g in ipairs(M.GROUPS) do if g.id == gid then return i end end; return #M.GROUPS end

return M
