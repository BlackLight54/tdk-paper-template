"""Tests for review.py. No network: `gh` is replaced by a fake. Run from the repository root:

    python3 -m unittest scripts/review/test_review.py
"""
import contextlib
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))
import review  # noqa: E402

SHA = "0123456789abcdef0123456789abcdef01234567"
DIGEST = "sha256:" + "ab" * 32
LOG = "This is XeTeX, Version 3.141592653 (TeX Live 2025)\n! Undefined control sequence.\n! Missing $ inserted.\n"
LOG += "LaTeX Warning: Reference `fig:a' on page 3 undefined on input line 9.\n"
LOG += "Package natbib Warning: Citation `very-long-key' on page 12\n(natbib)  undefined on input line 70.\n"
LOG += "LaTeX Warning: There were undefined references.\n"
CI_ENV = {"GITHUB_ACTIONS": "true", "GITHUB_REPOSITORY": "BlackLight54/TDK26-Example", "GITHUB_SHA": SHA,
          "GITHUB_REF_NAME": "main", "GITHUB_SERVER_URL": "https://github.com", "GITHUB_RUN_ID": "42", "GITHUB_RUN_ATTEMPT": "2"}


def call(*argv):
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        code = review.main([str(a) for a in argv])
    return code, out.getvalue(), err.getvalue()


def write(path, content):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(content if isinstance(content, bytes) else content.encode())
    return path


def cp(code=0, out="", err=""):
    return subprocess.CompletedProcess([], code, out, err)


class Workdir(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="test-review-"))
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)

    def make_bundle(self, name="bundle", extra=()):
        """A CI bundle made by `review.py bundle` from a fake build."""
        built = self.tmp / f"{name}-built"
        for doc in ("thesis", "reviewer"):
            write(built / f"{doc}.pdf", b"%PDF-1.4\n1 0 obj << /Type /Page >> endobj\n2 0 obj << /Type /Pages >> endobj\n")
            write(built / f"{doc}.log", LOG)
        write(self.tmp / f"{name}-lint.json", json.dumps({"phase": "polish", "phase_source": "thesis.tex", "profile": "tdk"}))
        write(self.tmp / f"{name}-skim" / "skim.md", "# skim\n![Figure 1](assets/fig1.png)\n")
        write(self.tmp / f"{name}-skim" / "skim.html", "<html></html>")
        write(self.tmp / f"{name}-skim" / "assets" / "fig1.png", b"png1")
        write(self.tmp / f"{name}-skim" / "assets" / "page-001.png", b"png2")
        out = self.tmp / name
        args = ["bundle", "--built", built, "--lint", self.tmp / f"{name}-lint.json", "--skim", self.tmp / f"{name}-skim",
                "--out", out, "--exit", "thesis=0", "--exit", "reviewer=0", "--exit", "lint=1", "--exit", "skim=0",
                "--image-ref", "texlive/texlive:latest", "--image-digest", DIGEST, *extra]
        with mock.patch.dict(os.environ, CI_ENV):
            code, _, err = call(*args)
        self.assertEqual(code, 0, err)
        return out


class TestBundle(Workdir):
    def test_counts_in_a_log(self):
        self.assertEqual(review.count_errors(LOG), 2)
        self.assertEqual(review.count_undefined(LOG), 2)  # the second one is wrapped; the summary line is not a warning

    def test_manifest_has_every_field_of_the_contract(self):
        m = review.load_manifest(self.make_bundle())
        self.assertEqual([m["schema"], m["repo"], m["sha"], m["ref"]], [1, "BlackLight54/TDK26-Example", SHA, "main"])
        self.assertEqual(m["built"], {"by": "ci", "run_url": "https://github.com/BlackLight54/TDK26-Example/actions/runs/42", "run_attempt": 2})
        self.assertEqual(m["image"], {"ref": "texlive/texlive:latest", "digest": DIGEST})
        self.assertEqual([m["phase"], m["phase_source"], m["profile"]], ["polish", "thesis.tex", "tdk"])
        self.assertEqual(m["builds"][1], {"doc": "reviewer", "engine": "xelatex", "latexmk_exit": 0, "errors": 2, "undefined": 2, "pages": 1})
        self.assertEqual([m["lint"], m["skim"]], [{"exit": 1}, {"exit": 0}])
        self.assertEqual(set(m["files"]), {"thesis.pdf", "reviewer.pdf", "logs/thesis.log", "logs/reviewer.log", "lint.json",
                                           "skim/skim.md", "skim/skim.html", "skim/assets/fig1.png", "skim/assets/page-001.png"})

    def test_sha_and_ref_options_override_the_environment(self):
        other = "f" * 40
        m = review.load_manifest(self.make_bundle(extra=["--sha", other, "--ref", "feature"]))
        self.assertEqual([m["sha"], m["ref"]], [other, "feature"])

    def test_a_digest_is_recorded_as_given_and_checked_for_its_form(self):
        built = self.tmp / "b"
        code, _, err = call("bundle", "--built", built, "--lint", "x", "--skim", "x", "--out", self.tmp / "o",
                            "--exit", "thesis=0", "--exit", "reviewer=0", "--image-digest", "latest")
        self.assertEqual(code, 1)
        self.assertIn("sha256:<hex>", err)

    def test_a_dirty_local_tree_is_refused_unless_allowed(self):
        repo = self.tmp / "paper"
        git = lambda *a: subprocess.run(["git", "-C", str(repo), "-c", "user.name=t", "-c", "user.email=t@t", *a], check=True, capture_output=True)
        repo.mkdir()
        git("init", "-q")
        write(repo / "thesis.tex", "x")
        git("add", "thesis.tex")
        git("commit", "-q", "-m", "x")
        for doc in ("thesis", "reviewer"):
            write(repo / f"{doc}.log", LOG)
            write(repo / f"{doc}.pdf", b"%PDF-1.4 /Type /Page")
        write(self.tmp / "lint.json", "{}")
        write(self.tmp / "skim" / "skim.md", "x")
        write(repo / "thesis.tex", "edited")
        args = ["bundle", "--built", repo, "--lint", self.tmp / "lint.json", "--skim", self.tmp / "skim", "--exit", "thesis=0",
                "--exit", "reviewer=0", "--by", "local", "--repo", "a/b"]
        code, _, err = call(*args, "--out", self.tmp / "o1")
        self.assertEqual(code, 1)
        self.assertIn("dirty", err)
        code, _, err = call(*args, "--out", self.tmp / "o2", "--allow-dirty")
        self.assertEqual(code, 0, err)
        built = review.load_manifest(self.tmp / "o2")["built"]
        self.assertTrue(built["dirty"])
        self.assertNotIn("run_url", built)


class TestFetch(Workdir):
    def fake_gh(self, bundle, runs=None, downloads=True):
        runs = [{"databaseId": 7, "status": "completed", "conclusion": "failure", "createdAt": "2026-10-28"}] if runs is None else runs
        calls = []
        def gh(args):
            calls.append(args)
            if args[:2] == ["run", "list"]:
                return cp(out=json.dumps(runs))
            if args[:2] == ["run", "download"]:
                if not downloads:
                    return cp(1, err="no valid artifacts found to download")
                shutil.copytree(bundle, args[args.index("-D") + 1], dirs_exist_ok=True)
                return cp()
            raise AssertionError(args)
        gh.calls = calls
        return gh

    def fetch(self, gh, *extra):
        with mock.patch.object(review, "gh", gh):
            return call("fetch", "--repo", "BlackLight54/TDK26-Example", "--sha", SHA, "--out", self.tmp / "got", *extra)

    def test_a_whole_bundle_is_fetched_and_its_path_printed(self):
        bundle = self.make_bundle()
        gh = self.fake_gh(bundle)
        code, out, err = self.fetch(gh)
        self.assertEqual((code, out.strip()), (0, str(self.tmp / "got")), err)
        self.assertEqual(gh.calls[1][:5], ["run", "download", "7", "-R", "BlackLight54/TDK26-Example"])
        self.assertIn(f"review-{SHA[:7]}", gh.calls[1])

    def test_a_changed_file_fails_the_verification_and_is_named(self):
        bundle = self.make_bundle()
        write(bundle / "reviewer.pdf", b"another build")
        code, _, err = self.fetch(self.fake_gh(bundle))
        self.assertEqual(code, 1)
        self.assertIn("reviewer.pdf: SHA-256 differs", err)

    def test_an_unlisted_or_missing_file_fails_the_verification(self):
        bundle = self.make_bundle()
        write(bundle / "extra.txt", "x")
        (bundle / "lint.json").unlink()
        _, problems = review.verify_bundle(bundle, SHA)
        self.assertEqual(sorted(problems), ["extra.txt: in the bundle but not listed in manifest.json",
                                            "lint.json: listed in manifest.json but missing"])

    def test_a_bundle_of_another_commit_is_refused(self):
        bundle = self.make_bundle()
        m = review.load_manifest(bundle)
        m["sha"] = "e" * 40
        write(bundle / "manifest.json", json.dumps(m))
        code, _, err = self.fetch(self.fake_gh(bundle))
        self.assertEqual(code, 1)
        self.assertIn("manifest.json: sha is", err)

    def test_an_expired_artifact_prints_the_rerun_command(self):
        code, _, err = self.fetch(self.fake_gh(None, downloads=False))
        self.assertEqual(code, 1)
        self.assertIn("gh run rerun 7 -R BlackLight54/TDK26-Example", err)

    def test_no_run_is_said_plainly(self):
        code, _, err = self.fetch(self.fake_gh(None, runs=[]))
        self.assertEqual(code, 1)
        self.assertIn("no paper.yml run", err)


class TestInputs(Workdir):
    def inputs(self, bundle, *personas, spine=None):
        extra = ["--spine", spine] if spine else []
        code, out, err = call("inputs", bundle, *personas, *extra)
        self.assertEqual(code, 0, err)
        result = json.loads(out)
        for entry in result.values():
            self.addCleanup(shutil.rmtree, entry["dir"], ignore_errors=True)
        return result

    def test_every_persona_file_has_valid_frontmatter(self):
        for path in sorted(review.PERSONAS.glob("*.md")):
            reads = review.persona_reads(review.PERSONAS, path.stem)
            self.assertTrue(set(reads) <= set(review.READS), path.name)
        self.assertEqual(review.persona_reads(review.PERSONAS, "skim"), ["skim-view"])

    def test_a_persona_directory_holds_its_reads_and_nothing_else(self):
        bundle = self.make_bundle()
        spine = write(self.tmp / "my-spine.md", "claims")
        r = self.inputs(bundle, "skim", "cryptographer", "champion", spine=spine)

        skim = Path(r["skim"]["dir"])
        self.assertEqual(sorted(r["skim"]["files"]), ["assets/fig1.png", "assets/page-001.png", "skim.md"])
        self.assertFalse((skim / "reviewer.pdf").exists())
        self.assertFalse((skim / "spine.md").exists())
        self.assertFalse(r["skim"]["spine"])

        self.assertEqual(sorted(r["cryptographer"]["files"]), ["reviewer.pdf", "spine.md"])
        self.assertTrue(r["cryptographer"]["spine"])
        self.assertEqual(review.walk_files(r["cryptographer"]["dir"]), ["reviewer.pdf", "spine.md"])

        self.assertEqual(len({r[p]["dir"] for p in r}), 3)  # one directory each
        self.assertFalse(review.inside_repo(r["champion"]["dir"]))
        m = review.load_manifest(bundle)
        self.assertEqual(r["cryptographer"]["files"]["reviewer.pdf"], m["files"]["reviewer.pdf"])

    def test_without_a_spine_the_entry_says_so(self):
        r = self.inputs(self.make_bundle(), "cryptographer")
        self.assertFalse(r["cryptographer"]["spine"])
        self.assertEqual(review.walk_files(r["cryptographer"]["dir"]), ["reviewer.pdf"])

    def test_a_tampered_bundle_yields_no_directories(self):
        bundle = self.make_bundle()
        write(bundle / "skim" / "skim.md", "edited")
        before = set(Path(tempfile.gettempdir()).glob("review-*"))
        code, _, err = call("inputs", bundle, "skim")
        self.assertEqual(code, 1)
        self.assertIn("skim/skim.md", err)
        self.assertEqual(set(Path(tempfile.gettempdir()).glob("review-*")), before)


class TestRecord(Workdir):
    def setUp(self):
        super().setUp()
        self.bundle = self.make_bundle()
        self.inputs = json.loads(call_inputs(self.bundle, "skim", "cryptographer"))
        for e in self.inputs.values():
            self.addCleanup(shutil.rmtree, e["dir"], ignore_errors=True)
        write(self.tmp / "inputs.json", json.dumps(self.inputs))
        self.findings = {
            "sha": SHA, "bundle": f"review-{SHA[:7]}", "mode": "draft", "panel": ["skim", "cryptographer"],
            "skipped": {"process-modeling": "no BPMN"}, "model": "claude-opus-5-5",
            "scores": {"A": [4, 5], "B/1": [3, 4], "B/2": [2, 4], "C": [7, 8], "D/1": [3, 5], "D/2": [3, 5], "E": [5, 8]},
            "findings": [
                {"id": "F1", "persona": "cryptographer", "criterion": "D/2", "severity": "blocker",
                 "where": 'p. 14 "the verifier learns nothing"', "objection": "No adversary is defined.\nIt is implied.", "answer": "Add Def. 2 to ch. 4"},
                {"id": "F2", "persona": "skim", "criterion": "E", "severity": "major", "where": "SG2", "objection": "SG2 has no row", "answer": "Add it"},
            ]}

    def record(self, *extra, findings=None):
        write(self.tmp / "findings.json", json.dumps(findings or self.findings))
        return call("record", self.tmp / "findings.json", "--bundle", self.bundle, "--inputs", self.tmp / "inputs.json", *extra)

    def test_dry_run_renders_every_finding_and_the_manifest(self):
        code, out, err = self.record("--dry-run")
        self.assertEqual(code, 0, err)
        self.assertRegex(out, r"Title: Review \d{4}-\d\d-\d\d 0123456\n")
        self.assertIn("- [ ] F1 cryptographer · D/2 · blocker · p. 14 \"the verifier learns nothing\": No adversary is defined. It is implied. Answer: Add Def. 2 to ch. 4", out)
        self.assertIn("- [ ] F2 skim · E · major · SG2: SG2 has no row. Answer: Add it", out)
        self.assertIn("| E | 5 | 8 |", out)
        self.assertIn("Total 24.5 of 35", out)
        self.assertIn("`review-confirmed`", out)
        self.assertIn("https://github.com/BlackLight54/TDK26-Example/actions/runs/42", out)
        manifest = review.load_manifest(self.bundle)
        self.assertIn(json.dumps(manifest, indent=2), out)
        self.assertIn(manifest["files"]["reviewer.pdf"], out)  # in the manifest block and in the inputs block

    def test_a_finding_outside_the_contract_is_refused(self):
        self.findings["findings"][0]["severity"] = "fatal"
        self.findings["findings"][1]["persona"] = "nobody"
        code, _, err = self.record("--dry-run")
        self.assertEqual(code, 1)
        self.assertIn("finding F1: severity must be one of", err)
        self.assertIn("finding F2: persona 'nobody' is not in the panel", err)

    def test_scores_go_with_the_skim(self):
        del self.findings["scores"]
        code, _, err = self.record("--dry-run")
        self.assertEqual(code, 1)
        self.assertIn("scores: the skim ran", err)

    def test_input_hashes_must_come_from_the_bundle(self):
        self.inputs["cryptographer"]["files"]["reviewer.pdf"] = "0" * 64
        write(self.tmp / "inputs.json", json.dumps(self.inputs))
        code, _, err = self.record("--dry-run")
        self.assertEqual(code, 1)
        self.assertIn("cryptographer/reviewer.pdf", err)

    def test_filing_runs_gh_issue_create_and_prints_the_url(self):
        seen = {}
        def gh(args):
            seen["args"] = args
            seen["body"] = Path(args[args.index("--body-file") + 1]).read_text()
            return cp(out="https://github.com/BlackLight54/TDK26-Example/issues/3\n")
        with mock.patch.object(review, "gh", gh):
            code, out, err = self.record()
        self.assertEqual((code, out.strip()), (0, "https://github.com/BlackLight54/TDK26-Example/issues/3"), err)
        self.assertEqual(seen["args"][:4], ["issue", "create", "-R", "BlackLight54/TDK26-Example"])
        self.assertIn("F2 skim", seen["body"])


def call_inputs(bundle, *personas):
    code, out, err = call("inputs", bundle, *personas)
    assert code == 0, err
    return out


if __name__ == "__main__":
    unittest.main()
