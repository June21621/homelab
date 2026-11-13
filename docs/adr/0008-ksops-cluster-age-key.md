# 0008. 클러스터 시크릿은 KSOPS + 클러스터 전용 age 키

- 상태: 채택 (2026-11-02)

## 맥락

시크릿 형식은 SOPS + age로 정했다(ADR 0003). 지금까지는 관리 PC의 관리자 키 하나로 호스트 시크릿(k3s 토큰, S3 백업 키)을
풀었다. 이제 ArgoCD가 클러스터 안에서 `gitops/`의 암호화된 Secret을 풀어야 한다.

같은 관리자 키를 클러스터에 넣으면, 클러스터가 털렸을 때 `ansible/`의 호스트 시크릿(AWS 백업 키 등)까지 풀린다.

## 결정

- ArgoCD repo-server에 **KSOPS**(Kustomize exec 플러그인)를 붙인다. init 컨테이너가 ksops 바이너리를 공유 볼륨에 복사하고,
  `kustomize.buildOptions: --enable-alpha-plugins --enable-exec`로 플러그인을 허용한다. Kustomize는 ArgoCD 내장 버전을 그대로 쓴다
- **클러스터 전용 age 키**를 따로 만든다(관리 PC `age-keygen`, 원본 Bitwarden). Terraform `argocd-bootstrap`이 그 파일을 읽어
  `argocd/sops-age` Secret으로 넣고, repo-server가 `SOPS_AGE_KEY_FILE`로 읽는다
- `.sops.yaml` 규칙(위에서부터 처음 맞는 것 하나):
  - `gitops/` 아래 `*.sops.yaml`: **관리자 키 + 클러스터 키** 두 수신자, `data`·`stringData`만 암호화(`encrypted_regex`)
  - 그 밖(`ansible/` 등): **관리자 키만**
- KSOPS 설치와 그것을 쓰는 앱은 **다른 PR로** 넣는다(아래 경쟁 상태)

## 검토한 대안

| 대안 | 장점 | 버린 이유 |
|---|---|---|
| 관리자 키를 클러스터에도 | 키 하나로 단순 | 클러스터가 털리면 호스트 시크릿까지 풀림 |
| helm-secrets 플러그인 | Helm 값 파일 암호화에 익숙한 방식 | 직접 만든 앱은 Kustomize(Helm 아님). 두 방식을 섞게 됨 |
| ArgoCD CMP(Config Management Plugin) 사이드카 | ArgoCD가 권장하는 확장 방식 | 사이드카 컨테이너가 상주(메모리). Kustomize 앱 하나에 쓰기엔 무거움 |
| Sealed Secrets / ESO | ADR 0003에서 비교 | 버린 이유는 0003과 같음 |

## 결과

- 클러스터에서 풀 수 있는 건 `gitops/` 시크릿뿐이다. 클러스터 키만으로 관리자 전용 파일을 풀면 실패(exit 128)하는 것을 확인했다
- 클러스터 age 개인키가 **Terraform state(S3)에도 들어간다.** 버킷이 SSE-S3·버전 관리·퍼블릭 차단이고 접근이 SSO 1시간 세션이라 수용했다
- 증명된 함정 두 가지:
  - **SOPS 기본 키 경로**: SOPS는 `SOPS_AGE_KEY_FILE` 외에 `~/.config/sops/age/keys.txt`도 함께 읽는다. 관리 PC에서 "클러스터 키만으로
    풀리는가"를 시험하면 관리자 키 덕분에 거짓으로 통과한다. `XDG_CONFIG_HOME`을 빈 폴더로 돌려 격리해야 제대로 실패한다
  - **경쟁 상태**: KSOPS 설치 PR과 시크릿 앱을 한 번에 넣었더니, ArgoCD가 설정(`argocd-cm`) 갱신 전에 앱을 먼저 렌더링해
    "external plugins disabled"로 한 번 실패했다. 다음 재조정(약 4분 뒤)에 성공했지만, 도구와 사용처는 PR을 나눈다
- **키 노출 시 절차**
  1. 새 클러스터 키 생성 → `.sops.yaml` 수신자 교체 → `sops updatekeys`로 `gitops/` 시크릿 재암호화(`sops rotate`로 데이터 키도 교체)
  2. Terraform으로 `argocd/sops-age` Secret 교체
  3. **실제 값을 재발급한다.** 옛 암호문은 Git 히스토리에 남으므로 재암호화만으로는 부족하다(관리자 키 노출 때 교체한 전례: 2026-10-18)
