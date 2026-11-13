"""tag-pr-guard: PR 하나를 검사해 통과면 0, 실패면 1. 실패 이유는 --report 파일에 Markdown으로."""

import argparse
import sys
from pathlib import Path

import yaml

from tag_pr_guard import github
from tag_pr_guard.rules import App, ChangedFile, Config, app_of, evaluate


def load_config(path: Path) -> Config:
    data = yaml.safe_load(Path(path).read_text(encoding="utf-8"))
    return Config(
        bot_login=data["bot_login"],
        signer_workflow=data["signer_workflow"],
        apps={name: App(repo=a["repo"], image=a["image"]) for name, a in data["apps"].items()},
    )


def with_contents(repo: str, files: list[ChangedFile], base_sha: str, head_sha: str) -> list[ChangedFile]:
    # 허용 경로 형식(overlay)인 파일만 받는다. 공격자가 정한 다른 경로는 API URL에 넣지 않는다
    return [
        ChangedFile(f.path, f.status, github.get_file(repo, f.path, base_sha), github.get_file(repo, f.path, head_sha))
        if app_of(f.path) is not None and f.status == "modified" else f
        for f in files
    ]


def render_report(errors: list[str]) -> str:
    if not errors:
        return ""
    # 공격자가 정한 경로·내용이 들어간다. 코드 블록 안에만 두어 멘션·링크가 동작하지 않게 하고,
    # 백틱과 줄바꿈을 바꿔 블록을 빠져나갈 수 없게 한다
    lines = "".join(f"- {e.replace('`', chr(39)).replace(chr(10), ' ').replace(chr(13), ' ')}\n" for e in errors)
    return f"### 태그 PR 자동 병합 검사 실패\n\n```text\n{lines}```\n"


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(prog="tag-pr-guard")
    p.add_argument("--repo", required=True, help="PR이 있는 repo (owner/name)")
    p.add_argument("--pr", required=True, type=int)
    p.add_argument("--author", required=True, help="PR 작성자 login")
    p.add_argument("--sender", help="이 검사를 일으킨 이벤트의 주체 (synchronize면 push한 계정)")
    p.add_argument("--base-sha", help="PR base 커밋")
    p.add_argument("--head-sha", help="PR head 커밋")
    p.add_argument("--config", required=True, type=Path, help="gitops/image-sources.yaml")
    p.add_argument("--report", required=True, type=Path, help="실패 이유를 쓸 Markdown 파일")
    args = p.parse_args(argv)

    config = load_config(args.config)
    files = github.list_pr_files(args.repo, args.pr)
    if args.author == config.bot_login:
        if not (args.base_sha and args.head_sha):
            errors = ["base·head SHA가 전달되지 않아 판단할 수 없음 (검사 워크플로 확인)"]
        else:
            files = with_contents(args.repo, files, args.base_sha, args.head_sha)
            errors = None
    else:
        errors = None
    if errors is None:
        errors = evaluate(
            args.author, files, config,
            lambda image, digest, repo, sha: github.verify_attestation(image, digest, repo, sha,
                                                                       config.signer_workflow),
            github.compare_ahead,
            sender=args.sender,
        )
    report = render_report(errors)
    args.report.write_text(report, encoding="utf-8")
    print(report or "통과")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
