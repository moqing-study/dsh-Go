#!/usr/bin/env python3
"""把改过的 Notara 插件与教学预设覆盖进已缓存的 rootfs。

为什么要有这一步:rootfs 缓存键只看 runtime/ 的配方。只改插件前端(js/css)
不该让那 40 分钟的全量组装重跑一遍,但打出来的包又必须真的带上新文件——
否则"改了源码"和"没改"编出来是同一个 APK。

做法只有一条原则:**改完必须自证**。这个脚本在最后会重新解包自己刚写出的
归档,把关键标记逐个 grep 一遍,缺一个就非零退出,让构建红在打包前。

用法:
    python3 runtime/notara-overlay/apply.py \
        --rootfs runtime/out/arm64-v8a/assets/runtime/rootfs-arm64-v8a.tar.xz \
        --manifest runtime/out/arm64-v8a/assets/runtime/manifest.json
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
PLUGIN_SRC = os.path.join(HERE, "plugin")
PRESET_JSON = os.path.join(HERE, "preset.json")

# 插件在 rootfs 里的落点,与 rtbuild.py 的 EXTRA_PLUGIN_DIR 一致。
PLUGIN_DIR = "opt/dsh-go/plugins/notara-vault-native"
PATCH_PATH = "etc/dsh-app/dsh-web.patch.yml"
RUNTIME_JSON = "etc/dsh-app/runtime.json"

# 打完包必须能在归档里找到这些字面量。少一个就说明改动没进去。
MARKERS = [
    (PLUGIN_DIR + "/client.js", "__NOTARA_DIRECT__"),
    (PLUGIN_DIR + "/client.js", "openLessonView"),
    (PLUGIN_DIR + "/client.js", "data-nv-view"),
    # embedded.css 由 client-source.ts 作为文本内联进 client.js,所以断言打在它上面。
    (PLUGIN_DIR + "/client.js", "nv-class-views"),
    (PATCH_PATH, "preset-notara-teacher"),
    (PATCH_PATH, "agent-preset-registry"),
]

VERSION_SUFFIX = re.compile(r"-nv[0-9a-f]{8}$")


def run(argv: list[str]) -> None:
    print("+ " + " ".join(argv), flush=True)
    subprocess.run(argv, check=True)


def unpack(rootfs: str, dest: str) -> None:
    with tarfile.open(rootfs, "r:xz") as tar:
        tar.extractall(dest)


def overlay_plugin(dest: str) -> int:
    target = os.path.join(dest, PLUGIN_DIR)
    if not os.path.isdir(target):
        sys.exit("rootfs 里没有 %s:基础镜像不是 Notara 版,不能只做 overlay。" % PLUGIN_DIR)
    count = 0
    for name in sorted(os.listdir(PLUGIN_SRC)):
        src = os.path.join(PLUGIN_SRC, name)
        if not os.path.isfile(src):
            continue
        shutil.copyfile(src, os.path.join(target, name))
        count += 1
    return count


def preset_rows() -> str:
    """把预设写成 YAML。

    YAML 是 JSON 的超集,所以那段复杂的 config 直接内联成一行 JSON 就是合法
    的 YAML——不需要额外的 YAML 库,也不会被缩进规则咬到。
    """
    with open(PRESET_JSON, encoding="utf-8") as fh:
        preset = json.load(fh)
    # 插件是按绝对路径挂载的,不是 npm 包:子插件行也必须给路径,否则解析不到。
    for row in preset.get("plugins", []):
        if row.get("name") == "@notara/vault-native/teacher":
            row["name"] = "/%s/teacher.js" % PLUGIN_DIR
    config = json.dumps(preset, ensure_ascii=False, separators=(",", ":"))
    return (
        "\n# --- notara overlay: 教学预设与默认值(由 runtime/notara-overlay 覆盖进来)---\n"
        "- id: agent-preset-registry\n"
        "  config:\n"
        "    default: notara-teacher\n"
        "- insert:\n"
        "    - id: preset-notara-teacher\n"
        "      name: '@deepseek-ai/dsh-agent-preset'\n"
        "      config: %s\n" % config
    )


def patch_config(dest: str) -> None:
    path = os.path.join(dest, PATCH_PATH)
    with open(path, encoding="utf-8") as fh:
        text = fh.read()
    marker = "\n# --- notara overlay:"
    if marker in text:
        # 旧的一份 overlay 块:整段换掉,别让上一版的预设留在里面。
        text = text[: text.index(marker)]
        print("replacing the previous overlay block")
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(text.rstrip("\n") + "\n" + preset_rows())


def bump_version(dest: str, digest: str) -> tuple[str, str]:
    path = os.path.join(dest, RUNTIME_JSON)
    with open(path, encoding="utf-8") as fh:
        data = json.load(fh)
    base = VERSION_SUFFIX.sub("", str(data.get("runtimeVersion") or "runtime"))
    version = "%s-nv%s" % (base, digest[:8])
    data["runtimeVersion"] = version
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(data, fh, ensure_ascii=False, indent=2, sort_keys=True)
        fh.write("\n")
    return base, version


def overlay_digest(dest: str) -> str:
    """按"实际写进 rootfs 的那些文件"算一个稳定指纹。

    用它做版本后缀,重复跑同一次 overlay 会得到同一个版本号,不会每跑一次
    就升一版。
    """
    h = hashlib.sha256()
    for base in (os.path.join(dest, PLUGIN_DIR),):
        for name in sorted(os.listdir(base)):
            path = os.path.join(base, name)
            if not os.path.isfile(path):
                continue
            h.update(name.encode())
            with open(path, "rb") as fh:
                for chunk in iter(lambda: fh.read(1 << 20), b""):
                    h.update(chunk)
    with open(os.path.join(dest, PATCH_PATH), "rb") as fh:
        h.update(fh.read())
    return h.hexdigest()


def pack(dest: str, out: str, threads: int) -> None:
    """按原归档同样的规矩重打:GNU tar、名字相对、排序父子在前。"""
    entries: list[str] = []
    for base, dirs, files in os.walk(dest):
        dirs.sort()
        for name in sorted(dirs) + sorted(files):
            full = os.path.join(base, name)
            entries.append(os.path.relpath(full, dest))
    entries.sort(key=lambda p: (p.count(os.sep), p))
    run(["tar", "--sort=name", "--owner=0", "--group=0", "--numeric-owner",
         "-cf", out + ".tar", "-C", dest] + entries)
    run(["xz", "-T%d" % threads, "-6", "-f", out + ".tar"])
    os.replace(out + ".tar.xz", out)


def verify(rootfs: str) -> None:
    with tarfile.open(rootfs, "r:xz") as tar:
        names = set(tar.getnames())

        def read(path: str) -> str:
            member = tar.extractfile(path)
            return member.read().decode("utf-8", "replace") if member else ""

        missing = 0
        for path, needle in MARKERS:
            if path not in names:
                print("MISSING FILE: %s" % path)
                missing = 1
                continue
            if needle not in read(path):
                print("MISSING MARKER: %s in %s" % (needle, path))
                missing = 1
        if missing:
            sys.exit("overlay 自检失败:改动没有真的进归档")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--rootfs", required=True)
    parser.add_argument("--manifest", required=True)
    parser.add_argument("--threads", type=int, default=int(os.environ.get("XZ_THREADS", "4")))
    args = parser.parse_args()

    with tempfile.TemporaryDirectory(prefix="notara-overlay-") as work:
        print("unpacking %s" % args.rootfs, flush=True)
        unpack(args.rootfs, work)
        copied = overlay_plugin(work)
        patch_config(work)
        digest = overlay_digest(work)
        base, version = bump_version(work, digest)
        print("plugin files: %d, version: %s -> %s" % (copied, base, version), flush=True)

        # 归档必须写在被清理的树**外面**:写在 work 里会把自己也打进去。
        staging = tempfile.mkdtemp(prefix="notara-pack-")
        out = os.path.join(staging, "rootfs-new.tar.xz")
        pack(work, out, args.threads)
        size = os.path.getsize(out)
        sha = hashlib.sha256()
        with open(out, "rb") as fh:
            for chunk in iter(lambda: fh.read(1 << 20), b""):
                sha.update(chunk)
        print("repacked: %d bytes sha256=%s" % (size, sha.hexdigest()), flush=True)

        os.replace(out, args.rootfs)
        shutil.rmtree(staging, ignore_errors=True)

    with open(args.manifest, encoding="utf-8") as fh:
        manifest = json.load(fh)
    manifest["runtimeVersion"] = version
    manifest["rootfsBytes"] = size
    manifest["rootfsSha256"] = sha.hexdigest()
    manifest["notaraOverlay"] = {
        "version": version,
        "base": base,
        "pluginFiles": copied,
    }
    with open(args.manifest, "w", encoding="utf-8") as fh:
        json.dump(manifest, fh, ensure_ascii=False, indent=2, sort_keys=True)
        fh.write("\n")
    print("manifest updated: %s" % version, flush=True)

    verify(args.rootfs)
    print("overlay ok", flush=True)


if __name__ == "__main__":
    main()
