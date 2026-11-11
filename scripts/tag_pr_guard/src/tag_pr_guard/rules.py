"""태그 PR 검사 규칙. GitHub을 부르지 않는 순수 함수만 둔다.

각 검사는 실패 이유 문자열 리스트를 돌려준다. 빈 리스트 = 통과.
PR의 diff는 데이터로만 읽는다. PR 브랜치의 코드는 실행하지 않는다.
"""

import re
from collections.abc import Callable
from dataclasses import dataclass

OVERLAY_PATH = re.compile(r"^gitops/apps/([a-z0-9-]+)/overlays/[a-z0-9-]+/kustomization\.yaml$")
TAG_LINE = re.compile(r'^    newTag: "([0-9a-f]{40})"$')

# (이미지 ref "<image>:<sha>", 앱 repo, sha) -> 실패 이유
Verify = Callable[[str, str, str], list[str]]


@dataclass(frozen=True)
class ChangedFile:
    path: str
    status: str
    patch: str | None


@dataclass(frozen=True)
class App:
    repo: str
    image: str


@dataclass(frozen=True)
class Config:
    bot_login: str
    signer_workflow: str
    apps: dict[str, App]


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


def check_patch(file: ChangedFile, image: str) -> tuple[list[str], str | None]:
    """바뀐 줄이 전부 설정 이미지의 newTag 한 줄 교체인지. 통과하면 새 SHA를 돌려준다"""
    if file.patch is None:
        return [f"diff 없음 (판단 불가): {file.path}"], None
    errors = []
    removed = added = 0
    new_shas = set()
    prev = ""  # 바로 앞 줄 (문맥 줄 포함). newTag 위가 그 이미지의 name 줄이어야 한다
    for line in file.patch.splitlines():
        if line.startswith("@@") or line.startswith("\\"):
            prev = ""
            continue
        if line.startswith(("+", "-")):
            m = TAG_LINE.match(line[1:])
            if not m:
                errors.append(f"newTag 외 변경: {file.path}: {line[:80]!r}")
            elif prev[1:] != f"  - name: {image}" and not (prev[:1] in "+-" and TAG_LINE.match(prev[1:])):
                errors.append(f"설정의 이미지({image})가 아닌 항목의 태그 변경: {file.path}")
            if line.startswith("+"):
                added += 1
                if m:
                    new_shas.add(m.group(1))
            else:
                removed += 1
        prev = line
    if removed != added:
        errors.append(f"삭제 {removed}줄·추가 {added}줄로 한 줄 교체가 아님: {file.path}")
    if not errors and len(new_shas) != 1:
        errors.append(f"새 SHA가 하나가 아님: {file.path}")
    return errors, (new_shas.pop() if not errors else None)


def evaluate(author: str, files: list[ChangedFile], config: Config, verify: Verify) -> list[str]:
    # 사람이 연 PR은 이 검사의 대상이 아니다(통과). 병합은 사람이 직접 한다
    if author != config.bot_login:
        return []
    if not files:
        return ["바뀐 파일 없음"]
    errors = check_paths(files, set(config.apps))
    shas: dict[str, set[str]] = {}
    for f in files:
        app = app_of(f.path)
        if app not in config.apps:
            continue
        file_errors, sha = check_patch(f, config.apps[app].image)
        errors += file_errors
        if sha:
            shas.setdefault(app, set()).add(sha)
    for app, found in shas.items():
        if len(found) > 1:
            errors.append(f"{app}: overlay마다 SHA가 서로 다름 ({', '.join(sorted(found))})")
    if errors:
        return errors
    # 형식이 모두 맞을 때만 증명서를 확인한다 (GitHub 호출을 아끼고, 실패 이유를 섞지 않는다)
    for app, found in shas.items():
        sha = next(iter(found))
        a = config.apps[app]
        errors += verify(f"{a.image}:{sha}", a.repo, sha)
    return errors
