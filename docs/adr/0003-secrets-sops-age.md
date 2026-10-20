# 0003. 시크릿 관리는 SOPS + age

- 상태: 채택 (2026-10-18)

## 맥락

목표는 "OS 설치 + seed 절차 이후 명령 하나로 재구축"이고, Git이 유일한 변경 경로다. 그런데 k3s 토큰, etcd 백업용
AWS 키, 앞으로의 Discord 웹훅·Cloudflare 토큰 같은 비밀값도 재구축에 필요하다. 평문으로 커밋할 수는 없고,
Git 밖에만 두면 재구축 때 손으로 채워야 한다.

비밀값이 필요한 시점은 두 곳이다.

1. **k3s가 뜨기 전**: Ansible이 호스트에 k3s 토큰·백업 키를 넣을 때
2. **k3s가 뜬 뒤**: ArgoCD가 클러스터 Secret을 만들 때

## 결정

- SOPS + age로 **값만** 암호화해 Git에 커밋한다(`*.sops.yaml`). 공개키는 `.sops.yaml`에, 개인키는 관리 PC
  `~/.config/sops/age/keys.txt`와 Bitwarden에만 둔다
- 호스트: Ansible `community.sops` vars 플러그인이 관리 PC에서 복호화해 전달한다. **미니 PC에는 SOPS도 age 키도 두지 않는다**
- 클러스터: ArgoCD repo-server의 KSOPS 플러그인으로 복호화한다(2단계)
- pre-commit이 `*.sops.yaml`·`secrets/`의 평문 커밋을 막는다

## 검토한 대안

| 대안 | 장점 | 버린 이유 |
|---|---|---|
| HashiCorp Vault + External Secrets Operator | 동적 시크릿, 자동 교체, 접근 감사 로그 | 메모리 수백 MB(예산 압박), 재부팅마다 unseal 필요. 미니 PC가 Vault에 접속할 첫 비밀(secret zero)은 결국 필요 |
| Sealed Secrets | 쿠버네티스에서 널리 쓰임 | 쿠버네티스 전용이라 k3s 설치 전(Ansible)에 못 씀. 열쇠가 클러스터 안에 있어 클러스터를 지우면 따로 백업해야 함 |
| Ansible Vault | 추가 설치 없음 | Ansible 전용이라 ArgoCD에서 못 씀. 파일 통째 암호화라 변경 내역이 안 보임 |
| AWS Secrets Manager / Parameter Store + ESO | Git에 암호문도 안 남음 | 클러스터에 AWS 자격 증명이 또 필요(닭과 달걀), 인터넷 의존, Secrets Manager는 시크릿당 과금 |
| Git 밖에 두고 수동 입력 | 단순 | "명령 하나로 재구축"과 충돌 |

## 결과

- 도구 하나와 키 하나로 호스트·클러스터 시크릿을 모두 다룬다. 서버·비용이 없다
- **개인키가 단일 실패 지점**이다. 잃으면 모든 시크릿을 원본(Bitwarden 등)에서 다시 만들어야 하고,
  새면 repo의 모든 시크릿이 위험하다
  - 실제 사례(2026-10-18): 최초 키가 작업 중 대화 기록에 노출되어 `sops rotate`로 데이터 키까지 새로 만들고
    키를 교체했다. 커밋 전이라 비용이 작았다
- 미니 PC의 `/etc/rancher/k3s/config.yaml`에는 값이 **평문**으로 있다(root 600). k3s가 실행 중에 값을 써야 하므로
  피할 수 없다. 디스크 암호화는 무인 재부팅과 충돌해 하지 않았다
- 동적 시크릿·자동 교체·감사 로그가 필요한 규모(여러 팀, 컴플라이언스)가 되면 ESO를 앞에 두고 저장소만 Vault로
  바꾸는 이전 경로가 있다
