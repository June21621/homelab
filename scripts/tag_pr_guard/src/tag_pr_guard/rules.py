"""태그 PR 검사 규칙. GitHub을 부르지 않는 순수 함수만 둔다.

각 검사는 실패 이유 문자열 리스트를 돌려준다. 빈 리스트 = 통과.
PR의 변경은 base·head 양쪽 파일 원문을 데이터로만 읽는다. PR 브랜치의 코드는 실행하지 않는다.

diff 텍스트(patch)를 쓰지 않는 이유: git은 `\\n`만 줄 끝으로 보지만 YAML 파서는 `\\r`·U+2028 같은
문자도 줄바꿈으로 본다. diff에서 "태그 한 줄"로 보이는 변경에 다른 YAML 줄을 숨길 수 있다(리뷰 C1).
그래서 원문을 `\\n`으로만 나눠 줄 단위로 정확히 비교하고, 바뀐 줄은 엄격한 정규식과 전체 일치해야 한다.
"""

import re
from collections.abc import Callable
from dataclasses import dataclass

OVERLAY_PATH = re.compile(r"\Agitops/apps/([a-z0-9-]+)/overlays/[a-z0-9-]+/kustomization\.yaml\Z")
TAG_LINE = re.compile(r'\A    newTag: "([0-9a-f]{40})"\Z')
DIGEST_LINE = re.compile(r"\A    digest: (sha256:[0-9a-f]{64})\Z")
# YAML이 줄바꿈으로 볼 수 있는데 git은 줄 끝으로 보지 않는 문자
HIDDEN_BREAKS = re.compile("[\r\x0b\x0c\x85  ]")

# (이미지, 다이제스트, 앱 repo, sha) -> 실패 이유
Verify = Callable[[str, str, str, str], list[str]]
# (앱 repo, 지금 sha, 새 sha) -> 실패 이유. 새 sha가 지금 sha의 자손이 아니면 실패
Ahead = Callable[[str, str, str], list[str]]


@dataclass(frozen=True)
class ChangedFile:
    path: str
    status: str
    base: str | None = None  # base 쪽 파일 원문
    head: str | None = None  # PR 쪽 파일 원문


@dataclass(frozen=True)
class App:
    repo: str
    image: str


@dataclass(frozen=True)
class Config:
    bot_login: str
    signer_workflow: str
    apps: dict[str, App]


@dataclass(frozen=True)
class Bump:
    old_sha: str
    new_sha: str
    digest: str


def app_of(path: str) -> str | None:
    m = OVERLAY_PATH.match(path)
    return m.group(1) if m else None


def check_paths(files: list[ChangedFile], apps: set[str]) -> list[str]:
    errors = []
    for f in files:
        app = app_of(f.path)
        if app is None:
            errors.append(f"허용 밖 파일: {f.path}")
        elif app not in apps:
            errors.append(f"설정에 없는 앱: {f.path}")
        elif f.status != "modified":
            errors.append(f"수정이 아닌 변경({f.status}): {f.path}")
    return errors


def _image_block(lines: list[str], image: str) -> tuple[int, re.Match, re.Match] | None:
    """`  - name: <image>` 바로 다음 두 줄이 newTag·digest인 위치. 정확히 한 곳이어야 한다"""
    found = [i for i, line in enumerate(lines) if line == f"  - name: {image}"]
    if len(found) != 1 or found[0] + 2 >= len(lines):
        return None
    i = found[0]
    tag, digest = TAG_LINE.match(lines[i + 1]), DIGEST_LINE.match(lines[i + 2])
    return (i, tag, digest) if tag and digest else None


def check_overlay(file: ChangedFile, image: str) -> tuple[list[str], Bump | None]:
    """base와 head가 설정 이미지의 newTag·digest 두 줄만 다른지. 통과하면 바뀐 값을 돌려준다"""
    if file.base is None or file.head is None:
        return [f"파일 원문 없음 (판단 불가): {file.path}"], None
    if HIDDEN_BREAKS.search(file.head):
        return [f"줄바꿈으로 해석될 수 있는 특수 문자 포함: {file.path}"], None
    base, head = file.base.split("\n"), file.head.split("\n")
    if len(base) != len(head):
        return [f"줄 수가 바뀜 ({len(base)} → {len(head)}): {file.path}"], None
    b, h = _image_block(base, image), _image_block(head, image)
    if b is None or h is None or b[0] != h[0]:
        return [f"{image}의 newTag·digest 형식이 아님: {file.path}"], None
    i = b[0]
    changed = [n for n, (x, y) in enumerate(zip(base, head, strict=True)) if x != y]
    outside = [n + 1 for n in changed if n not in (i + 1, i + 2)]
    if outside:
        return [f"newTag·digest 외 변경 (줄 {', '.join(map(str, outside))}): {file.path}"], None
    if not changed:
        return [f"바뀐 것이 없음: {file.path}"], None
    if i + 1 not in changed or i + 2 not in changed:
        return [f"newTag와 digest가 함께 바뀌지 않음: {file.path}"], None
    return [], Bump(old_sha=b[1].group(1), new_sha=h[1].group(1), digest=h[2].group(1))


def evaluate(
    author: str,
    files: list[ChangedFile],
    config: Config,
    verify: Verify,
    ahead: Ahead,
    *,
    sender: str | None = None,
) -> list[str]:
    # 사람이 연 PR은 이 검사의 대상이 아니다(통과). 단 마지막 push가 봇이면 가로채기로 본다(리뷰 C2)
    if author != config.bot_login:
        if sender == config.bot_login:
            return ["봇이 사람 PR 브랜치에 push함 (가로채기 의심)"]
        return []
    if not files:
        return ["바뀐 파일 없음"]
    errors = check_paths(files, set(config.apps))
    bumps: dict[str, set[Bump]] = {}
    for f in files:
        app = app_of(f.path)
        if app not in config.apps or f.status != "modified":
            continue
        file_errors, found = check_overlay(f, config.apps[app].image)
        errors += file_errors
        if found:
            bumps.setdefault(app, set()).add(found)
    for app, found in bumps.items():
        if len({(x.new_sha, x.digest) for x in found}) > 1:
            errors.append(f"{app}: overlay마다 새 SHA·digest가 서로 다름")
    if errors:
        return errors
    # 형식이 모두 맞을 때만 GitHub에 묻는다 (호출을 아끼고, 실패 이유를 섞지 않는다)
    for app, found in bumps.items():
        a = config.apps[app]
        new = next(iter(found))
        for old_sha in sorted({x.old_sha for x in found}):
            errors += ahead(a.repo, old_sha, new.new_sha)
    if errors:
        return errors
    for app, found in bumps.items():
        a = config.apps[app]
        new = next(iter(found))
        errors += verify(a.image, new.digest, a.repo, new.new_sha)
    return errors
