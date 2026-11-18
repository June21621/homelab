#!/usr/bin/env bash
# Discord 알림 문구 테스트: 실제로 받았던 알림(scripts/testdata/alertmanager/*.json)을 템플릿에 넣어
# 제목·본문이 기대값(*.expected, "제목\n---\n본문")과 같은지 본다. amtool이 PATH에 있어야 한다.
#   사용: test-am-templates.sh <템플릿 폴더(*.tmpl)>
# verify-argocd.sh --static이 렌더링한 차트에서 템플릿을 꺼내(am_config_for_check.py) 실행한다.
set -euo pipefail

tmpl_dir="${1:?사용: test-am-templates.sh <템플릿 폴더>}"
data_dir="$(cd "$(dirname "$0")" && pwd)/testdata/alertmanager"

shopt -s nullglob
tmpls=("${tmpl_dir}"/*.tmpl)
((${#tmpls[@]} > 0)) || { echo "템플릿 파일 없음: ${tmpl_dir}" >&2; exit 1; }

render() {  # render <정의 이름> <데이터 파일>
  amtool template render --template.glob="${tmpl_dir}/*.tmpl" \
    --template.text="{{ template \"$1\" . }}" --template.data="$2"
}

fails=0
for data in "${data_dir}"/*.json; do
  name="$(basename "${data}" .json)"
  # amtool 출력은 끝에 줄바꿈이 없다. 제목이 한 줄인지도 함께 확인되도록 구분선을 직접 붙인다
  got="$(render homelab.discord.title "${data}")"$'\n---\n'"$(render homelab.discord.message "${data}")"
  if diff -u "${data_dir}/${name}.expected" <(printf '%s\n' "${got}") >/dev/null; then
    echo "PASS  ${name}"
  else
    echo "FAIL  ${name}"
    diff -u "${data_dir}/${name}.expected" <(printf '%s\n' "${got}") | sed 's/^/      /' || true
    fails=$((fails + 1))
  fi
done
((fails == 0))
