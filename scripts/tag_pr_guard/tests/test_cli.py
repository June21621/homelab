import subprocess
from pathlib import Path

from tag_pr_guard import cli, github
from tag_pr_guard.rules import ChangedFile

REPO_ROOT = Path(__file__).resolve().parents[3]
CONFIG = REPO_ROOT / "gitops" / "image-sources.yaml"
BOT = "june21621-tag-bump[bot]"
NEW = "b" * 40
PATCH = (
    "@@ -8,5 +8,5 @@\n"
    "   - name: ghcr.io/june21621/portfolio\n"
    f'-    newTag: "{"a" * 40}"\n'
    f'+    newTag: "{NEW}"\n'
)


def files(patch=PATCH):
    return [
        ChangedFile(f"gitops/apps/portfolio/overlays/{env}/kustomization.yaml", "modified", patch)
        for env in ("prod", "lab")
    ]


def run_cli(tmp_path, monkeypatch, pr_files, attestation=()):
    calls = []

    def fake_verify(image_ref, repo, sha, signer_workflow):
        calls.append((image_ref, repo, sha, signer_workflow))
        return list(attestation)

    monkeypatch.setattr(github, "list_pr_files", lambda repo, pr: pr_files)
    monkeypatch.setattr(github, "verify_attestation", fake_verify)
    report = tmp_path / "report.md"
    code = cli.main(
        ["--repo", "June21621/homelab", "--pr", "11", "--author", BOT,
         "--config", str(CONFIG), "--report", str(report)]
    )
    return code, report.read_text(encoding="utf-8"), calls


def test_load_real_config():
    config = cli.load_config(CONFIG)
    assert config.bot_login == BOT
    assert config.apps["portfolio"].image == "ghcr.io/june21621/portfolio"


def test_pass_exits_zero_with_empty_report(tmp_path, monkeypatch):
    code, report, calls = run_cli(tmp_path, monkeypatch, files())
    assert code == 0
    assert report == ""
    assert calls == [(
        f"ghcr.io/june21621/portfolio:{NEW}", "June21621/portfolio", NEW,
        "June21621/homelab/.github/workflows/build-and-bump.yaml",
    )]


def test_fail_exits_one_with_reasons(tmp_path, monkeypatch):
    code, report, _ = run_cli(tmp_path, monkeypatch, files(PATCH + "+  replicas: 3\n"))
    assert code == 1
    assert "newTag 외 변경" in report
    assert report.count("\n- ") >= 1


def test_attestation_failure_fails(tmp_path, monkeypatch):
    code, report, _ = run_cli(tmp_path, monkeypatch, files(), attestation=["빌드 증명서 검증 실패"])
    assert code == 1
    assert "빌드 증명서 검증 실패" in report


def test_verify_attestation_pins_main_and_signer(monkeypatch):
    seen = {}

    def fake_run(args, **kw):
        seen["args"], seen["kw"] = args, kw
        return subprocess.CompletedProcess(args, 1, "", "no matching attestations\n")

    monkeypatch.setattr(subprocess, "run", fake_run)
    errors = github.verify_attestation("img:sha", "o/app", "s" * 40, "o/homelab/.github/workflows/b.yaml")
    args = seen["args"]
    assert args[:3] == ["gh", "attestation", "verify"]
    assert "oci://img:sha" in args
    assert args[args.index("--signer-workflow") + 1] == "o/homelab/.github/workflows/b.yaml"
    assert args[args.index("--source-ref") + 1] == "refs/heads/main"
    assert args[args.index("--source-digest") + 1] == "s" * 40
    assert seen["kw"].get("shell") in (None, False)
    assert errors and "no matching attestations" in errors[0]


def test_list_pr_files_flattens_pages(monkeypatch):
    out = '[[{"filename": "a", "status": "modified", "patch": "+x"}], [{"filename": "b", "status": "removed"}]]'
    monkeypatch.setattr(subprocess, "run", lambda args, **kw: subprocess.CompletedProcess(args, 0, out, ""))
    assert github.list_pr_files("o/r", 3) == [
        ChangedFile("a", "modified", "+x"),
        ChangedFile("b", "removed", None),
    ]
