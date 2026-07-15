#!/usr/bin/env python3
"""Raven profile-db descriptor validator (Plan 02 §6 D1 contract).

STDLIB-ONLY. No pip, no `jsonschema` dependency: the JSON-Schema checks we
need are hand-rolled over the parsed JSON. Two layers run:

  (a) STRUCTURAL validation against schema/descriptor.schema.json
      (types, required, enums, const, ranges, patterns, additionalProperties)
      via a minimal draft-2020-12 walker covering the subset of keywords the
      schema uses.

  (b) CROSS-AXIS COHERENCE — the real gate. Single-source identity axes must
      co-vary and never contradict:
        * platform string must match os (Win32 / MacIntel / Linux x86_64).
        * gpu.vendor/renderer must be plausible for os (no Apple GPU off
          macOS, no Direct3D off Windows, no Mesa off Linux, no Metal off
          macOS) — the host-OS/GPU-match rule.
        * languages[0] must share locale's primary language subtag
          (languages <-> Accept-Language single source), and locale's region
          must be consistent with timezone's country/region (timezone <-> geo).
        * screen: availW <= w, availH <= h, dpr in a sane set,
          pixelDepth == colorDepth in {24,30}.
        * chromeMajor within a sane band (>= 140).

Usage:
  python3 validate.py <descriptor.json>
  python3 validate.py --all profile-db/fixtures/
Prints PASS or a list of FAIL reasons per file; exit 0 (all pass) / 1 (any fail).
Runs on system python3 — no venv/pip needed.
"""
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SCHEMA_PATH = os.path.join(HERE, "schema", "descriptor.schema.json")


# ---------------------------------------------------------------------------
# (a) Structural validation: minimal JSON-Schema (draft 2020-12) walker
# ---------------------------------------------------------------------------
_TYPE_CHECKS = {
    "object": lambda v: isinstance(v, dict),
    "array": lambda v: isinstance(v, list),
    "string": lambda v: isinstance(v, str),
    "boolean": lambda v: isinstance(v, bool),
    "null": lambda v: v is None,
    "integer": lambda v: isinstance(v, int) and not isinstance(v, bool),
    "number": lambda v: isinstance(v, (int, float)) and not isinstance(v, bool),
}


def _type_ok(value, t):
    if isinstance(t, list):
        return any(_type_ok(value, x) for x in t)
    return _TYPE_CHECKS.get(t, lambda v: True)(value)


def _num_eq(a, b):
    try:
        # 8 == 8.0 is intentional (deviceMemory 8 vs 8.0); bool must not match ints
        if isinstance(a, bool) != isinstance(b, bool):
            return False
        return a == b
    except Exception:
        return False


def _validate_node(value, schema, path, errors):
    if "type" in schema and not _type_ok(value, schema["type"]):
        errors.append("%s: expected type %s, got %s"
                      % (path, schema["type"], type(value).__name__))
        return  # remaining keyword checks are unreliable on a wrong type

    if "const" in schema and value != schema["const"]:
        errors.append("%s: must equal %r, got %r" % (path, schema["const"], value))

    if "enum" in schema and not any(_num_eq(value, e) for e in schema["enum"]):
        errors.append("%s: %r not in enum %s" % (path, value, schema["enum"]))

    if isinstance(value, (int, float)) and not isinstance(value, bool):
        if "minimum" in schema and value < schema["minimum"]:
            errors.append("%s: %s < minimum %s" % (path, value, schema["minimum"]))
        if "maximum" in schema and value > schema["maximum"]:
            errors.append("%s: %s > maximum %s" % (path, value, schema["maximum"]))

    if isinstance(value, str):
        if "minLength" in schema and len(value) < schema["minLength"]:
            errors.append("%s: string shorter than minLength %s"
                          % (path, schema["minLength"]))
        if "pattern" in schema and re.search(schema["pattern"], value) is None:
            errors.append("%s: %r does not match pattern %s"
                          % (path, value, schema["pattern"]))

    if isinstance(value, list):
        if "minItems" in schema and len(value) < schema["minItems"]:
            errors.append("%s: fewer than minItems %s" % (path, schema["minItems"]))
        if "items" in schema:
            for i, item in enumerate(value):
                _validate_node(item, schema["items"], "%s[%d]" % (path, i), errors)

    if isinstance(value, dict):
        props = schema.get("properties", {})
        for req in schema.get("required", []):
            if req not in value:
                errors.append("%s: missing required property '%s'" % (path, req))
        if schema.get("additionalProperties", True) is False:
            for k in value:
                if k not in props:
                    errors.append("%s: unexpected property '%s'" % (path, k))
        for k, sub in props.items():
            if k in value:
                child = ("%s.%s" % (path, k)) if path != "$" else k
                _validate_node(value[k], sub, child, errors)

    if "anyOf" in schema:
        if not any(_subschema_ok(value, s) for s in schema["anyOf"]):
            errors.append("%s: %r matched none of anyOf" % (path, value))
    if "oneOf" in schema:
        n = sum(1 for s in schema["oneOf"] if _subschema_ok(value, s))
        if n != 1:
            errors.append("%s: matched %d of oneOf (need exactly 1)" % (path, n))


def _subschema_ok(value, schema):
    tmp = []
    _validate_node(value, schema, "$", tmp)
    return not tmp


def validate_structural(instance, schema):
    errors = []
    _validate_node(instance, schema, "$", errors)
    return errors


# ---------------------------------------------------------------------------
# (b) Cross-axis coherence
# ---------------------------------------------------------------------------
OS_PLATFORM = {"windows": "Win32", "macos": "MacIntel", "linux": "Linux x86_64"}
DPR_OK = {1, 1.25, 1.5, 1.75, 2, 2.25, 2.5, 3}
DEPTH_OK = {24, 30}

# OS-specific GPU tells: substring -> the single os it may appear under.
GPU_OS_TELLS = [
    ("apple", "macos"),
    ("metal", "macos"),
    ("direct3d", "windows"),
    ("d3d11", "windows"),
    ("d3d9", "windows"),
    ("mesa", "linux"),
]

# Coarse region -> acceptable IANA tz prefixes/zones (a match = startswith).
# Regions absent from the map are treated leniently (skip the strict check).
REGION_TZ = {
    "US": ["America/", "Pacific/Honolulu", "Pacific/Pago_Pago"],
    "CA": ["America/"],
    "MX": ["America/"],
    "BR": ["America/"],
    "AR": ["America/"],
    "GB": ["Europe/London"],
    "IE": ["Europe/Dublin"],
    "FR": ["Europe/Paris"],
    "DE": ["Europe/Berlin", "Europe/Busingen"],
    "ES": ["Europe/Madrid", "Atlantic/Canary", "Africa/Ceuta"],
    "IT": ["Europe/Rome"],
    "NL": ["Europe/Amsterdam"],
    "SE": ["Europe/Stockholm"],
    "PL": ["Europe/Warsaw"],
    "RU": ["Europe/Moscow", "Europe/Kaliningrad", "Asia/"],
    "JP": ["Asia/Tokyo"],
    "CN": ["Asia/Shanghai", "Asia/Urumqi"],
    "KR": ["Asia/Seoul"],
    "IN": ["Asia/Kolkata"],
    "AU": ["Australia/"],
    "NZ": ["Pacific/Auckland"],
}


def _region(tag):
    if not isinstance(tag, str):
        return None
    parts = tag.split("-")
    return parts[1].upper() if len(parts) > 1 else None


def _primary(tag):
    if not isinstance(tag, str):
        return None
    return tag.split("-")[0].lower()


def validate_coherence(d):
    errs = []
    if not isinstance(d, dict):
        return ["top level is not a JSON object"]

    osname = d.get("os")

    # --- platform <-> os ---
    plat = d.get("platform")
    if osname in OS_PLATFORM and isinstance(plat, str):
        if plat != OS_PLATFORM[osname]:
            errs.append("platform '%s' does not match os '%s' (expected '%s')"
                        % (plat, osname, OS_PLATFORM[osname]))

    # --- gpu <-> os (host-OS/GPU-match) ---
    gpu = d.get("gpu")
    if isinstance(gpu, dict) and osname in OS_PLATFORM:
        blob = " ".join(str(gpu.get(k, "")) for k in
                        ("vendor", "renderer", "architecture", "device")).lower()
        for tell, only_os in GPU_OS_TELLS:
            if tell in blob and osname != only_os:
                errs.append("gpu tell '%s' is only valid on os '%s', but os is '%s'"
                            % (tell, only_os, osname))

    # --- languages[0] <-> locale (Accept-Language single source) ---
    langs = d.get("languages")
    locale = d.get("locale")
    if isinstance(langs, list) and langs and isinstance(locale, str):
        first = langs[0]
        if _primary(first) != _primary(locale):
            errs.append("languages[0] '%s' language subtag != locale '%s'"
                        % (first, locale))
        else:
            fr, lr = _region(first), _region(locale)
            if fr and lr and fr != lr:
                errs.append("languages[0] region '%s' != locale region '%s'"
                            % (fr, lr))

    # --- locale region <-> timezone (geo single source) ---
    tz = d.get("timezone")
    region = _region(locale)
    if region and isinstance(tz, str) and region in REGION_TZ:
        if not any(tz == p or tz.startswith(p) for p in REGION_TZ[region]):
            errs.append("timezone '%s' not plausible for locale region '%s' "
                        "(expected one of %s)" % (tz, region, REGION_TZ[region]))

    # --- screen geometry ---
    sc = d.get("screen")
    if isinstance(sc, dict):
        w, h = sc.get("w"), sc.get("h")
        aw, ah = sc.get("availW"), sc.get("availH")
        if isinstance(w, int) and isinstance(aw, int) and aw > w:
            errs.append("screen.availW %d > screen.w %d" % (aw, w))
        if isinstance(h, int) and isinstance(ah, int) and ah > h:
            errs.append("screen.availH %d > screen.h %d" % (ah, h))
        dpr = sc.get("dpr")
        if isinstance(dpr, (int, float)) and not isinstance(dpr, bool):
            if dpr not in DPR_OK:
                errs.append("screen.dpr %s not in sane set %s"
                            % (dpr, sorted(DPR_OK)))
        cd, pd = sc.get("colorDepth"), sc.get("pixelDepth")
        if isinstance(cd, int) and isinstance(pd, int):
            if cd != pd:
                errs.append("screen.colorDepth %d != screen.pixelDepth %d" % (cd, pd))
            if cd not in DEPTH_OK:
                errs.append("screen.colorDepth %d not in {24,30}" % cd)

    # --- hardwareConcurrency (real, even, in band) ---
    hc = d.get("hardwareConcurrency")
    if isinstance(hc, int) and not isinstance(hc, bool):
        if hc < 2 or hc > 256:
            errs.append("hardwareConcurrency %d outside real range [2,256]" % hc)
        elif hc % 2 != 0:
            errs.append("hardwareConcurrency %d is odd (expected even)" % hc)

    # --- chromeMajor band ---
    cm = d.get("chromeMajor")
    if isinstance(cm, int) and not isinstance(cm, bool) and cm < 140:
        errs.append("chromeMajor %d below sane band (>=140)" % cm)

    return errs


# ---------------------------------------------------------------------------
# Driver
# ---------------------------------------------------------------------------
def validate_file(path, schema):
    try:
        with open(path) as f:
            data = json.load(f)
    except (OSError, ValueError) as e:
        return ["cannot read/parse JSON: %s" % e]
    return validate_structural(data, schema) + validate_coherence(data)


def _report(path, reasons):
    if reasons:
        print("FAIL %s" % path)
        for r in reasons:
            print("  - %s" % r)
    else:
        print("PASS %s" % path)
    return not reasons


def main(argv):
    try:
        with open(SCHEMA_PATH) as f:
            schema = json.load(f)
    except (OSError, ValueError) as e:
        print("cannot load schema %s: %s" % (SCHEMA_PATH, e))
        return 2

    if argv and argv[0] == "--all":
        target = argv[1] if len(argv) > 1 else os.path.join(HERE, "fixtures")
        if not os.path.isdir(target):
            print("not a directory: %s" % target)
            return 2
        files = sorted(os.path.join(target, n) for n in os.listdir(target)
                       if n.endswith(".json"))
        if not files:
            print("no .json fixtures in %s" % target)
            return 2
        all_ok = True
        for p in files:
            all_ok = _report(p, validate_file(p, schema)) and all_ok
        return 0 if all_ok else 1

    if not argv:
        print(__doc__)
        return 2

    ok = _report(argv[0], validate_file(argv[0], schema))
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
