import pytest

from tag_pr_guard.rules import App, ChangedFile, Config, evaluate

BOT = "june21621-tag-bump[bot]"
IMAGE = "ghcr.io/june21621/portfolio"
OLD = "a" * 40
NEW = "b" * 40
CONFIG = Config(
    bot_login=BOT,
    signer_workflow="June21621/homelab/.github/workflows/build-and-bump.yaml",
    apps={"portfolio": App(repo="June21621/portfolio", image=IMAGE)},
)


def overlay(env: str, app: str = "portfolio") -> str:
    return f"gitops/apps/{app}/overlays/{env}/kustomization.yaml"


def tag_patch(old: str = OLD, new: str = NEW, image: str = IMAGE, extra: str = "") -> str:
    return (
        "@@ -8,5 +8,5 @@ patches:\n"
        " images:\n"
        f"   - name: {image}\n"
        f'-    newTag: "{old}"\n'
        f'+    newTag: "{new}"\n' + extra
    )


def bump(env: str, **kw) -> ChangedFile:
    return ChangedFile(path=overlay(env), status="modified", patch=tag_patch(**kw))


class FakeVerify:
    def __init__(self, result: list[str] | None = None):
        self.calls: list[tuple[str, str, str]] = []
        self.result = result or []

    def __call__(self, image_ref: str, repo: str, sha: str) -> list[str]:
        self.calls.append((image_ref, repo, sha))
        return self.result


def run(files, author=BOT, verify=None):
    verify = verify or FakeVerify()
    return evaluate(author, files, CONFIG, verify), verify


def test_valid_bump_passes():
    errors, verify = run([bump("prod"), bump("lab")])
    assert errors == []
    assert verify.calls == [(f"{IMAGE}:{NEW}", "June21621/portfolio", NEW)]


def test_human_pr_passes_without_checks():
    errors, verify = run([ChangedFile(".github/workflows/x.yaml", "modified", "+evil")], author="June21621")
    assert errors == []
    assert verify.calls == []


def test_rejects_empty_pr():
    errors, _ = run([])
    assert any("바뀐 파일 없음" in e for e in errors)


def test_rejects_extra_line():
    errors, verify = run([bump("prod", extra="+  replicas: 3\n")])
    assert any("newTag 외 변경" in e for e in errors)
    assert verify.calls == []


def test_rejects_path_outside_overlays():
    f = ChangedFile("scripts/tag_pr_guard/src/tag_pr_guard/rules.py", "modified", tag_patch())
    errors, _ = run([f])
    assert any("허용 밖 파일" in e for e in errors)


def test_rejects_workflow_file():
    f = ChangedFile(".github/workflows/tag-pr-guard.yaml", "modified", tag_patch())
    errors, _ = run([f])
    assert any("허용 밖 파일" in e for e in errors)


def test_rejects_unknown_app():
    f = ChangedFile(overlay("prod", app="evil"), "modified", tag_patch())
    errors, _ = run([f])
    assert any("설정에 없는 앱" in e for e in errors)


@pytest.mark.parametrize("status", ["added", "renamed", "removed"])
def test_rejects_added_or_renamed_file(status):
    f = ChangedFile(overlay("prod"), status, tag_patch())
    errors, _ = run([f])
    assert any("수정이 아닌 변경" in e for e in errors)


def test_rejects_missing_patch():
    errors, _ = run([ChangedFile(overlay("prod"), "modified", None)])
    assert any("diff 없음" in e for e in errors)


@pytest.mark.parametrize("tag", ["latest", "abc1234", "B" * 40])
def test_rejects_short_or_nonhex_tag(tag):
    errors, verify = run([bump("prod", new=tag)])
    assert errors
    assert verify.calls == []


def test_rejects_two_different_shas_in_one_app():
    errors, verify = run([bump("prod", new=NEW), bump("lab", new="c" * 40)])
    assert any("SHA가 서로 다름" in e for e in errors)
    assert verify.calls == []


def test_rejects_tag_change_of_other_image():
    # 같은 overlay에 다른 이미지가 있을 때, 그 이미지의 newTag를 바꾼 diff는 설정의 이미지를 증명하지 못한다
    errors, verify = run([bump("prod", image="ghcr.io/evil/other")])
    assert any("설정의 이미지" in e for e in errors)
    assert verify.calls == []


def test_rejects_unbalanced_lines():
    patch = f'@@ -8,4 +8,5 @@\n   - name: {IMAGE}\n+    newTag: "{NEW}"\n'
    errors, _ = run([ChangedFile(overlay("prod"), "modified", patch)])
    assert errors


def test_attestation_failure_is_reported():
    errors, _ = run([bump("prod"), bump("lab")], verify=FakeVerify(["증명서 없음"]))
    assert "증명서 없음" in errors
