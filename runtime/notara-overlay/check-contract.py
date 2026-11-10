#!/usr/bin/env python3
"""宿主与网页的接口契约自检。

两件事必须同时成立,否则构建直接失败:

1. Flutter 里每一个 `__NOTARA_DIRECT__.<name>` 调用,`direct-api.js` 都要真的
   导出 `<name>`,而且打包产物 `client.js` 里也要能找到这个属性名。
2. 网页 `postMessage` 的消息 type,Flutter 侧都要有分支处理。

为什么要做成门禁:上一版顶栏四键调 `openHeaderAction`,而 direct-api 只导出了
`openHistory / openTeaching / openSummary`。点击之后 `undefined` 被三元表达式
吞掉,静默失败,界面上只弹一句"面板未登记"——没有任何报错指向真正的原因。
2MB 的压缩产物里,人眼不可能靠读代码发现这种错位。

esbuild 会 mangle 局部变量名,但**不会**改对象字面量的属性名,所以属性名可以
直接当作存在性证据。
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DART_DIR = ROOT / "app/lib/ui/teaching"
API_JS = ROOT / "runtime/notara-overlay/plugin/direct-api.js"
BUNDLE_JS = ROOT / "runtime/notara-overlay/plugin/client.js"
SOURCE_TS = ROOT / "runtime/notara-overlay/plugin/client-source.ts"

# `window.__NOTARA_DIRECT__ ? window.__NOTARA_DIRECT__.openLessonView(...)`
CALL = re.compile(r"__NOTARA_DIRECT__\.([A-Za-z_$][\w$]*)\s*\(")
# direct-api.js 里 `const api = { ... }` 的方法声明
API_METHOD = re.compile(r"^    (?:async\s+)?([A-Za-z_$][\w$]*)\s*\(", re.MULTILINE)
# client-source.ts 里 postMessage 的 type。必须限定在 postMessage 调用内部,
# 否则会把无关的 `type: 'number'` 之类的普通字段也算成消息类型。
POST_TYPE = re.compile(r"postMessage\([^;]{0,160}?type:\s*'([a-zA-Z]+)'")
# Flutter 侧 _onBridgeMessage 里比较的 type
DART_TYPE = re.compile(r"data\['type'\]\s*==\s*'([a-zA-Z]+)'")


def called_from_dart() -> dict[str, list[str]]:
    """宿主调了哪些方法,各自出现在哪些文件里。"""
    found: dict[str, list[str]] = {}
    for path in sorted(DART_DIR.glob("*.dart")):
        text = path.read_text(encoding="utf-8")
        for name in CALL.findall(text):
            found.setdefault(name, []).append(path.name)
    return found


def exported_by_source() -> set[str]:
    """direct-api.js 的返回对象里声明了哪些方法。"""
    text = API_JS.read_text(encoding="utf-8")
    start = text.index("const api = {")
    end = text.index("\n  };", start)
    return set(API_METHOD.findall(text[start:end]))


def present_in_bundle(names: set[str]) -> set[str]:
    """产物里哪些属性名真的存在。"""
    text = BUNDLE_JS.read_text(encoding="utf-8")
    return {name for name in names if re.search(re.escape(name) + r"\s*[(:]", text)}


def check_contract() -> list[str]:
    problems: list[str] = []
    called = called_from_dart()
    exported = exported_by_source()
    bundled = present_in_bundle(set(called))

    for name, where in sorted(called.items()):
        files = ", ".join(sorted(set(where)))
        if name not in exported:
            problems.append(
                "Flutter 调用了 __NOTARA_DIRECT__.%s(%s),但 direct-api.js 没有导出它"
                % (name, files)
            )
        elif name not in bundled:
            problems.append(
                "direct-api.js 声明了 %s,但打包产物 client.js 里找不到——产物没有重新构建"
                % name
            )

    for name in sorted(exported - set(called)):
        print("note: 导出但宿主暂未使用: %s" % name)
    print("contract: %d called, %d exported, %d present in bundle"
          % (len(called), len(exported), len(bundled)))
    return problems


def check_messages() -> list[str]:
    problems: list[str] = []
    sent = set(POST_TYPE.findall(SOURCE_TS.read_text(encoding="utf-8")))
    handled: set[str] = set()
    for path in sorted(DART_DIR.glob("*.dart")):
        handled |= set(DART_TYPE.findall(path.read_text(encoding="utf-8")))
    # 只有网页主动发给宿主的消息需要宿主处理;`view` 回执走另一条分支。
    for name in sorted(sent - handled):
        problems.append("网页会 postMessage type='%s',但 Flutter 的 _onBridgeMessage 没有这个分支" % name)
    print("messages: sent %s / handled %s" % (sorted(sent), sorted(handled)))
    return problems


def main() -> None:
    problems = check_contract() + check_messages()
    if problems:
        print("\n接口契约不通过:", file=sys.stderr)
        for line in problems:
            print("  - " + line, file=sys.stderr)
        sys.exit(1)
    print("contract ok")


if __name__ == "__main__":
    main()
