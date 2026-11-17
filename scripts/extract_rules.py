# /// script
# requires-python = ">=3.12"
# dependencies = ["pyyaml==6.0.3"]
# ///
"""PrometheusRule 매니페스트에서 spec(규칙 그룹)만 꺼내 promtool이 읽는 규칙 파일로 저장한다.

사용: extract_rules.py <규칙 폴더> <출력 폴더>
  <규칙 폴더>/*.yaml 의 kind: PrometheusRule 문서마다 <출력 폴더>/<metadata.name>.yaml
  알림 규칙은 severity 라벨이 warning·critical 중 하나여야 한다(라우팅이 이 라벨로 갈린다, 6단계 §3.7)
  <규칙 폴더>/tests/*_test.yaml의 rule_files가 가리키는 규칙이 있어야 한다
문제가 있으면 목록을 출력하고 1.
"""

import sys
from pathlib import Path

import yaml

SEVERITIES = {"warning", "critical"}


def extract(src: Path, dst_dir: Path) -> tuple[list[Path], list[str]]:
    written, errors = [], []
    for f in sorted(src.glob("*.yaml")):
        for doc in yaml.safe_load_all(f.read_text(encoding="utf-8")):
            if not doc or doc.get("kind") != "PrometheusRule":
                continue
            name = doc["metadata"]["name"]
            groups = (doc.get("spec") or {}).get("groups") or []
            for g in groups:
                for r in g.get("rules") or []:
                    if "alert" in r and (r.get("labels") or {}).get("severity") not in SEVERITIES:
                        errors.append(f"{f.name}: {r['alert']}: severity 라벨은 warning·critical 중 하나")
            out = dst_dir / f"{name}.yaml"
            out.write_text(yaml.safe_dump({"groups": groups}, allow_unicode=True), encoding="utf-8")
            written.append(out)
    return written, errors


def check_test_refs(src: Path, written: list[Path]) -> list[str]:
    """promtool은 rule_files가 없으면 경고만 하고 테스트를 통과시킨다. 가리키는 규칙이 있는지 직접 본다"""
    names = {p.name for p in written}
    errors = []
    for t in sorted((src / "tests").glob("*_test.yaml")):
        for ref in (yaml.safe_load(t.read_text(encoding="utf-8")) or {}).get("rule_files") or []:
            if ref not in names:
                errors.append(f"tests/{t.name}: rule_files의 {ref}에 해당하는 PrometheusRule(metadata.name)이 없음")
    return errors


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        print("사용: extract_rules.py <규칙 폴더> <출력 폴더>", file=sys.stderr)
        return 2
    src = Path(argv[1])
    written, errors = extract(src, Path(argv[2]))
    errors += check_test_refs(src, written)
    for e in errors:
        print(e)
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
