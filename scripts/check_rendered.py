# /// script
# requires-python = ">=3.12"
# dependencies = ["pyyaml==6.0.3"]
# ///
"""렌더링된 매니페스트(helm template · kustomize 결과)를 표준 입력으로 받아 규칙을 검사한다.

사용: helm template ... | uv run --script scripts/check_rendered.py argocd
통과하면 0, 아니면 위반 목록을 출력하고 1.
"""

import sys

import yaml

WORKLOAD_KINDS = {"Deployment", "StatefulSet", "DaemonSet", "Job"}
# 5단계에서 끈 ArgoCD 컴포넌트 (설계 §3.2)
DISABLED_ARGOCD_PARTS = ("dex", "notifications", "applicationset")


def workloads(docs):
    return [d for d in docs if d.get("kind") in WORKLOAD_KINDS]


def containers(workload):
    spec = workload["spec"]["template"]["spec"]
    return spec.get("initContainers", []) + spec.get("containers", [])


def check_resources(docs):
    errors = []
    for w in workloads(docs):
        for c in containers(w):
            res = c.get("resources") or {}
            if not (res.get("limits") or {}).get("memory"):
                errors.append(f"{w['metadata']['name']}/{c['name']}: limits.memory 없음")
            if not (res.get("requests") or {}).get("memory"):
                errors.append(f"{w['metadata']['name']}/{c['name']}: requests.memory 없음")
    return errors


def check_argocd(docs):
    errors = check_resources(docs)
    for w in workloads(docs):
        name = w["metadata"]["name"]
        # applicationset은 차트에 끄는 옵션이 없어 replicas 0으로 끈다 (파드 없음 = 메모리 0)
        if any(part in name for part in DISABLED_ARGOCD_PARTS) and w["spec"].get("replicas", 1) != 0:
            errors.append(f"꺼야 할 컴포넌트가 떠 있음: {w['kind']}/{name}")
    return errors


def check_root(docs):
    """gitops/root/root.yaml: 루트 앱이 자기 폴더(gitops/root)를 main에서 자동 동기화"""
    roots = [d for d in docs if d.get("kind") == "Application" and d["metadata"]["name"] == "root"]
    if len(docs) != 1 or len(roots) != 1:
        return ["루트 Application(root) 하나만 있어야 함"]
    spec = roots[0]["spec"]
    errors = []
    auto = (spec.get("syncPolicy") or {}).get("automated") or {}
    if not (auto.get("prune") and auto.get("selfHeal")):
        errors.append("루트 앱: automated.prune·selfHeal 필요")
    if spec.get("source", {}).get("path") != "gitops/root":
        errors.append("루트 앱: source.path는 gitops/root")
    if spec.get("source", {}).get("targetRevision") != "main":
        errors.append("루트 앱: targetRevision은 main")
    return errors


CHECKS = {"argocd": check_argocd, "root": check_root}


def main(argv):
    if len(argv) != 2 or argv[1] not in CHECKS:
        print(f"사용: check_rendered.py <{'|'.join(CHECKS)}>", file=sys.stderr)
        return 2
    docs = [d for d in yaml.safe_load_all(sys.stdin) if d]
    if not docs:
        print("입력 매니페스트가 비어 있음")
        return 1
    errors = CHECKS[argv[1]](docs)
    for e in errors:
        print(e)
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
