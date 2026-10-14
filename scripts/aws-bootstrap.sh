#!/usr/bin/env bash
# 3단계: Terraform state·백업용 S3 버킷과 미니 PC 백업용 IAM 사용자를 만든다.
# Terraform이 자기 state 버킷을 만들 수 없으므로(닭과 달걀) 이 부분만 스크립트로 둔다.
#
# 실행 위치: AWS CloudShell (서울 리전, Identity Center AdministratorAccess로 로그인한 콘솔)
#   bash aws-bootstrap.sh check   # 현재 상태만 출력 (아무것도 바꾸지 않음)
#   bash aws-bootstrap.sh apply   # 없는 것은 만들고 설정은 아래 값으로 맞춤 (여러 번 실행해도 안전)
#
# 하지 않는 것 (콘솔에서 직접, docs/runbook.md 참고):
#   - 액세스 키 생성: 비밀값이 터미널 기록에 남지 않게 콘솔에서 만들어 바로 Bitwarden에 저장
#   - Identity Center 권한 세트 homelab-tfstate: 마지막에 출력하는 정책 JSON을 콘솔에 붙여넣기
set -euo pipefail

REGION="ap-northeast-2"
PREFIX="june21621-homelab"
TFSTATE_BUCKET="${PREFIX}-tfstate"
BACKUP_BUCKET="${PREFIX}-k3s-backup"
BACKUP_USER="homelab-k3s-backup"

export AWS_REGION="${REGION}" AWS_PAGER=""

log() { printf '\n==> %s\n' "$*"; }

# --- 정책 문서 -------------------------------------------------------------

# HTTPS가 아닌 접근은 전부 거부
bucket_policy() {
  local bucket="$1"
  cat <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "DenyInsecureTransport",
      "Effect": "Deny",
      "Principal": "*",
      "Action": "s3:*",
      "Resource": ["arn:aws:s3:::${bucket}", "arn:aws:s3:::${bucket}/*"],
      "Condition": {"Bool": {"aws:SecureTransport": "false"}}
    }
  ]
}
JSON
}

# 이전 버전은 N일 뒤 삭제, 덜 올라간 업로드 조각은 7일 뒤 삭제, 남은 삭제 표시 정리
lifecycle() {
  local noncurrent_days="$1"
  cat <<JSON
{
  "Rules": [
    {
      "ID": "expire-noncurrent-versions",
      "Status": "Enabled",
      "Filter": {},
      "NoncurrentVersionExpiration": {"NoncurrentDays": ${noncurrent_days}},
      "AbortIncompleteMultipartUpload": {"DaysAfterInitiation": 7}
    },
    {
      "ID": "remove-expired-delete-markers",
      "Status": "Enabled",
      "Filter": {},
      "Expiration": {"ExpiredObjectDeleteMarker": true}
    }
  ]
}
JSON
}

# 버킷 하나에 대한 읽기·쓰기·삭제만 (k3s etcd 스냅샷과 restic이 오래된 백업을 정리하므로 삭제 필요)
bucket_rw_policy() {
  local bucket="$1"
  cat <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ListBucket",
      "Effect": "Allow",
      "Action": ["s3:ListBucket", "s3:GetBucketLocation"],
      "Resource": "arn:aws:s3:::${bucket}"
    },
    {
      "Sid": "ObjectReadWriteDelete",
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"],
      "Resource": "arn:aws:s3:::${bucket}/*"
    }
  ]
}
JSON
}

# --- 상태 확인 --------------------------------------------------------------

bucket_exists() { aws s3api head-bucket --bucket "$1" >/dev/null 2>&1; }
user_exists() { aws iam get-user --user-name "$1" >/dev/null 2>&1; }

show_bucket() {
  local bucket="$1"
  if ! bucket_exists "${bucket}"; then
    echo "  ${bucket}: 없음 (apply 시 생성)"
    return
  fi
  echo "  ${bucket}: 있음"
  printf '    버전 관리: %s\n' "$(aws s3api get-bucket-versioning --bucket "${bucket}" --query Status --output text)"
  printf '    퍼블릭 차단: %s\n' "$(aws s3api get-public-access-block --bucket "${bucket}" \
    --query 'PublicAccessBlockConfiguration.[BlockPublicAcls,IgnorePublicAcls,BlockPublicPolicy,RestrictPublicBuckets]' \
    --output text 2>/dev/null || echo '설정 없음')"
  printf '    암호화: %s\n' "$(aws s3api get-bucket-encryption --bucket "${bucket}" \
    --query 'ServerSideEncryptionConfiguration.Rules[0].ApplyServerSideEncryptionByDefault.SSEAlgorithm' \
    --output text 2>/dev/null || echo '설정 없음')"
  printf '    수명 주기 규칙 수: %s\n' "$(aws s3api get-bucket-lifecycle-configuration --bucket "${bucket}" \
    --query 'length(Rules)' --output text 2>/dev/null || echo 0)"
  printf '    버킷 정책: %s\n' "$(aws s3api get-bucket-policy --bucket "${bucket}" >/dev/null 2>&1 && echo 있음 || echo 없음)"
}

check() {
  log "계정: $(aws sts get-caller-identity --query Arn --output text)"
  log "S3 버킷 (${REGION})"
  show_bucket "${TFSTATE_BUCKET}"
  show_bucket "${BACKUP_BUCKET}"
  log "IAM 사용자"
  if user_exists "${BACKUP_USER}"; then
    echo "  ${BACKUP_USER}: 있음"
    printf '    인라인 정책: %s\n' "$(aws iam list-user-policies --user-name "${BACKUP_USER}" --query PolicyNames --output text)"
    printf '    액세스 키 수: %s\n' "$(aws iam list-access-keys --user-name "${BACKUP_USER}" --query 'length(AccessKeyMetadata)' --output text)"
    printf '    콘솔 로그인: %s\n' "$(aws iam get-login-profile --user-name "${BACKUP_USER}" >/dev/null 2>&1 && echo '있음(!)' || echo '없음')"
  else
    echo "  ${BACKUP_USER}: 없음 (apply 시 생성)"
  fi
}

# --- 적용 -------------------------------------------------------------------

ensure_bucket() {
  local bucket="$1" noncurrent_days="$2"
  log "버킷 ${bucket}"
  if bucket_exists "${bucket}"; then
    echo "  이미 있음"
  else
    aws s3api create-bucket --bucket "${bucket}" \
      --create-bucket-configuration "LocationConstraint=${REGION}" >/dev/null
    aws s3api wait bucket-exists --bucket "${bucket}"
    echo "  생성함"
  fi

  aws s3api put-public-access-block --bucket "${bucket}" --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
  aws s3api put-bucket-ownership-controls --bucket "${bucket}" \
    --ownership-controls 'Rules=[{ObjectOwnership=BucketOwnerEnforced}]'
  aws s3api put-bucket-encryption --bucket "${bucket}" --server-side-encryption-configuration \
    '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"},"BucketKeyEnabled":true}]}'
  aws s3api put-bucket-versioning --bucket "${bucket}" --versioning-configuration Status=Enabled
  aws s3api put-bucket-policy --bucket "${bucket}" --policy "$(bucket_policy "${bucket}")"
  aws s3api put-bucket-lifecycle-configuration --bucket "${bucket}" \
    --lifecycle-configuration "$(lifecycle "${noncurrent_days}")" >/dev/null
  aws s3api put-bucket-tagging --bucket "${bucket}" --tagging 'TagSet=[{Key=project,Value=homelab}]'
  echo "  설정 적용: 퍼블릭 차단, 소유권 강제, SSE-S3, 버전 관리, HTTPS 강제, 이전 버전 ${noncurrent_days}일 보관"
}

ensure_backup_user() {
  log "IAM 사용자 ${BACKUP_USER}"
  if user_exists "${BACKUP_USER}"; then
    echo "  이미 있음"
  else
    aws iam create-user --user-name "${BACKUP_USER}" \
      --tags Key=project,Value=homelab Key=purpose,Value=mini-pc-backup >/dev/null
    echo "  생성함 (콘솔 로그인 없음, 액세스 키 없음)"
  fi
  aws iam put-user-policy --user-name "${BACKUP_USER}" \
    --policy-name "${BACKUP_BUCKET}-rw" --policy-document "$(bucket_rw_policy "${BACKUP_BUCKET}")"
  echo "  인라인 정책 ${BACKUP_BUCKET}-rw 적용 (이 버킷만 읽기·쓰기·삭제)"
}

apply() {
  local identity
  identity="$(aws sts get-caller-identity --query Arn --output text)"
  log "계정: ${identity}"
  case "${identity}" in
    *:root) echo "root로 실행하지 마세요. Identity Center(AdministratorAccess)로 로그인한 CloudShell에서 실행" >&2; exit 1 ;;
  esac

  ensure_bucket "${TFSTATE_BUCKET}" 90
  ensure_bucket "${BACKUP_BUCKET}" 30
  ensure_backup_user

  log "다음 단계 (콘솔에서 직접)"
  echo "  1) IAM → 사용자 → ${BACKUP_USER} → 보안 자격 증명 → 액세스 키 만들기 → 바로 Bitwarden에 저장"
  echo "  2) IAM Identity Center → 권한 세트 → 사용자 지정 권한 세트 'homelab-tfstate' → 인라인 정책에 아래 JSON"
  echo
  bucket_rw_policy "${TFSTATE_BUCKET}"
}

case "${1:-}" in
  check) check ;;
  apply) apply ;;
  *) echo "사용법: bash $0 check|apply" >&2; exit 2 ;;
esac
