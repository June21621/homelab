# 5단계 설계: ArgoCD 부트스트랩 + GitHub Actions 파이프라인

- 작성일: 2026-10-26 (브레인스토밍 2026-10-21~26)
- 상태: 승인 (2026-10-26)
- 표기: **[사용자]** = 사용자가 정한 것, **[제안]** = 내가 정한 기본값(바꿔도 됨)
- 상위 설계: `2026-10-18-direction-change-design.md` §5단계(문서상 "2단계"), CLAUDE.md "진행 단계 5"

## 1. 의도

이 단계가 끝나면 **클러스터 안의 변경은 git push로만** 일어난다. 앱 repo에 push하면 사람 손을 거치지 않고
몇 분 안에 미니 PC에 새 파드가 뜨고, 태그 외의 줄을 바꾼 PR은 자동 병합이 거부된다.
취업 포트폴리오용이므로 "왜 이렇게 했나"(ADR)와 "정말 막히는가"(검증 기록)가 동작만큼 중요하다.

### 목표
- Terraform으로 ArgoCD를 한 번 설치하고, 이후 ArgoCD가 자기 자신까지 Git으로 관리한다
- Git의 SOPS 암호화 시크릿을 ArgoCD(KSOPS)가 풀어 배포한다
- 첫 서비스(포트폴리오 앱)가 push → 빌드 → 태그 PR → 자동 병합 → 배포로 이어진다
- 자동 병합은 "태그 한 줄만 바뀌었고, 그 이미지가 우리 워크플로로 앱 repo main 커밋에서 빌드됐다"가 증명될 때만

### 비목표
- 외부 공개(Cloudflare Tunnel) — 7단계. 5단계 확인은 `kubectl port-forward`
- 포트폴리오 디자인·내용 — 파이프라인 완성 후 별도 작업, taste-skill 사용 **[사용자]**
- DB(Postgres) **[사용자: 데모는 DB 없음]**
- PR 프리뷰 — 8단계. 프리뷰 코멘트용 GitHub App도 8단계 **[사용자]**
- ArgoCD SSO(dex), notifications, ApplicationSet **[사용자: 끔]** — ApplicationSet은 8단계 비교 때 재검토
- 모니터링·알림 — 6단계 (ArgoCD 동기화 실패 알림도 6단계에서 Alertmanager로)

### 반목표 (이렇게 되면 실패)
- 앱 repo의 CI 자격 증명(GitHub App 토큰)이 새면 `ansible/`·`terraform/`·`.github/workflows/`를 바꿔 main에 들어갈 수 있음
- 이름표(태그)만 같은 다른 이미지가 검사를 통과함
- 첫 설치 values와 이후 ArgoCD가 쓰는 values가 따로 있어 서로 어긋남
- 비밀값이 평문으로 Git·로그·대화 기록에 남음
- 5단계 이후 사람이 `kubectl apply`·`helm install`을 해야 하는 경로가 남음 (첫 부트스트랩 제외)

## 2. 제약

- 단일 노드 N100 16GB, 기반 컴포넌트 합계 4GB 안팎. 모든 차트에 requests/limits, 차트 버전 고정
- 관리 PC는 WSL2. Terraform·kubectl·helm은 `scripts/bootstrap-workstation.sh`로 버전 고정 설치(helm 3.22.1 설치됨)
- 클러스터 API(6443)는 Tailscale로만 접근(ACL 허용됨). kubeconfig `~/.kube/homelab.yaml`
- Terraform state: S3 `june21621-homelab-tfstate`, `use_lockfile = true`, SSO 프로필 `homelab-tfstate`(세션 1시간)
- homelab repo는 private(나중에 public 전환 예정). 커밋·Terraform 실행은 WSL에서, push는 사용자가 직접
- 셸은 `set -euo pipefail` + shellcheck, 로직·API는 Python(`uv` 고정) + pytest
- CLAUDE.md·`docs/runbook.md`는 변경안을 먼저 보여 주고 승인받은 뒤 수정

## 3. 결정 사항

### 3.1 첫 서비스: 포트폴리오 앱 **[사용자]**
- 새 repo `June21621/portfolio` **[제안: 이름]**, public **[제안]** → GHCR 이미지도 public, pull 시크릿 불필요
- FastAPI **[사용자]**, `uv`로 의존성 고정, python slim 멀티 스테이지, non-root **[제안]**
- 엔드포인트 **[사용자 승인]**
  - `GET /` 버전(git SHA)·빌드 시각·파드 이름을 보여 주는 HTML 한 장 (5단계는 이름 정도의 최소 내용)
  - `GET /healthz`, `GET /readyz` → liveness·readiness probe
  - `GET /metrics` → Prometheus 지표(6단계용)
  - `POST /chaos/memory?mb=N`, `POST /chaos/crash` → 6·9단계 OOM·재시작 검증. **환경 변수로 켤 때만 동작**
- 배포는 Kustomize **[사용자]**: `base/` + `overlays/prod`(chaos 끔) + `overlays/lab`(chaos 켬). 같은 이미지, 다른 설정
- 이후 계획(이번 범위 아님): 9단계 후 포트폴리오는 S3 + CloudFront 정적으로 이전 **[사용자]**, lab은 실험 대상으로 남기길 권함

### 3.2 ArgoCD 부트스트랩과 자기 관리 (A 방식) **[사용자]**
- `terraform/argocd-bootstrap/` **[제안]**에서 `helm_release`로 argo-cd 차트 설치
  - values는 **Git의 `gitops/platform/argocd/values.yaml` 한 벌**을 Terraform이 `file()`로 읽는다
  - `lifecycle { ignore_changes = all }` **[제안]** → 설치 후 Terraform은 ArgoCD를 건드리지 않음
- Terraform이 **루트 Application 하나**도 함께 만든다(app-of-apps). 루트 앱이 가리키는 목록에 **ArgoCD 자신**이 들어 있어,
  이후 ArgoCD 업그레이드·설정 변경은 `gitops/`의 차트 버전·values를 바꾸는 PR로 한다
- 끄는 컴포넌트: dex, notifications, applicationset **[사용자]**. 켜는 것: application-controller, repo-server, server, redis
- 동기화 정책: 자동 동기화 + self-heal + prune **[제안]**. 롤백 = git revert
- 비상 복구 경로: ArgoCD 자기 업그레이드가 실패해 스스로 못 고치면 `terraform apply -replace=helm_release.argocd` → 9단계 검증 항목에 추가
- 웹 UI: 외부 노출 없음. `kubectl -n argocd port-forward svc/argocd-server 8080:443` → `https://localhost:8080`, `admin`.
  초기 비밀번호는 화면에 출력하지 않고 클립보드로 복사하는 방법을 runbook에 적고, 로그인 후 초기 비밀번호 시크릿 삭제

### 3.3 부트스트랩 시크릿 (Git을 읽기 전에 필요한 것) — Terraform이 넣는다
1. ~~homelab repo 읽기 키~~ → **불필요**. homelab을 5-1 전에 public으로 전환하므로(§3.7) ArgoCD는 인증 없이 HTTPS로 읽는다
2. **클러스터 전용 age 키** **[사용자]**: 관리자 age 키와 별도. 사용자가 WSL에서 `age-keygen`으로 한 번 생성,
   Bitwarden에 백업, 저장소 밖 경로에 둠. Terraform이 그 파일을 읽어 KSOPS용 시크릿으로 넣는다
   - `.sops.yaml`: `gitops/` 아래 `*.sops.yaml`은 **관리자 키 + 클러스터 키** 두 수신자로 암호화,
     그 밖(`ansible/` 등)은 지금처럼 관리자 키만. 규칙 순서는 gitops 규칙이 먼저
   - 이유: 클러스터가 털려도 호스트 시크릿(AWS 백업 키 등)은 풀리지 않게
- Terraform state에 클러스터 age 개인키가 들어간다. state 버킷은 SSE-S3·버전 관리·퍼블릭 차단·SSO 1시간 세션이라 수용 **[제안]**

### 3.4 Terraform의 GitHub 권한 **[제안]**
- 세분화된 개인 토큰(fine-grained PAT): 기한 90일, 대상 repo는 homelab·portfolio, Administration 쓰기(ruleset·auto-merge 설정)
- Bitwarden 보관, 실행할 때만 `GITHUB_TOKEN` 환경 변수로. 만료 갱신은 runbook에 기록
- 5-5에서 사용 (public 전환으로 5-1의 배포 키가 빠져 5-1에는 필요 없음)

### 3.5 CI: GitHub Actions 호스티드 러너 **[사용자: 기존 결정]**
- 공통 로직은 homelab의 **재사용 워크플로** `.github/workflows/build-and-bump.yaml` **[제안: 이름]**,
  앱 repo에는 이를 호출하는 10줄짜리 진입 파일만
  - homelab이 public이므로 다른 repo에서 별도 설정 없이 호출 가능
  - public repo의 Actions 로그는 누구나 볼 수 있다 → 워크플로에서 비밀값·내부 정보를 출력하지 않는다
- 순서: 테스트(pytest) → 이미지 빌드 → GHCR push(태그 = `github.sha`) → **빌드 증명서**(`actions/attest-build-provenance`) → 태그 PR 생성
- 태그는 커밋 SHA. `latest`·덮어쓰기 태그 금지
- 앱 repo의 main push에서만 태그 PR을 연다(다른 브랜치는 빌드·테스트만)

### 3.6 태그 갱신 PR과 자동 병합 검사
- 태그 갱신용 GitHub App **[사용자: 지금 하나만]**: homelab repo만 설치, Contents 쓰기·Pull requests 쓰기,
  **Workflows 권한 없음**(→ `.github/workflows/`를 바꾸는 커밋을 push할 수 없음). App ID와 개인키는 앱 repo의 Actions 시크릿
- 태그 PR은 `gitops/apps/<앱>/overlays/*/kustomization.yaml`의 `newTag:` 줄만 바꾼다. prod·lab 둘 다 같은 SHA로 **[제안]**
- homelab의 검사 워크플로가 Python 스크립트 `scripts/tag_pr_guard/` **[제안: 위치]**를 실행해 전부 통과해야 성공:
  1. PR 작성자가 우리 App(bot)인가
  2. 바뀐 파일이 `gitops/apps/*/overlays/*/kustomization.yaml`뿐인가
  3. 바뀐 줄이 `newTag:` 줄뿐인가 (추가·삭제 줄 모두 검사)
  4. 새 태그 SHA가 해당 앱 repo **main 브랜치의 커밋**인가
  5. 이미지가 존재하고, **빌드 증명서**가 그 repo·그 커밋·우리 재사용 워크플로를 가리키는가(`gh attestation verify`)
- **검사 스크립트는 반드시 main(base) 쪽 코드로 실행한다** **[제안]**. App은 `.github/workflows/`는 못 바꾸지만
  `scripts/tag_pr_guard/`는 바꿀 수 있으므로, PR 브랜치의 스크립트를 실행하면 검사를 무력화할 수 있다.
  PR의 변경 내용은 GitHub API로 받은 diff를 **데이터로만** 읽고, PR 브랜치 코드는 실행하지 않는다
- 자동 병합을 쓰려면 repo 설정 "Allow auto-merge"를 켜야 한다(현재 꺼짐, Terraform으로 관리)
- 통과 → 자동 병합 예약(squash). 실패 → 병합 안 함 + 실패 이유를 PR 코멘트로
- 앱 repo ↔ 태그 PR 매핑(어느 앱 폴더가 어느 repo인가)은 homelab 안의 설정 파일 하나로 **[제안]**
- pytest 테스트 케이스: 정상 태그 PR, 태그 외 줄 섞임, 허용 밖 파일, main이 아닌 커밋, 증명서 없음, App이 아닌 작성자
- main 보호(ruleset, Terraform GitHub provider로 코드화): 직접 push 금지, 병합 전 PR 필수, 검사 통과 필수, 강제 push 금지.
  **리뷰 승인 필수는 걸지 않음** **[제안]** — 혼자 쓰는 repo라 본인 PR을 승인할 수 없기 때문
- 사람이 연 일반 PR은 이 검사의 대상이 아니다(자동 병합 안 함, 사람이 병합). 검사 워크플로가 "App이 아닌 PR"을
  실패로 만들면 사람 PR이 막히므로, 필수 검사는 "App PR이면 전부 검사, 사람 PR이면 통과"로 동작 **[제안]**

### 3.7 확인된 제약: 무료 요금제 + private repo (2026-10-26 조회)
- homelab repo는 private이고 계정은 GitHub Free. API 조회 결과 ruleset·branch protection 모두
  "Upgrade to GitHub Pro or make this repository public"으로 거부됨 → **지금 main은 보호되지 않은 상태**
- 같은 이유로 private repo에서는 자동 병합(auto-merge)도 쓸 수 없다
- 빌드 증명서는 portfolio repo(public)에서 만들어지므로 영향 없음
- **결정: 5-1 전에 homelab을 public으로 전환** **[사용자]** (Pro 구독 대신)
- 공개 전 점검 결과(2026-10-26):
  - gitleaks 전체 히스토리(커밋 15개) 스캔: 비밀값 없음
  - 드러나는 정보: 커밋 작성자 개인 이메일, 사설 LAN IP·MAC, Tailscale IP, 기기 이름, S3 버킷 이름 → 위험 낮음
  - 커밋 이메일은 히스토리 교체 없이 그대로 공개 **[사용자]**. 새 portfolio repo는 noreply로 시작해도 됨(선택)
- 공개 절차: `.superpowers/` gitignore 추가 → tools-helm 정리·push → gitleaks 재확인 → 콘솔에서 public 전환(사용자)

### 3.8 gitops 디렉터리 구조 **[제안]**
```
gitops/
├── root/                      # 루트 앱이 가리키는 곳: 하위 Application 목록
│   ├── argocd.yaml            # ArgoCD 자신
│   ├── ksops-test.yaml        # 5-2 확인용 (확인 후 삭제)
│   └── portfolio.yaml         # prod·lab 두 Application 또는 하나씩
├── platform/
│   └── argocd/values.yaml     # Terraform 첫 설치와 ArgoCD 자기 관리가 같이 읽는 values
└── apps/
    └── portfolio/
        ├── base/
        └── overlays/{prod,lab}/
```

## 4. 진행 순서와 확인 기준 **[사용자 승인]**

CD를 먼저 만들어 사람이 연 PR로 배포를 확인한 뒤 CI를 붙인다(문제가 생기면 CD·CI 중 어느 쪽인지 나눠 보기 위해).

| 단계 | 할 일 | 확인 기준 |
|---|---|---|
| 5-0 | 공개 준비(§3.7) | homelab public, main 보호 API 조회가 403이 아님 |
| 5-1 | Terraform `argocd-bootstrap`, 클러스터 age 키 시크릿, 루트 앱, ArgoCD 자기 관리 | UI 로그인, ArgoCD 앱 Synced·Healthy, 재실행 시 Terraform 변경 0, ArgoCD 메모리 실측 기록 |
| 5-2 | KSOPS(repo-server 플러그인), `.sops.yaml` 수신자 규칙, 테스트 시크릿 | 암호화 파일 push → 클러스터에 시크릿 생성. 관리자 키만으로 암호화한 파일은 복호화 실패 |
| 5-3 | portfolio repo·앱·Dockerfile, 첫 이미지, `gitops/apps/portfolio/` prod·lab | 사람이 태그 바꾼 PR 병합 → 새 파드, 화면에 SHA, lab에서만 chaos 동작 |
| 5-4 | 재사용 워크플로, 증명서, GitHub App, 태그 PR 자동 생성 | 앱 push → homelab에 태그 PR 자동 생성 |
| 5-5 | 검사 스크립트·테스트·워크플로, ruleset(Terraform), 자동 병합 | push → 몇 분 안에 새 파드(걸린 시간 기록). 태그 외 줄·허용 밖 파일·워크플로 수정 PR은 거부 |
| 5-6 | ADR 0005(GitHub Actions), 0006(pull 배포), 0007(gitops 위치·태그 갱신 경로), 0008(KSOPS·클러스터 키), 0009(ArgoCD 자기 관리) **[제안]**, `docs/verification/` 기록, CLAUDE.md·runbook 변경안 | 사용자 승인 |

5-5의 거부 검증은 실제로 PR을 만들어 확인하고 `docs/verification/`에 재현 방법·기대·실제를 남긴다.

## 5. 사용자 수동 작업 (콘솔, runbook에 기록)

| 언제 | 작업 |
|---|---|
| 5-1 전 | homelab repo public 전환(Settings → Danger Zone) |
| 5-1 전 | 클러스터 전용 age 키 생성(`age-keygen`) → Bitwarden 백업. 개인키를 화면에 띄우지 않게 안내 |
| 5-1 | `terraform apply`는 사용자가 실행(SSO 로그인 필요) |
| 5-3 전 | GitHub에 portfolio repo 생성 |
| 5-4 전 | 태그 갱신용 GitHub App 생성·설치, App ID·개인키를 portfolio repo 시크릿에 등록 |
| 5-5 전 | Terraform용 fine-grained PAT 생성 → Bitwarden |

## 6. 구현자에게 맡기는 것

- 차트·도구 버전(설치 시점의 안정 버전으로 고정, 2주 이상 된 것), requests/limits 값(실측 후 조정)
- 루트 Application을 Terraform에서 만드는 방법. 주의: `kubernetes_manifest`는 plan 시점에 CRD가 있어야 해서 빈 클러스터에서
  실패할 수 있다. argo-cd 차트의 `extraObjects`나 argocd-apps 차트 등 첫 apply 한 번에 되는 방법을 고를 것
- KSOPS를 repo-server에 붙이는 방식(공식 문서 방식 따름)
- Kustomize 세부(라벨, 리소스 이름), FastAPI 앱 내부 구조, 지표 라이브러리
- 태그 PR 브랜치 이름·커밋 메시지 형식, 이미 열린 태그 PR이 있을 때 처리(덮어쓰기 권장)
- Makefile 타깃 이름(`make argocd-bootstrap` 등)

## 7. 기타

- `.superpowers/`가 2026-10-26 기준 git 추적 대상(??)으로 보인다. 첫 커밋 전에 `.gitignore`에 추가하는 변경안을 먼저 보여 줄 것
  (공개 전이라 특히 중요: 기여 초안·블로그 초안이 공개 repo에 들어가면 안 됨)
- 작업 브랜치: `tools-helm`(174f9b1, push 전)에서 이어 간다 **[사용자]**
