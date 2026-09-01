#!/usr/bin/env python3
"""Mechanical checks over a local model's reply.

Text in, verdict out. No model, no network, no I/O beyond stdin/stdout — which is
what lets `scripts/tests/eval-checks.test.sh` verify these in the *hermetic* suite,
on a machine with no oMLX and no Apple silicon.

Every check answers a question with a right answer: did the reply obey the sentence
ceiling, did it skip the preamble the system prompt forbids, did it stay in one
script, is the label one of the offered candidates. Nothing here judges whether a
summary is any *good* — that stays a human's job, and scripts/eval/README.md says so
in the terms this file cannot enforce.

Exit status is about whether the check RAN, not about its verdict:

    0   the check ran; read "ok" from the JSON on stdout
    2   usage error — unknown check name, malformed --expect, missing argument

A harness that conflates those two reports a crash as a finding, so they are kept
apart deliberately.
"""

import argparse
import json
import re
import sys

# ── sentence_count ───────────────────────────────────────────────────────────────
# Deliberately simple, and its limits are stated rather than papered over. A `.`
# flanked by digits is a decimal, not a terminator; runs like "?!" or "…" count once.
# What it does NOT know: abbreviations ("Dr. Chen" reads as two sentences), ellipses
# used mid-clause, or a model that writes one enormous comma-spliced sentence. A check
# whose failure modes are written down beats one that pretends to be exact.
_TERMINATORS = ".!?。！？…"


def sentence_count(text):
    n = 0
    i = 0
    chars = text
    length = len(chars)
    while i < length:
        c = chars[i]
        if c not in _TERMINATORS:
            i += 1
            continue
        # A decimal point: digit before AND digit after. Not a sentence boundary.
        if c == "." and i > 0 and chars[i - 1].isdigit() and i + 1 < length and chars[i + 1].isdigit():
            i += 1
            continue
        n += 1
        # Collapse a run of terminators ("?!", "...") into the one boundary it is.
        while i < length and chars[i] in _TERMINATORS:
            i += 1
    # Trailing content with no terminator is still a sentence — small models often
    # drop the final full stop, and counting that as zero would flatter them.
    tail = re.split("[" + re.escape(_TERMINATORS) + "]", text)[-1]
    if tail.strip():
        n += 1
    return n


def check_sentence_count(text, expect):
    ceiling = expect.get("max")
    if not isinstance(ceiling, int):
        raise ValueError("sentence_count needs an integer 'max'")
    observed = sentence_count(text)
    return {
        "ok": observed <= ceiling,
        "observed": observed,
        "expected": {"max": ceiling},
        "detail": f"counted {observed} sentence(s), ceiling {ceiling}",
    }


# ── no_preamble ──────────────────────────────────────────────────────────────────
# Server.swift sends `outputOnlyRule` as the system prompt: "Output only the requested
# result. No preamble...". This measures whether the model obeyed it.
#
# The check matches OPENERS, anchored at the start — not "does a preamble exist
# anywhere". That is the honest scope: a lead-in buried in the middle is not caught.
# Anchoring is what keeps ordinary content that merely contains a colon ("Three items
# were deferred: budget, venue") from being flagged.
_PREAMBLE_PATTERNS = [
    r"(?:sure|certainly|of course|okay|ok)\s*[,!:.]",
    r"here (?:is|are|'s)\b",
    r"(?:the following|below) (?:is|are)\b",
    r"this is (?:a |the )?(?:summary|translation|rewrite|answer|result)\b",
    r"i(?:'ve| have| will| ?'ll| am going to)\b",
    r"let me\b",
    r"as requested\b",
    r"(?:以下|下面)(?:是|為|为|就是)",
    r"這(?:是|就是)(?:一份|一個|一个)?(?:摘要|翻譯|翻译|結果|结果|回答)",
    r"好的[，,、:：]",
    r"當然|当然[，,、:：]",
    r"我(?:已經|已经|會|会|來|来|將|将)",
    r"(?:摘要|總結|总结)(?:如下|如下：)",
]
_PREAMBLE_RE = re.compile("|".join(_PREAMBLE_PATTERNS), re.IGNORECASE)

# Markdown emphasis and quoting a model may wrap its opener in.
_LEADING_NOISE = re.compile(r"^[\s>*_`\"'“”‘’\-—•]+")


def check_no_preamble(text, expect):
    head = _LEADING_NOISE.sub("", text)[:120]
    m = _PREAMBLE_RE.match(head)
    return {
        "ok": m is None,
        "observed": head[: m.end()] if m else head[:40],
        "expected": {"opener": "content, not a lead-in"},
        "detail": f"opener matched {m.group(0)!r}" if m else "no known preamble opener",
    }


# ── script_purity ────────────────────────────────────────────────────────────────
# The documented failure on issue #1: a small model asked for 繁體中文 emitted mixed
# Traditional and Simplified.
#
# A CURATED set of characters that exist only in Simplified. It is not exhaustive, and
# that direction is chosen: characters valid in BOTH scripts are deliberately left out
# (里, 干, 万, 与, 云, 后, 几, 峰, 靜, 黃 …), because a false positive would flag a clean
# reply and quietly discredit the harness, whereas a miss only under-reports. Say so in
# any report: this check finds mixing, it does not certify purity.
_SIMPLIFIED_ONLY = set(
    "这个们会国说时实对发为么样点过还进问题关开间长东车见话记认识学写讲议论设计试请谢"
    "边远连选适达迟爱头买卖员产业务动办报纸轮转载运输银钱铁钢铜铅锁针线纺织级红绿蓝紫"
    "绍继续经络给结绝统绕维绵编缩缝网罗币师帅归当尽层属岁岗峡巩击凤凰凭刘划则刚创删剑"
    "劳势勋胜匀区医华协单卫厅历厉压厌厨县参双变听吗吨响哑唤啸图园圆圣块坏坚坛垒场声壮"
    "壳处备复夺奋奖妆妇妈娄学孙宁宝审宪岛巅帮带帜庄庆库应庙废弹张录彻径忆态怀总恋恳恶"
    "恼惊惧惨惯懒战扑执扩扪扫扬扰抚护拟拢拣挚挡挤挥捞损捡换据掷掸摄摆摊撵攒败货贝贞负"
    "贡财责贤贩贪贫贯贱贴贵贷贸费贺贼贾赁资赋赌赏赐赔赖赚赞赠赢赵赶趋跃践跄踪蹑轧轨轩"
    "软轰轻较辆辈辉辐辖辗辙辞辽迁违逊递逻遗邓邮邻郑酝释钉钊钓钟钥钦钩钮钳钻铃铝铭铸铺"
    "链销锅锋锐错锡锦键锯镇镜镖门闪闭闯闲闷闻阀阁阅阔队阶阳阴阵陆陈险随隐难雾韦韩顶顷"
    "项顺须顽顾顿颁颂预领颇颈频颖颗题颜额颠风飘飞饥饭饮饰饱饲饼馆驱驰驳驶驻驼驾骂骄验"
    "骑骗骤髅鱼鲁鲜鸟鸡鸣鸦鸭鸿鹅鹏鹤鹰麦齐齿龄龙龟两"
)


def check_script_purity(text, expect):
    want = expect.get("script")
    if want != "traditional":
        raise ValueError("script_purity only implements script='traditional'")
    offenders = sorted({c for c in text if c in _SIMPLIFIED_ONLY})
    return {
        "ok": not offenders,
        "observed": "".join(offenders),
        "expected": {"script": "traditional"},
        "detail": (
            "no Simplified-only characters found (curated set — a miss is possible)"
            if not offenders
            else f"Simplified-only character(s) present: {''.join(offenders)}"
        ),
    }


# ── category_member ──────────────────────────────────────────────────────────────
# For local_classify: the reply must BE one of the offered labels, not a sentence
# mentioning one. "This is a feature request, I think." is a failure to follow the
# format even though the right label is in there.
_TRAILING_PUNCT = "  \t\r\n.。!！?？,，、:：;；\"'“”‘’`*_"


def check_category_member(text, expect):
    categories = expect.get("categories")
    if not isinstance(categories, list) or not categories:
        raise ValueError("category_member needs a non-empty 'categories' list")
    normalized = text.strip().strip(_TRAILING_PUNCT).strip().casefold()
    wanted = {str(c).strip().casefold() for c in categories}
    return {
        "ok": normalized in wanted,
        "observed": text.strip()[:80],
        "expected": {"categories": categories},
        "detail": (
            f"{normalized!r} is one of the candidates"
            if normalized in wanted
            else f"{normalized!r} is not one of {sorted(wanted)}"
        ),
    }


CHECKS = {
    "sentence_count": check_sentence_count,
    "no_preamble": check_no_preamble,
    "script_purity": check_script_purity,
    "category_member": check_category_member,
}


def run_one(name, text, expect):
    fn = CHECKS.get(name)
    if fn is None:
        raise KeyError(name)
    result = fn(text, expect)
    result["check"] = name
    return result


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__)
    g = p.add_mutually_exclusive_group(required=True)
    g.add_argument("--check", help="run a single named check")
    g.add_argument("--spec", help='JSON object of {check_name: expect_object} — what run.sh calls')
    p.add_argument("--expect", default="{}", help="JSON object of expectations for --check")
    p.add_argument("--text-file", help="read the reply from this file instead of stdin")
    p.add_argument("--list", action="store_true", help=argparse.SUPPRESS)
    args = p.parse_args(argv)

    if args.text_file:
        with open(args.text_file, encoding="utf-8") as fh:
            text = fh.read()
    else:
        text = sys.stdin.read()

    try:
        if args.check:
            expect = json.loads(args.expect)
            print(json.dumps(run_one(args.check, text, expect), ensure_ascii=False))
        else:
            spec = json.loads(args.spec)
            if not isinstance(spec, dict):
                raise ValueError("--spec must be a JSON object")
            results = [run_one(name, text, exp) for name, exp in spec.items()]
            print(
                json.dumps(
                    {"checks": results, "all_ok": all(r["ok"] for r in results)},
                    ensure_ascii=False,
                )
            )
    except KeyError as e:
        # An unknown check name is a typo in a case file. Failing loudly is the whole
        # point: a silently-skipped check is an eval that reports without checking.
        print(f"unknown check: {e.args[0]} (known: {', '.join(sorted(CHECKS))})", file=sys.stderr)
        return 2
    except (ValueError, json.JSONDecodeError) as e:
        print(f"bad expectation: {e}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
