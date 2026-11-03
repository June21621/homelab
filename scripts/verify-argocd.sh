#!/usr/bin/env bash
# ArgoCD 확인 (관리 PC에서 실행). 하나라도 실패하면 non-zero.
#   --static : 클러스터 없이 repo 파일만 검사 (커밋 전)
#   (기본)   : 클러스터의 모든 Application이 Synced·Healthy인지
set -euo pipefail

cd "$(dirname "$0")/.."
KUBECONFIG="${KUBECONFIG:-${HOME}/.kube/homelab.yaml}"
export KUBECONFIG

ARGOCD_APP=gitops/root/argocd.yaml
ROOT_APP=gitops/root/root.yaml
ARGOCD_VALUES=gitops/platform/argocd/values.yaml
BOOTSTRAP_TF=terraform/argocd-bootstrap/main.tf

fails=0
check() {  # check <설명> <명령...>
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then
    echo "PASS  ${desc}"
  else
    echo "FAIL  ${desc}"
    fails=$((fails + 1))
  fi
}

# Application의 Helm 소스(chart: argo-cd)에 적힌 차트 버전
chart_version() {
  awk '/chart: argo-cd/ { f = 1 } f && /targetRevision:/ { print $2; exit }' "${ARGOCD_APP}"
}

# 첫 설치(Terraform)와 자기 관리(ArgoCD)가 같은 파일을 읽어야 버전·values가 어긋나지 않는다
tf_reads_single_source() {
  grep -q 'yamldecode(file(".*gitops/root/argocd.yaml"))' "${BOOTSTRAP_TF}" &&
    grep -q 'file(".*gitops/platform/argocd/values.yaml")' "${BOOTSTRAP_TF}" &&
    grep -q 'yamldecode(file(".*gitops/root/root.yaml"))' "${BOOTSTRAP_TF}"
}

root_app_ok() {
  uv run --quiet --script scripts/check_rendered.py root <"${ROOT_APP}"
}

render_argocd() {
  local version
  version="$(chart_version)"
  [[ -n "${version}" ]] || return 1
  helm template argocd argo-cd --repo https://argoproj.github.io/argo-helm \
    --version "${version}" --namespace argocd --kube-version 1.36.5 -f "${ARGOCD_VALUES}"
}

# gitops/root/의 모든 Application (파일마다 --- 를 붙여 여러 문서로 이어 붙인다)
apps_finalizer_ok() {
  local f
  for f in gitops/root/*.yaml; do
    echo '---'
    cat "${f}"
  done | uv run --quiet --script scripts/check_rendered.py apps
}

argocd_render_ok() {
  local out
  out="$(render_argocd)" || return 1
  uv run --quiet --script scripts/check_rendered.py argocd <<<"${out}"
}

static_checks() {
  check "Terraform이 차트 버전·values·루트 앱을 gitops/에서 읽음" tf_reads_single_source
  check "argo-cd 차트 렌더링: 끈 컴포넌트 없음, 모든 컨테이너 limits" argocd_render_ok
  check "루트 앱: gitops/root를 main에서 자동 동기화(prune·selfHeal)" root_app_ok
  check "서비스 앱은 finalizer 있음, argocd·root는 없음" apps_finalizer_ok
}

APPS=""
all_synced_healthy() {
  awk '$2 != "Synced" || $3 != "Healthy" { bad = 1 } END { exit bad }' <<<"${APPS}"
}

live_checks() {
  APPS="$(kubectl get applications.argoproj.io -n argocd --no-headers \
    -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status)" || {
    echo "FAIL  Application 목록 조회"
    fails=$((fails + 1))
    return
  }
  echo "${APPS}"
  check "Application이 하나 이상" test -n "${APPS}"
  check "모든 Application이 Synced·Healthy" all_synced_healthy
}

if [[ "${1:-}" == "--static" ]]; then
  static_checks
else
  live_checks
fi

if ((fails > 0)); then
  echo "실패 ${fails}건"
  exit 1
fi
echo "모두 통과"
