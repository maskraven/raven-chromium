#!/usr/bin/env python3
"""Raven fingerprint snapshot comparator — Plan 04 persistence + coherence gate.

STDLIB ONLY (no pip). Given two probe snapshot JSON files, this tool:

  1. PERSISTENCE (spec §8.1): are the two canonical snapshots byte-identical?
     - Authoritative signal when both files carry a top-level "hash" (same JS
       engine produced both → directly comparable): hashA == hashB.
     - Falls back to a Python-side canonical (recursively key-sorted, compact)
       byte comparison when hashes are absent.
     - On divergence, prints a per-key diff (added / removed / changed paths) so
       the offending non-deterministic surface is obvious.

  2. COHERENCE (spec §8.3): basic cross-axis contradiction checks on each
     snapshot — the real bar ("most builds pass persistence and fail coherence"):
       - navigator.userAgent Chrome major == userAgentData Chrome major.
       - navigator.languages[0] language subtag == Intl locale/language subtag.
       - navigator.platform consistent with the UA OS token.
       - timezone present and not the UTC default (suspicious-flag).

Exit code: 0 if PERSISTENT and COHERENT, 1 otherwise.

Usage:
    python3 compare.py A.json B.json
    python3 compare.py --help

Each input file may be either the raw snapshot object or the full probe payload
{"hash": ..., "snapshot": {...}} exposed on window.__RAVEN_FP__.
"""

import argparse
import json
import re
import sys


UNAVAILABLE = "unavailable"


# --------------------------------------------------------------------------- #
# loading / canonicalization                                                  #
# --------------------------------------------------------------------------- #

def load_file(path):
    """Return (snapshot_dict, embedded_hash_or_None)."""
    with open(path, "r", encoding="utf-8") as fh:
        data = json.load(fh)
    if isinstance(data, dict) and "snapshot" in data and isinstance(data["snapshot"], dict):
        return data["snapshot"], data.get("hash")
    return data, None


def canonical(value):
    """Canonical compact JSON string with recursively sorted keys.

    Mirrors the probe's canonicalize(): compact separators + sorted keys. Used
    for the Python-side byte-identity comparison and for the diff.
    """
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True)


def flatten(value, prefix=""):
    """Flatten a JSON structure to {dotted.path: leaf_value}."""
    out = {}
    if isinstance(value, dict):
        for k in value:
            out.update(flatten(value[k], prefix + "." + str(k) if prefix else str(k)))
    elif isinstance(value, list):
        for i, item in enumerate(value):
            out.update(flatten(item, "{0}[{1}]".format(prefix, i)))
    else:
        out[prefix] = value
    return out


# --------------------------------------------------------------------------- #
# helpers to read fields defensively                                          #
# --------------------------------------------------------------------------- #

def get(snap, *path):
    """Walk a path; return None if any segment missing or value is a sentinel."""
    cur = snap
    for seg in path:
        if isinstance(cur, dict) and seg in cur:
            cur = cur[seg]
        elif isinstance(cur, list) and isinstance(seg, int) and 0 <= seg < len(cur):
            cur = cur[seg]
        else:
            return None
    if cur == UNAVAILABLE:
        return None
    if isinstance(cur, dict) and "error" in cur and len(cur) == 1:
        return None
    return cur


def chrome_major_from_ua(ua):
    if not isinstance(ua, str):
        return None
    m = re.search(r"Chrome/(\d+)", ua)
    return int(m.group(1)) if m else None


def chrome_major_from_uadata(uad):
    """Extract the Chrome/Chromium major from userAgentData (multiple sources)."""
    if not isinstance(uad, dict):
        return None
    he = uad.get("highEntropy") if isinstance(uad.get("highEntropy"), dict) else {}
    # 1) high-entropy uaFullVersion, e.g. "138.0.7204.97"
    ufv = he.get("uaFullVersion")
    if isinstance(ufv, str):
        m = re.match(r"(\d+)", ufv)
        if m:
            return int(m.group(1))
    # 2) high-entropy fullVersionList
    for src_key in ("fullVersionList",):
        lst = he.get(src_key)
        if isinstance(lst, list):
            maj = _major_from_brand_list(lst)
            if maj is not None:
                return maj
    # 3) low-entropy brands
    maj = _major_from_brand_list(uad.get("brands"))
    if maj is not None:
        return maj
    return None


def _major_from_brand_list(lst):
    if not isinstance(lst, list):
        return None
    for entry in lst:
        if not isinstance(entry, dict):
            continue
        brand = str(entry.get("brand", ""))
        if "Chrom" in brand or "Google Chrome" in brand:
            ver = str(entry.get("version", ""))
            m = re.match(r"(\d+)", ver)
            if m:
                return int(m.group(1))
    return None


def lang_subtag(tag):
    if not isinstance(tag, str) or not tag:
        return None
    return tag.split("-")[0].lower()


# --------------------------------------------------------------------------- #
# persistence                                                                 #
# --------------------------------------------------------------------------- #

def check_persistence(snap_a, hash_a, snap_b, hash_b):
    """Return (ok, method, diff_lines)."""
    diff_lines = []
    canon_a = canonical(snap_a)
    canon_b = canonical(snap_b)
    canon_identical = canon_a == canon_b

    if hash_a is not None and hash_b is not None:
        method = "embedded-hash"
        ok = hash_a == hash_b
    else:
        method = "python-canonical"
        ok = canon_identical

    if not ok or not canon_identical:
        fa = flatten(snap_a)
        fb = flatten(snap_b)
        keys = sorted(set(fa) | set(fb))
        for k in keys:
            in_a, in_b = k in fa, k in fb
            if in_a and not in_b:
                diff_lines.append("  - removed  {0} = {1}".format(k, json.dumps(fa[k])))
            elif in_b and not in_a:
                diff_lines.append("  + added    {0} = {1}".format(k, json.dumps(fb[k])))
            elif fa[k] != fb[k]:
                diff_lines.append("  ~ changed  {0}: {1} -> {2}".format(
                    k, json.dumps(fa[k]), json.dumps(fb[k])))
    return ok, method, diff_lines


# --------------------------------------------------------------------------- #
# coherence                                                                   #
# --------------------------------------------------------------------------- #

def check_coherence(snap, tag):
    """Return list of (name, status, detail). status in {ok, fail, skip}."""
    results = []

    # 1) UA Chrome major == userAgentData Chrome major
    ua = get(snap, "navigator", "userAgent")
    uad = get(snap, "navigator", "userAgentData")
    ua_major = chrome_major_from_ua(ua)
    uad_major = chrome_major_from_uadata(uad)
    if ua_major is None or uad_major is None:
        results.append(("ua-vs-uadata-major", "skip",
                        "ua_major={0} uadata_major={1}".format(ua_major, uad_major)))
    elif ua_major == uad_major:
        results.append(("ua-vs-uadata-major", "ok", "both Chrome major {0}".format(ua_major)))
    else:
        results.append(("ua-vs-uadata-major", "fail",
                        "UA says {0}, userAgentData says {1}".format(ua_major, uad_major)))

    # 2) languages[0] subtag == Intl locale/language subtag
    languages = get(snap, "navigator", "languages")
    lang0 = languages[0] if isinstance(languages, list) and languages else None
    intl_locale = get(snap, "intl", "locale") or get(snap, "navigator", "language")
    a_sub = lang_subtag(lang0)
    b_sub = lang_subtag(intl_locale)
    if a_sub is None or b_sub is None:
        results.append(("languages-vs-intl-locale", "skip",
                        "languages[0]={0} intl.locale={1}".format(lang0, intl_locale)))
    elif a_sub == b_sub:
        results.append(("languages-vs-intl-locale", "ok",
                        "both '{0}' (languages[0]={1}, locale={2})".format(a_sub, lang0, intl_locale)))
    else:
        results.append(("languages-vs-intl-locale", "fail",
                        "languages[0]={0} ('{1}') vs Intl locale={2} ('{3}')".format(
                            lang0, a_sub, intl_locale, b_sub)))

    # 3) navigator.platform consistent with UA OS token
    platform = get(snap, "navigator", "platform")
    results.append(_check_platform_vs_ua(platform, ua))

    # 4) timezone present and not the UTC default (suspicious flag)
    tz = get(snap, "intl", "timeZone")
    if tz is None:
        results.append(("timezone-present", "fail", "timezone missing/unavailable"))
    elif str(tz) in ("UTC", "Etc/UTC", "Etc/Unknown", "GMT"):
        results.append(("timezone-present", "fail",
                        "timezone is '{0}' — UTC default is a spoof tell (suspicious)".format(tz)))
    else:
        results.append(("timezone-present", "ok", "timezone '{0}'".format(tz)))

    return results


def _check_platform_vs_ua(platform, ua):
    name = "platform-vs-ua-os"
    if not isinstance(platform, str) or not isinstance(ua, str):
        return (name, "skip", "platform={0} ua_present={1}".format(platform, isinstance(ua, str)))
    p = platform
    # (platform predicate, required UA token, human label)
    rules = [
        (lambda: "Android" in p, "Android", "Android"),
        (lambda: p.startswith("Win"), "Windows", "Windows"),
        (lambda: p.startswith("Mac") or p == "MacIntel", "Mac OS X", "macOS"),
        (lambda: "Linux" in p or p.startswith("X11"), "Linux", "Linux"),
        (lambda: p in ("iPhone", "iPad", "iPod"), "like Mac OS X", "iOS"),
        (lambda: "CrOS" in p, "CrOS", "ChromeOS"),
    ]
    for pred, token, label in rules:
        if pred():
            # Special-case: Android UA also contains "Linux"; disambiguate.
            if label == "Linux" and "Android" in ua:
                return (name, "fail",
                        "platform '{0}' (Linux) but UA contains Android token".format(p))
            if token in ua:
                return (name, "ok", "platform '{0}' matches UA {1} token".format(p, label))
            return (name, "fail",
                    "platform '{0}' ({1}) but UA lacks '{2}' token".format(p, label, token))
    return (name, "skip", "unrecognized platform '{0}'".format(p))


# --------------------------------------------------------------------------- #
# reporting                                                                   #
# --------------------------------------------------------------------------- #

def print_coherence(tag, results):
    print("COHERENCE [{0}]:".format(tag))
    for name, status, detail in results:
        mark = {"ok": "PASS", "fail": "FAIL", "skip": "skip"}[status]
        print("  [{0}] {1}: {2}".format(mark, name, detail))


def main(argv):
    parser = argparse.ArgumentParser(
        prog="compare.py",
        description="Raven fingerprint snapshot comparator: PERSISTENCE (byte-identical "
                    "across restarts) + COHERENCE (zero cross-axis contradictions). "
                    "Exit 0 if persistent and coherent, else 1.")
    parser.add_argument("a", metavar="A.json", help="first snapshot (e.g. dump_A.json)")
    parser.add_argument("b", metavar="B.json", help="second snapshot (e.g. dump_B.json)")
    parser.add_argument("--quiet", action="store_true", help="suppress the per-key diff body")
    args = parser.parse_args(argv)

    try:
        snap_a, hash_a = load_file(args.a)
        snap_b, hash_b = load_file(args.b)
    except (OSError, ValueError) as exc:
        print("error: {0}".format(exc), file=sys.stderr)
        return 2

    print("=" * 70)
    print("Raven fingerprint compare")
    print("  A: {0}".format(args.a))
    print("  B: {0}".format(args.b))
    print("=" * 70)

    # ---- persistence ----
    p_ok, method, diff_lines = check_persistence(snap_a, hash_a, snap_b, hash_b)
    print("PERSISTENCE ({0}): {1}".format(method, "PASS — byte-identical" if p_ok else "FAIL"))
    if hash_a is not None or hash_b is not None:
        print("  hash A: {0}".format(hash_a))
        print("  hash B: {0}".format(hash_b))
    if diff_lines:
        print("  {0} differing key(s):".format(len(diff_lines)))
        if not args.quiet:
            for line in diff_lines:
                print(line)
        else:
            print("  (diff suppressed with --quiet)")

    # ---- coherence (run on both snapshots) ----
    res_a = check_coherence(snap_a, "A")
    res_b = check_coherence(snap_b, "B")
    print("-" * 70)
    print_coherence("A", res_a)
    print_coherence("B", res_b)

    coherent = all(s != "fail" for _, s, _ in res_a) and all(s != "fail" for _, s, _ in res_b)

    print("=" * 70)
    print("RESULT: persistence={0} coherence={1}".format(
        "PASS" if p_ok else "FAIL", "PASS" if coherent else "FAIL"))
    print("=" * 70)

    return 0 if (p_ok and coherent) else 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
