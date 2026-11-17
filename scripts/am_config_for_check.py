# /// script
# requires-python = ">=3.12"
# dependencies = ["pyyaml==6.0.3"]
# ///
"""helm template 결과(표준 입력)에서 Alertmanager 설정을 꺼내 amtool check-config용 사본을 만든다.

사용: helm template ... | am_config_for_check.py <출력 폴더>
  <출력 폴더>/alertmanager.yaml 을 쓴다. 설정 안의 *_file 경로(클러스터의 Secret 마운트 위치)는
  <출력 폴더>/secrets/<파일 이름>(빈 파일)로 바꾼다. 실제 비밀값은 다루지 않는다.
설정이 없으면 1.
"""

import base64
import sys
from pathlib import Path

import yaml

FILE_KEYS = ("webhook_url_file", "url_file")


def rewrite_files(node, secrets: Path):
    if isinstance(node, dict):
        for k, v in node.items():
            if k in FILE_KEYS and isinstance(v, str):
                target = secrets / Path(v).name
                target.touch()
                node[k] = str(target)
            else:
                rewrite_files(v, secrets)
    elif isinstance(node, list):
        for v in node:
            rewrite_files(v, secrets)


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print("사용: am_config_for_check.py <출력 폴더>", file=sys.stderr)
        return 2
    out = Path(argv[1])
    secrets = out / "secrets"
    secrets.mkdir(parents=True, exist_ok=True)
    for doc in yaml.safe_load_all(sys.stdin):
        if doc and doc.get("kind") == "Secret" and "alertmanager.yaml" in (doc.get("data") or {}):
            cfg = yaml.safe_load(base64.b64decode(doc["data"]["alertmanager.yaml"]))
            rewrite_files(cfg, secrets)
            cfg.pop("templates", None)  # 클러스터 안 경로(/etc/alertmanager/config)라 여기선 없음
            (out / "alertmanager.yaml").write_text(yaml.safe_dump(cfg), encoding="utf-8")
            return 0
    print("alertmanager.yaml을 담은 Secret이 없음")
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
