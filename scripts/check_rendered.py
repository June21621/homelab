# /// script
# requires-python = ">=3.12"
# dependencies = ["pyyaml==6.0.3"]
# ///
"""렌더링된 매니페스트(helm template · kustomize 결과)를 표준 입력으로 받아 규칙을 검사한다.

사용: helm template ... | uv run --script scripts/check_rendered.py argocd
통과하면 0, 아니면 위반 목록을 출력하고 1.
"""

import re
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
    return errors + check_ksops(docs)


def check_ksops(docs):
    """repo-server가 KSOPS로 gitops/의 SOPS 파일을 풀 수 있는지 (5-2)"""
    errors = []
    repo = [w for w in workloads(docs) if w["metadata"]["name"] == "argocd-repo-server"]
    if len(repo) != 1:
        return ["argocd-repo-server Deployment가 없음"]
    spec = repo[0]["spec"]["template"]["spec"]
    if not any(c.get("image", "").startswith("viaductoss/ksops:") for c in spec.get("initContainers", [])):
        errors.append("repo-server: KSOPS init 컨테이너 없음")
    main = next((c for c in spec["containers"] if c["name"] == "repo-server"), {})
    env = {e["name"]: e.get("value") for e in main.get("env", [])}
    if not env.get("SOPS_AGE_KEY_FILE"):
        errors.append("repo-server: SOPS_AGE_KEY_FILE 없음")
    mounts = {m["mountPath"] for m in main.get("volumeMounts", [])}
    if "/usr/local/bin/ksops" not in mounts:
        errors.append("repo-server: /usr/local/bin/ksops 마운트 없음")
    secret_vols = {v.get("secret", {}).get("secretName") for v in spec.get("volumes", [])}
    if "sops-age" not in secret_vols:
        errors.append("repo-server: sops-age Secret 볼륨 없음")
    cms = [d for d in docs if d.get("kind") == "ConfigMap" and d["metadata"]["name"] == "argocd-cm"]
    opts = ((cms[0].get("data") or {}) if cms else {}).get("kustomize.buildOptions", "")
    if "--enable-exec" not in opts or "--enable-alpha-plugins" not in opts:
        errors.append("argocd-cm: kustomize.buildOptions에 --enable-alpha-plugins --enable-exec 필요")
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


SHA_TAG = re.compile(r":[0-9a-f]{40}$")


def check_app(docs, chaos):
    """직접 만든 앱(kustomize overlay 렌더링 결과): 메모리 제한, 컨테이너 보안 설정, 이미지 태그는 커밋 SHA,
    Namespace를 앱 리소스로 포함(앱을 지우면 finalizer가 함께 정리), chaos는 lab에서만"""
    errors = check_resources(docs)
    if not any(d.get("kind") == "Namespace" for d in docs):
        errors.append("Namespace 리소스 없음 (CreateNamespace로 만든 네임스페이스는 앱을 지워도 남음)")
    for w in workloads(docs):
        pod = w["spec"]["template"]["spec"]
        for c in containers(w):
            where = f"{w['metadata']['name']}/{c['name']}"
            sec = c.get("securityContext") or {}
            if not (sec.get("runAsNonRoot") or (pod.get("securityContext") or {}).get("runAsNonRoot")):
                errors.append(f"{where}: runAsNonRoot: true 필요")
            if not sec.get("readOnlyRootFilesystem"):
                errors.append(f"{where}: readOnlyRootFilesystem: true 필요")
            if not SHA_TAG.search(c.get("image", "")):
                errors.append(f"{where}: 이미지 태그는 40자 커밋 SHA ({c.get('image')})")
            env = {e["name"]: e.get("value") for e in c.get("env", [])}
            on = env.get("CHAOS_ENABLED") == "true"
            if on and not chaos:
                errors.append(f"{where}: prod에서는 CHAOS_ENABLED가 꺼져 있어야 함")
            if chaos and not on:
                errors.append(f"{where}: lab에서는 CHAOS_ENABLED=true 필요")
    return errors


FINALIZER = "resources-finalizer.argocd.argoproj.io"
# 지우면 ArgoCD 자신이 통째로 삭제되므로 finalizer를 달면 안 되는 앱
PROTECTED_APPS = {"argocd", "root"}


def check_apps(docs):
    """gitops/root/의 Application들: 서비스 앱은 Git에서 지우면 리소스까지 정리(finalizer),
    argocd·root는 정의를 실수로 지워도 ArgoCD가 살아남게(finalizer 금지)"""
    errors = []
    for app in (d for d in docs if d.get("kind") == "Application"):
        name = app["metadata"]["name"]
        has = FINALIZER in (app["metadata"].get("finalizers") or [])
        if name in PROTECTED_APPS and has:
            errors.append(f"{name}: {FINALIZER} 금지 (지우면 ArgoCD까지 삭제됨)")
        elif name not in PROTECTED_APPS and not has:
            errors.append(f"{name}: {FINALIZER} 필요 (없으면 앱을 지워도 리소스가 남음)")
    return errors


CHECKS = {
    "argocd": check_argocd,
    "root": check_root,
    "apps": check_apps,
    "app-prod": lambda docs: check_app(docs, chaos=False),
    "app-lab": lambda docs: check_app(docs, chaos=True),
}


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
