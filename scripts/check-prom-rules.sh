#!/usr/bin/env bash
# 직접 만든 알림 규칙(PrometheusRule) 검사: 문법(promtool check rules) + 단위 테스트(promtool test rules).
#   사용: check-prom-rules.sh <규칙 폴더>   (예: gitops/platform/monitoring/rules)
#   <규칙 폴더>/*.yaml = PrometheusRule, <규칙 폴더>/tests/*_test.yaml = promtool 테스트(rule_files는 파일 이름만)
# 규칙 파일이 없으면 통과. 하나라도 실패하면 1.
set -euo pipefail

src="${1:?사용: check-prom-rules.sh <규칙 폴더>}"
here="$(cd "$(dirname "$0")" && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

uv run --quiet --script "${here}/extract_rules.py" "${src}" "${work}" || exit 1

shopt -s nullglob
rules=("${work}"/*.yaml)
if ((${#rules[@]} == 0)); then
  echo "규칙 파일 없음: ${src}"
  exit 0
fi
promtool check rules "${rules[@]}" || exit 1

tests=("${src}"/tests/*_test.yaml)
if ((${#tests[@]} > 0)); then
  cp "${tests[@]}" "${work}/"
  (cd "${work}" && promtool test rules ./*_test.yaml) || exit 1
fi
