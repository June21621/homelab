# /// script
# requires-python = ">=3.12"
# dependencies = ["pyyaml==6.0.3"]
# ///
"""렌더링된 매니페스트(helm template · kustomize 결과)를 표준 입력으로 받아 규칙을 검사한다.

사용: helm template ... | uv run --script scripts/check_rendered.py argocd
통과하면 0, 아니면 위반 목록을 출력하고 1.
"""

import base64
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


# 6-3a: 지표 Service만 켠다. ServiceMonitor는 monitoring 앱이 만든다 (6단계 설계 §3.6)
ARGOCD_METRICS_SERVICES = ("argocd-application-controller-metrics", "argocd-server-metrics", "argocd-repo-server-metrics")


def check_argocd_metrics(docs):
    errors = []
    # Terraform argocd-bootstrap이 같은 values로 빈 클러스터에 설치한다. ServiceMonitor CRD가 없어 첫 apply가 실패한다
    for d in docs:
        if d.get("kind") == "ServiceMonitor":
            errors.append(f"ServiceMonitor/{d['metadata']['name']}: ArgoCD 차트에서 만들면 안 됨 (빈 클러스터 재구축 실패)")
    services = {d["metadata"]["name"] for d in docs if d.get("kind") == "Service"}
    for name in ARGOCD_METRICS_SERVICES:
        if name not in services:
            errors.append(f"지표 Service {name} 없음 (metrics.enabled)")
    return errors


def check_argocd(docs):
    errors = check_resources(docs) + check_argocd_metrics(docs)
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


# 태그(:커밋 SHA)는 사람이 읽기 위한 것, 실제로 받는 이미지는 digest로 고정한다(태그는 덮어쓸 수 있다)
SHA_TAG = re.compile(r":[0-9a-f]{40}@sha256:[0-9a-f]{64}$")


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
                errors.append(f"{where}: 이미지는 40자 커밋 SHA 태그 + sha256 digest ({c.get('image')})")
            env = {e["name"]: e.get("value") for e in c.get("env", [])}
            on = env.get("CHAOS_ENABLED") == "true"
            if on and not chaos:
                errors.append(f"{where}: prod에서는 CHAOS_ENABLED가 꺼져 있어야 함")
            if chaos and not on:
                errors.append(f"{where}: lab에서는 CHAOS_ENABLED=true 필요")
    return errors


FINALIZER = "resources-finalizer.argocd.argoproj.io"
# finalizer를 달면 안 되는 플랫폼 앱. argocd·root: 지우면 ArgoCD 자신이 통째로 삭제됨.
# monitoring: 지우면 prometheus-operator CRD와 함께 모든 ServiceMonitor·PrometheusRule·지표 데이터가 사라짐 (6단계 §3.2)
PROTECTED_APPS = {"argocd", "root", "monitoring"}


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


# --- monitoring (kube-prometheus-stack, 6단계 설계 §3) ---

# operator가 StatefulSet으로 펼치는 CR. helm template 결과에는 워크로드가 아니라 CR로 나온다
MONITORING_CRS = {"Prometheus", "Alertmanager"}
# k3s는 이것들을 k3s server 한 프로세스에 넣어 따로 수집할 주소가 없다 (§3.1)
DISABLED_SCRAPE = ("kube-etcd", "kube-scheduler", "kube-controller-manager", "kube-proxy")
# k3s에 안 맞거나(오탐) 단일 노드에 쓸모없는(API SLO) 기본 규칙 그룹 (§3.4)
DISABLED_RULE_GROUP = re.compile(
    r"^(etcd|kube-scheduler|kubernetes-system-(controller-manager|scheduler|kube-proxy)"
    r"|kube-apiserver-(burnrate|histogram|slos|availability)|windows)"
)
# 비밀값은 KSOPS Secret을 파일로 마운트해 경로로만 참조한다 (§3.3)
RECEIVER_FILES = {
    ("discord_configs", "webhook_url_file"): "/etc/alertmanager/secrets/alertmanager-receivers/discord-webhook-url",
    ("webhook_configs", "url_file"): "/etc/alertmanager/secrets/alertmanager-receivers/healthchecks-ping-url",
}
URL_KEYS = {"discord_configs": "webhook_url", "webhook_configs": "url"}
WATCHDOG_TIMING = {"group_wait": "0s", "group_interval": "1m", "repeat_interval": "1m"}


def custom_resources(docs):
    return [d for d in docs if d.get("kind") in MONITORING_CRS]


def check_cr_resources(docs):
    errors = []
    for d in custom_resources(docs):
        where = f"{d['kind']}/{d['metadata']['name']}"
        spec = d.get("spec") or {}
        if not ((spec.get("resources") or {}).get("limits") or {}).get("memory"):
            errors.append(f"{where}: spec.resources.limits.memory 없음")
        # spec.containers는 operator가 만드는 컨테이너(사이드카 포함)를 덮어쓴다. 덮어쓸 때도 제한 필요
        for c in spec.get("containers") or []:
            res = c.get("resources") or {}
            if not (res.get("limits") or {}).get("memory"):
                errors.append(f"{where}/{c['name']}: limits.memory 없음")
    return errors


def alertmanager_config(docs):
    for d in docs:
        if d.get("kind") == "Secret" and "alertmanager.yaml" in (d.get("data") or {}):
            return yaml.safe_load(base64.b64decode(d["data"]["alertmanager.yaml"]))
    return None


def walk_routes(route):
    yield route
    for child in route.get("routes") or []:
        yield from walk_routes(child)


def is_watchdog(route):
    matchers = " ".join(route.get("matchers") or [])
    return "Watchdog" in matchers or (route.get("match") or {}).get("alertname") == "Watchdog"


def check_alertmanager(cfg):
    if cfg is None:
        return ["alertmanager.yaml을 담은 Secret이 없음"]
    errors = []
    for r in cfg.get("receivers") or []:
        for kind, url_key in URL_KEYS.items():
            for conf in r.get(kind) or []:
                if url_key in conf:
                    errors.append(f"receiver {r['name']}: {kind}.{url_key}에 URL을 직접 쓰면 안 됨 (*_file 사용)")
                file_key = next(fk for (k, fk) in RECEIVER_FILES if k == kind)
                want = RECEIVER_FILES[(kind, file_key)]
                if conf.get(file_key) != want:
                    errors.append(f"receiver {r['name']}: {kind}.{file_key}는 {want}")
    text = yaml.safe_dump(cfg)
    for literal in ("discord.com", "hc-ping.com", "https://"):
        if literal in text:
            errors.append(f"Alertmanager 설정에 URL 리터럴 '{literal}'")
    watchdog = [r for r in walk_routes(cfg.get("route") or {}) if is_watchdog(r)]
    if not watchdog:
        errors.append("Watchdog route 없음 (healthchecks.io 핑)")
    for r in watchdog:
        for key, want in WATCHDOG_TIMING.items():
            if r.get(key) != want:
                errors.append(f"Watchdog route: {key}는 {want} (지금 {r.get(key)})")
    return errors


def check_monitoring(docs):
    errors = check_resources(docs) + check_cr_resources(docs)
    for d in docs:
        name = d.get("metadata", {}).get("name", "")
        if d.get("kind") in ("Service", "ServiceMonitor") and any(t in name for t in DISABLED_SCRAPE):
            errors.append(f"끈 수집 대상이 있음: {d['kind']}/{name}")
        if d.get("kind") == "PrometheusRule":
            for g in (d.get("spec") or {}).get("groups") or []:
                if DISABLED_RULE_GROUP.match(g.get("name", "")):
                    errors.append(f"끈 기본 규칙 그룹이 있음: {g['name']} ({name})")
    for p in (d for d in docs if d.get("kind") == "Prometheus"):
        if (p.get("spec") or {}).get("retention") != "7d":
            errors.append(f"Prometheus/{p['metadata']['name']}: retention은 7d")
    return errors + check_alertmanager(alertmanager_config(docs))


CHECKS = {
    "argocd": check_argocd,
    "monitoring": check_monitoring,
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
