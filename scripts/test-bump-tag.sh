#!/usr/bin/env bash
# scripts/bump-tag.sh 테스트. 임시 git repo에서 돌린다. verify-argocd.sh --static이 실행
set -euo pipefail

BUMP="$(cd "$(dirname "$0")" && pwd)/bump-tag.sh"
IMAGE=ghcr.io/example/app
OTHER=ghcr.io/example/other
OLD=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
NEW=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
OLD_D=sha256:1111111111111111111111111111111111111111111111111111111111111111
NEW_D=sha256:2222222222222222222222222222222222222222222222222222222222222222
PROD=gitops/apps/app/overlays/prod/kustomization.yaml
LAB=gitops/apps/app/overlays/lab/kustomization.yaml

ROOT="$(mktemp -d)"
trap 'rm -rf "${ROOT}"' EXIT
fails=0

commit_all() {
  git add -A && git -c user.name=t -c user.email=t@example.com commit -qm "$1"
}

setup() {
  mkdir "${ROOT}/$1" && cd "${ROOT}/$1" && git init -q
  mkdir -p "$(dirname "${PROD}")" "$(dirname "${LAB}")"
  local f
  for f in "${PROD}" "${LAB}"; do
    printf 'images:\n  - name: %s\n    newTag: "%s"\n    digest: %s\n  - name: %s\n    newTag: "%s"\n    digest: %s\n' \
      "${OTHER}" "${OLD}" "${OLD_D}" "${IMAGE}" "${OLD}" "${OLD_D}" >"${f}"
  done
  commit_all init
}

bump() { bash "${BUMP}" "$@"; }

changed_lines() { git diff --numstat | cut -f1,2 | sort -u; }

bumps_tag_and_digest_in_every_overlay() {
  bump app "${IMAGE}" "${NEW}" "${NEW_D}" &&
    [[ "$(git diff --name-only | wc -l)" -eq 2 ]] &&
    [[ "$(changed_lines)" == $'2\t2' ]] &&
    grep -Fq "newTag: \"${NEW}\"" "${PROD}" &&
    grep -Fq "digest: ${NEW_D}" "${LAB}"
}

leaves_other_image_alone() {
  bump app "${IMAGE}" "${NEW}" "${NEW_D}" &&
    [[ "$(sed -n 3p "${PROD}")" == "    newTag: \"${OLD}\"" ]] &&
    [[ "$(sed -n 4p "${PROD}")" == "    digest: ${OLD_D}" ]]
}

same_tag_is_no_change() {
  bump app "${IMAGE}" "${OLD}" "${OLD_D}" && git diff --quiet
}

rejects_short_sha() {
  ! bump app "${IMAGE}" abc1234 "${NEW_D}" 2>/dev/null && git diff --quiet
}

rejects_bad_digest() {
  ! bump app "${IMAGE}" "${NEW}" sha256:abc 2>/dev/null && git diff --quiet
}

rejects_unknown_image() {
  ! bump app ghcr.io/example/nope "${NEW}" "${NEW_D}" 2>/dev/null && git diff --quiet
}

rejects_unknown_app() {
  ! bump nope "${IMAGE}" "${NEW}" "${NEW_D}" 2>/dev/null && git diff --quiet
}

rejects_unquoted_tag() {
  sed -i "s/\"${OLD}\"/${OLD}/" "${PROD}" && commit_all unquoted &&
    ! bump app "${IMAGE}" "${NEW}" "${NEW_D}" 2>/dev/null
}

rejects_missing_digest_line() {
  sed -i "/digest: /d" "${PROD}" && commit_all nodigest &&
    ! bump app "${IMAGE}" "${NEW}" "${NEW_D}" 2>/dev/null
}

dot_in_image_is_not_wildcard() {
  # 이미지 이름의 '.'이 정규식 와일드카드로 쓰이면 비슷한 이름의 항목까지 바뀔 수 있다
  sed -i "s#${OTHER}#ghcrXio/example/app#" "${PROD}" && commit_all lookalike &&
    bump app "${IMAGE}" "${NEW}" "${NEW_D}" &&
    [[ "$(sed -n 3p "${PROD}")" == "    newTag: \"${OLD}\"" ]]
}

n=0
for t in bumps_tag_and_digest_in_every_overlay leaves_other_image_alone same_tag_is_no_change \
  rejects_short_sha rejects_bad_digest rejects_unknown_image rejects_unknown_app rejects_unquoted_tag \
  rejects_missing_digest_line dot_in_image_is_not_wildcard; do
  n=$((n + 1))
  if (setup "${n}" && "${t}"); then
    echo "PASS  ${t}"
  else
    echo "FAIL  ${t}"
    fails=$((fails + 1))
  fi
done

((fails == 0))
