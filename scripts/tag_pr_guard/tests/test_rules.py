import pytest

from tag_pr_guard.rules import App, ChangedFile, Config, evaluate

BOT = "june21621-tag-bump[bot]"
HUMAN = "June21621"
IMAGE = "ghcr.io/june21621/portfolio"
REPO = "June21621/portfolio"
OLD = "a" * 40
NEW = "b" * 40
OLD_DIGEST = "sha256:" + "1" * 64
NEW_DIGEST = "sha256:" + "2" * 64
CONFIG = Config(
    bot_login=BOT,
    signer_workflow="June21621/homelab/.github/workflows/build-and-bump.yaml",
    apps={"portfolio": App(repo=REPO, image=IMAGE)},
)


def overlay_path(env: str, app: str = "portfolio") -> str:
    return f"gitops/apps/{app}/overlays/{env}/kustomization.yaml"


def overlay(sha: str = OLD, digest: str = OLD_DIGEST, *, namespace: str = "portfolio", other: str = "") -> str:
    # 실제 overlay처럼 한글 주석이 있다(ASCII만 허용하면 정상 파일이 막힌다)
    return (
        "# 운영: chaos 엔드포인트 없음\n"
        "apiVersion: kustomize.config.k8s.io/v1beta1\n"
        "kind: Kustomization\n"
        f"namespace: {namespace}\n"
        "resources:\n"
        "  - ./namespace.yaml\n"
        "  - ../../base\n"
        "images:\n"
        f"{other}"
        f"  - name: {IMAGE}\n"
        f'    newTag: "{sha}"\n'
        f"    digest: {digest}\n"
    )


def bump(env: str, head: str | None = None, base: str | None = None, status: str = "modified") -> ChangedFile:
    return ChangedFile(
        path=overlay_path(env),
        status=status,
        base=overlay() if base is None else base,
        head=overlay(NEW, NEW_DIGEST) if head is None else head,
    )


class Recorder:
    def __init__(self, result: list[str] | None = None):
        self.calls: list[tuple] = []
        self.result = result or []

    def __call__(self, *args) -> list[str]:
        self.calls.append(args)
        return self.result


def run(files, author=BOT, sender=None, verify=None, ahead=None):
    verify = verify or Recorder()
    ahead = ahead or Recorder()
    errors = evaluate(author, files, CONFIG, verify, ahead, sender=sender)
    return errors, verify, ahead


def test_valid_bump_passes():
    errors, verify, ahead = run([bump("prod"), bump("lab")])
    assert errors == []
    assert ahead.calls == [(REPO, OLD, NEW)]
    assert verify.calls == [(IMAGE, NEW_DIGEST, REPO, NEW)]


# --- 사람 PR -------------------------------------------------------------------

def test_human_pr_passes_without_checks():
    f = ChangedFile(".github/workflows/x.yaml", "modified", "a", "evil")
    errors, verify, _ = run([f], author=HUMAN, sender=HUMAN)
    assert errors == []
    assert verify.calls == []


def test_human_pr_fails_when_bot_pushed_to_it():
    # 리뷰 C2: 봇 키로 사람 PR 브랜치에 커밋을 올리면, 작성자만 보는 면제를 악용할 수 있다
    errors, _, _ = run([bump("prod")], author=HUMAN, sender=BOT)
    assert any("봇이 사람 PR" in e for e in errors)


# --- 줄 구분 문자 숨기기 (리뷰 C1) ---------------------------------------------

@pytest.mark.parametrize("sep", [" ", " ", "\x85", "\r", "\x0b", "\x0c"])
def test_rejects_hidden_line_break_in_tag_line(sep):
    head = overlay(NEW, NEW_DIGEST).replace(
        f'    newTag: "{NEW}"\n', f'    newTag: "{NEW}"{sep}    newName: docker.io/attacker/x\n'
    )
    errors, verify, ahead = run([bump("prod", head=head)])
    assert errors
    assert verify.calls == [] and ahead.calls == []


@pytest.mark.parametrize("sep", [" ", "\r"])
def test_rejects_hidden_line_break_in_other_line(sep):
    head = overlay(NEW, NEW_DIGEST).replace("  - ../../base\n", f"  - ../../base{sep}patches: []\n")
    errors, _, _ = run([bump("prod", head=head)])
    assert errors


# --- 태그·다이제스트 외 변경 ---------------------------------------------------

def test_rejects_other_line_change():
    errors, verify, _ = run([bump("prod", head=overlay(NEW, NEW_DIGEST, namespace="kube-system"))])
    assert any("newTag·digest 외 변경" in e for e in errors)
    assert verify.calls == []


def test_rejects_added_line():
    head = overlay(NEW, NEW_DIGEST) + "    newName: docker.io/attacker/x\n"
    errors, _, _ = run([bump("prod", head=head)])
    assert any("줄 수" in e for e in errors)


def test_rejects_tag_change_of_other_image():
    other = '  - name: ghcr.io/evil/other\n    newTag: "' + OLD + '"\n    digest: ' + OLD_DIGEST + "\n"
    base = overlay(other=other)
    head = overlay(other=other.replace(OLD, NEW).replace(OLD_DIGEST, NEW_DIGEST))
    errors, _, _ = run([bump("prod", base=base, head=head)])
    assert any("newTag·digest 외 변경" in e for e in errors)


def test_rejects_tag_change_without_digest_change():
    # 태그만 바꾸고 다이제스트는 옛 이미지 것 → 검사한 이미지와 배포되는 이미지가 어긋난다
    errors, _, _ = run([bump("prod", head=overlay(NEW, OLD_DIGEST))])
    assert any("digest" in e for e in errors)


def test_rejects_no_change():
    errors, _, _ = run([bump("prod", head=overlay())])
    assert any("바뀐 것이 없음" in e for e in errors)


def test_rejects_overlay_without_digest_line():
    base = overlay().replace(f"    digest: {OLD_DIGEST}\n", "")
    head = overlay(NEW, NEW_DIGEST).replace(f"    digest: {NEW_DIGEST}\n", "")
    errors, _, _ = run([bump("prod", base=base, head=head)])
    assert any("형식" in e for e in errors)


@pytest.mark.parametrize("tag", ["latest", "abc1234", "B" * 40])
def test_rejects_short_or_nonhex_tag(tag):
    errors, verify, _ = run([bump("prod", head=overlay(tag, NEW_DIGEST))])
    assert errors
    assert verify.calls == []


def test_rejects_malformed_digest():
    errors, _, _ = run([bump("prod", head=overlay(NEW, "sha256:abc"))])
    assert errors


# --- 경로·상태 ---------------------------------------------------------------

def test_rejects_empty_pr():
    errors, _, _ = run([])
    assert any("바뀐 파일 없음" in e for e in errors)


@pytest.mark.parametrize("path", [
    "scripts/tag_pr_guard/src/tag_pr_guard/rules.py",
    ".github/workflows/tag-pr-guard.yaml",
    "gitops/root/evil.yaml",
])
def test_rejects_path_outside_overlays(path):
    errors, _, _ = run([ChangedFile(path, "modified", "a", "b")])
    assert any("허용 밖 파일" in e for e in errors)


def test_rejects_unknown_app():
    f = ChangedFile(overlay_path("prod", app="evil"), "modified", overlay(), overlay(NEW, NEW_DIGEST))
    errors, _, _ = run([f])
    assert any("설정에 없는 앱" in e for e in errors)


@pytest.mark.parametrize("status", ["added", "renamed", "removed"])
def test_rejects_added_or_renamed_file(status):
    errors, _, _ = run([bump("prod", status=status)])
    assert any("수정이 아닌 변경" in e for e in errors)


@pytest.mark.parametrize("side", ["base", "head"])
def test_rejects_missing_content(side):
    f = bump("prod")
    f = ChangedFile(f.path, f.status, None if side == "base" else f.base, None if side == "head" else f.head)
    errors, _, _ = run([f])
    assert any("판단 불가" in e for e in errors)


def test_rejects_two_different_shas_in_one_app():
    errors, verify, _ = run([bump("prod"), bump("lab", head=overlay("c" * 40, NEW_DIGEST))])
    assert any("서로 다름" in e for e in errors)
    assert verify.calls == []


# --- 롤백·증명서 (리뷰 I1·I2) ---------------------------------------------------

def test_rejects_rollback_to_older_build():
    errors, verify, _ = run([bump("prod"), bump("lab")], ahead=Recorder(["이전 커밋으로 되돌림"]))
    assert "이전 커밋으로 되돌림" in errors
    assert verify.calls == []


def test_attestation_failure_is_reported():
    errors, _, _ = run([bump("prod"), bump("lab")], verify=Recorder(["증명서 없음"]))
    assert "증명서 없음" in errors
