#!/usr/bin/env python3
"""提取指定 operationId 的 OpenAPI 定义，供实现 Agent 参考。"""

from __future__ import annotations

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SPEC_PATH = ROOT / "docs" / "openapi.json"

TARGETS = sys.argv[1:] if len(sys.argv) > 1 else []


def main() -> None:
    """输出目标 operation 的详细定义。"""
    with SPEC_PATH.open(encoding="utf-8") as fh:
        spec = json.load(fh)

    for path, methods in spec.get("paths", {}).items():
        for method, op in methods.items():
            opid = op.get("operationId", "")
            if TARGETS and opid not in TARGETS:
                continue
            print(f"### [{method.upper()}] {path}  ->  {opid}")
            print(f"summary: {op.get('summary', '')}")
            print(f"tags: {op.get('tags', [])}")
            for p in op.get("parameters", []):
                schema = p.get("schema", {})
                required = p.get("required", False)
                print(
                    f"  param: {p.get('name')} in={p.get('in')} "
                    f"type={schema.get('type', schema.get('$ref', '?'))} "
                    f"required={required} default={schema.get('default', '-')}"
                )
            if op.get("requestBody"):
                rb = op["requestBody"]
                content = rb.get("content", {})
                for ctype, cval in content.items():
                    sch = cval.get("schema", {})
                    ref = sch.get("$ref", sch.get("type", "?"))
                    print(f"  body: {ctype} -> {ref}")
            responses = op.get("responses", {})
            for code, resp in responses.items():
                content = resp.get("content", {})
                refs = []
                for cval in content.values():
                    sch = cval.get("schema", {})
                    refs.append(sch.get("$ref", sch.get("type", "?")))
                print(f"  resp: {code} -> {refs}")
            print()


if __name__ == "__main__":
    main()
