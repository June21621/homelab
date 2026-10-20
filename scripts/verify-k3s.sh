#!/usr/bin/env bash
# k3s 설치 결과 확인 (관리 PC에서 실행). 하나라도 실패하면 non-zero.
# 필요: ~/.kube/homelab.yaml (make kubeconfig), Tailscale 연결, LAN 연결(포트 닫힘 확인용)
set -euo pipefail

KUBECONFIG="${KUBECONFIG:-${HOME}/.kube/homelab.yaml}"
export KUBECONFIG
TS_IP="${TS_IP:-100.124.153.34}"
LAN_IP="${LAN_IP:-192.168.35.235}"
K3S_VERSION="${K3S_VERSION:-v1.36.5+k3s1}"

fails=0 skips=0
check() {  # check <설명> <명령...>
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then
    echo "PASS  ${desc}"
  else
    echo "FAIL  ${desc}"
    fails=$((fails + 1))
  fi
}

node_ready_and_version() {
  kubectl get node homelab -o jsonpath='{.status.conditions[?(@.type=="Ready")].status} {.status.nodeInfo.kubeletVersion}' \
    | grep -qx "True ${K3S_VERSION}"
}
# kubectl이 실패하면 "문제 파드 없음"으로 통과하지 않도록 출력을 먼저 받는다.
# STATUS만 보면 "0/1 Running"(준비 안 됨)을 놓치므로 READY 열(x/y)도 본다
all_pods_healthy() {
  local pods
  pods="$(kubectl get pods -A --no-headers)" || return 1
  [[ -n "${pods}" ]] || return 1
  awk '$4 == "Completed" { next }
       { split($3, r, "/"); if ($4 != "Running" || r[1] != r[2]) bad = 1 }
       END { exit bad }' <<<"${pods}"
}
no_svclb() {
  local pods
  pods="$(kubectl get pods -n kube-system --no-headers)" || return 1
  ! grep -q '^svclb-' <<<"${pods}"
}
traefik_clusterip() {
  kubectl get svc traefik -n kube-system -o jsonpath='{.spec.type}' | grep -qx ClusterIP
}
# busybox nslookup은 검색 도메인을 붙이지 않으므로 전체 이름(FQDN)으로 묻는다.
# kubectl run --rm -i는 파드가 너무 빨리 끝나면 attach에 실패해 파드를 남기므로,
# 매번 다른 이름으로 만들고 → 끝나길 기다려 로그를 읽고 → 직접 지운다
pod_dns() {
  local pod="dnstest-${RANDOM}" ok=1
  kubectl run "${pod}" --restart=Never --image=busybox:1.37 -- \
    nslookup kubernetes.default.svc.cluster.local >/dev/null || return 1
  if kubectl wait "pod/${pod}" --for=jsonpath='{.status.phase}'=Succeeded --timeout=90s >/dev/null; then
    kubectl logs "${pod}" | grep -q '^Address: 10\.43\.0\.1$' && ok=0
  fi
  kubectl delete pod "${pod}" --wait=false >/dev/null 2>&1 || true
  return "${ok}"
}
# NodePort·LoadBalancer 서비스와 hostPort는 kube-proxy·portmap이 PREROUTING에서 DNAT해
# ufw(INPUT)를 거치지 않고 LAN에 열린다. 클러스터 쪽에서 아예 없는지 확인한다.
# hostNetwork 파드(node-exporter 등)의 포트는 호스트 소켓이라 ufw를 거치므로 허용
no_host_exposure() {
  local svcs pods
  svcs="$(kubectl get svc -A --no-headers -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,TYPE:.spec.type)" || return 1
  pods="$(kubectl get pods -A --no-headers -o 'custom-columns=NS:.metadata.namespace,HOSTNET:.spec.hostNetwork,HOSTPORTS:.spec.containers[*].ports[*].hostPort')" || return 1
  if grep -Eq '[[:space:]](NodePort|LoadBalancer)$' <<<"${svcs}"; then return 1; fi
  ! awk '$2 != "true" && $3 != "<none>" { found = 1 } END { exit !found }' <<<"${pods}"
}
# 정기 스냅샷은 6시간마다. 업로드가 실패해도 k3s 로그에만 남으므로, 가장 최근 S3 사본의 나이를 본다
s3_snapshot_fresh() {
  local snaps latest
  snaps="$(kubectl get etcdsnapshotfiles --no-headers -o custom-columns=LOC:.spec.location,READY:.status.readyToUse,CREATED:.status.creationTime)" || return 1
  latest="$(awk '$1 ~ /^s3:/ && $2 == "true" { print $3 }' <<<"${snaps}" | sort | tail -n 1)"
  [[ -n "${latest}" ]] || return 1
  (( $(date +%s) - $(date -d "${latest}" +%s) < 7 * 3600 ))
}
port_closed() { ! nc -zw3 "$1" "$2"; }
port_open() { nc -zw3 "$1" "$2"; }

check "노드 Ready, ${K3S_VERSION}" node_ready_and_version
check "모든 파드 Running/Completed" all_pods_healthy
check "servicelb 없음" no_svclb
check "traefik 서비스 ClusterIP" traefik_clusterip
check "파드 DNS 조회" pod_dns
check "호스트 포트 노출 없음 (NodePort·LoadBalancer·hostPort)" no_host_exposure
check "S3 etcd 스냅샷 7시간 이내" s3_snapshot_fresh
check "Tailscale 6443 열림" port_open "${TS_IP}" 6443
for p in 80 443 10250; do
  check "Tailscale ${p} 닫힘" port_closed "${TS_IP}" "${p}"
done
# LAN은 대조군(SSH 22)이 열려야 "닫힘" 결과를 믿을 수 있다.
# 공유기 무선 격리 등으로 관리 PC가 LAN에 닿지 않으면 확인 불가로 건너뛴다(같은 ufw라 위 Tailscale 결과가 근거)
if port_open "${LAN_IP}" 22; then
  for p in 6443 80 443 10250 2379 2380; do  # 2379·2380: etcd가 LAN 주소에서 대기함
    check "LAN ${p} 닫힘" port_closed "${LAN_IP}" "${p}"
  done
else
  echo "SKIP  LAN 포트 확인 (관리 PC에서 ${LAN_IP}:22에 닿지 않음 — 유선 LAN 기기에서 다시 실행)"
  skips=$((skips + 1))
fi

echo
if [[ "${fails}" -gt 0 ]]; then
  echo "실패 ${fails}건"
  exit 1
fi
# 확인하지 못한 항목을 "모두 통과"로 덮지 않는다 (종료 코드는 0: 실패는 아님)
if [[ "${skips}" -gt 0 ]]; then
  echo "통과 — 단, 확인 불가 ${skips}건 (위 SKIP 참고)"
else
  echo "모두 통과"
fi
