#!/usr/bin/env bash
# 앱의 모든 overlay에서 이미지의 newTag·digest 두 줄만 바꾼다. repo 루트에서 실행.
# build-and-bump.yaml의 bump job이 쓴다. 입력은 앱 repo에서 오므로 형식부터 검사한다.
# digest를 함께 쓰는 이유: 태그(:sha)는 레지스트리에서 덮어쓸 수 있다. 쿠버네티스는 digest로 이미지를 받는다
# 사용: bump-tag.sh <앱> <이미지> <40자 커밋 SHA> <sha256:64자 digest>
set -euo pipefail

die() {
  echo "bump-tag: $*" >&2
  exit 1
}

[[ $# -eq 4 ]] || die "사용: bump-tag.sh <앱> <이미지> <40자 SHA> <sha256:digest>"
app="$1"
image="$2"
sha="$3"
digest="$4"
[[ "${app}" =~ ^[a-z0-9-]+$ ]] || die "앱 이름 형식 오류: ${app}"
[[ "${image}" =~ ^[a-z0-9./-]+$ ]] || die "이미지 이름 형식 오류: ${image}"
[[ "${sha}" =~ ^[0-9a-f]{40}$ ]] || die "태그는 40자 커밋 SHA여야 함: ${sha}"
[[ "${digest}" =~ ^sha256:[0-9a-f]{64}$ ]] || die "digest 형식 오류: ${digest}"

shopt -s nullglob
files=(gitops/apps/"${app}"/overlays/*/kustomization.yaml)
((${#files[@]} > 0)) || die "overlay 없음: ${app}"

for f in "${files[@]}"; do
  tmp="$(mktemp)"
  # 이미지 이름은 정규식이 아니라 문자열로 비교한다('.'이 와일드카드가 되지 않게).
  # 그 이미지 항목 바로 다음 두 줄이 newTag·digest 형식이어야 하고, 그 두 줄만 바꾼다.
  # newTag의 따옴표를 유지해야 숫자로만 된 SHA도 문자열로 남는다
  if ! awk -v name="  - name: ${image}" -v sha="${sha}" -v digest="${digest}" '
    BEGIN { found = 0; state = 0 }
    state == 1 {
      if ($0 !~ /^    newTag: "[0-9a-f]{40}"$/) exit 2
      print "    newTag: \"" sha "\""; state = 2; next
    }
    state == 2 {
      if ($0 !~ /^    digest: sha256:[0-9a-f]{64}$/) exit 2
      print "    digest: " digest; state = 0; next
    }
    $0 == name { found++; state = 1 }
    { print }
    END { if (state != 0 || found != 1) exit 2 }
  ' "${f}" >"${tmp}"; then
    rm -f "${tmp}"
    die "${f}: ${image} 항목이 하나가 아니거나 newTag·digest 형식이 예상과 다름"
  fi
  cat "${tmp}" >"${f}" # 권한·링크를 유지하려고 mv 대신 덮어쓴다
  rm -f "${tmp}"
  # 이미 같은 값이면 변경 없음, 아니면 정확히 두 줄 교체여야 한다
  changed="$(git diff --numstat -- "${f}" | cut -f1,2)"
  [[ -z "${changed}" || "${changed}" == $'2\t2' ]] || die "${f}: newTag·digest 두 줄 교체가 아님 (${changed})"
done
