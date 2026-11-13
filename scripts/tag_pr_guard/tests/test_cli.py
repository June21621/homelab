import subprocess
from pathlib import Path

from tag_pr_guard import cli, github
from tag_pr_guard.rules import ChangedFile

REPO_ROOT = Path(__file__).resolve().parents[3]
CONFIG = REPO_ROOT / "gitops" / "image-sources.yaml"
BOT = "june21621-tag-bump[bot]"
IMAGE = "ghcr.io/june21621/portfolio"
OLD, NEW = "a" * 40, "b" * 40
OLD_DIGEST, NEW_DIGEST = "sha256:" + "1" * 64, "sha256:" + "2" * 64
BASE_SHA, HEAD_SHA = "c" * 40, "d" * 40


def overlay(sha, digest, extra=""):
    return f'images:\n  - name: {IMAGE}\n    newTag: "{sha}"\n    digest: {digest}\n{extra}'


PATHS = [f"gitops/apps/portfolio/overlays/{env}/kustomization.yaml" for env in ("prod", "lab")]


def run_cli(tmp_path, monkeypatch, head_extra="", attestation=(), ahead=(), shas=True, author=BOT, sender=None,
            pr_paths=PATHS):
    calls = {"verify": [], "ahead": [], "get": []}

    def fake_get(repo, path, ref):
        calls["get"].append((repo, path, ref))
        return overlay(OLD, OLD_DIGEST) if ref == BASE_SHA else overlay(NEW, NEW_DIGEST, head_extra)

    def fake_verify(image, digest, repo, sha, signer_workflow):
        calls["verify"].append((image, digest, repo, sha, signer_workflow))
        return list(attestation)

    def fake_ahead(repo, old, new):
        calls["ahead"].append((repo, old, new))
        return list(ahead)

    monkeypatch.setattr(github, "list_pr_files", lambda repo, pr: [ChangedFile(p, "modified") for p in pr_paths])
    monkeypatch.setattr(github, "get_file", fake_get)
    monkeypatch.setattr(github, "verify_attestation", fake_verify)
    monkeypatch.setattr(github, "compare_ahead", fake_ahead)
    report = tmp_path / "report.md"
    argv = ["--repo", "June21621/homelab", "--pr", "11", "--author", author,
            "--config", str(CONFIG), "--report", str(report)]
    if shas:
        argv += ["--base-sha", BASE_SHA, "--head-sha", HEAD_SHA]
    if sender:
        argv += ["--sender", sender]
    code = cli.main(argv)
    return code, report.read_text(encoding="utf-8"), calls


def test_load_real_config():
    config = cli.load_config(CONFIG)
    assert config.bot_login == BOT
    assert config.apps["portfolio"].image == IMAGE


def test_pass_exits_zero_with_empty_report(tmp_path, monkeypatch):
    code, report, calls = run_cli(tmp_path, monkeypatch)
    assert code == 0
    assert report == ""
    # 파일 원문은 PR이 아니라 base·head 커밋에서 받는다
    assert ("June21621/homelab", PATHS[0], BASE_SHA) in calls["get"]
    assert ("June21621/homelab", PATHS[0], HEAD_SHA) in calls["get"]
    assert calls["ahead"] == [("June21621/portfolio", OLD, NEW)]
    assert calls["verify"] == [(IMAGE, NEW_DIGEST, "June21621/portfolio", NEW,
                                "June21621/homelab/.github/workflows/build-and-bump.yaml")]


def test_fail_exits_one_with_reasons(tmp_path, monkeypatch):
    code, report, _ = run_cli(tmp_path, monkeypatch, head_extra="  replicas: 3\n")
    assert code == 1
    assert "줄 수" in report


def test_bot_pr_without_shas_fails_closed(tmp_path, monkeypatch):
    # 옛 워크플로가 새 인자를 안 넘기면 봇 PR은 실패해야 한다 (판단 불가 = 거부)
    code, report, calls = run_cli(tmp_path, monkeypatch, shas=False)
    assert code == 1
    assert "SHA" in report
    assert calls["verify"] == []


def test_human_pr_without_new_args_still_passes(tmp_path, monkeypatch):
    # 이 변경을 넣는 PR은 옛 워크플로로 돈다. 사람 PR이 막히면 병합할 수 없다
    code, report, calls = run_cli(tmp_path, monkeypatch, shas=False, author="June21621")
    assert code == 0
    assert calls["get"] == []


def test_human_pr_pushed_by_bot_fails(tmp_path, monkeypatch):
    code, report, _ = run_cli(tmp_path, monkeypatch, author="June21621", sender=BOT)
    assert code == 1
    assert "가로채기" in report


def test_does_not_fetch_files_outside_overlays(tmp_path, monkeypatch):
    # 허용 밖 경로는 API URL에 넣지 않는다 (공격자가 정한 경로)
    code, report, calls = run_cli(tmp_path, monkeypatch, pr_paths=["../../x?ref=evil"])
    assert code == 1
    assert calls["get"] == []


def test_attestation_failure_fails(tmp_path, monkeypatch):
    code, report, _ = run_cli(tmp_path, monkeypatch, attestation=["빌드 증명서 검증 실패"])
    assert code == 1
    assert "빌드 증명서 검증 실패" in report


def test_rollback_fails(tmp_path, monkeypatch):
    code, report, calls = run_cli(tmp_path, monkeypatch, ahead=["이전 커밋"])
    assert code == 1
    assert calls["verify"] == []


def test_report_cannot_break_out_of_code_block(tmp_path, monkeypatch):
    # 리뷰 M3: 공격자가 정한 경로가 코멘트에 들어간다. 멘션·링크가 동작하지 않게 코드 블록 안에만 둔다
    code, report, _ = run_cli(tmp_path, monkeypatch, pr_paths=["```\n@someone [x](http://evil)"])
    assert code == 1
    body = report.split("```text\n", 1)[1]
    assert body.count("```") == 1  # 닫는 펜스 하나뿐


def fake_run(seen, returncode=0, stdout="", stderr=""):
    def run(args, **kw):
        seen["args"], seen["kw"] = args, kw
        return subprocess.CompletedProcess(args, returncode, stdout, stderr)
    return run


def test_verify_attestation_pins_digest_main_and_exact_signer(monkeypatch):
    seen = {}
    monkeypatch.setattr(subprocess, "run", fake_run(seen, 1, "", "no matching attestations\n"))
    errors = github.verify_attestation(IMAGE, NEW_DIGEST, "o/app", NEW, "o/homelab/.github/workflows/b.yaml")
    args = seen["args"]
    assert args[:3] == ["gh", "attestation", "verify"]
    assert f"oci://{IMAGE}@{NEW_DIGEST}" in args  # 태그가 아니라 다이제스트로 (태그는 덮어쓸 수 있다)
    assert args[args.index("--cert-identity") + 1] == (
        "https://github.com/o/homelab/.github/workflows/b.yaml@refs/heads/main"
    )
    assert "--deny-self-hosted-runners" in args
    assert args[args.index("--source-ref") + 1] == "refs/heads/main"
    assert args[args.index("--source-digest") + 1] == NEW
    assert seen["kw"].get("shell") in (None, False)
    assert errors and "no matching attestations" in errors[0]


def test_compare_ahead(monkeypatch):
    seen = {}
    monkeypatch.setattr(subprocess, "run", fake_run(seen, 0, "ahead\n"))
    assert github.compare_ahead("o/app", OLD, NEW) == []
    assert f"repos/o/app/compare/{OLD}...{NEW}" in seen["args"]
    for status in ("behind", "diverged", "identical"):
        monkeypatch.setattr(subprocess, "run", fake_run(seen, 0, f"{status}\n"))
        assert github.compare_ahead("o/app", OLD, NEW)
    monkeypatch.setattr(subprocess, "run", fake_run(seen, 1, "", "Not Found"))
    assert github.compare_ahead("o/app", OLD, NEW)


def test_get_file_returns_raw_text_or_none(monkeypatch):
    seen = {}
    monkeypatch.setattr(subprocess, "run", fake_run(seen, 0, "a b\n".encode()))
    assert github.get_file("o/r", "gitops/x.yaml", HEAD_SHA) == "a b\n"  # 문자를 바꾸거나 버리지 않는다
    assert "repos/o/r/contents/gitops/x.yaml?ref=" + HEAD_SHA in seen["args"]
    monkeypatch.setattr(subprocess, "run", fake_run(seen, 0, b"\xff\xfe"))
    assert github.get_file("o/r", "x", HEAD_SHA) is None  # UTF-8이 아니면 판단 불가
    monkeypatch.setattr(subprocess, "run", fake_run(seen, 1, b"", b"404"))
    assert github.get_file("o/r", "x", HEAD_SHA) is None


def test_list_pr_files_flattens_pages(monkeypatch):
    out = '[[{"filename": "a", "status": "modified", "patch": "+x"}], [{"filename": "b", "status": "removed"}]]'
    monkeypatch.setattr(subprocess, "run", lambda args, **kw: subprocess.CompletedProcess(args, 0, out, ""))
    assert github.list_pr_files("o/r", 3) == [ChangedFile("a", "modified"), ChangedFile("b", "removed")]
