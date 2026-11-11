#!/usr/bin/env bash
# 앱의 모든 overlay에서 이미지 태그(newTag) 한 줄만 바꾼다. repo 루트에서 실행.
# build-and-bump.yaml의 bump job이 쓴다. 입력은 앱 repo에서 오므로 형식부터 검사한다.
# 사용: bump-tag.sh <앱> <이미지> <40자 커밋 SHA>
set -euo pipefail

die() {
  echo "bump-tag: $*" >&2
  exit 1
}

[[ $# -eq 3 ]] || die "사용: bump-tag.sh <앱> <이미지> <40자 SHA>"
app="$1"
image="$2"
sha="$3"
[[ "${app}" =~ ^[a-z0-9-]+$ ]] || die "앱 이름 형식 오류: ${app}"
[[ "${image}" =~ ^[a-z0-9./-]+$ ]] || die "이미지 이름 형식 오류: ${image}"
[[ "${sha}" =~ ^[0-9a-f]{40}$ ]] || die "태그는 40자 커밋 SHA여야 함: ${sha}"

shopt -s nullglob
files=(gitops/apps/"${app}"/overlays/*/kustomization.yaml)
((${#files[@]} > 0)) || die "overlay 없음: ${app}"

for f in "${files[@]}"; do
  grep -Fxq "  - name: ${image}" "${f}" || die "${f}에 이미지 없음: ${image}"
  # 그 이미지 항목의 바로 다음 줄만 바꾼다. 따옴표를 유지해야 숫자로만 된 SHA도 문자열로 남는다
  sed -i -E "\\#^  - name: ${image}\$#,+1 s/^(    newTag: )\"[0-9a-f]{40}\"\$/\\1\"${sha}\"/" "${f}"
  grep -Fxq "    newTag: \"${sha}\"" "${f}" || die "${f}의 newTag 형식이 예상과 다름"
  # 이미 같은 태그면 변경 없음, 아니면 정확히 한 줄 교체여야 한다
  changed="$(git diff --numstat -- "${f}" | cut -f1,2)"
  [[ -z "${changed}" || "${changed}" == $'1\t1' ]] || die "${f}: 한 줄 교체가 아님 (${changed})"
done
