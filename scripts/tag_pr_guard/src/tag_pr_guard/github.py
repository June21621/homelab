"""gh CLI 호출. 인자는 리스트로만 넘기고 셸을 거치지 않는다 (PR 내용이 명령으로 해석되지 않게)."""

import json
import subprocess

from tag_pr_guard.rules import ChangedFile


def list_pr_files(repo: str, pr: int) -> list[ChangedFile]:
    # --slurp: 페이지마다의 배열을 배열 하나로 묶는다
    result = subprocess.run(
        ["gh", "api", "--paginate", "--slurp", f"repos/{repo}/pulls/{pr}/files"],
        capture_output=True, text=True, check=True, timeout=60,
    )
    return [
        ChangedFile(path=f["filename"], status=f["status"], patch=f.get("patch"))
        for page in json.loads(result.stdout)
        for f in page
    ]


def verify_attestation(image_ref: str, repo: str, sha: str, signer_workflow: str) -> list[str]:
    """이미지가 앱 repo main의 그 커밋에서, 우리 재사용 워크플로로 빌드됐는지 (빌드 증명서)"""
    result = subprocess.run(
        [
            "gh", "attestation", "verify", f"oci://{image_ref}",
            "--repo", repo,
            "--signer-workflow", signer_workflow,
            "--source-ref", "refs/heads/main",
            "--source-digest", sha,
            "--format", "json",
        ],
        capture_output=True, text=True, check=False, timeout=120,
    )
    if result.returncode == 0:
        return []
    reason = (result.stderr.strip().splitlines() or ["이유 없음"])[-1]
    return [f"빌드 증명서 검증 실패: {image_ref} ({reason})"]
