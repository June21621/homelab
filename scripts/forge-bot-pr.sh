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
#   cleanup     위조 PR을 닫고 위조 브랜치를 지운다
#
# 키와 토큰은 화면·로그·명령 인자에 남기지 않는다(헤더는 600 파일로 넘김). 토큰은 끝날 때 폐기한다.
# gh는 쓰지 않는다: WSL의 gh가 Windows gh.exe면 GH_TOKEN이 전달되지 않아 사용자 계정으로 PR이 열린다.
# 위조 PR에는 자동 병합을 예약하지 않는다(검사가 잘못 통과해도 병합되지 않게). 병합 가능 여부는
# PR 화면과 mergeStateStatus로 따로 확인한다.
set -euo pipefail

REPO=June21621/homelab
API=https://api.github.com
FAKE_SHA=a4085114bc9c3a958e200220c68d7741ae056757 # 예전에 실제로 빌드된 portfolio SHA

die() { echo "오류: $*" >&2; exit 1; }

[[ $# -ge 3 ]] || die "사용법: $0 <키.pem> <client ID> <시나리오...>"
KEY=$1 CLIENT_ID=$2
shift 2
[[ -r "${KEY}" ]] || die "키 파일을 읽을 수 없음: ${KEY}"
for s in "$@"; do
  case "${s}" in other-file | same-file | guard | workflow | cleanup) ;; *) die "모르는 시나리오: ${s}" ;; esac
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
set_tag() { sed -i -E "s/^(    newTag: )\"[0-9a-f]{40}\"$/\\1\"${FAKE_SHA}\"/" "${prod}"; }

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
  esac
  git diff --stat
  [[ -n "$(git status --porcelain)" ]] || die "$1: 위조 변경이 적용되지 않음"
}

run_scenario() {
  local s=$1 branch="bump/portfolio-forge-$1"
  echo
  echo "=== ${s} ==="
  git switch -q main
  git reset -q --hard origin/main
  git switch -q -c "${branch}"
  forge "${s}"
  git commit -qam "bump(portfolio): forged ${s}"

  if [[ "${s}" == workflow ]]; then
    # 기대: App에 Workflows 권한이 없어 GitHub이 push를 거부한다
    if git_t push -q origin "${branch}" 2>"${work}/push.err"; then
      echo "실패: workflow 파일 push가 받아들여짐"
      return 1
    fi
    echo "기대대로 push 거부:"
    grep -iE 'workflow|refusing|denied' "${work}/push.err" || cat "${work}/push.err"
    return 0
  fi

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
