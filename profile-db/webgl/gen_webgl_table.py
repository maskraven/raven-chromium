#!/usr/bin/env python3
# Copyright 2026 The Raven Authors. All rights reserved.
#
# GENERATOR (source of truth): reads the persona GPU dataset JSON and emits a
# self-contained C++ header holding the static persona param table consumed by
# webgl_persona_params.cc.  Do NOT hand-edit the generated header; edit this
# script (and/or the JSON) and re-run:
#
#   python3 gen_webgl_table.py \
#       --json  <repo>/profile-db/webgl/webgl-gpu-params.json \
#       --out   <staging>/.../webgl/webgl_persona_params_data.h
#
# Defaults point at the in-repo dataset and the staging output path so that a
# bare `python3 gen_webgl_table.py` regenerates the checked-in header.
#
# Each JSON cap NAME is mapped to its canonical GL enum value (hex emitted
# inline so the header needs no GL headers of its own) and bucketed by the C++
# type the WebGL getParameter path returns for it:
#   INT     -> GLint   (single)
#   INT64   -> GLint64 (single; WebGL2 spec returns 64-bit)
#   FLOAT   -> GLfloat (single)
#   IARR2   -> GLint[2]
#   FARR2   -> GLfloat[2]

import argparse
import json
import os
import sys

# --- Cap name -> (GL enum value) classification -----------------------------
# Values are the standard OpenGL(ES) tokens; comments name the GL_* macro so a
# reader can cross-check against third_party/khronos/GLES2/gl2.h + GLES3/gl3.h.

INT_CAPS = {
    # WebGL 1 integer caps
    "MAX_TEXTURE_SIZE": 0x0D33,                  # GL_MAX_TEXTURE_SIZE
    "MAX_CUBE_MAP_TEXTURE_SIZE": 0x851C,         # GL_MAX_CUBE_MAP_TEXTURE_SIZE
    "MAX_RENDERBUFFER_SIZE": 0x84E8,             # GL_MAX_RENDERBUFFER_SIZE
    "MAX_TEXTURE_IMAGE_UNITS": 0x8872,           # GL_MAX_TEXTURE_IMAGE_UNITS
    "MAX_VERTEX_TEXTURE_IMAGE_UNITS": 0x8B4C,    # GL_MAX_VERTEX_TEXTURE_IMAGE_UNITS
    "MAX_COMBINED_TEXTURE_IMAGE_UNITS": 0x8B4D,  # GL_MAX_COMBINED_TEXTURE_IMAGE_UNITS
    "MAX_VERTEX_ATTRIBS": 0x8869,                # GL_MAX_VERTEX_ATTRIBS
    "MAX_VERTEX_UNIFORM_VECTORS": 0x8DFB,        # GL_MAX_VERTEX_UNIFORM_VECTORS
    "MAX_FRAGMENT_UNIFORM_VECTORS": 0x8DFD,      # GL_MAX_FRAGMENT_UNIFORM_VECTORS
    "MAX_VARYING_VECTORS": 0x8DFC,               # GL_MAX_VARYING_VECTORS
    # WebGL 2 integer caps
    "MAX_3D_TEXTURE_SIZE": 0x8073,               # GL_MAX_3D_TEXTURE_SIZE
    "MAX_ARRAY_TEXTURE_LAYERS": 0x88FF,          # GL_MAX_ARRAY_TEXTURE_LAYERS
    "MAX_DRAW_BUFFERS": 0x8824,                  # GL_MAX_DRAW_BUFFERS
    "MAX_COLOR_ATTACHMENTS": 0x8CDF,             # GL_MAX_COLOR_ATTACHMENTS
    "MAX_SAMPLES": 0x8D57,                       # GL_MAX_SAMPLES
    "MAX_UNIFORM_BUFFER_BINDINGS": 0x8A2F,       # GL_MAX_UNIFORM_BUFFER_BINDINGS
    "MAX_VERTEX_UNIFORM_BLOCKS": 0x8A2B,         # GL_MAX_VERTEX_UNIFORM_BLOCKS
    "MAX_FRAGMENT_UNIFORM_BLOCKS": 0x8A2D,       # GL_MAX_FRAGMENT_UNIFORM_BLOCKS
    "MAX_VERTEX_UNIFORM_COMPONENTS": 0x8B4A,     # GL_MAX_VERTEX_UNIFORM_COMPONENTS
    "MAX_FRAGMENT_UNIFORM_COMPONENTS": 0x8B49,   # GL_MAX_FRAGMENT_UNIFORM_COMPONENTS
    "MAX_VERTEX_OUTPUT_COMPONENTS": 0x9122,      # GL_MAX_VERTEX_OUTPUT_COMPONENTS
    "MAX_FRAGMENT_INPUT_COMPONENTS": 0x9125,     # GL_MAX_FRAGMENT_INPUT_COMPONENTS
    "MAX_VARYING_COMPONENTS": 0x8B4B,            # GL_MAX_VARYING_COMPONENTS
    "MAX_COMBINED_UNIFORM_BLOCKS": 0x8A2E,       # GL_MAX_COMBINED_UNIFORM_BLOCKS
    "MIN_PROGRAM_TEXEL_OFFSET": 0x8904,          # GL_MIN_PROGRAM_TEXEL_OFFSET
    "MAX_PROGRAM_TEXEL_OFFSET": 0x8905,          # GL_MAX_PROGRAM_TEXEL_OFFSET
    "MAX_TRANSFORM_FEEDBACK_SEPARATE_ATTRIBS": 0x8C8A,  # GL_MAX_TRANSFORM_FEEDBACK_SEPARATE_ATTRIBS
    "UNIFORM_BUFFER_OFFSET_ALIGNMENT": 0x8A34,   # GL_UNIFORM_BUFFER_OFFSET_ALIGNMENT
}

INT64_CAPS = {
    "MAX_UNIFORM_BLOCK_SIZE": 0x8A30,  # GL_MAX_UNIFORM_BLOCK_SIZE (GLint64)
    "MAX_ELEMENT_INDEX": 0x8D6B,       # GL_MAX_ELEMENT_INDEX      (GLint64)
}

FLOAT_CAPS = {
    "MAX_TEXTURE_LOD_BIAS": 0x84FD,    # GL_MAX_TEXTURE_LOD_BIAS (GLfloat)
}

IARR2_CAPS = {
    "MAX_VIEWPORT_DIMS": 0x0D3A,       # GL_MAX_VIEWPORT_DIMS (GLint[2])
}

FARR2_CAPS = {
    "ALIASED_LINE_WIDTH_RANGE": 0x846E,  # GL_ALIASED_LINE_WIDTH_RANGE (GLfloat[2])
    "ALIASED_POINT_SIZE_RANGE": 0x846D,  # GL_ALIASED_POINT_SIZE_RANGE (GLfloat[2])
}

GUARD = "THIRD_PARTY_BLINK_RENDERER_MODULES_WEBGL_WEBGL_PERSONA_PARAMS_DATA_H_"


def cstr(s):
    """Return a safe C++ string literal for s."""
    out = ['"']
    for ch in s:
        if ch == '\\':
            out.append('\\\\')
        elif ch == '"':
            out.append('\\"')
        elif ch == '\n':
            out.append('\\n')
        elif ch == '\t':
            out.append('\\t')
        elif ch == '\r':
            out.append('\\r')
        else:
            out.append(ch)
    out.append('"')
    return "".join(out)


def cfloat(x):
    """Format a numeric JSON value as a C++ float literal (always suffixed f)."""
    s = repr(float(x))
    if "e" in s or "E" in s:
        return s + "f"
    if "." not in s:
        s += ".0"
    return s + "f"


def cint64(x):
    return "{}LL".format(int(x))


def derive_webgl2_gl_version(v1):
    """Map the WebGL1 VERSION string to its canonical WebGL2 form."""
    return v1.replace("WebGL 1.0", "WebGL 2.0").replace(
        "OpenGL ES 2.0", "OpenGL ES 3.0")


def derive_webgl2_glsl_version(v1):
    """Map the WebGL1 SHADING_LANGUAGE_VERSION string to its WebGL2 form."""
    return v1.replace("WebGL GLSL ES 1.0", "WebGL GLSL ES 3.00").replace(
        "OpenGL ES GLSL ES 1.0", "OpenGL ES GLSL ES 3.0")


def ident(key):
    """Turn a dataset key into a C++ identifier fragment."""
    return "".join(ch if (ch.isalnum()) else "_" for ch in key)


def collect_caps(entry, unmapped):
    """Bucket an entry's webgl1+webgl2 caps by type. Records unmapped names."""
    ints, i64s, floats, iarr2, farr2 = [], [], [], [], []
    for section in ("webgl1", "webgl2"):
        caps = entry.get(section, {})
        for name, value in caps.items():
            if name in INT_CAPS:
                ints.append((INT_CAPS[name], int(value), name))
            elif name in INT64_CAPS:
                i64s.append((INT64_CAPS[name], int(value), name))
            elif name in FLOAT_CAPS:
                floats.append((FLOAT_CAPS[name], value, name))
            elif name in IARR2_CAPS:
                iarr2.append((IARR2_CAPS[name], value, name))
            elif name in FARR2_CAPS:
                farr2.append((FARR2_CAPS[name], value, name))
            else:
                unmapped.add(name)
    return ints, i64s, floats, iarr2, farr2


def emit(dataset):
    out = []
    w = out.append
    unmapped = set()

    w("// Copyright 2026 The Raven Authors. All rights reserved.")
    w("// Use of this source code is governed by a BSD-style license.")
    w("//")
    w("// GENERATED FILE - DO NOT EDIT.")
    w("// Produced by third_party/.../webgl/gen_webgl_table.py from")
    w("// profile-db/webgl/webgl-gpu-params.json. Regenerate rather than editing.")
    w("//")
    w("// Self-contained persona GPU parameter table. GL enum values are inlined")
    w("// as hex (matching third_party/khronos/GLES2/gl2.h + GLES3/gl3.h) so this")
    w("// header pulls in no GL headers of its own.")
    w("")
    w("#ifndef " + GUARD)
    w("#define " + GUARD)
    w("")
    w("#include <cstddef>")
    w("#include <cstdint>")
    w("")
    w("namespace blink {")
    w("namespace webgl_persona {")
    w("namespace data {")
    w("")
    w("// pname is the GL enum (GLenum == uint32_t); typed value follows.")
    w("struct IntCap {")
    w("  uint32_t pname;")
    w("  int32_t value;")
    w("};")
    w("struct Int64Cap {")
    w("  uint32_t pname;")
    w("  int64_t value;")
    w("};")
    w("struct FloatCap {")
    w("  uint32_t pname;")
    w("  float value;")
    w("};")
    w("struct FloatArr2Cap {")
    w("  uint32_t pname;")
    w("  float v0;")
    w("  float v1;")
    w("};")
    w("struct IntArr2Cap {")
    w("  uint32_t pname;")
    w("  int32_t v0;")
    w("  int32_t v1;")
    w("};")
    w("")
    w("struct PersonaEntry {")
    w("  const char* key;                 // dataset key (diagnostics only)")
    w("  const char* os;                  // \"windows\" | \"macos\" | \"linux\"")
    w("  const char* renderer_substring;  // case-insensitive 'contains' match")
    w("  const char* unmasked_vendor;     // reference data / self-test")
    w("  const char* unmasked_renderer;   // reference data / self-test")
    w("  const char* gl_version_webgl1;")
    w("  const char* gl_version_webgl2;")
    w("  const char* glsl_version_webgl1;")
    w("  const char* glsl_version_webgl2;")
    w("  const IntCap* int_caps;")
    w("  size_t int_caps_count;")
    w("  const Int64Cap* int64_caps;")
    w("  size_t int64_caps_count;")
    w("  const FloatCap* float_caps;")
    w("  size_t float_caps_count;")
    w("  const FloatArr2Cap* float_arr2_caps;")
    w("  size_t float_arr2_caps_count;")
    w("  const IntArr2Cap* int_arr2_caps;")
    w("  size_t int_arr2_caps_count;")
    w("  bool has_float_precision;")
    w("  int32_t float_precision[3];      // FLOAT: [range_min, range_max, precision]")
    w("  const char* const* extensions1;")
    w("  size_t extensions1_count;")
    w("  const char* const* extensions2;")
    w("  size_t extensions2_count;")
    w("};")
    w("")

    keys = list(dataset.keys())

    # Per-entry static arrays.
    for key in keys:
        e = dataset[key]
        tag = ident(key)
        ints, i64s, floats, iarr2, farr2 = collect_caps(e, unmapped)

        w("// ---- {} ----".format(key))
        if ints:
            w("constexpr IntCap k_{}_int[] = {{".format(tag))
            for pname, value, name in ints:
                w("    {{0x{:04X}, {}}},  // {}".format(pname, value, name))
            w("};")
        if i64s:
            w("constexpr Int64Cap k_{}_int64[] = {{".format(tag))
            for pname, value, name in i64s:
                w("    {{0x{:04X}, {}}},  // {}".format(pname, cint64(value), name))
            w("};")
        if floats:
            w("constexpr FloatCap k_{}_float[] = {{".format(tag))
            for pname, value, name in floats:
                w("    {{0x{:04X}, {}}},  // {}".format(pname, cfloat(value), name))
            w("};")
        if farr2:
            w("constexpr FloatArr2Cap k_{}_farr2[] = {{".format(tag))
            for pname, value, name in farr2:
                w("    {{0x{:04X}, {}, {}}},  // {}".format(
                    pname, cfloat(value[0]), cfloat(value[1]), name))
            w("};")
        if iarr2:
            w("constexpr IntArr2Cap k_{}_iarr2[] = {{".format(tag))
            for pname, value, name in iarr2:
                w("    {{0x{:04X}, {}, {}}},  // {}".format(
                    pname, int(value[0]), int(value[1]), name))
            w("};")

        ext1 = e.get("extensions1", [])
        ext2 = e.get("extensions2", [])
        w("constexpr const char* k_{}_ext1[] = {{".format(tag))
        for x in ext1:
            w("    {},".format(cstr(x)))
        w("};")
        w("constexpr const char* k_{}_ext2[] = {{".format(tag))
        for x in ext2:
            w("    {},".format(cstr(x)))
        w("};")
        w("")

    # The table.
    w("constexpr PersonaEntry kPersonaTable[] = {")
    for key in keys:
        e = dataset[key]
        tag = ident(key)
        ints, i64s, floats, iarr2, farr2 = collect_caps(e, unmapped)
        match = e["match"]
        gl1 = e["glVersion"]
        glsl1 = e["glslVersion"]
        prec = e.get("precision", {}).get("FLOAT")

        def arr(name_suffix, present, count):
            if present:
                return "k_{}_{}".format(tag, name_suffix), str(count)
            return "nullptr", "0"

        int_ptr, int_cnt = arr("int", ints, len(ints))
        i64_ptr, i64_cnt = arr("int64", i64s, len(i64s))
        flt_ptr, flt_cnt = arr("float", floats, len(floats))
        farr2_ptr, farr2_cnt = arr("farr2", farr2, len(farr2))
        iarr2_ptr, iarr2_cnt = arr("iarr2", iarr2, len(iarr2))

        if prec:
            has_prec = "true"
            prec_init = "{{{}, {}, {}}}".format(int(prec[0]), int(prec[1]), int(prec[2]))
        else:
            has_prec = "false"
            prec_init = "{0, 0, 0}"

        w("    {")
        w("        /*key*/ {},".format(cstr(key)))
        w("        /*os*/ {},".format(cstr(match["os"])))
        w("        /*renderer_substring*/ {},".format(cstr(match["renderer_contains"])))
        w("        /*unmasked_vendor*/ {},".format(cstr(e["unmaskedVendor"])))
        w("        /*unmasked_renderer*/ {},".format(cstr(e["unmaskedRenderer"])))
        w("        /*gl_version_webgl1*/ {},".format(cstr(gl1)))
        w("        /*gl_version_webgl2*/ {},".format(cstr(derive_webgl2_gl_version(gl1))))
        w("        /*glsl_version_webgl1*/ {},".format(cstr(glsl1)))
        w("        /*glsl_version_webgl2*/ {},".format(cstr(derive_webgl2_glsl_version(glsl1))))
        w("        /*int_caps*/ {}, {},".format(int_ptr, int_cnt))
        w("        /*int64_caps*/ {}, {},".format(i64_ptr, i64_cnt))
        w("        /*float_caps*/ {}, {},".format(flt_ptr, flt_cnt))
        w("        /*float_arr2_caps*/ {}, {},".format(farr2_ptr, farr2_cnt))
        w("        /*int_arr2_caps*/ {}, {},".format(iarr2_ptr, iarr2_cnt))
        w("        /*has_float_precision*/ {},".format(has_prec))
        w("        /*float_precision*/ {},".format(prec_init))
        w("        /*extensions1*/ k_{}_ext1, {},".format(tag, len(e.get("extensions1", []))))
        w("        /*extensions2*/ k_{}_ext2, {},".format(tag, len(e.get("extensions2", []))))
        w("    },")
    w("};")
    w("")
    w("constexpr size_t kPersonaTableCount =")
    w("    sizeof(kPersonaTable) / sizeof(kPersonaTable[0]);")
    w("")
    w("}  // namespace data")
    w("}  // namespace webgl_persona")
    w("}  // namespace blink")
    w("")
    w("#endif  // " + GUARD)
    w("")

    return "\n".join(out), unmapped


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    default_json = "/Users/antonio/Projects/Raven-Chromium/profile-db/webgl/webgl-gpu-params.json"
    default_out = os.path.join(
        here, "tree", "third_party", "blink", "renderer", "modules", "webgl",
        "webgl_persona_params_data.h")

    ap = argparse.ArgumentParser(description="Emit persona WebGL param table header.")
    ap.add_argument("--json", default=default_json)
    ap.add_argument("--out", default=default_out)
    args = ap.parse_args()

    with open(args.json, "r", encoding="utf-8") as f:
        dataset = json.load(f)

    text, unmapped = emit(dataset)

    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    with open(args.out, "w", encoding="utf-8") as f:
        f.write(text)

    sys.stderr.write("wrote {} ({} entries)\n".format(args.out, len(dataset)))
    if unmapped:
        sys.stderr.write("UNMAPPED CAP NAMES (no GLenum): {}\n".format(
            ", ".join(sorted(unmapped))))
    else:
        sys.stderr.write("all cap names mapped to a GLenum\n")


if __name__ == "__main__":
    main()
