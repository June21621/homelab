# 5단계: ArgoCD 부트스트랩 + GitHub Actions 파이프라인 구현 계획

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Terraform으로 ArgoCD를 한 번 설치해 자기 관리로 넘기고, portfolio 앱 push가 빌드 → GHCR → 태그 PR → 검사 통과 시 자동 병합 → 배포로 이어지게 만든다.

**Architecture:** WSL의 Terraform(`terraform/argocd-bootstrap/`)이 클러스터 age 키 시크릿과 argo-cd Helm 릴리스를 만들고, values의 `extraObjects`로 루트 Application을 꽂는다. 루트 앱은 `gitops/root/`의 Application들(ArgoCD 자신 포함)을 관리한다. portfolio repo의 Actions는 homelab의 재사용 워크플로로 이미지를 빌드·증명하고 GitHub App 토큰으로 `newTag:` 한 줄짜리 PR을 연다. homelab의 검사 워크플로가 main 쪽 Python 스크립트로 PR diff를 데이터로만 검사하고, ruleset의 필수 검사가 자동 병합을 통제한다.

**Tech Stack:** Terraform 1.16.5(helm·kubernetes·github provider), argo-cd Helm 차트, KSOPS, SOPS 3.13.3 + age, Kustomize(kubectl 1.36.5 내장), Python + uv 0.12.23 + pytest, FastAPI, GitHub Actions(`actions/create-github-app-token`, `actions/attest-build-provenance`, `docker/build-push-action`), GHCR

**Spec:** `docs/superpowers/specs/2026-10-26-step5-argocd-cicd-design.md`

## Global Constraints

- 차트·이미지·액션·provider 버전은 모두 고정, `latest` 금지. 고를 때는 2주 이상 된 안정 버전, 고른 버전은 커밋 메시지에 적는다
- 서드파티 GitHub Action은 **커밋 SHA로 고정**(`uses: owner/action@<40자 SHA> # vX.Y.Z`) — public repo
- 모든 차트·Deployment에 requests/limits. 기반 컴포넌트 합계 4GB 안팎
- 커밋·Terraform·sops는 WSL에서. WSL 명령은 스크립트 파일로 만들어 `wsl.exe -d Ubuntu-24.04 -- bash <path>`로 실행. `terraform apply`·`git push`·콘솔 작업은 사용자가 실행
- **커밋 전에 커밋 대상 파일 목록을 사용자에게 보여 줄 것**
- 비밀값을 화면·로그·대화에 출력하지 않는다. 비밀값을 다루는 명령 뒤에는 `clear` 안내. public repo의 Actions 로그에 비밀값·내부 정보를 찍지 않는다
- ArgoCD가 뜬 뒤 클러스터 변경은 Git으로만. `kubectl`은 get·describe·logs·port-forward만. 삭제가 따르는 작업(초기 비밀번호 시크릿 삭제, 테스트 앱 prune)은 실행 전 사용자 확인
- ArgoCD는 `main`을 본다 → `gitops/` 변경은 PR이 main에 병합돼야 반영. 각 Task 끝의 PR은 사용자가 push·병합
- 셸 `set -euo pipefail` + shellcheck, 로직·API는 Python(uv 고정) + pytest
- CLAUDE.md·`docs/runbook.md`는 변경안 승인 후에만 수정(Task 9)
- 이름: 클러스터 age 키 파일 `~/.config/sops/age/homelab-cluster.txt`(WSL, repo 밖), 백업 Bitwarden "homelab-cluster-age". 시크릿 `argocd/sops-age`(키 `keys.txt`)
- 이름: 앱 repo `June21621/portfolio`(로컬 `C:\Users\kymoo\Downloads\Projects\portfolio`), 이미지 `ghcr.io/june21621/portfolio`, 네임스페이스 `portfolio`(prod)·`portfolio-lab`(lab)
- 이름: 재사용 워크플로 `.github/workflows/build-and-bump.yaml`, 검사 워크플로 `.github/workflows/tag-pr-guard.yaml`(job 이름 `tag-pr-guard` = ruleset 필수 검사), 검사 패키지 `scripts/tag_pr_guard/`, 앱 매핑 `gitops/image-sources.yaml`
- Terraform state: 버킷 `june21621-homelab-tfstate`, 리전 `ap-northeast-2`, 프로필 `homelab-tfstate`, `use_lockfile = true`, 키 `argocd-bootstrap/terraform.tfstate`·`github/terraform.tfstate`
- kubeconfig `~/.kube/homelab.yaml`(context `homelab`)

## Review Focus

1. **태그 PR이 파일을 수정이 아니라 추가·삭제·이름 변경** → 경로만 보면 통과할 수 있음. 기대: `status != "modified"`면 거부 → Task 7 `test_rejects_added_or_renamed_file`
2. **PR 안의 파일 이름·내용이 셸로 흘러가 명령 주입** → 기대: 실패 이유 코멘트는 `--body-file`로만 쓰고, `${{ github.event.pull_request.* }}` 문자열을 `run:`에 넣지 않음 → Task 8 Step 2 grep 검사
3. **사람이 연 PR이 필수 검사에 막힘** → 기대: App이 아닌 작성자면 검사 즉시 성공 → Task 7 `test_human_pr_passes_without_checks`
4. **ArgoCD 차트 버전·values가 Terraform과 Git에서 어긋남** → 기대: Terraform이 `gitops/root/argocd.yaml`에서 버전을, `gitops/platform/argocd/values.yaml`에서 values를 읽음(한 벌) → Task 1 Step 1 테스트
5. **diff `patch`가 비어 있음(큰 파일·바이너리)** → 기대: 판단 불가 = 거부 → Task 7 `test_rejects_missing_patch`

---

### Task 0: 5-0 공개 준비

**Files:**
- Modify: `.gitignore` (`.superpowers/` 추가)
- Commit: `docs/superpowers/specs/2026-10-26-step5-argocd-cicd-design.md`, 이 계획

- [ ] **Step 1: `.gitignore`의 "에디터·OS" 위에 `# --- 작업용 임시 파일 (기여·블로그 초안) ---` + `.superpowers/` 추가** → `git status --short`에서 `.superpowers/`가 사라지는지 확인
- [ ] **Step 2: gitleaks 전체 히스토리 재확인** — pre-commit 캐시의 gitleaks로 `gitleaks git --redact .` → Expected: `no leaks found`
- [ ] **Step 3: 커밋 대상 목록을 사용자에게 보여 주고 커밋** (`.gitignore`, spec, plan) → 사용자가 `tools-helm` push → PR → main 병합
- [ ] **Step 4: 사용자 콘솔 작업** — homelab Settings → Danger Zone → public. runbook 기록 대상으로 메모
- [ ] **Step 5: 확인** — `gh api repos/June21621/homelab --jq .private` → `false`, `gh api repos/June21621/homelab/rulesets` → `[]`(403이 아님)

---

### Task 1: 5-1 ArgoCD 부트스트랩 (Terraform) + 자기 관리

**Files:**
- Create: `gitops/root/argocd.yaml` — ArgoCD 자신의 Application (multi-source: argo-cd 차트 + `$values` ref로 homelab repo)
- Create: `gitops/platform/argocd/values.yaml` — 첫 설치·자기 관리 공용 values
- Create: `terraform/argocd-bootstrap/{versions.tf,backend.tf,main.tf,variables.tf}`
- Create: `scripts/verify-argocd.sh`
- Modify: `Makefile` (`argocd-bootstrap`, `verify-argocd`, `argocd-ui` 타깃, `.PHONY`)
- Modify: `scripts/bootstrap-workstation.sh` — `age-keygen`이 없으면 설치(apt `age`, 버전 기록)

**Interfaces:**
- Produces: 네임스페이스 `argocd`(Terraform 소유), Secret `argocd/sops-age`, Helm 릴리스 `argocd`, 루트 Application `root`(→ `gitops/root/`, 디렉터리 재귀 없음), Application `argocd`
- Produces: `gitops/root/*.yaml` 하나 = Application 하나 (Task 2·5가 여기에 파일을 추가)
- Produces: `make verify-argocd` — 모든 Application이 Synced·Healthy면 0, 아니면 목록 출력 후 1

- [ ] **Step 1: 단일 출처 테스트 먼저** — `scripts/verify-argocd.sh`에 `--static` 모드: (a) `terraform/argocd-bootstrap/main.tf`가 `yamldecode(file(".../gitops/root/argocd.yaml"))`로 차트 버전을, `file(".../gitops/platform/argocd/values.yaml")`로 values를 읽는지 grep, (b) `helm template argo-cd --repo https://argoproj.github.io/argo-helm --version <argocd.yaml의 버전> -f values.yaml` 결과에 `dex`·`notifications`·`applicationset` Deployment가 없고, 모든 컨테이너에 `resources.limits.memory`가 있으며, `kind: Application` `name: root`가 있음 → 파일이 없으니 FAIL 확인
- [ ] **Step 2: values 작성** — `dex.enabled: false`, `notifications.enabled: false`, `applicationSet.replicas: 0`(또는 차트의 비활성 키), 각 컴포넌트 requests/limits(시작값: controller 512Mi, repo-server 256Mi, server 128Mi, redis 64Mi — 실측 후 조정), `configs.params.server.insecure`는 기본 유지(port-forward 443), `extraObjects`에 루트 Application(`automated: {prune: true, selfHeal: true}`, repoURL `https://github.com/June21621/homelab.git`, path `gitops/root`, targetRevision `main`)
- [ ] **Step 3: `gitops/root/argocd.yaml` 작성** — namespace `argocd`, sources: [차트 `argo-cd` 고정 버전 + `helm.valueFiles: [$values/gitops/platform/argocd/values.yaml]`, homelab repo `ref: values`], syncPolicy automated(prune·selfHeal)
- [ ] **Step 4: Terraform 작성** — provider: helm·kubernetes(`config_path = pathexpand("~/.kube/homelab.yaml")`, `config_context = "homelab"`), backend는 Global Constraints 값. 리소스 순서: `kubernetes_namespace.argocd` → `kubernetes_secret.sops_age`(`keys.txt = file(pathexpand(var.cluster_age_key_path))`, 기본값 `~/.config/sops/age/homelab-cluster.txt`) → `helm_release.argocd`(`create_namespace = false`, `depends_on` 시크릿, `lifecycle { ignore_changes = all }`). 루트 앱은 Terraform 리소스로 만들지 않는다(`kubernetes_manifest`는 빈 클러스터 plan에서 CRD가 없어 실패)
- [ ] **Step 5: 정적 검사 통과** — `terraform -chdir=terraform/argocd-bootstrap init -backend=false && terraform validate`, `terraform fmt -check`, `bash scripts/verify-argocd.sh --static`, shellcheck → 모두 PASS
- [ ] **Step 6: Makefile 타깃** — `argocd-bootstrap`: `aws sso login --profile homelab-tfstate` 안내 후 `terraform init` + `apply`(사용자 실행), `verify-argocd`, `argocd-ui`: `kubectl -n argocd port-forward svc/argocd-server 8080:443`
- [ ] **Step 7: 커밋 목록 보여 주고 커밋 → 사용자 push·PR·main 병합** (루트 앱이 main의 `gitops/root/`를 보므로 apply 전에 병합 필수)
- [ ] **Step 8: 사용자 작업** — WSL에서 `age-keygen -o ~/.config/sops/age/homelab-cluster.txt`(공개키만 화면에 나옴, 파일은 `chmod 600`) → Bitwarden에 파일 내용 백업 → `clear`. 공개키를 알려 받아 Task 2에서 사용
- [ ] **Step 9: 사용자가 `make argocd-bootstrap`** → Expected: apply 성공. 이어서 `make verify-argocd` → `root`·`argocd` 둘 다 Synced·Healthy
- [ ] **Step 10: 멱등 확인** — 사용자가 다시 `terraform plan` → `No changes`
- [ ] **Step 11: UI 확인** — `make argocd-ui` + 초기 비밀번호를 화면에 띄우지 않고 클립보드로(`kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d | clip.exe`) → `https://localhost:8080` 로그인 → 비밀번호 변경 → (사용자 확인 후) 초기 비밀번호 시크릿 삭제
- [ ] **Step 12: 메모리 실측** — `kubectl top pods -n argocd` 결과를 Task 9 검증 기록용으로 남김

---

### Task 2: 5-2 KSOPS (Git PR로 반영 = 자기 관리 첫 검증)

**Files:**
- Modify: `gitops/platform/argocd/values.yaml` — repo-server에 KSOPS
- Modify: `.sops.yaml` — gitops 규칙 추가(맨 위)
- Create: `gitops/apps/ksops-test/{kustomization.yaml,secret-generator.yaml,test.sops.yaml}`
- Create: `gitops/root/ksops-test.yaml`

**Interfaces:**
- Consumes: Secret `argocd/sops-age`(Task 1)
- Produces: `gitops/` 아래 시크릿 작성 규칙 = `*.sops.yaml` + KSOPS generator 파일. Task 5 이후 시크릿은 이 방식

- [ ] **Step 1: `.sops.yaml` 규칙 테스트 먼저** — `gitops/apps/ksops-test/test.sops.yaml`(평문 `kind: Secret`, `stringData.hello: world`)을 `sops -e -i` → `sops -d`를 `SOPS_AGE_KEY_FILE=~/.config/sops/age/homelab-cluster.txt`로 시도 → 지금은 관리자 키로만 잠겨 FAIL 확인
- [ ] **Step 2: `.sops.yaml` 맨 위에 규칙 추가** — `path_regex: ^gitops/.*\.sops\.ya?ml$`, `age: <관리자 공개키>,<클러스터 공개키>`. 기존 규칙은 그 아래 그대로 → `sops updatekeys` 후 Step 1 명령 → PASS, 관리자 키로도 PASS
- [ ] **Step 3: values에 KSOPS** — KSOPS 공식 문서의 ArgoCD 설치 방식: initContainer(`viaductoss/ksops` 고정 태그)가 `ksops`·`kustomize`를 공유 볼륨에 복사, repo-server에 마운트, `configs.cm.kustomize.buildOptions: "--enable-alpha-plugins --enable-exec"`, Secret `sops-age`를 마운트하고 `SOPS_AGE_KEY_FILE` 지정. `helm template` 결과에 repo-server initContainer가 있는지 `verify-argocd.sh --static`에 검사 추가
- [ ] **Step 4: 테스트 앱** — generator가 `test.sops.yaml`을 가리키고, Application은 namespace `ksops-test`, `CreateNamespace=true`
- [ ] **Step 5: 커밋 → 사용자 PR·병합** → Expected: Application `argocd`가 스스로 갱신(repo-server 재시작), `ksops-test` Synced, `kubectl -n ksops-test get secret`에 시크릿 존재(값은 출력하지 않음: `-o jsonpath='{.data}' | wc -c`로 비어 있지 않음만)
- [ ] **Step 6: 부정 검사** — 관리자 키로만 암호화한 파일로 바꾼 브랜치를 PR로 열어(병합하지 않음) 로컬 `kubectl kustomize --enable-alpha-plugins --enable-exec`에 클러스터 키만 주면 실패하는지 확인 → 기록
- [ ] **Step 7: 정리** — (사용자 확인 후) `gitops/root/ksops-test.yaml`·`gitops/apps/ksops-test/` 삭제 PR → prune으로 네임스페이스 삭제 확인

---

### Task 3: portfolio 앱 (portfolio repo)

**Files (portfolio repo):**
- Create: `pyproject.toml`, `uv.lock`, `src/portfolio/{__init__.py,settings.py,app.py,metrics.py}`, `tests/test_app.py`, `Dockerfile`, `.dockerignore`, `README.md`

**Interfaces:**
- Produces: `Settings.from_env() -> Settings` — 필드 `version: str`(env `APP_VERSION`, 기본 `"dev"`), `build_time: str`(`BUILD_TIME`), `pod_name: str`(`POD_NAME`), `chaos_enabled: bool`(`CHAOS_ENABLED`, `"true"`일 때만 True, 기본 False)
- Produces: `create_app(settings: Settings) -> FastAPI`
- Produces: 이미지 빌드 인자 `GIT_SHA`, `BUILD_TIME` → 각각 env `APP_VERSION`, `BUILD_TIME`. 컨테이너 포트 8000, UID 10001, `uvicorn portfolio.app:app`

- [ ] **Step 0: 사용자 작업** — GitHub에 public repo `portfolio` 생성(빈 repo), 로컬 clone. 이 repo 커밋 이메일은 사용자 선택(noreply 가능)
- [ ] **Step 1: 실패하는 테스트** — `TestClient`로:
  - `test_index_shows_version_and_pod`: `version="abc123"`, `pod_name="p-1"` → `GET /` 200, 본문에 `abc123`, `p-1`
  - `test_healthz_and_readyz`: 둘 다 200
  - `test_metrics_exposes_request_counter`: `GET /` 후 `GET /metrics` 본문에 `http_requests_total` 와 `path="/"`(경로 라벨은 라우트 템플릿)
  - `test_chaos_hidden_when_disabled`: `chaos_enabled=False` → `POST /chaos/memory?mb=1`, `POST /chaos/crash` 둘 다 404
  - `test_chaos_memory_allocates`: `chaos_enabled=True` → `POST /chaos/memory?mb=5` 202, 응답 JSON `held_mb >= 5`
  - `test_chaos_memory_rejects_bad_size`: `mb=0`, `mb=4097` → 422
  - `test_chaos_crash_schedules_exit`: `os._exit`를 monkeypatch → 202 응답 후 `os._exit(1)` 호출됨
  - `test_settings_chaos_only_true_string`: `CHAOS_ENABLED` 가 `"1"`·`"yes"`·없음 → False, `"true"` → True
- [ ] **Step 2: `uv run pytest`** → FAIL(모듈 없음)
- [ ] **Step 3: 구현** — 메모리는 모듈 수준 리스트에 `bytearray(mb * 2**20)`를 쌓아 유지, crash는 `BackgroundTasks`로 응답 후 `os._exit(1)`. 지표는 `prometheus_client`(Counter `http_requests_total{method,path,status}`, Histogram `http_request_duration_seconds{path}`), `/metrics`는 지표 미들웨어 집계에서 제외. HTML은 문자열 템플릿 한 장
- [ ] **Step 4: `uv run pytest`** → PASS
- [ ] **Step 5: Dockerfile** — 2단계(uv로 `--frozen` 설치 → python slim 런타임), non-root UID 10001, `LABEL org.opencontainers.image.source=https://github.com/June21621/portfolio`. 로컬 빌드는 하지 않아도 됨(Task 4 CI가 검증)
- [ ] **Step 6: 커밋(목록 보여 주고) → 사용자 push**

---

### Task 4: 5-4 전반 — 재사용 워크플로 빌드 단계 + 첫 이미지

**Files:**
- Create (homelab): `.github/workflows/build-and-bump.yaml` (이 Task에서는 `build` job만)
- Create (portfolio): `.github/workflows/ci.yaml`

**Interfaces:**
- Produces: 재사용 워크플로 입력 — `inputs.app: string`(gitops/apps 아래 폴더 이름), `inputs.image: string`(예 `ghcr.io/june21621/portfolio`); outputs `digest`
- Produces: 이미지 `ghcr.io/june21621/portfolio:<github.sha 40자>` + 빌드 증명서(레지스트리에도 push)
- Consumes(portfolio ci.yaml): `test` job(uv sync --locked + pytest) → `needs: test` → `uses: June21621/homelab/.github/workflows/build-and-bump.yaml@main`, `secrets: inherit`

- [ ] **Step 1: build job** — permissions `contents: read, packages: write, id-token: write, attestations: write`. checkout(호출한 앱 repo) → GHCR 로그인(`GITHUB_TOKEN`) → `docker/build-push-action`(build-args `GIT_SHA=${{ github.sha }}`, `BUILD_TIME`; push는 `github.ref == 'refs/heads/main'`일 때만) → main일 때 `actions/attest-build-provenance`(`subject-name: inputs.image`, `subject-digest`, `push-to-registry: true`)
- [ ] **Step 2: 정적 검사** — `actionlint`(관리 PC에 고정 설치하거나 pre-commit 훅 추가, 버전 고정)로 두 워크플로 검사 → PASS
- [ ] **Step 3: homelab 커밋 → 사용자 PR·병합**, 이어서 portfolio `ci.yaml` 커밋 → 사용자 push(main)
- [ ] **Step 4: 사용자 작업** — GHCR 패키지 `portfolio` 설정에서 visibility public(첫 push 패키지는 private로 생김)
- [ ] **Step 5: 확인** — Actions 실행 성공, `gh attestation verify oci://ghcr.io/june21621/portfolio:<sha> --repo June21621/portfolio --signer-workflow June21621/homelab/.github/workflows/build-and-bump.yaml` → 성공

---

### Task 5: 5-3 portfolio 배포 (CD 확인, 사람이 연 태그 PR)

**Files (homelab):**
- Create: `gitops/apps/portfolio/base/{kustomization.yaml,deployment.yaml,service.yaml}`
- Create: `gitops/apps/portfolio/overlays/prod/kustomization.yaml`, `gitops/apps/portfolio/overlays/lab/{kustomization.yaml,chaos-patch.yaml}`
- Create: `gitops/root/portfolio-prod.yaml`, `gitops/root/portfolio-lab.yaml`
- Create: `gitops/image-sources.yaml`

**Interfaces:**
- Produces: 각 overlay `kustomization.yaml`의 `images: [{name: ghcr.io/june21621/portfolio, newTag: "<40자 SHA>"}]` — **태그 PR이 바꾸는 유일한 줄**
- Produces: `gitops/image-sources.yaml` 스키마(Task 6·7이 읽음):
  ```yaml
  bot_login: <App slug>[bot]          # Task 6에서 채움
  signer_workflow: June21621/homelab/.github/workflows/build-and-bump.yaml
  apps:
    portfolio: {repo: June21621/portfolio, image: ghcr.io/june21621/portfolio}
  ```

- [ ] **Step 1: 렌더링 테스트 먼저** — `scripts/verify-argocd.sh --static`에 추가: `kubectl kustomize gitops/apps/portfolio/overlays/{prod,lab}` 성공, prod에 `CHAOS_ENABLED` 없음(또는 `false`), lab에 `"true"`, 두 overlay의 newTag가 40자 hex, 모든 컨테이너에 requests/limits·`runAsNonRoot: true`·`readOnlyRootFilesystem: true` → FAIL 확인
- [ ] **Step 2: 작성** — base: Deployment 1 replica, 포트 8000, probes `/healthz`(liveness)·`/readyz`(readiness), env `POD_NAME`(downward API), requests `25m/64Mi`, limits `128Mi`(prod). lab patch: `CHAOS_ENABLED=true`, limits `256Mi`(OOM 실험 여유). 네임스페이스 prod `portfolio`, lab `portfolio-lab`. Application은 `CreateNamespace=true`, automated(prune·selfHeal). newTag는 Task 4의 SHA
- [ ] **Step 3: `--static` PASS → 커밋 → 사용자 PR·병합** → `make verify-argocd` 통과, 두 네임스페이스 파드 Running
- [ ] **Step 4: 사람이 연 태그 PR로 CD 확인** — portfolio에 작은 변경 push → 새 SHA 이미지 → 사용자가 homelab에서 두 overlay newTag만 바꾼 PR 병합 → 3분 안팎에 새 파드, `kubectl -n portfolio port-forward svc/portfolio 8000:80` → `/`에 새 SHA. 걸린 시간 기록
- [ ] **Step 5: lab 차이 확인** — lab `POST /chaos/memory?mb=1` 202, prod는 404

---

### Task 6: 5-4 후반 — GitHub App + 태그 PR 자동 생성

**Files:**
- Modify (homelab): `.github/workflows/build-and-bump.yaml` — `bump` job 추가
- Modify (homelab): `gitops/image-sources.yaml` — `bot_login` 채움

**Interfaces:**
- Consumes: portfolio repo 시크릿 `TAG_BUMP_APP_ID`, `TAG_BUMP_APP_PRIVATE_KEY`(`secrets: inherit`로 전달)
- Produces: homelab 브랜치 `bump/<app>-<sha 앞 7자>`, PR 제목 `bump(<app>): <sha 앞 7자>`, 본문에 앱 repo 커밋 링크. 같은 앱의 이전 열린 bump PR은 닫는다. 자동 병합 예약은 이 Task에서 넣지 않는다(repo의 auto-merge 설정이 Task 8에서 켜짐)

- [ ] **Step 1: 사용자 작업(화면별 안내)** — GitHub App 생성: 이름 예 `homelab-tag-bump`, webhook 끔, Repository 권한 Contents: Read & write, Pull requests: Read & write, Metadata: Read, **Workflows: 없음**. homelab에만 설치. 개인키 생성 → portfolio repo Actions 시크릿 두 개 등록 → 로컬 키 파일 삭제 안내
- [ ] **Step 2: bump job** — `needs: build`, `if: github.ref == 'refs/heads/main'`. `actions/create-github-app-token`(owner `June21621`, repositories `homelab`) → homelab checkout(App 토큰) → 각 overlay에서 `yq -i '(.images[] | select(.name == "<image>")).newTag = "<sha>"'` → 변경이 정확히 그 줄뿐인지 `git diff --numstat`로 자체 확인 → 커밋·push·PR. 앱 repo 입력값은 `env:`로 넘기고 `run:` 안에 `${{ }}`로 직접 넣지 않는다
- [ ] **Step 3: actionlint PASS → 커밋 → 사용자 PR·병합**
- [ ] **Step 4: 확인** — portfolio에 push → homelab에 bump PR이 자동으로 열림, 작성자 `<slug>[bot]`, diff가 두 줄(-/+)×overlay 수. PR은 사용자가 병합(아직 자동 병합 없음)

---

### Task 7: 5-5 전반 — 검사 스크립트 (TDD)

**Files:**
- Create: `scripts/tag_pr_guard/pyproject.toml`, `uv.lock`, `src/tag_pr_guard/{__init__.py,rules.py,github.py,cli.py}`, `tests/test_rules.py`, `tests/test_cli.py`

**Interfaces:**
- Produces (`rules.py`, 순수 함수, 실패 이유 문자열 리스트를 돌려줌 — 빈 리스트 = 통과):
  - `ChangedFile(path: str, status: str, patch: str | None)` (dataclass)
  - `check_paths(files: list[ChangedFile], apps: set[str]) -> list[str]` — 경로가 `gitops/apps/<app>/overlays/<env>/kustomization.yaml`이고 `<app>`이 설정에 있으며 `status == "modified"`
  - `check_patch(file: ChangedFile) -> tuple[list[str], str | None]` — 추가·삭제 줄이 전부 `^\s*newTag:\s*"?[0-9a-f]{40}"?\s*$`이고 +/- 개수가 같으며 새 SHA가 하나뿐일 때 그 SHA를 돌려줌
  - `evaluate(author: str, files: list[ChangedFile], config: Config, verify: Callable[[str, str, str], list[str]]) -> list[str]` — 작성자가 `config.bot_login`이 아니면 `[]`. 앱마다 `verify(image_ref, repo, sha)` 호출
- Produces (`github.py`): `list_pr_files(repo: str, pr: int) -> list[ChangedFile]`(`gh api --paginate`), `verify_attestation(image_ref: str, repo: str, sha: str, signer_workflow: str) -> list[str]` — `gh attestation verify oci://<image_ref> --repo <repo> --signer-workflow <signer> --source-ref refs/heads/main --source-digest <sha>`, 실패 시 이유 한 줄(설계 §3.6의 4·5번 검사를 이 한 번으로 확인)
- Produces (`cli.py`): `tag-pr-guard --repo <owner/name> --pr <n> --author <login> --config gitops/image-sources.yaml --report <path>` → 통과 0 / 실패 1, 실패 이유를 `--report` 파일에 Markdown 목록으로

- [ ] **Step 1: 실패하는 테스트** (`tests/test_rules.py`, 가짜 `verify`)
  - `test_valid_bump_passes`: 두 overlay에서 `-  newTag: <sha1>` / `+  newTag: <sha2>` → `[]`, verify가 `ghcr.io/june21621/portfolio:<sha2>`로 1회 호출
  - `test_human_pr_passes_without_checks`: 작성자 `June21621` + 아무 파일 → `[]`, verify 호출 0회
  - `test_rejects_extra_line`: 같은 patch에 `+  replicas: 3` 추가 → 실패 이유에 `newTag 외 변경`
  - `test_rejects_path_outside_overlays`: `scripts/tag_pr_guard/src/tag_pr_guard/rules.py` 수정 → `허용 밖 파일`
  - `test_rejects_workflow_file`: `.github/workflows/tag-pr-guard.yaml` → `허용 밖 파일`
  - `test_rejects_unknown_app`: `gitops/apps/evil/overlays/prod/kustomization.yaml` → `설정에 없는 앱`
  - `test_rejects_added_or_renamed_file`: status `added`·`renamed`·`removed` → 각각 거부
  - `test_rejects_missing_patch`: `patch=None` → `diff 없음`
  - `test_rejects_short_or_nonhex_tag`: `newTag: latest`, `newTag: abc1234` → 거부
  - `test_rejects_two_different_shas_in_one_app`: prod·lab에 서로 다른 SHA → 거부
  - `test_attestation_failure_is_reported`: verify가 `["증명서 없음"]` → 결과에 포함
- [ ] **Step 2: `uv run --project scripts/tag_pr_guard pytest`** → FAIL
- [ ] **Step 3: `rules.py` 구현** — patch 줄 중 `@@`로 시작하는 줄과 앞이 공백인 문맥 줄은 무시, `+`/`-`로 시작하는 줄만 검사
- [ ] **Step 4: PASS 확인**
- [ ] **Step 5: `tests/test_cli.py`** — `list_pr_files`·`verify_attestation`을 monkeypatch: 통과 시 종료 코드 0·report 비어 있음, 실패 시 1·report에 이유 목록. 실제 `gh` 호출 없음 → FAIL → `cli.py`·`github.py` 구현(`subprocess.run([...], check=False)`, 인자 리스트로만, 셸 사용 금지) → PASS
- [ ] **Step 6: 커밋**(PR은 Task 8과 함께)

---

### Task 8: 5-5 후반 — 검사 워크플로 + ruleset(Terraform) + 종단 검증

**Files:**
- Create: `.github/workflows/tag-pr-guard.yaml`
- Create: `terraform/github/{versions.tf,backend.tf,main.tf,imports.tf}`
- Modify: `Makefile` (`github-apply` 타깃)
- Create: `docs/verification/2026-10-XX-tag-pr-guard.md`

**Interfaces:**
- Consumes: Task 7 CLI, `gitops/image-sources.yaml`
- Produces: 필수 검사 컨텍스트 `tag-pr-guard`(GitHub Actions 앱), repo 설정 `allow_auto_merge = true`

- [ ] **Step 1: 워크플로** — `on: pull_request: branches: [main]`(경로 필터 없음 — 모든 PR에서 돌아야 필수 검사가 충족됨). permissions `contents: read, pull-requests: write`. checkout `ref: ${{ github.event.pull_request.base.sha }}`(**PR 코드가 아니라 base**), uv 설치, `tag-pr-guard --repo "$REPO" --pr "$PR" --author "$AUTHOR" --report report.md`(값은 `env:`로), 실패 시 `gh pr comment "$PR" --body-file report.md` 후 exit 1
- [ ] **Step 2: 주입 방지 검사** — `grep -nE '\$\{\{ *github\.event\.pull_request\.(title|body|head\.ref)' .github/workflows/*.yaml` → 결과 없음, actionlint PASS
- [ ] **Step 3: 커밋 → 사용자 PR·병합** (ruleset 전에 워크플로가 main에 있어야 필수 검사가 존재함)
- [ ] **Step 4: Terraform github** — provider `integrations/github` 고정, owner `June21621`, 토큰은 `GITHUB_TOKEN` 환경 변수. `import` 블록으로 기존 `homelab` repo → `github_repository.homelab`(visibility `public`, `allow_auto_merge = true`, `delete_branch_on_merge = true`, `lifecycle { prevent_destroy = true }`, 나머지 속성은 import 후 plan에서 변경 0이 되도록 맞춤). `github_repository_ruleset.main`: target `~DEFAULT_BRANCH`, rules `deletion`, `non_fast_forward`, `pull_request`(승인 0), `required_status_checks`(context `tag-pr-guard`), bypass 없음
- [ ] **Step 5: 사용자 작업** — fine-grained PAT(90일, homelab·portfolio, Administration RW) → Bitwarden → `make github-apply`(plan을 먼저 보여 주고, repo 속성 변경이 의도한 두 개뿐인지 사용자와 확인 후 apply)
- [ ] **Step 5b: bump job에 자동 병합 예약 추가** — PR 생성 직후 App 토큰으로 `gh pr merge --auto --squash "$PR_URL"`(검사 워크플로는 읽기·코멘트 권한만 유지) → actionlint → 커밋 → 사용자 PR·병합
- [ ] **Step 6: 종단 확인** — portfolio에 push → bump PR → `tag-pr-guard` 성공 → 자동 병합 → 새 파드. push부터 새 파드까지 시간 기록
- [ ] **Step 7: 거부 검증(각각 PR을 만들어 확인, 병합 안 됨을 기록)**
  - App 토큰으로 newTag + 다른 줄을 바꾼 PR → 검사 실패, 코멘트, 병합 버튼 막힘
  - App 토큰으로 `scripts/tag_pr_guard/` 수정 PR → base의 스크립트가 거부
  - App 토큰으로 `.github/workflows/` 수정 push → GitHub가 push 자체를 거부(Workflows 권한 없음)
  - main 직접 push → ruleset이 거부
  - 사람 PR → 검사 즉시 성공, 사람이 병합 가능
  - App 토큰 PR을 만드는 방법: 사용자가 portfolio repo에 수동 실행용 임시 워크플로를 두거나, App 개인키로 로컬에서 토큰 발급(키는 화면에 띄우지 않음) — 방법은 실행 시 사용자와 정함
- [ ] **Step 8: 검증 기록 작성**(재현 방법·기대·실제·걸린 시간) → 커밋 → PR

---

### Task 9: 5-6 문서

**Files:**
- Create: `docs/adr/0005-ci-github-actions.md`, `0006-pull-based-deploy.md`, `0007-gitops-location-and-tag-path.md`, `0008-ksops-cluster-age-key.md`, `0009-argocd-self-management.md`
- Modify: `docs/adr/README.md` (목록)
- 제안만: `CLAUDE.md`, `docs/runbook.md` 변경안 → 승인 후 반영

- [ ] **Step 1: ADR 5개** — 기존 ADR 형식(맥락·결정·대안·결과). 0007에 "PR 브랜치 스크립트 실행 금지" 이유, 0008에 키 노출 시 절차(키 교체 + gitops 재암호화 + 실제 값 재발급), 0009에 비상 복구 `terraform apply -replace=helm_release.argocd`(원인이 Git이면 revert 먼저)
- [ ] **Step 2: runbook 변경안** — public 전환, 클러스터 age 키 생성·백업, `make argocd-bootstrap`, UI 접속·초기 비밀번호, GitHub App 생성, GHCR public, PAT 갱신(90일), 키 노출 대응
- [ ] **Step 3: CLAUDE.md 변경안** — 5단계 ✅ 결과(메모리 실측, 배포 시간), 미정 사항에서 첫 서비스·GitHub App(태그용) 제거, 아키텍처 표의 GitHub 무료+public 제약
- [ ] **Step 4: 사용자 승인 → 반영 → 커밋 → PR**. 9단계 검증 목록에 "ArgoCD 자기 업그레이드 실패 → 비상 재설치", "selfHeal로 kubectl 직접 변경 되돌림" 추가 제안
