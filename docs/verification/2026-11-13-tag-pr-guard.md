# 검증: 태그 PR 자동 배포와 위조 PR 거부

- 날짜: 2026-11-12 (종단 확인), 2026-11-13 (거부 검증)
- 대상: `June21621/homelab` main 보호 규칙(ruleset), 태그 PR 검사기, 앱 repo `June21621/portfolio`
- 관련 코드: `.github/workflows/build-and-bump.yaml`, `.github/workflows/tag-pr-guard.yaml`,
  `scripts/tag_pr_guard/`, `scripts/bump-tag.sh`, `terraform/github/`, `scripts/forge-bot-pr.sh`

## 목적

두 가지를 실제 PR로 확인한다.

1. **사람 손 없이 배포된다**: 앱 repo main에 병합하면 이미지 빌드 → 태그 PR → 검사 → 자동 병합 → 새 파드까지 이어진다
2. **태그 한 줄 말고는 자동으로 들어가지 않는다**: 태그 갱신 봇의 자격 증명이 새어 나가도(앱 repo가 털린 상황)
   봇 이름으로 다른 변경을 자동 병합시킬 수 없다

## 구조 요약

| 단계 | 어디서 | 무엇을 |
|---|---|---|
| 빌드 | 앱 repo Actions (homelab의 재사용 워크플로) | 이미지 → GHCR, 빌드 증명서(attestation) |
| 태그 PR | 같은 워크플로의 bump job | GitHub App(`june21621-tag-bump`) 단기 토큰으로 homelab에 PR, 자동 병합 예약, 같은 앱의 이전 태그 PR 닫기 |
| 검사 | homelab Actions | `tag-pr-guard`: base(main) 코드로 PR diff를 데이터로 읽어 태그 줄만 바뀌었는지·증명서 확인. `static-checks`: pre-commit·kustomize 렌더 검사·pytest·terraform validate |
| 병합 | GitHub | ruleset이 두 검사 통과(GitHub Actions 앱이 보고한 것만 인정)를 요구. 우회 계정 없음 |
| 배포 | 클러스터 안 ArgoCD | main을 폴링해 동기화 |

App 권한은 Contents·Pull requests 쓰기만 있고 **Workflows 권한은 없다**. homelab에만 설치했다.

## 1. 종단 확인 (2026-11-12)

### 재현 방법

portfolio에 `/version` 엔드포인트를 추가하는 PR(#1)을 만들어 main에 병합했다. 그 뒤로는 아무것도 손대지 않았다.

### 기대 동작

빌드 → 봇 태그 PR → 두 검사 통과 → GitHub 자동 병합 → ArgoCD가 prod·lab에 새 이미지 배포. 이전 봇 PR(#11)은 닫힌다.

### 실제 결과 (KST)

| 시각 | 사건 | 걸린 시간 |
|---|---|---|
| 18:53:00 | portfolio PR #1 병합 (`9c608ea`) | 0 |
| 18:53:13 | 테스트 통과 | 8초 |
| 18:53:58 | 이미지 빌드·push·빌드 증명서 | 41초 |
| 18:54:11 | 봇이 homelab PR #15 생성, 자동 병합 예약. #11은 "새 태그 PR로 대체됨"으로 닫힘 | |
| 18:54:31 | `tag-pr-guard` 통과 | 13초 |
| 18:55:41 | `static-checks` 통과 | 1분 23초 |
| 18:56:26 | GitHub 자동 병합 (`0656d10`) | 검사 끝 + 45초 |
| 18:59:33 | lab Synced·Healthy, 새 파드 Ready | 병합 + 3분 7초 |
| 19:01:00 | prod Synced·Healthy, 새 파드 Ready | 병합 + 4분 34초 |

- **앱 병합 → prod 반영: 8분 0초**, 사람 개입 0회
- prod 파드에서 `GET /version` → `{"version":"9c608ea…","build_time":"2026-11-12T09:53:22Z","pod":"portfolio-855879d966-frpzn"}`, 재시작 0
- 병합된 브랜치 `bump/portfolio-9c608ea`는 repo 설정으로 자동 삭제됨

### 해석

- 8분 중 약 4분 반은 **ArgoCD의 Git 폴링 주기(3분)** 대기다. GitHub webhook을 쓰면 줄일 수 있지만 클러스터로 들어오는
  경로가 필요하다(지금은 인바운드 포트 0). 7단계 Cloudflare Tunnel 때 검토
- `static-checks` 1분 남짓은 대부분 도구 설치(terraform·helm·kubectl·pre-commit 훅) 시간이다. 자동 병합이라 기다림 비용은 작다

## 2. 위조 봇 PR 거부 (2026-11-13)

### 재현 방법

앱 repo가 털려 App 개인키가 새어 나간 상황을 재현한다.

1. App 설정의 Credentials에서 **시험용 개인키를 하나 더 만든다** (운영 키는 GitHub 시크릿에만 있어 꺼낼 수 없다)
2. 관리 PC(WSL)에서 `scripts/forge-bot-pr.sh <키> <client ID> other-file same-file guard workflow`
   - 봇 job과 같은 권한의 설치 토큰을 받아, 봇 이름(`june21621-tag-bump[bot]`)으로 커밋·PR을 만든다
   - 위조 PR에는 자동 병합을 예약하지 않았다. 검사가 잘못 통과해도 병합되지 않게 하기 위해서이며,
     병합 가능 여부는 `mergeStateStatus`로 확인했다(자동 병합도 같은 조건을 기다리므로 결론은 같다)
3. 확인 후 `cleanup`으로 위조 PR을 닫고 브랜치를 지운 뒤, 시험용 키를 WSL에서 `shred -u`, GitHub에서 삭제

### 기대 동작과 실제 결과

| 시나리오 | 위조 내용 | 기대 | 실제 |
|---|---|---|---|
| `other-file` (#16) | 태그 + base 메모리 limit 128Mi → 2Gi | `tag-pr-guard` 실패 | ✅ 실패 "허용 밖 파일: `gitops/apps/portfolio/base/deployment.yaml`". `static-checks`는 **통과**. 병합 `BLOCKED` |
| `same-file` (#17) | 태그 + 같은 파일의 `namespace: portfolio` → `kube-system` | `tag-pr-guard` 실패 | ✅ 실패 "newTag 외 변경: `-namespace: portfolio`, `+namespace: kube-system`". `static-checks` **통과**. `BLOCKED` |
| `guard` (#18) | 검사기 `evaluate()` 첫 줄에 `return []` (항상 통과) | base 코드가 실행돼 실패 | ✅ `tag-pr-guard` 실패 "허용 밖 파일: `rules.py`" + `static-checks`도 실패(pytest가 "막아야 할 PR이 통과" 다수 검출). `BLOCKED` |
| `workflow` | `.github/workflows/tag-pr-guard.yaml` 한 줄 추가 후 push | push 자체 거부 | ✅ `refusing to allow a GitHub App to create or update workflow ... without 'workflows' permission`. 브랜치가 생기지 않음 |

각 실패 PR에는 검사기가 실패 이유를 코멘트로 남겼다. 검사 시간은 `tag-pr-guard` 7~8초, `static-checks` 1분 7초~1분 18초.

### 해석

- **두 검사는 역할이 다르다.** 메모리 2Gi·kube-system은 문법상 멀쩡한 설정이라 `static-checks`가 통과시켰고,
  이를 막은 것은 "태그 줄만"이라는 `tag-pr-guard`의 규칙이다
- **검사기 위조가 무력한 이유**: `tag-pr-guard`는 PR 코드가 아니라 `base.sha`(main)를 체크아웃해 실행한다.
  PR 쪽 검사기는 데이터로만 읽힌다. 여기에 pytest가 두 번째 방어선으로 걸렸다
- **워크플로 위조는 권한에서 막힌다**: App에 Workflows 권한을 주지 않았기 때문에 검사 워크플로 자체를 지우거나 바꿀 수 없다

## 3. 사람 경로

| 시나리오 | 기대 | 실제 |
|---|---|---|
| main 직접 push (2026-11-13) | ruleset이 거부 | ✅ `GH013: Repository rule violations` — "Changes must be made through a pull request", "2 of 2 required status checks are expected". main 변화 없음 |
| 사람이 연 PR (#13, #14) | `tag-pr-guard` 즉시 통과(봇이 아니면 검사 대상 아님), 사람이 병합 | ✅ 7초·8초에 통과, 수동 병합. 자동 병합은 예약되지 않음 |

#12(검사 워크플로를 처음 넣은 PR)는 main에 검사기가 아직 없어 `tag-pr-guard`가 "Project directory does not exist"로
실패했다. base 코드로 실행하는 설계상 첫 PR은 반드시 이렇게 실패한다(실패 쪽으로 닫힘). ruleset 적용 전이라 병합할 수 있었다.

사람 PR도 `static-checks`는 그대로 받는다. 사람 PR을 `tag-pr-guard`에서 실패시키지 않는 이유는, 필수 검사가 보고되지 않거나
실패하면 우회 계정이 없는 ruleset 때문에 사람도 병합할 수 없기 때문이다.

## 발견한 것

- **WSL의 `gh`가 Windows `gh.exe`면 WSL 환경 변수(`GH_TOKEN`)가 전달되지 않는다.** 위조 스크립트를 `gh`로 짰다면 PR이
  사용자 계정으로 열려 검증이 무의미해졌다. 스크립트는 `curl`로 API를 호출하고, 토큰은 600 권한 헤더 파일로 넘겨
  명령 인자(프로세스 목록)에도 남기지 않는다
- **App 개인키 백업이 없었다.** 운영 키는 portfolio 시크릿에만 있다. 키를 잃어도 새 키를 만들어 시크릿을 바꾸면 되므로
  백업 대신 "필요하면 재발급"으로 운영한다(runbook에 기록 예정)
- GitHub 자동 병합은 검사 완료 후 바로가 아니라 약 45초 뒤에 일어났다
- 봇 커밋은 `git push`로 만들어 서명 검증(`verified`)이 false다. ruleset에 서명 필수 규칙은 넣지 않았다

## 남은 한계와 후속

- `pull_request` 이벤트의 **워크플로 파일은 PR 쪽 것이 쓰인다.** 봇은 Workflows 권한이 없어 바꿀 수 없지만,
  사람 PR은 검사 워크플로를 바꿔 스스로 통과시킬 수 있다. 사람 PR은 사람이 병합하므로 리뷰가 방어선이다(ADR로 기록 예정)
- 증명서 음성 시나리오(증명서 없음·SHA 불일치·다른 서명 워크플로)는 검사기를 로컬에서 실제 이미지에 돌려 확인했고,
  위조 PR로는 시험하지 않았다. 위조 PR은 경로 규칙에서 먼저 실패해 증명서 검사까지 가지 않는다
- 배포 반영 시간을 줄이는 ArgoCD webhook은 7단계에서 검토
