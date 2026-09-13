#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""以 HEAD 原文为基准重放全部语义改动，产出不含格式化噪声的版本。

用法：python3 scripts/migrate_visual_replay.py [--apply]
不带 --apply 只做校验（打印差异，不写文件）。
"""
import collections
import os
import re
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import migrate_visual_system as p1          # noqa: E402
import migrate_visual_system_pass2 as p2    # noqa: E402
import migrate_visual_manual_blocks as man  # noqa: E402
import migrate_visual_extra as extra        # noqa: E402

ROOT = os.path.normpath(os.path.dirname(os.path.abspath(__file__)) + "/..")


def tokens(text):
    """去掉所有空白后的字符串，用来判断两份代码是否只是排版不同。"""
    return re.sub(r"\s+", "", text)


def compare(a, b):
    """返回 (是否等价, 差异片段列表)。等价 = 去掉空白后完全一致。"""
    if a == b:
        return True, []
    import difflib
    sm = difflib.SequenceMatcher(None, a, b, autojunk=False)
    diffs = []
    for tag, i1, i2, j1, j2 in sm.get_opcodes():
        if tag != "equal":
            diffs.append("%s 重放=%r 现在=%r" % (tag, a[i1:i2][:80], b[j1:j2][:80]))
    return False, diffs[:6]


def head_of(rel):
    return subprocess.run(["git", "show", "HEAD:" + rel],
                          capture_output=True, text=True).stdout


def replay(rel, src):
    out = src
    # 1) 手工块
    for old, new in man.BLOCKS.get(rel, []):
        if old not in out:
            print("   !! 手工块未命中: %r" % old.split("\n")[0][:70])
        out = out.replace(old, new)
    # 2) 第一轮规则
    for old, new in p1.BLOCKS.get(rel, []):
        if old not in out:
            print("   !! pass1 块未命中: %r" % old.split("\n")[0][:70])
        out = out.replace(old, new)
    for old, new in p1.LINES:
        out = out.replace(old, new)
    for pattern, table in p1.RADIUS:
        def repl(m, table=table):
            value = float(m.group(1))
            key = int(value) if value == int(value) else None
            if key is None or key not in table:
                return m.group(0)
            return table[key]
        out = pattern.sub(repl, out)
    out, _added = p1.ensure_imports(rel, out)
    # 3) 第二轮规则
    for key in (rel, rel + "#2"):
        for old, new in p2.EXACT.get(key, []):
            if old not in out:
                print("   !! pass2 块未命中: %r" % old.split("\n")[0][:70])
            out = out.replace(old, new)
    for pattern, repl in p2.REGEX_RULES:
        out = pattern.sub(repl, out)
    # 4) 收尾补充规则
    out = extra.apply(rel, out)
    # 5) 清理已无引用的 isDark 声明，并补齐（可能新增依赖的）主题导入
    while out.count(p2.DECL) > 0:
        probe = out.replace(p2.DECL, "", 1)
        if "isDark" in probe:
            break
        out = probe
    out, _added = p1.ensure_imports(rel, out)
    return out


def main():
    apply = "--apply" in sys.argv
    # app_theme.dart 是整体重写，不参与重放（保持现状即可）
    skip = {"lib/theme/app_theme.dart"}
    files = [f for f in subprocess.run(
        ["git", "diff", "--name-only"], capture_output=True, text=True
    ).stdout.split() if f.endswith(".dart") and f not in skip]
    ok, bad = [], []
    for rel in files:
        path = os.path.join(ROOT, rel)
        if not os.path.exists(path):
            print("跳过（已删除）：", rel)
            continue
        head = head_of(rel)
        if not head:
            print("跳过（HEAD 无此文件）：", rel)
            continue
        current = open(path, encoding="utf-8").read()
        replayed = replay(rel, head)
        same, diffs = compare(tokens(replayed), tokens(current))
        if same:
            ok.append(rel)
            if apply:
                open(path, "w", encoding="utf-8").write(replayed)
        else:
            bad.append(rel)
            print("## 不等价：", rel)
            for d in diffs:
                print("   ", d)
    print()
    print("等价 %d 个%s" % (len(ok), "（已写回）" if apply else ""))
    if bad:
        print("不等价 %d 个：%s" % (len(bad), ", ".join(bad)))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
