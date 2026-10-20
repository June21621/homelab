# 0004. 관리 접근의 포트 제한은 ufw가 아니라 Tailscale ACL로

- 상태: 채택 (2026-10-18)

## 맥락

1단계(하드닝)에서 ufw로 "기본 차단 + LAN·Tailscale에서 SSH만 허용"을 설정했고, k3s 설치 때 "6443은 tailscale0에서만"
규칙을 더했다. 그런데 설치 확인 스크립트(`scripts/verify-k3s.sh`)가 Tailscale 주소의 **10250(kubelet)과
Traefik NodePort가 열려 있음**을 잡아냈다.

미니 PC의 iptables를 확인한 결과:

```
-A INPUT ... (kube-router, kube-proxy 규칙)
-A INPUT -j ts-input              ← Tailscale 체인이 ufw보다 먼저
-A INPUT -j ufw-before-input ...
-A ts-input -i tailscale0 -j ACCEPT   ← tailscale0로 들어온 건 전부 허용
```

Tailscale은 접근 제어를 자기 ACL로 한다는 전제로 tailscale0 트래픽을 ufw보다 먼저 받아들인다.
즉 **2단계(Tailscale 설치) 이후 ufw의 tailscale0 규칙은 효과가 없었다.** LAN 쪽은 ufw가 막을 것으로 **예상**하지만,
관리 PC가 무선 격리로 LAN에 닿지 않아 아직 바깥에서 확인하지 못했다(유선 기기에서 `make verify-k3s`로 확인 예정).
또 NodePort·hostPort는 PREROUTING DNAT로 ufw(INPUT)를 거치지 않으므로, 클러스터에 그런 노출이 없다는 것을
`verify-k3s`의 "호스트 포트 노출 없음" 검사로 따로 확인한다.

## 결정

Tailscale 쪽 포트 제한은 **Tailscale ACL(grants)**로 한다.

- `autogroup:member` → `tag:server`: `tcp:22`, `tcp:6443`, `icmp:*`만
- `autogroup:member` → `autogroup:self`: 전부 (같은 사람의 기기끼리)
- 기본 "모든 기기 → 모든 기기" 규칙 삭제

지금은 관리 콘솔에서 수동으로 적용했고(runbook 기록), 4단계에서 Terraform으로 옮기면서 `tests`(허용·차단 자동 검사)를 넣는다.
ufw의 tailscale0 규칙은 Tailscale을 netfilter 끔 모드로 바꿀 때를 대비한 이중 장치로 남겨 둔다.

## 검토한 대안

| 대안 | 장점 | 버린 이유 |
|---|---|---|
| Tailscale `netfilter-mode`를 바꿔 ufw가 다루게 함 | 방화벽이 ufw 하나로 통일 | Tailscale 기본 동작과 싸우는 구성이라 업데이트 때 깨지기 쉬움. 직접 연결용 규칙을 손으로 맞춰야 함 |
| 그대로 두고 기록만 | 작업 없음 | tailnet 기기 하나만 털려도 미니 PC의 모든 포트(kubelet, 앞으로의 서비스 포트)에 닿음 |

## 결과

- 확인 결과(2026-10-18): Tailscale 경유 22·6443·ping 허용, 10250·31494·31889 차단. 기존 SSH 세션 유지
- 접근 제어가 **두 곳**에 나뉜다: LAN은 ufw, Tailscale은 ACL. 규칙을 바꿀 때 둘 다 봐야 한다
- 미니 PC(`tag:server`)가 먼저 사람 기기로 연결하는 것은 막힌다. 그런 경로가 필요해지면 ACL에 명시한다
- 교훈: 방화벽 규칙은 "넣었다"가 아니라 **바깥에서 실제로 접속해 봐야** 검증된다. 확인 스크립트에 Tailscale 경유
  포트 검사를 상시로 넣었다
