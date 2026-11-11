#!/usr/bin/env bash
# scripts/bump-tag.sh 테스트. 임시 git repo에서 돌린다. verify-argocd.sh --static이 실행
set -euo pipefail

BUMP="$(cd "$(dirname "$0")" && pwd)/bump-tag.sh"
IMAGE=ghcr.io/example/app
OTHER=ghcr.io/example/other
OLD=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
NEW=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
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
    printf 'images:\n  - name: %s\n    newTag: "%s"\n  - name: %s\n    newTag: "%s"\n' \
      "${OTHER}" "${OLD}" "${IMAGE}" "${OLD}" >"${f}"
  done
  commit_all init
}

bump() { bash "${BUMP}" "$@"; }

changed_lines() { git diff --numstat | cut -f1,2 | sort -u; }

bumps_every_overlay_one_line() {
  bump app "${IMAGE}" "${NEW}" &&
    [[ "$(git diff --name-only | wc -l)" -eq 2 ]] &&
    [[ "$(changed_lines)" == $'1\t1' ]] &&
    grep -Fq "newTag: \"${NEW}\"" "${PROD}" &&
    grep -Fq "newTag: \"${NEW}\"" "${LAB}"
}

leaves_other_image_alone() {
  bump app "${IMAGE}" "${NEW}" &&
    [[ "$(sed -n 3p "${PROD}")" == "    newTag: \"${OLD}\"" ]]
}

same_tag_is_no_change() {
  bump app "${IMAGE}" "${OLD}" && git diff --quiet
}

rejects_short_sha() {
  ! bump app "${IMAGE}" abc1234 2>/dev/null && git diff --quiet
}

rejects_unknown_image() {
  ! bump app ghcr.io/example/nope "${NEW}" 2>/dev/null && git diff --quiet
}

rejects_unknown_app() {
  ! bump nope "${IMAGE}" "${NEW}" 2>/dev/null && git diff --quiet
}

rejects_unquoted_tag() {
  sed -i "s/\"${OLD}\"/${OLD}/" "${PROD}" && commit_all unquoted &&
    ! bump app "${IMAGE}" "${NEW}" 2>/dev/null
}

n=0
for t in bumps_every_overlay_one_line leaves_other_image_alone same_tag_is_no_change \
  rejects_short_sha rejects_unknown_image rejects_unknown_app rejects_unquoted_tag; do
  n=$((n + 1))
  if (setup "${n}" && "${t}"); then
    echo "PASS  ${t}"
  else
    echo "FAIL  ${t}"
    fails=$((fails + 1))
  fi
done

((fails == 0))
