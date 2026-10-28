#!/usr/bin/env python3
"""Review runs: assemble, fetch and verify the evidence bundle of one commit, hand each persona
exactly its inputs, and file one issue for a recorded run. The formats are fixed in README.md.

    review.py bundle  --built DIR --lint FILE --skim DIR --out DIR     (CI, or locally)
    review.py fetch   --repo OWNER/NAME --sha SHA [--out DIR]
    review.py inputs  BUNDLE PERSONA... [--spine FILE]
    review.py record  FINDINGS --bundle BUNDLE [--inputs FILE] [--dry-run]

Python 3 standard library only. GitHub is reached through the `gh` CLI.
"""
import argparse
import datetime
import hashlib
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import tempfile
from pathlib import Path, PurePosixPath

SCHEMA = 1
DOCS = ("thesis", "reviewer")
CRITERIA = ("A", "B/1", "B/2", "C", "D/1", "D/2", "E")
SEVERITIES = ("blocker", "major", "minor")
MODES = ("premortem", "draft")
READS = ("reviewer-pdf", "skim-view", "spine")
HEX40 = re.compile(r"[0-9a-f]{40}")
HEX64 = re.compile(r"[0-9a-f]{64}")
BODY_LIMIT = 65000  # GitHub refuses an issue body of 65536 characters
PERSONAS = Path(__file__).resolve().parents[2] / ".claude" / "skills" / "reviewer-passes" / "personas"


class Fail(Exception):
    """A reason to stop, printed without a traceback; the exit status is 1."""


# --- helpers ----------------------------------------------------------------------------------

def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def walk_files(root):
    """Every file under root as a posix path relative to it; symlinked directories are not entered."""
    out = []
    for dirpath, _, names in os.walk(root):
        for n in names:
            out.append(Path(dirpath, n).relative_to(root).as_posix())
    return sorted(out)


def hash_tree(root):
    return {rel: sha256_file(Path(root, rel)) for rel in walk_files(root)}


def run(cmd, cwd=None):
    try:
        return subprocess.run(cmd, cwd=cwd, capture_output=True, text=True)
    except FileNotFoundError:
        raise Fail(f"{cmd[0]} is not installed or not on PATH")


def gh(args):
    return run(["gh", *args])


def git(path, *args):
    """Stdout of a git command in path, or None when it fails (not a repository, no remote)."""
    r = run(["git", "-C", str(path), *args])
    return r.stdout.strip() if r.returncode == 0 else None


def check_repo(repo):
    if not re.fullmatch(r"[\w.-]+/[\w.-]+", repo or ""):
        raise Fail(f"--repo must be owner/name, not {repo!r}")
    return repo


def empty_dir(path):
    path = Path(path)
    if path.exists() and (not path.is_dir() or any(path.iterdir())):
        raise Fail(f"{path} exists and is not an empty directory")
    return path


def inside_repo(path):
    return any((p / ".git").exists() for p in [Path(path).resolve(), *Path(path).resolve().parents])


def one_line(s):
    return " ".join(str(s).split())


# --- the bundle: verification -----------------------------------------------------------------

def load_manifest(bundle):
    mp = Path(bundle, "manifest.json")
    if not mp.is_file():
        raise Fail(f"{bundle} has no manifest.json")
    try:
        m = json.loads(mp.read_text(encoding="utf-8"))
    except ValueError as e:
        raise Fail(f"{mp} is not JSON: {e}")
    if not isinstance(m, dict):
        raise Fail(f"{mp} is not a JSON object")
    return m


def verify_bundle(bundle, sha=None):
    """Return (manifest, problems). A problem names the file; an empty list means the bundle is whole."""
    bundle = Path(bundle)
    m = load_manifest(bundle)
    problems = []
    if m.get("schema") != SCHEMA:
        problems.append(f"manifest.json: schema is {m.get('schema')!r}, this script reads {SCHEMA}")
    if sha is not None and m.get("sha") != sha:
        problems.append(f"manifest.json: sha is {m.get('sha')!r}, but {sha} was requested")
    files = m.get("files")
    if not isinstance(files, dict) or not files:
        problems.append("manifest.json: files is missing or empty")
        return m, problems
    root = bundle.resolve()
    for name, want in sorted(files.items()):
        rel = PurePosixPath(name)
        p = bundle / name
        if rel.is_absolute() or ".." in rel.parts or root not in p.resolve().parents:
            problems.append(f"{name}: path leaves the bundle")
        elif p.is_symlink() or not p.is_file():
            problems.append(f"{name}: listed in manifest.json but missing")
        elif sha256_file(p) != want:
            problems.append(f"{name}: SHA-256 differs from manifest.json")
    for extra in sorted(set(walk_files(bundle)) - set(files) - {"manifest.json"}):
        problems.append(f"{extra}: in the bundle but not listed in manifest.json")
    return m, problems


def verified(bundle, sha=None):
    m, problems = verify_bundle(bundle, sha)
    if problems:
        raise Fail(f"bundle {bundle} does not verify:\n" + "\n".join(f"  - {p}" for p in problems))
    return m


# --- bundle -----------------------------------------------------------------------------------

def count_errors(log):
    return sum(1 for line in log.splitlines() if line.startswith("! "))


def count_undefined(log):
    """Undefined references and citations. LaTeX wraps its log at 79 columns, so `undefined` may sit on
    the line after `Reference `x' on page 3`; each warning is counted once, at its first line."""
    lines = log.splitlines()
    n = 0
    for i, line in enumerate(lines):
        if re.search(r"(Reference|Citation) [`'].*", line):
            tail = line + (" " + lines[i + 1] if i + 1 < len(lines) else "")
            if re.search(r"(Reference|Citation) .* undefined", tail):
                n += 1
    return n


def engine_of(log):
    head = log[:400]
    for needle, engine in (("XeTeX", "xelatex"), ("LuaHBTeX", "lualatex"), ("LuaTeX", "lualatex"), ("pdfTeX", "pdflatex")):
        if needle in head:
            return engine
    return "unknown"


def count_pages(pdf):
    r = run(["pdfinfo", str(pdf)]) if shutil.which("pdfinfo") else None
    if r is not None and r.returncode == 0:
        m = re.search(r"^Pages:\s+(\d+)", r.stdout, re.M)
        if m:
            return int(m.group(1))
    n = len(re.findall(rb"/Type\s*/Page(?![s\w])", Path(pdf).read_bytes()))
    if n:
        return n  # a count of page objects: right for a PDF without object streams only
    print(f"review.py: warning: cannot count the pages of {pdf} (install poppler-utils for pdfinfo)", file=sys.stderr)
    return None


def parse_exits(items):
    exits = {}
    for item in items or []:
        m = re.fullmatch(r"(thesis|reviewer|lint|skim)=(\d+)", item)
        if not m:
            raise Fail(f"--exit takes thesis=N, reviewer=N, lint=N or skim=N, not {item!r}")
        exits[m.group(1)] = int(m.group(2))
    for doc in DOCS:
        if doc not in exits:
            raise Fail(f"--exit {doc}=N is required: the latexmk exit code of the {doc} build")
    return exits


def source_identity(a):
    """repo, sha, ref and the built{} object, from GitHub Actions' environment or from git."""
    env = os.environ
    by = a.by or ("ci" if env.get("GITHUB_ACTIONS") == "true" else "local")
    if by == "ci":
        repo, sha, ref = a.repo or env.get("GITHUB_REPOSITORY"), a.sha or env.get("GITHUB_SHA"), a.ref or env.get("GITHUB_REF_NAME")
        missing = [n for n, v in (("GITHUB_REPOSITORY or --repo", repo), ("GITHUB_SHA or --sha", sha),
                                  ("GITHUB_REF_NAME or --ref", ref), ("GITHUB_RUN_ID", env.get("GITHUB_RUN_ID"))) if not v]
        if missing:
            raise Fail("--by ci needs " + ", ".join(missing))
        server = env.get("GITHUB_SERVER_URL", "https://github.com")
        built = {"by": "ci", "run_url": f"{server}/{repo}/actions/runs/{env['GITHUB_RUN_ID']}",
                 "run_attempt": int(env.get("GITHUB_RUN_ATTEMPT", "1"))}
        return check_repo(repo), sha, ref, built
    head = git(a.built, "rev-parse", "HEAD")
    sha = a.sha or head
    if not sha:
        raise Fail(f"{a.built} is not in a git repository: pass --sha")
    if head and head != sha:
        raise Fail(f"{a.built} is at {head}, but --sha says {sha}")
    repo = a.repo
    if not repo:
        m = re.search(r"github\.com[:/]([\w.-]+/[\w.-]+?)(?:\.git)?$", git(a.built, "remote", "get-url", "origin") or "")
        repo = m.group(1) if m else None
    ref = a.ref or git(a.built, "rev-parse", "--abbrev-ref", "HEAD")
    if not repo or not ref:
        raise Fail("cannot tell the repository or the branch: pass --repo and --ref")
    dirty = bool(head and git(a.built, "status", "--porcelain"))
    if dirty and not a.allow_dirty:
        raise Fail(f"the tree of {a.built} is dirty, so a bundle of it is not evidence of {sha[:7]}; commit, or pass --allow-dirty")
    built = {"by": "local", "host": socket.gethostname()}
    if dirty:
        built["dirty"] = True
    return check_repo(repo), sha, ref, built


def cmd_bundle(a):
    built, lint, skim, out = Path(a.built), Path(a.lint), Path(a.skim), Path(a.out)
    exits = parse_exits(a.exit)
    if a.image_digest is not None and not re.fullmatch(r"sha256:[0-9a-fA-F]+", a.image_digest):
        raise Fail(f"--image-digest must look like sha256:<hex>, not {a.image_digest!r}")
    if not built.is_dir():
        raise Fail(f"--built {built} is not a directory")
    try:
        lint_doc = json.loads(lint.read_text(encoding="utf-8"))
    except (OSError, ValueError) as e:
        raise Fail(f"--lint {lint} is not readable JSON ({e}): pass the output of texlua scripts/lint.lua all --doc reviewer --json")
    if not isinstance(lint_doc, dict):
        raise Fail(f"--lint {lint} is not a JSON object")
    repo, sha, ref, built_info = source_identity(a)
    if not HEX40.fullmatch(sha):
        raise Fail(f"the commit SHA must be 40 lowercase hex digits, not {sha!r}")
    skim_ok = (skim / "skim.md").is_file()
    if not skim_ok and exits.get("skim", 0) == 0:
        raise Fail(f"--skim {skim} has no skim.md (and --exit skim=N does not say the skim failed)")
    out = empty_dir(out)

    builds = []
    for doc in DOCS:
        pdf, log = built / f"{doc}.pdf", built / f"{doc}.log"
        if not log.is_file():
            if exits[doc] == 0:
                raise Fail(f"{log} is missing, but --exit {doc}=0 says the build succeeded")
            # the build never ran (a step before it failed, or it was skipped): the bundle still
            # carries the other evidence, and the manifest says this one has none
            print(f"review.py: warning: {log} is missing; the {doc} build is recorded as not started", file=sys.stderr)
            builds.append({"doc": doc, "engine": None, "latexmk_exit": exits[doc], "started": False, "errors": None, "undefined": None, "pages": None})
            continue
        if not pdf.is_file() and exits[doc] == 0:
            raise Fail(f"{pdf} is missing, but --exit {doc}=0 says the build succeeded")
        text = log.read_text(encoding="utf-8", errors="replace")
        builds.append({"doc": doc, "engine": engine_of(text), "latexmk_exit": exits[doc], "started": True, "errors": count_errors(text),
                       "undefined": count_undefined(text), "pages": count_pages(pdf) if pdf.is_file() else None})
    if not any(b["started"] for b in builds):
        raise Fail("neither build left a log: there is no evidence to bundle")

    (out / "logs").mkdir(parents=True, exist_ok=True)
    for doc in DOCS:
        if (built / f"{doc}.pdf").is_file():
            shutil.copy2(built / f"{doc}.pdf", out / f"{doc}.pdf")
        if (built / f"{doc}.log").is_file():
            shutil.copy2(built / f"{doc}.log", out / "logs" / f"{doc}.log")
    shutil.copy2(lint, out / "lint.json")
    if skim_ok:
        shutil.copytree(skim, out / "skim")
    else:
        print(f"review.py: warning: no skim output in {skim}; the bundle has no skim view", file=sys.stderr)

    manifest = {
        "schema": SCHEMA, "repo": repo, "sha": sha, "ref": ref, "built": built_info,
        "image": {"ref": a.image_ref, "digest": a.image_digest},
        "phase": lint_doc.get("phase"), "phase_source": lint_doc.get("phase_source"),
        "profile": lint_doc.get("profile") or os.environ.get("LINT_PROFILE", "tdk"),
        "builds": builds, "lint": {"exit": exits.get("lint")}, "skim": {"exit": exits.get("skim")},
        "files": hash_tree(out),
    }
    (out / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print(f"{out} (review-{sha[:7]}, {len(manifest['files'])} files)")


# --- fetch ------------------------------------------------------------------------------------

def resolve_sha(repo, sha):
    sha = sha.lower()
    if HEX40.fullmatch(sha):
        return sha
    if not re.fullmatch(r"[0-9a-f]{7,39}", sha):
        raise Fail(f"--sha must be 7 to 40 hex digits, not {sha!r}")
    r = gh(["api", f"repos/{repo}/commits/{sha}", "--jq", ".sha"])
    full = r.stdout.strip()
    if r.returncode != 0 or not HEX40.fullmatch(full):
        raise Fail(f"cannot resolve {sha} in {repo}: {r.stderr.strip() or 'no such commit'}")
    return full


def cmd_fetch(a):
    repo = check_repo(a.repo)
    sha = resolve_sha(repo, a.sha)
    name = f"review-{sha[:7]}"
    r = gh(["run", "list", "-R", repo, "--commit", sha, "--workflow", "paper.yml", "--limit", "20",
            "--json", "databaseId,status,conclusion,createdAt"])
    if r.returncode != 0:
        raise Fail(f"gh run list failed: {r.stderr.strip()}")
    runs = sorted(json.loads(r.stdout or "[]"), key=lambda x: x.get("createdAt", ""), reverse=True)
    if not runs:
        raise Fail(f"no paper.yml run for {sha[:7]} in {repo}; push the commit, or run "
                   f"`gh workflow run paper.yml -R {repo} --ref <branch>` if it is a branch head")
    runs = [x for x in runs if x["status"] == "completed"]
    if not runs:
        raise Fail(f"the paper.yml run for {sha[:7]} has not finished; wait for it")
    out = empty_dir(a.out) if a.out else None
    last = ""
    for run_ in runs:
        dest = out or Path(tempfile.mkdtemp(prefix=f"{name}-"))
        r = gh(["run", "download", str(run_["databaseId"]), "-R", repo, "-n", name, "-D", str(dest)])
        if r.returncode == 0:
            verified(dest, sha)
            print(dest)
            return
        last = r.stderr.strip()
        if not out:
            shutil.rmtree(dest, ignore_errors=True)
    raise Fail(f"cannot download {name} from the runs for {sha[:7]}: {last}\n"
               f"Either it expired (artifacts are kept 14 days), or the workflow of that commit does not upload one.\n"
               f"If it expired, rebuild it with:\n"
               f"  gh run rerun {runs[0]['databaseId']} -R {repo}")


# --- inputs -----------------------------------------------------------------------------------

def parse_frontmatter(text):
    m = re.match(r"---\n(.*?)\n---\n", text, re.S)
    if not m:
        return {}
    fm, key = {}, None
    for line in m.group(1).splitlines():
        item = re.match(r"\s*-\s+(.*)", line)
        if item and key and isinstance(fm.get(key), list):
            fm[key].append(item.group(1).strip().strip("'\""))
        elif ":" in line:
            k, _, v = line.partition(":")
            key, v = k.strip(), v.strip()
            fm[key] = ([x.strip() for x in v[1:-1].split(",") if x.strip()] if v.startswith("[") and v.endswith("]")
                       else [] if v == "" else v.strip("'\""))
    return fm


def persona_file(personas_dir, persona):
    path = Path(personas_dir, f"{persona}.md")
    if not re.fullmatch(r"[a-z0-9-]+", persona) or not path.is_file():
        raise Fail(f"no persona {persona!r} in {personas_dir}")
    return path


def persona_version(personas_dir, persona):
    """The persona file's SHA-256 and the commit of the checkout it came from (None outside git):
    the bundle's SHA names the paper, not the persona that read it, so a run records both."""
    path = persona_file(personas_dir, persona)
    return {"file": path.name, "sha256": sha256_file(path), "commit": git(path.parent, "rev-parse", "HEAD")}


def persona_reads(personas_dir, persona):
    path = persona_file(personas_dir, persona)
    fm = parse_frontmatter(path.read_text(encoding="utf-8"))
    if fm.get("name") != persona:
        raise Fail(f"{path}: frontmatter name is {fm.get('name')!r}, expected {persona!r}")
    reads = fm.get("reads")
    if not isinstance(reads, list) or not reads or any(r not in READS for r in reads):
        raise Fail(f"{path}: reads must be a non-empty list of {', '.join(READS)}; found {reads!r}")
    return reads


def cmd_inputs(a):
    manifest = verified(a.bundle)
    files = manifest["files"]
    personas_dir = Path(a.skills) if a.skills else PERSONAS
    if len(set(a.personas)) != len(a.personas):
        raise Fail("a persona is listed twice")
    spine = Path(a.spine) if a.spine else None
    if spine and not spine.is_file():
        raise Fail(f"--spine {spine} is not a file")
    if inside_repo(tempfile.gettempdir()):
        raise Fail(f"{tempfile.gettempdir()} is inside a git repository; point TMPDIR elsewhere")
    reads = {p: persona_reads(personas_dir, p) for p in a.personas}  # all personas checked before any directory exists
    for p, r in reads.items():
        if "reviewer-pdf" in r and "reviewer.pdf" not in files:
            raise Fail(f"{p} reads the reviewer PDF, but the bundle has none (did the reviewer build fail?)")
        if "skim-view" in r and "skim/skim.md" not in files:
            raise Fail(f"{p} reads the skim view, but the bundle has none (did the skim fail?)")

    result = {}
    for p, r in reads.items():
        d = Path(tempfile.mkdtemp(prefix=f"review-{p}-"))
        copies = []  # (source, name inside the directory)
        if "reviewer-pdf" in r:
            copies.append((Path(a.bundle, "reviewer.pdf"), "reviewer.pdf"))
        if "skim-view" in r:
            copies.append((Path(a.bundle, "skim/skim.md"), "skim.md"))
            copies += [(Path(a.bundle, n), n[len("skim/"):]) for n in sorted(files) if n.startswith("skim/assets/")]
        if "spine" in r and spine:
            copies.append((spine, "spine.md"))
        for src, name in copies:
            (d / name).parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(src, d / name)
        result[p] = {"dir": str(d), "files": hash_tree(d), "spine": (d / "spine.md").is_file(), "persona": persona_version(personas_dir, p)}
    print(json.dumps(result, indent=2))


# --- record -----------------------------------------------------------------------------------

def validate_findings(f, panel_inputs):
    """Every problem with findings.json against the contract, as a list of messages."""
    if not isinstance(f, dict):
        return ["the top level must be a JSON object"]
    errs = []
    sha = f.get("sha")
    if not (isinstance(sha, str) and HEX40.fullmatch(sha)):
        errs.append("sha: 40 lowercase hex digits")
    elif f.get("bundle") != f"review-{sha[:7]}":
        errs.append(f"bundle: expected review-{sha[:7]}, found {f.get('bundle')!r}")
    if f.get("mode") not in MODES:
        errs.append(f"mode: one of {', '.join(MODES)}")
    panel = f.get("panel")
    if not (isinstance(panel, list) and panel and all(isinstance(p, str) and p for p in panel)):
        errs.append("panel: a non-empty list of persona names")
        panel = []
    skipped = f.get("skipped", {})
    if not (isinstance(skipped, dict) and all(isinstance(k, str) and isinstance(v, str) for k, v in skipped.items())):
        errs.append("skipped: an object of persona -> reason")
    if not (isinstance(f.get("model"), str) and f["model"].strip()):
        errs.append("model: the model that ran the personas")
    scores = f.get("scores")
    if scores is not None:
        ok = isinstance(scores, dict) and set(scores) <= set(CRITERIA) and all(
            isinstance(v, list) and len(v) == 2 and all(isinstance(x, (int, float)) and not isinstance(x, bool) for x in v)
            and 0 <= v[0] <= v[1] for v in scores.values())
        if not ok:
            errs.append(f"scores: an object of criterion ({', '.join(CRITERIA)}) -> [score, maximum]")
        if "skim" not in panel:
            errs.append("scores: present, but skim is not in the panel")
    elif "skim" in panel:
        errs.append("scores: the skim ran, so its scores are required")
    findings = f.get("findings")
    if not isinstance(findings, list):
        errs.append("findings: a list")
        findings = []
    seen = set()
    for i, x in enumerate(findings, 1):
        label = f"findings[{i}]"
        if not isinstance(x, dict):
            errs.append(f"{label}: an object")
            continue
        fid = x.get("id")
        label = f"finding {fid}" if isinstance(fid, str) else label
        if not (isinstance(fid, str) and re.fullmatch(r"F\d+", fid)) or fid in seen:
            errs.append(f"{label}: id must be F<number> and unique")
        seen.add(fid)
        for key in ("persona", "where", "objection", "answer"):
            if not (isinstance(x.get(key), str) and x[key].strip()):
                errs.append(f"{label}: {key} is missing or empty")
        if x.get("persona") not in panel:
            errs.append(f"{label}: persona {x.get('persona')!r} is not in the panel")
        if x.get("criterion") not in CRITERIA:
            errs.append(f"{label}: criterion must be one of {', '.join(CRITERIA)}")
        if x.get("severity") not in SEVERITIES:
            errs.append(f"{label}: severity must be one of {', '.join(SEVERITIES)}")
    for p in panel:
        files = panel_inputs.get(p)
        if not (isinstance(files, dict) and files and all(isinstance(v, str) and HEX64.fullmatch(v) for v in files.values())):
            errs.append(f"inputs: persona {p} needs an object of file -> SHA-256")
    return errs


def bundle_name(input_name):
    """Where a persona's input file came from in the bundle, or None for the spine."""
    if input_name == "reviewer.pdf":
        return input_name
    if input_name == "skim.md" or input_name.startswith("assets/"):
        return "skim/" + input_name
    return None


def load_json(path, what):
    try:
        return json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, ValueError) as e:
        raise Fail(f"{what} {path}: {e}")


def total(scores):
    if set(scores) != set(CRITERIA):
        return None
    def at(i):
        s = lambda k: scores[k][i]
        return s("A") + (s("B/1") + s("B/2")) / 2 + s("C") + s("D/1") + s("D/2") + s("E")
    return at(0), at(1)


def finding_line(x):
    objection = one_line(x["objection"]).rstrip(". ")
    return (f"- [ ] {x['id']} {x['persona']} · {x['criterion']} · {x['severity']} · "
            f"{one_line(x['where'])}: {objection}. Answer: {one_line(x['answer'])}")


def render_issue(f, manifest, inputs, today, versions=None):
    sha7, sha, repo, built = f["sha"][:7], f["sha"], manifest["repo"], manifest["built"]
    title = f"Review {today} {sha7}"
    run_url = built.get("run_url")
    base = run_url.split("/actions/runs/")[0] if run_url else f"https://github.com/{repo}"
    where = f"[CI run]({run_url})" if run_url else f"a local build on {built.get('host', 'an unnamed host')}, with no CI run" + (
        "; its tree was dirty" if built.get("dirty") else "")
    lines = [f"Review of [`{sha7}`]({base}/commit/{sha}) in mode `{f['mode']}`, run by {f['model']} on the bundle "
             f"`{f['bundle']}` ({where}).", "",
             "**Panel:** " + ", ".join(f"`{p}`" for p in f["panel"]),
             "**Skipped:** " + ("; ".join(f"`{p}`: {one_line(r)}" for p, r in f.get("skipped", {}).items()) or "none"), ""]
    scores = f.get("scores")
    if scores:
        lines += ["## Skim scores", "", "| Criterion | Score | Maximum |", "|---|---|---|"]
        lines += [f"| {c} | {scores[c][0]:g} | {scores[c][1]:g} |" for c in CRITERIA if c in scores]
        t = total(scores)
        if t:
            lines += ["", f"Total {t[0]:g} of {t[1]:g} (B is the average of B/1 and B/2, D is D/1 plus D/2)."]
        lines.append("")
    lines += ["## Findings", ""] + [finding_line(x) for x in f["findings"]]
    lines += ["", "## Dispositions", "",
              "Propose a disposition per finding in a comment: `F3 fixed in <sha>`, `F4 rejected: <reason>` or `F5 deferred`. "
              "The advisor confirms them with the `review-confirmed` label.", "",
              "<details><summary>Manifest</summary>", "", "```json", json.dumps(manifest, indent=2), "```", "", "</details>", "",
              "<details><summary>Persona inputs (SHA-256)</summary>", "", "```text"]
    for p in f["panel"]:
        lines.append(p)
        lines += [f"  {h}  {n}" for n, h in sorted(inputs[p].items())]
    lines += ["```", "", "</details>", "", "<details><summary>Persona versions (SHA-256 of the persona file, and the commit it was read from)</summary>", "", "```text"]
    for p in f["panel"]:
        v = (versions or {}).get(p)
        lines.append(f"{p}  {v['sha256']}  {v.get('commit') or 'no commit'}" if isinstance(v, dict) and v.get("sha256") else f"{p}  not recorded (run `review.py inputs` and pass --inputs)")
    lines += ["```", "", "</details>"]
    return title, "\n".join(lines) + "\n"


def cmd_record(a):
    f = load_json(a.findings, "findings")
    inputs = f.get("inputs") if isinstance(f, dict) else None
    versions = {}
    if inputs is None and a.inputs:
        saved = load_json(a.inputs, "--inputs")
        inputs = {p: v.get("files") for p, v in saved.items() if isinstance(v, dict)} if isinstance(saved, dict) else {}
        versions = {p: v.get("persona") for p, v in saved.items() if isinstance(v, dict)} if isinstance(saved, dict) else {}
    if inputs is None:
        raise Fail("findings.json has no inputs: pass --inputs with the output saved from `review.py inputs`")
    if not isinstance(inputs, dict):
        inputs = {}
    errs = validate_findings(f, inputs)
    if errs:
        raise Fail(f"{a.findings} does not match the contract:\n" + "\n".join(f"  - {e}" for e in errs))
    manifest = verified(a.bundle, f["sha"])
    if (manifest.get("built") or {}).get("dirty"):
        raise Fail("the bundle was built from a dirty tree (built.dirty is true): an ad hoc run, not evidence of "
                   f"{f['sha'][:7]}; record a CI bundle, or a local bundle of a clean tree")
    for p in f["panel"]:
        for name, h in inputs[p].items():
            src = bundle_name(name)
            if src and manifest["files"].get(src) != h:
                raise Fail(f"inputs: {p}/{name} has SHA-256 {h}, but the bundle's {src} differs or is missing")
    repo = check_repo(a.repo or manifest["repo"])
    title, body = render_issue(f, manifest, inputs, datetime.date.today().isoformat(), versions)
    if len(body) > BODY_LIMIT:
        raise Fail(f"the issue body is {len(body)} characters; GitHub accepts at most 65536")
    if a.dry_run:
        print(f"Repository: {repo}\nTitle: {title}\n\n{body}", end="")
        return
    with tempfile.TemporaryDirectory(prefix="review-issue-") as tmp:
        bodyfile = Path(tmp, "body.md")
        bodyfile.write_text(body, encoding="utf-8")
        r = gh(["issue", "create", "-R", repo, "--title", title, "--body-file", str(bodyfile)])
    if r.returncode != 0:
        raise Fail(f"gh issue create failed: {r.stderr.strip()}")
    print(r.stdout.strip())


# --- command line -----------------------------------------------------------------------------

def parser():
    ap = argparse.ArgumentParser(prog="review.py", description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True, metavar="{bundle,fetch,inputs,record}")

    p = sub.add_parser("bundle", help="assemble the evidence bundle of one commit from a built paper",
                       description="Assemble review-<sha7>/ (README.md, 'The bundle') from a built paper directory "
                       "holding thesis.pdf, reviewer.pdf, thesis.log and reviewer.log. In CI the commit comes from "
                       "GITHUB_REPOSITORY, GITHUB_SHA, GITHUB_REF_NAME, GITHUB_SERVER_URL, GITHUB_RUN_ID and GITHUB_RUN_ATTEMPT; "
                       "locally from git, and a dirty tree is refused. Locally, `docker image inspect --format "
                       "'{{index .RepoDigests 0}}' <image>` prints the image digest after the '@'.")
    p.add_argument("--built", required=True, metavar="DIR", help="the directory the paper was built in")
    p.add_argument("--lint", required=True, metavar="FILE", help="lint.json: texlua scripts/lint.lua all --doc reviewer --json")
    p.add_argument("--skim", required=True, metavar="DIR", help="the skim output directory (skim.md, skim.html, skim.json, assets/)")
    p.add_argument("--out", required=True, metavar="DIR", help="the bundle directory to create (must be empty or absent)")
    p.add_argument("--by", choices=("ci", "local"), help="who built it (default: ci inside GitHub Actions, else local)")
    p.add_argument("--allow-dirty", action="store_true", help="local only: bundle a dirty tree and record dirty: true")
    p.add_argument("--exit", action="append", metavar="NAME=N",
                   help="exit code of a step: thesis=N and reviewer=N (latexmk) are required; lint=N and skim=N are recorded when given")
    p.add_argument("--sha", help="the commit (default GITHUB_SHA or git HEAD); on pull_request runs GITHUB_SHA is the merge commit")
    p.add_argument("--ref", help="the branch or tag (default GITHUB_REF_NAME or the current branch)")
    p.add_argument("--repo", help="owner/name (default GITHUB_REPOSITORY or the origin remote)")
    p.add_argument("--image-ref", help="the container image that built the PDFs, as named in the workflow")
    p.add_argument("--image-digest", help="its digest, sha256:<hex>, recorded as given")
    p.set_defaults(func=cmd_bundle)

    p = sub.add_parser("fetch", help="download and verify the bundle of a commit from its CI run",
                       description="Find the paper.yml run of a commit, download its artifact review-<sha7> and check "
                       "every file hash and that manifest.json names the requested commit. Prints the directory.")
    p.add_argument("--repo", required=True, metavar="OWNER/NAME")
    p.add_argument("--sha", required=True, help="the commit, 7 to 40 hex digits")
    p.add_argument("--out", metavar="DIR", help="where to put the bundle (default: a fresh temporary directory)")
    p.set_defaults(func=cmd_fetch)

    p = sub.add_parser("inputs", help="make one directory per persona holding exactly its inputs",
                       description="For each persona, read `reads` from its file and copy exactly those inputs from the "
                       "verified bundle into a fresh temporary directory. Prints persona -> {dir, files, spine} as JSON.")
    p.add_argument("bundle", metavar="BUNDLE", help="a bundle directory printed by `fetch`")
    p.add_argument("personas", nargs="+", metavar="PERSONA")
    p.add_argument("--spine", metavar="FILE", help="the spine, for personas that read it; without it they are told there is none")
    p.add_argument("--skills", metavar="DIR", help=f"the personas directory (default {PERSONAS})")
    p.set_defaults(func=cmd_inputs)

    p = sub.add_parser("record", help="file one issue for a run",
                       description="Validate findings.json (README.md, 'findings.json') and open one issue on the paper "
                       "repository: the panel, the skim scores, one task-list line per finding, the manifest and the input hashes.")
    p.add_argument("findings", metavar="FINDINGS", help="findings.json")
    p.add_argument("--bundle", required=True, metavar="DIR", help="the bundle `fetch` printed; its manifest goes into the issue")
    p.add_argument("--inputs", metavar="FILE", help="the saved output of `review.py inputs`, when findings.json has no inputs")
    p.add_argument("--repo", metavar="OWNER/NAME", help="default: the repository named in the manifest")
    p.add_argument("--dry-run", action="store_true", help="print the title and body; do not touch GitHub")
    p.set_defaults(func=cmd_record)
    return ap


def main(argv=None):
    a = parser().parse_args(argv)
    try:
        a.func(a)
    except Fail as e:
        print(f"review.py: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
