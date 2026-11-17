#!/usr/bin/env bash
# scripts/check-prom-rules.sh 테스트. 임시 폴더에 PrometheusRule·promtool 테스트를 만들어 돌린다.
# verify-argocd.sh --static이 실행. promtool이 PATH에 있어야 한다 (scripts/install-prom-tools.sh)
set -euo pipefail

CHECK="$(cd "$(dirname "$0")" && pwd)/check-prom-rules.sh"
ROOT="$(mktemp -d)"
trap 'rm -rf "${ROOT}"' EXIT
fails=0

# rule <폴더> <expr> : PrometheusRule 하나(이름 sample)를 만든다
rule() {
  mkdir -p "$1/tests"
  cat >"$1/sample.yaml" <<EOF
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: sample
  namespace: monitoring
spec:
  groups:
    - name: sample
      rules:
        - alert: SampleDown
          expr: $2
          for: 2m
          labels:
            severity: warning
EOF
}

# unit <폴더> <기대 알림 목록(YAML)> : up이 계속 0인 3분 뒤 상태를 검사하는 promtool 테스트
unit() {
  cat >"$1/tests/sample_test.yaml" <<EOF
rule_files: [sample.yaml]
evaluation_interval: 1m
tests:
  - interval: 1m
    input_series:
      - series: 'up{job="x"}'
        values: '0x5'
    alert_rule_test:
      - eval_time: 3m
        alertname: SampleDown
        exp_alerts: $2
EOF
}

case_() {  # case_ <설명> <기대 종료 코드> <폴더>
  local code=0
  bash "${CHECK}" "$3" >/dev/null 2>&1 || code=$?
  if [[ "${code}" -eq "$2" ]]; then
    echo "PASS  $1"
  else
    echo "FAIL  $1 (종료 코드 ${code}, 기대 $2)"
    fails=$((fails + 1))
  fi
}

mkdir "${ROOT}/empty"
case_ "규칙 파일이 없으면 통과" 0 "${ROOT}/empty"

rule "${ROOT}/good" 'up == 0'
unit "${ROOT}/good" '[{exp_labels: {severity: warning, job: x}}]'
case_ "올바른 규칙 + 맞는 테스트는 통과" 0 "${ROOT}/good"

rule "${ROOT}/orphan" 'up == 0'
unit "${ROOT}/orphan" '[]'
rm "${ROOT}/orphan/sample.yaml"
case_ "테스트만 있고 규칙 파일이 없으면 실패" 1 "${ROOT}/orphan"

rule "${ROOT}/syntax" 'rate(up'
case_ "문법이 깨진 규칙은 실패" 1 "${ROOT}/syntax"

rule "${ROOT}/wrong" 'up == 0'
unit "${ROOT}/wrong" '[]'
case_ "기대와 다른 알림(테스트 실패)은 실패" 1 "${ROOT}/wrong"

rule "${ROOT}/nolabel" 'up == 0'
sed -i '/labels:/,/severity:/d' "${ROOT}/nolabel/sample.yaml"
case_ "severity 라벨 없는 알림은 실패" 1 "${ROOT}/nolabel"

if ((fails > 0)); then
  echo "실패 ${fails}건"
  exit 1
fi
