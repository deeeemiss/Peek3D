#!/usr/bin/env python3
"""Builds valid/ktx2_cube.glb: a unit cube whose two halves use KTX2 textures
of the two Basis Universal flavours (KHR_texture_basisu, no PNG/JPEG fallback).

    make_ktx2_fixture.py UASTC.ktx2 ETC1S.ktx2 OUT.glb

The cube is original work (CC0). The textures are not made here: a UASTC + Zstd
supercompressed 256x256 carbon-fibre pattern and a BasisLZ (ETC1S) 2048x2048
map, both from the glTF Sample Asset ChronographWatch (see README.md for the
credit). Only the mesh and the glTF wrapper are generated.
"""
import json, struct, sys

# (normal, u axis, v axis): each face is centred on the cube and spans -.5..+.5
FACES = [
    ((1, 0, 0), (0, 0, -1), (0, 1, 0)),
    ((0, 1, 0), (1, 0, 0), (0, 0, -1)),
    ((0, 0, 1), (1, 0, 0), (0, 1, 0)),
    ((-1, 0, 0), (0, 0, 1), (0, 1, 0)),
    ((0, -1, 0), (1, 0, 0), (0, 0, 1)),
    ((0, 0, -1), (-1, 0, 0), (0, 1, 0)),
]


def face(n, u, v):
    corners = [(-1, -1), (1, -1), (1, 1), (-1, 1)]
    pos = [tuple(.5 * n[i] + .5 * a * u[i] + .5 * b * v[i] for i in range(3)) for a, b in corners]
    uv = [((a + 1) / 2, 1 - (b + 1) / 2) for a, b in corners]
    return pos, [n] * 4, uv


def main(uastc, etc1s, out):
    blobs, views, accessors, primitives = [], [], [], []

    def add(data, target=None):
        pad = -sum(map(len, blobs)) % 4
        if pad:
            blobs.append(b"\0" * pad)
        view = {"buffer": 0, "byteOffset": sum(map(len, blobs)), "byteLength": len(data)}
        if target:
            view["target"] = target
        views.append(view)
        blobs.append(data)
        return len(views) - 1

    def accessor(values, fmt, kind, target, component=5126, bounds=False):
        data = b"".join(struct.pack(fmt, *v) if isinstance(v, tuple) else struct.pack(fmt, v) for v in values)
        a = {"bufferView": add(data, target), "componentType": component, "count": len(values), "type": kind}
        if bounds:
            a["min"] = [min(p[i] for p in values) for i in range(3)]
            a["max"] = [max(p[i] for p in values) for i in range(3)]
        accessors.append(a)
        return len(accessors) - 1

    for half, faces in enumerate((range(0, 3), range(3, 6))):
        pos, nrm, uvs, idx = [], [], [], []
        for k, f in enumerate(faces):
            p, n, t = face(*FACES[f])
            idx += [4 * k + i for i in (0, 1, 2, 0, 2, 3)]
            pos += p
            nrm += n
            uvs += t
        primitives.append({
            "attributes": {"POSITION": accessor(pos, "<3f", "VEC3", 34962, bounds=True),
                           "NORMAL": accessor(nrm, "<3f", "VEC3", 34962),
                           "TEXCOORD_0": accessor(uvs, "<2f", "VEC2", 34962)},
            "indices": accessor(idx, "<H", "SCALAR", 34963, component=5123),
            "material": half, "mode": 4})

    images = [{"bufferView": add(open(path, "rb").read()), "mimeType": "image/ktx2"} for path in (uastc, etc1s)]

    def material(name, texture):
        return {"name": name, "pbrMetallicRoughness": {"baseColorTexture": {"index": texture},
                                                       "metallicFactor": 0, "roughnessFactor": .8}}

    doc = {
        "asset": {"version": "2.0", "generator": "make_ktx2_fixture.py",
                  "copyright": "Mesh: made for Peek3D (CC0 1.0). Textures: see tests/fixtures/README.md"},
        "extensionsUsed": ["KHR_texture_basisu"], "extensionsRequired": ["KHR_texture_basisu"],
        "scene": 0, "scenes": [{"nodes": [0]}], "nodes": [{"mesh": 0, "name": "KTX2 cube"}],
        "meshes": [{"primitives": primitives}],
        "materials": [material("UASTC + Zstd", 0), material("ETC1S (BasisLZ)", 1)],
        "textures": [{"sampler": 0, "extensions": {"KHR_texture_basisu": {"source": i}}} for i in range(2)],
        "images": images,
        "samplers": [{"magFilter": 9729, "minFilter": 9987, "wrapS": 10497, "wrapT": 10497}],
        "accessors": accessors, "bufferViews": views,
    }
    binary = b"".join(blobs)
    binary += b"\0" * (-len(binary) % 4)
    doc["buffers"] = [{"byteLength": len(binary)}]
    js = json.dumps(doc, separators=(",", ":")).encode()
    js += b" " * (-len(js) % 4)
    json_chunk = struct.pack("<I4s", len(js), b"JSON") + js
    bin_chunk = struct.pack("<I4s", len(binary), b"BIN\0") + binary
    total = 12 + len(json_chunk) + len(bin_chunk)
    open(out, "wb").write(struct.pack("<4sII", b"glTF", 2, total) + json_chunk + bin_chunk)


if __name__ == "__main__":
    main(*sys.argv[1:4])
