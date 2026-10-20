# 검증: etcd S3 스냅샷 복원 리허설

- 날짜: 2026-10-20
- 대상: 미니 PC `homelab`, k3s v1.36.5+k3s1 (단일 노드, embedded etcd)
- 관련 코드: `ansible/etcd-restore.yml`, `make etcd-restore SNAPSHOT=<이름>`

## 목적

"백업이 있다"가 아니라 "백업으로 되살릴 수 있다"를 확인한다. 복원은 로컬 파일이 아니라 **S3 사본**으로 한다
(미니 PC 디스크를 잃어도 복구되는지까지 확인).

## 재현 방법

1. 기준 데이터: `kubectl create configmap drill-marker -n default ...` (2026-10-18 15:29:02)
2. 수동 스냅샷: 미니 PC에서 `sudo k3s etcd-snapshot save --name drill`
   → `drill-homelab-1792474798` (2026-10-20 14:39:58), 로컬·S3 모두 READY
   (`kubectl get etcdsnapshotfiles`로 확인. 관리 PC는 백업 버킷 권한이 없어 S3를 직접 보지 않는다)
3. 스냅샷 이후 데이터: `drill-after` (1차) / `drill-after2` (2차)
4. 관리 PC: `time make etcd-restore SNAPSHOT=drill-homelab-1792474798` → `yes`
5. 확인: `drill-marker` 존재, `drill-after*` 없음, `make verify-k3s`

## 기대 동작

- k3s 중지 → S3에서 스냅샷을 받아 `--cluster-reset` → k3s 시작 → 노드 Ready
- 스냅샷 이전 객체는 남고, 이후 객체는 사라진다
- 실행 중인 컨테이너는 유지된다 (`KillMode=process`)

## 실제 결과

| | 1차 (15:36) | 2차 (15:45) |
|---|---|---|
| 데이터 | `drill-marker` 있음, `drill-after` 없음 ✅ | `drill-marker` 있음, `drill-after2` 없음 ✅ |
| 플레이북 | ❌ `failed=1` (대기 태스크 버그, 아래) | ✅ `failed=0` |
| `verify-k3s` | — | 전부 통과 (LAN은 무선 격리로 건너뜀) |
| 파드 재시작 | 0 | 0 |

### 1차에서 발견한 버그

"노드 Ready 대기" 태스크가 `command` 모듈로
`jsonpath={.status.conditions[?(@.type=="Ready")].status}`를 실행했는데, `command` 모듈이 따옴표를 벗겨
`@.type==Ready`가 되어 kubectl이 `unrecognized identifier Ready` 오류를 냈다. **복원 자체는 성공했지만
플레이북은 5분 재시도 후 실패**로 끝났다. 실제 장애 때였다면 "복원 실패"로 오판했을 것이다.

수정: 따옴표가 필요 없는 `kubectl wait --for=condition=Ready node/<노드> --timeout=10s`를 `argv`로 실행하고,
API가 아직 안 떠 있을 때를 위해 `until: rc == 0`으로 재시도. 2차에서 `failed=0` 확인.

## 감지·복구 시간 (systemd journal 기준)

| | k3s 중지 | 복원 완료·시작 | 시작 완료 | API 중단 |
|---|---|---|---|---|
| 1차 | 15:36:48 | 15:36:55 | 15:37:05 | 약 17초 |
| 2차 | 15:45:32 | 15:45:40 | 15:45:45 | 약 14초 |

- S3 내려받기 + etcd 재설정: 7~8초 (스냅샷 11MB)
- 2차 `time` 결과(`real 0m19.975s`)는 sudo 비밀번호·`yes` 입력 시간까지 포함한 명령 전체 시간이다

## 남은 한계와 후속

- `kubectl wait`은 etcd에서 복원된 노드 상태가 이미 Ready면 kubelet 보고 전에도 통과할 수 있다.
  플레이북 성공만 믿지 말고 `make verify-k3s`로 파드·DNS까지 확인한다
- 이번 리허설은 **같은 호스트** 복원이다. 새로 설치한 호스트 복원(토큰 고정의 효과)은 6단계 "클러스터 삭제 후 재구축"에서 검증한다
- 정기 스냅샷 S3 업로드 실패는 지금 k3s 로그에만 남는다 → 3단계 모니터링에서 "마지막 S3 스냅샷이 N시간 넘게 없음" 알림 추가
