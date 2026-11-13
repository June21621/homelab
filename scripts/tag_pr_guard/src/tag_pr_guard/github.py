"""gh CLI 호출. 인자는 리스트로만 넘기고 셸을 거치지 않는다 (PR 내용이 명령으로 해석되지 않게)."""

import json
import subprocess

from tag_pr_guard.rules import ChangedFile


def list_pr_files(repo: str, pr: int) -> list[ChangedFile]:
    """바뀐 파일의 경로와 상태만. 내용은 get_file로 base·head 커밋에서 따로 받는다"""
    # --slurp: 페이지마다의 배열을 배열 하나로 묶는다
    result = subprocess.run(
        ["gh", "api", "--paginate", "--slurp", f"repos/{repo}/pulls/{pr}/files"],
        capture_output=True, text=True, check=True, timeout=60,
    )
    return [ChangedFile(path=f["filename"], status=f["status"]) for page in json.loads(result.stdout) for f in page]


def get_file(repo: str, path: str, ref: str) -> str | None:
    """커밋 ref의 파일 원문. 없거나 UTF-8이 아니면 None(판단 불가). 문자를 바꾸거나 버리지 않는다"""
    result = subprocess.run(
        ["gh", "api", "-H", "Accept: application/vnd.github.raw+json", f"repos/{repo}/contents/{path}?ref={ref}"],
        capture_output=True, check=False, timeout=60,
    )
    if result.returncode != 0:
        return None
    try:
        return result.stdout.decode("utf-8")
    except UnicodeDecodeError:
        return None


def compare_ahead(repo: str, old_sha: str, new_sha: str) -> list[str]:
    """새 SHA가 지금 SHA의 자손(앞선 커밋)인지. 예전 빌드로 되돌리는 롤백 공격을 막는다"""
    result = subprocess.run(
        ["gh", "api", f"repos/{repo}/compare/{old_sha}...{new_sha}", "--jq", ".status"],
        capture_output=True, text=True, check=False, timeout=60,
    )
    status = result.stdout.strip() if result.returncode == 0 else "확인 실패"
    if status == "ahead":
        return []
    return [f"새 커밋이 지금 배포된 커밋보다 앞서지 않음 ({status}): {old_sha[:7]} → {new_sha[:7]}"]


def verify_attestation(image: str, digest: str, repo: str, sha: str, signer_workflow: str) -> list[str]:
    """이미지(다이제스트)가 앱 repo main의 그 커밋에서, homelab main의 재사용 워크플로로 빌드됐는지"""
    result = subprocess.run(
        [
            "gh", "attestation", "verify", f"oci://{image}@{digest}",
            "--repo", repo,
            # 서명 워크플로를 브랜치까지 정확히 고정한다 (--signer-workflow는 다른 브랜치의 같은 파일도 받아들인다)
            "--cert-identity", f"https://github.com/{signer_workflow}@refs/heads/main",
            "--deny-self-hosted-runners",
            "--source-ref", "refs/heads/main",
            "--source-digest", sha,
            "--format", "json",
        ],
        capture_output=True, text=True, check=False, timeout=120,
    )
    if result.returncode == 0:
        return []
    reason = (result.stderr.strip().splitlines() or ["이유 없음"])[-1]
    return [f"빌드 증명서 검증 실패: {image}@{digest} ({reason})"]
