#!/usr/bin/env bash
# Alertmanager 테스트 (관리 PC에서). 클러스터 리소스는 바꾸지 않고 Alertmanager API만 쓴다.
#   fire             : 가짜 warning 알림(HomelabTestAlert)을 5분 동안 → Discord 수신, 5분 뒤 해결 알림
#   silence-watchdog : Watchdog을 30분 일시 정지 → healthchecks.io 핑이 끊겨 이메일이 와야 함(감시자 감시 확인)
# 응답에는 비밀값이 없다(웹훅 URL은 Alertmanager 안의 파일에만 있음).
set -euo pipefail

KUBECONFIG="${KUBECONFIG:-${HOME}/.kube/homelab.yaml}"
export KUBECONFIG
PORT=19093
API="http://127.0.0.1:${PORT}/api/v2"

usage() {
  echo "사용: alert-test.sh fire|silence-watchdog" >&2
  exit 2
}
[[ $# -eq 1 ]] || usage

kubectl -n monitoring port-forward svc/monitoring-kube-prometheus-alertmanager "${PORT}:9093" >/dev/null 2>&1 &
pf=$!
trap 'kill "${pf}" 2>/dev/null || true' EXIT
for _ in $(seq 1 20); do
  curl -fsS "${API}/status" >/dev/null 2>&1 && break
  sleep 0.5
done
curl -fsS "${API}/status" >/dev/null || { echo "Alertmanager에 연결하지 못함 (port-forward)" >&2; exit 1; }

# API에는 UTC(…Z)로 보낸다. 사람에게는 한국 시간도 같이 보여 준다(검증 기록은 KST로 쓴다)
now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
later() { date -u -d "+$1 minutes" +%Y-%m-%dT%H:%M:%SZ; }
kst() { TZ=Asia/Seoul date -d "${1:-now}" '+%H:%M:%S KST'; }

case "$1" in
  fire)
    curl -fsS -X POST "${API}/alerts" -H 'Content-Type: application/json' -d "[{
      \"labels\": {\"alertname\": \"HomelabTestAlert\", \"severity\": \"warning\", \"namespace\": \"monitoring\"},
      \"annotations\": {\"summary\": \"테스트 알림 (scripts/alert-test.sh)\", \"description\": \"테스트라 할 일 없음. 5분 뒤 해결 알림이 와야 한다\"},
      \"startsAt\": \"$(now)\", \"endsAt\": \"$(later 5)\"}]"
    echo "보냄 $(kst) ($(now)): HomelabTestAlert(warning). group_wait 30초 뒤 Discord, 5분 뒤($(kst '+5 minutes')) 해결 알림"
    ;;
  silence-watchdog)
    id="$(curl -fsS -X POST "${API}/silences" -H 'Content-Type: application/json' -d "{
      \"matchers\": [{\"name\": \"alertname\", \"value\": \"Watchdog\", \"isRegex\": false, \"isEqual\": true}],
      \"startsAt\": \"$(now)\", \"endsAt\": \"$(later 30)\",
      \"createdBy\": \"alert-test.sh\", \"comment\": \"감시자 감시 확인 (6단계 확인 기준 4)\"}")"
    echo "Watchdog 일시 정지 $(kst) ($(now)) ~ $(kst '+30 minutes') ${id}"
    echo "healthchecks.io DOWN 이메일 예상 $(kst '+15 minutes') 무렵(Period 5분 + Grace 10분), 자동 해제 뒤 UP 이메일"
    ;;
  *) usage ;;
esac
