"""tag-pr-guard: PR 하나를 검사해 통과면 0, 실패면 1. 실패 이유는 --report 파일에 Markdown으로."""

import argparse
import sys
from pathlib import Path

import yaml

from tag_pr_guard import github
from tag_pr_guard.rules import App, Config, evaluate


def load_config(path: Path) -> Config:
    data = yaml.safe_load(Path(path).read_text(encoding="utf-8"))
    return Config(
        bot_login=data["bot_login"],
        signer_workflow=data["signer_workflow"],
        apps={name: App(repo=a["repo"], image=a["image"]) for name, a in data["apps"].items()},
    )


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(prog="tag-pr-guard")
    p.add_argument("--repo", required=True, help="PR이 있는 repo (owner/name)")
    p.add_argument("--pr", required=True, type=int)
    p.add_argument("--author", required=True, help="PR 작성자 login")
    p.add_argument("--config", required=True, type=Path, help="gitops/image-sources.yaml")
    p.add_argument("--report", required=True, type=Path, help="실패 이유를 쓸 Markdown 파일")
    args = p.parse_args(argv)

    config = load_config(args.config)
    files = github.list_pr_files(args.repo, args.pr)
    errors = evaluate(
        args.author, files, config,
        lambda image_ref, repo, sha: github.verify_attestation(image_ref, repo, sha, config.signer_workflow),
    )
    report = ""
    if errors:
        report = "### 태그 PR 자동 병합 검사 실패\n\n" + "".join(f"- {e}\n" for e in errors)
    args.report.write_text(report, encoding="utf-8")
    print(report or "통과")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
