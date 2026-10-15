#!/usr/bin/env python3
"""Regenerates the Draco / KTX2 files in invalid/ from valid/Box-Draco.glb,
valid/RiggedSimple-Draco.glb and valid/ktx2_cube.glb. Each one must be refused
with a normal error.

    make_invalid_fixtures.py        (run from anywhere)

Three groups: files whose compressed stream is damaged (the decoder has to say
no), files whose glTF around a good stream is wrong (the validator has to say
no, before GLTFKit2 would build anything out of it), and a texture reference
that crashed GLTFKit2 before the validator checked it.
"""
import json, random, struct
from pathlib import Path

HERE = Path(__file__).resolve().parent
VALID, INVALID = HERE / "valid", HERE / "invalid"


def read(path):
    data = path.read_bytes()
    json_len = struct.unpack_from("<I", data, 12)[0]
    return json.loads(data[20:20 + json_len]), bytearray(data[20 + json_len + 8:])


def write(doc, binary, path):
    body = json.dumps(doc, separators=(",", ":")).encode()
    body += b" " * (-len(body) % 4)
    json_chunk = struct.pack("<I4s", len(body), b"JSON") + body
    bin_chunk = struct.pack("<I4s", len(binary), b"BIN\0") + bytes(binary)
    path.write_bytes(struct.pack("<4sII", b"glTF", 2, 12 + len(json_chunk) + len(bin_chunk)) + json_chunk + bin_chunk)


def draco_of(doc):
    """(primitive, extension, bufferView) of the first Draco primitive."""
    primitive = doc["meshes"][0]["primitives"][0]
    extension = primitive["extensions"]["KHR_draco_mesh_compression"]
    return primitive, extension, doc["bufferViews"][extension["bufferView"]]


def variant(source, name, change):
    doc, binary = read(VALID / source)
    change(doc, binary)
    write(doc, binary, INVALID / name)


def truncated(doc, binary):
    _, _, view = draco_of(doc)
    view["byteLength"] //= 2  # the stream ends mid-way; the view is still inside the buffer


def magic(doc, binary):
    _, _, view = draco_of(doc)
    binary[view["byteOffset"]:view["byteOffset"] + 5] = b"DRAKO"


def garbage(seed):
    def change(doc, binary):
        _, _, view = draco_of(doc)
        rng = random.Random(seed)
        start = view["byteOffset"] + 11  # keep the header: the damage is in the body
        for i in range(start, view["byteOffset"] + view["byteLength"]):
            binary[i] = rng.randrange(256)
    return change


def unknown_attribute(doc, binary):
    _, extension, _ = draco_of(doc)
    # The stream has two attributes (ids 0 and 1). The id has to stay below the
    # accessor count, or GLTFKit2's own parser refuses the file first.
    extension["attributes"]["POSITION"] = 2


def no_indices(doc, binary):
    primitive, _, _ = draco_of(doc)
    del primitive["indices"]


def strip_mode(doc, binary):
    primitive, _, _ = draco_of(doc)
    primitive["mode"] = 5


def extra_attribute(doc, binary):
    primitive, extension, _ = draco_of(doc)
    primitive["attributes"]["TEXCOORD_0"] = primitive["attributes"]["POSITION"]
    assert "TEXCOORD_0" not in extension["attributes"]


def basisu_source(doc, binary):
    """KHR_texture_basisu naming image -1: found by fuzzing, crashed GLTFKit2.

    The two images are cut down to four bytes each so the file stays tiny; the
    crash comes before anything reads them."""
    doc["textures"][1]["extensions"]["KHR_texture_basisu"]["source"] = -1
    first = min(doc["bufferViews"][image["bufferView"]]["byteOffset"] for image in doc["images"])
    for image in doc["images"]:
        view = doc["bufferViews"][image["bufferView"]]
        view["byteOffset"], view["byteLength"] = first, 4
    del binary[first + 4:]
    doc["buffers"][0]["byteLength"] = len(binary)


def main():
    variant("Box-Draco.glb", "Box-Draco-stream-truncated.glb", truncated)
    variant("Box-Draco.glb", "Box-Draco-stream-magic.glb", magic)
    variant("RiggedSimple-Draco.glb", "RiggedSimple-Draco-stream-garbage.glb", garbage(7))
    variant("Box-Draco.glb", "Box-Draco-attribute-unknown-id.glb", unknown_attribute)
    variant("Box-Draco.glb", "Box-Draco-indices-removed.glb", no_indices)
    variant("Box-Draco.glb", "Box-Draco-mode-strip.glb", strip_mode)
    variant("Box-Draco.glb", "Box-Draco-attribute-not-compressed.glb", extra_attribute)
    variant("ktx2_cube.glb", "ktx2_cube-textures-basisu-source-crash.glb", basisu_source)


if __name__ == "__main__":
    main()
