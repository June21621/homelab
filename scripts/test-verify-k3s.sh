#!/usr/bin/env bash
# verify-k3s.sh와 etcd-restore.yml의 회귀 테스트. 클러스터·미니 PC에 접속하지 않는다.
# 가짜 kubectl·nc를 PATH 앞에 두고 상황별 출력을 흉내 내, 검사가 문제를 잡는지 확인한다.
# 실행: bash scripts/test-verify-k3s.sh  (관리 PC WSL, GNU date 필요)
set -euo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
stub="$(mktemp -d)"
trap 'rm -rf "${stub}"' EXIT

# --- 가짜 kubectl: 인자를 보고 S_* 환경변수의 내용을 출력한다 ---------------
cat >"${stub}/kubectl" <<'STUB'
#!/usr/bin/env bash
args="$*"
case "${args}" in
  "get node homelab"*)                     echo "True v1.36.5+k3s1" ;;
  "get pods -A --no-headers -o custom-columns"*) printf '%s\n' "${S_HOSTPODS}" ;;
  "get pods -A --no-headers"*)             printf '%s\n' "${S_PODS}" ;;
  "get pods -n kube-system --no-headers"*) printf '%s\n' "${S_PODS}" ;;
  "get svc traefik"*)                      echo "ClusterIP" ;;
  "get svc -A --no-headers -o custom-columns"*) printf '%s\n' "${S_SVCS}" ;;
  "get etcdsnapshotfiles"*)                printf '%s\n' "${S_SNAPS}" ;;
  run*|delete*)                            : ;;
  wait*)                                   : ;;
  logs*)                                   echo "Address: 10.43.0.1" ;;
  *) echo "stub kubectl: 예상 못 한 호출: ${args}" >&2; exit 99 ;;
esac
STUB
# 가짜 nc: S_OPEN에 "주소:포트"가 있으면 열림
cat >"${stub}/nc" <<'STUB'
#!/usr/bin/env bash
host="${*: -2:1}"; port="${*: -1}"
[[ " ${S_OPEN} " == *" ${host}:${port} "* ]]
STUB
chmod +x "${stub}/kubectl" "${stub}/nc"

fresh="$(date -u -d '-1 hour' +%FT%TZ)"
stale="$(date -u -d '-8 hours' +%FT%TZ)"

# 정상 상태 기본값
base_env() {
  export S_PODS="kube-system   coredns-1   1/1   Running     0   2d
kube-system   helm-install-traefik-1   0/1   Completed   0   2d
kube-system   metrics-server-1   1/1   Running   0   2d"
  export S_HOSTPODS="kube-system   <none>   <none>
monitoring   true   9100"
  export S_SVCS="kube-system   traefik   ClusterIP
kube-system   kube-dns   ClusterIP"
  export S_SNAPS="file:///var/lib/rancher/k3s/server/db/snapshots/a   true   ${fresh}
s3://bucket/etcd/a   true   ${fresh}"
  export S_OPEN="100.124.153.34:6443"
}

pass=0 fail=0
expect() {  # expect <테스트 이름> <출력에 있어야 할 문자열>
  if grep -qF -- "$2" <<<"${out}"; then
    echo "ok    $1"; pass=$((pass + 1))
  else
    echo "FAIL  $1  (기대: '$2')"; fail=$((fail + 1))
  fi
}
run_verify() { out="$(PATH="${stub}:${PATH}" bash "${repo}/scripts/verify-k3s.sh" 2>&1 || true)"; }

# 1. 정상 + LAN 미도달 → 통과지만 확인 불가가 요약에 드러나야 함
base_env; run_verify
expect "정상: 파드 검사 통과"            "PASS  모든 파드 Running/Completed"
expect "정상: 노출 없음 통과"            "PASS  호스트 포트 노출 없음"
expect "정상: 백업 신선도 통과"          "PASS  S3 etcd 스냅샷 7시간 이내"
expect "LAN 미도달은 요약에 표시"        "확인 불가 1건"

# 2. Running이지만 Ready가 아닌 파드
base_env; S_PODS="${S_PODS}
kube-system   metrics-server-2   0/1   Running   0   1m"; run_verify
expect "0/1 Running 파드는 실패"         "FAIL  모든 파드 Running/Completed"

# 3. NodePort·LoadBalancer 서비스
base_env; S_SVCS="${S_SVCS}
default   demo   NodePort"; run_verify
expect "NodePort 서비스는 실패"          "FAIL  호스트 포트 노출 없음"

# 4. hostNetwork가 아닌 파드의 hostPort (DNAT로 ufw 우회)
base_env; S_HOSTPODS="${S_HOSTPODS}
default   <none>   8080"; run_verify
expect "hostPort 파드는 실패"            "FAIL  호스트 포트 노출 없음"

# 5. S3 스냅샷이 오래됨 / S3 항목 없음
base_env; S_SNAPS="s3://bucket/etcd/a   true   ${stale}"; run_verify
expect "8시간 된 S3 스냅샷은 실패"       "FAIL  S3 etcd 스냅샷 7시간 이내"
base_env; S_SNAPS="file:///x   true   ${fresh}"; run_verify
expect "S3 항목이 없으면 실패"           "FAIL  S3 etcd 스냅샷 7시간 이내"

# 6. 복원 플레이북: 비밀값을 명령줄로 넘기지 않고, 출력을 숨기지 않는다
restore="${repo}/ansible/etcd-restore.yml"
out="$(grep -nE 'k3s_token|k3s_etcd_s3_(access|secret)_key|no_log' "${restore}" || echo "없음")"
expect "복원 플레이북에 비밀값·no_log 없음" "없음"
out="$(cat "${restore}")"
expect "복원 전에 config.yaml 존재 확인"   "/etc/rancher/k3s/config.yaml"

echo
echo "통과 ${pass} / 실패 ${fail}"
[[ "${fail}" -eq 0 ]]
