#!/usr/bin/env python3
"""Loader regression tests for Peek3D. Runs the Debug app's self-test hooks.

    scripts/test.py                  build, then fixtures + FBX deformation + Draco/KTX2 + recovery + 150 fuzz cases per GLB
    scripts/test.py --fuzz all       every mutation (thousands of runs, minutes)
    scripts/test.py --fuzz 0         no fuzzing
    scripts/test.py --app PATH       test an already built app (e.g. an old commit)

Fixtures have explicit expectations and are the actual test:
  testmodels/*, tests/fixtures/valid/*   must load
  tests/fixtures/invalid/*               must fail with a clean error
Fuzzing mutates the numbers in each valid GLB's JSON, and the compressed
bytes (flipped, cut short) of each valid GLB that uses Draco. A mutated file
may really be invalid, so a rejection is just a statistic; only a crash or a
hang fails the run. Failing mutations are saved in build/test/failures/.
"""
import argparse, json, os, platform, random, struct, subprocess, sys, tempfile, zlib
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BUILD = ROOT / "build" / "test"
FIXTURES = ROOT / "tests" / "fixtures"
MODEL_EXTS = {".glb", ".gltf", ".obj", ".stl", ".fbx", ".usd", ".usdz", ".usda", ".usdc", ".dae", ".ply", ".abc"}
TIMEOUT = 20


def build():
    # Unsigned: no sandbox, so the app can read fixtures where they are.
    # The system PATH avoids non-Apple unzip/tar breaking package resolution.
    env = dict(os.environ, PATH="/usr/bin:/bin:/usr/sbin:/sbin")
    subprocess.run(["xcodebuild", "-project", "Peek3D.xcodeproj", "-scheme", "Peek3D",
                    "-configuration", "Debug", "-destination", f"platform=macOS,arch={platform.machine()}",
                    "-derivedDataPath", str(BUILD), "CODE_SIGNING_ALLOWED=NO", "-quiet", "build"],
                   cwd=ROOT, env=env, check=True)
    return BUILD / "Build/Products/Debug/Peek3D.app/Contents/MacOS/Peek3D"


def run(app, env):
    """('loaded' | 'rejected' | 'crash' | 'hang', stdout)"""
    try:
        p = subprocess.run([str(app)], env=dict(os.environ, **env), capture_output=True,
                           text=True, errors="replace", timeout=TIMEOUT)
    except subprocess.TimeoutExpired:
        return "hang", ""
    if p.returncode == 0 and ("SELFTEST_OK" in p.stdout or "SEQUENCE_DONE" in p.stdout):
        return "loaded", p.stdout
    if p.returncode == 1 and "SELFTEST_FAIL" in p.stdout:
        return "rejected", p.stdout
    return "crash", p.stdout + f"\n(exit {p.returncode})"


def models(folder):
    return sorted(f for f in folder.iterdir() if f.suffix.lower() in MODEL_EXTS) if folder.is_dir() else []


def check_fixtures(app, pool):
    valid = models(ROOT / "testmodels") + models(FIXTURES / "valid")
    invalid = models(FIXTURES / "invalid")
    cases = [(f, "loaded") for f in valid] + [(f, "rejected") for f in invalid]
    failures = []
    for (f, want), (got, out) in zip(cases, pool.map(lambda c: run(app, {"PEEK3D_SELFTEST": str(c[0])}), cases)):
        if got != want:
            failures.append(f"{f.relative_to(ROOT)}: expected {want}, got {got}\n    " + out.strip().replace("\n", "\n    "))
    print(f"fixtures: {len(valid)} valid, {len(invalid)} invalid, {len(failures)} wrong")
    return failures


def check_deformation(app, pool):
    """Skinned / blend-shape FBX fixtures must visibly deform, not just load.

    The app's own self-test renders them (bind pose vs mid-clip vs a control
    with the deformer removed) and compares pixels; see verifyDeformation in
    SelfTest.swift. The PNGs it writes land in build/test/deform/."""
    fixtures = [FIXTURES / "valid" / "skinned_bend.fbx", FIXTURES / "valid" / "morph_cube.fbx"]
    out_dir = BUILD / "deform"
    out_dir.mkdir(parents=True, exist_ok=True)
    results = pool.map(lambda f: run(app, {"PEEK3D_SELFTEST": str(f),
                                           "PEEK3D_SELFTEST_DEFORM": str(out_dir / (f.stem + ".png"))}), fixtures)
    failures = []
    for f, (got, out) in zip(fixtures, results):
        if got != "loaded" or "DEFORM_OK" not in out:
            failures.append(f"deformation {f.relative_to(ROOT)}: {got}\n    "
                            + "\n    ".join(l for l in out.splitlines() if "DEFORM" in l or "SELFTEST" in l))
    print(f"deformation: {len(fixtures)} fixtures, {len(failures)} wrong")
    return failures


def png_pixels(path):
    """[(r, g, b, a), ...] of an 8-bit RGB/RGBA PNG, without dependencies."""
    data = path.read_bytes()
    pos, idat, header = 8, b"", None
    while pos < len(data):
        length, kind = struct.unpack_from(">I4s", data, pos)
        body = data[pos + 8:pos + 8 + length]
        if kind == b"IHDR":
            header = struct.unpack(">IIBBBBB", body)
        elif kind == b"IDAT":
            idat += body
        pos += 12 + length
    width, height, depth, color, _, _, interlace = header
    channels = {2: 3, 6: 4}[color]
    assert depth == 8 and interlace == 0
    raw, stride, prev, pixels = zlib.decompress(idat), width * channels, bytearray(width * channels), []
    for y in range(height):
        base = y * (stride + 1)
        kind, line = raw[base], bytearray(raw[base + 1:base + 1 + stride])
        for i in range(stride):
            a = line[i - channels] if i >= channels else 0
            b = prev[i]
            c = prev[i - channels] if i >= channels else 0
            if kind == 1:
                line[i] = (line[i] + a) & 255
            elif kind == 2:
                line[i] = (line[i] + b) & 255
            elif kind == 3:
                line[i] = (line[i] + (a + b) // 2) & 255
            elif kind == 4:
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                line[i] = (line[i] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
        prev = line
        pixels += [tuple(line[x * channels:x * channels + 3]) + ((line[x * channels + 3],) if channels == 4 else (255,))
                   for x in range(width)]
    return pixels


def check_compressed(app, pool):
    """Draco geometry and KTX2/BasisU textures must decode AND show up on screen.

    Each fixture is loaded and rendered offscreen by the app's own self-test.
    Draco: the triangle/vertex counts of the uncompressed original, and the
    model's colour on screen. KTX2: a textured cube, so many distinct colours
    and neither black (texture failed to decode) nor magenta (SceneKit's
    placeholder for a texture it can't use)."""
    out_dir = BUILD / "compressed"
    out_dir.mkdir(parents=True, exist_ok=True)
    cases = [  # fixture, triangles, vertices, what it shows
        ("Box-Draco.glb", 12, 24, "a red box"),
        ("RiggedSimple-Draco.glb", 188, 160, "a green rig"),
        ("ktx2_cube.glb", 12, 24, "a textured cube"),
    ]

    def one(case):
        f = FIXTURES / "valid" / case[0]
        return run(app, {"PEEK3D_SELFTEST": str(f), "PEEK3D_SELFTEST_RENDER": str(out_dir / (f.stem + ".png"))})

    failures = []
    for (name, tris, verts, what), (got, out) in zip(cases, pool.map(one, cases)):
        fields = dict(line.split(": ", 1) for line in out.splitlines() if ": " in line)
        problem = None
        if got != "loaded":
            problem = got
        elif (fields.get("triangles"), fields.get("vertices")) != (str(tris), str(verts)):
            problem = f"{fields.get('triangles')} triangles / {fields.get('vertices')} vertices, expected {tris} / {verts}"
        else:
            pixels = png_pixels(out_dir / (Path(name).stem + ".png"))
            body = [p for p in pixels if p[3] > 128]  # the model; the background is transparent
            if name.startswith("Box"):
                ok = sum(r > 150 and g < 80 and b < 80 for r, g, b, _ in body) > 20000
            elif name.startswith("Rigged"):
                ok = sum(g > r + 25 and g > b + 25 for r, g, b, _ in body) > 5000
            else:
                black = sum(max(p[:3]) < 25 for p in body)
                magenta = sum(p[0] > 200 and p[1] < 60 and p[2] > 200 for p in body)
                ok = len(body) > 40000 and len(set(body)) > 1500 and black < len(body) // 20 and magenta < len(body) // 20
            if not ok:
                problem = f"does not show {what} ({len(body)} model pixels, {len(set(body))} colours)"
        if problem:
            failures.append(f"compressed {name}: {problem}")
    print(f"compressed: {len(cases)} fixtures, {len(failures)} wrong")
    return failures


def check_recovery(app, pool):
    """A window must end up showing the last good file, not a stale one."""
    t = ROOT / "testmodels"
    bad = FIXTURES / "invalid" / "garbage.glb"
    cases = [
        ("valid → bad → other valid", [t / "Box.glb", bad, t / "Fox.glb"], False, ("Fox.glb", 576, False)),
        ("valid → bad keeps the model", [t / "Box.glb", bad], False, ("Box.glb", 12, True)),
        ("rapid drops: last one wins", [t / "Fox.glb", t / "Box.glb"], True, ("Box.glb", 12, False)),
        ("rapid drops ending on a bad file", [t / "Box.glb", bad], True, ("none", 0, True)),
    ]

    def one(case):
        _, files, rapid, _ = case
        env = {"PEEK3D_SELFTEST_SEQUENCE": "|".join(map(str, files))}
        if rapid:
            env["PEEK3D_SELFTEST_RAPID"] = "1"
        return run(app, env)

    failures = []
    for (name, _, _, (shown, tris, has_error)), (got, out) in zip(cases, pool.map(one, cases)):
        fields = dict(line.split(": ", 1) for line in out.splitlines() if ": " in line)
        actual = (fields.get("shown"), int(fields.get("triangles", -1)), fields.get("error", "none") != "none")
        if got != "loaded" or actual != (shown, tris, has_error):
            failures.append(f"recovery '{name}': expected {(shown, tris, has_error)}, got {got} {actual}")
    print(f"recovery: {len(cases)} sequences, {len(failures)} wrong")
    return failures


# -- Fuzzing ---------------------------------------------------------------

SECTIONS = ["accessors", "bufferViews", "buffers", "nodes", "meshes", "skins", "animations",
            "images", "textures", "samplers", "scenes", "materials"]
NASTY = [-1, 0, 1, 3, 255, 2**31 - 1, 2**32 + 1, 1e30]


def read_glb(path):
    data = path.read_bytes()
    json_len = struct.unpack_from("<I", data, 12)[0]
    return json.loads(data[20:20 + json_len]), data[20 + json_len:]


def write_glb(doc, rest, path):
    body = json.dumps(doc).encode()
    body += b" " * (-len(body) % 4)
    chunk = struct.pack("<I4s", len(body), b"JSON") + body
    path.write_bytes(struct.pack("<4sII", b"glTF", 2, 12 + len(chunk) + len(rest)) + chunk + rest)


def number_paths(node, path=()):
    if isinstance(node, bool):
        return
    if isinstance(node, (int, float)):
        yield path
    elif isinstance(node, dict):
        for k, v in node.items():
            yield from number_paths(v, path + (k,))
    elif isinstance(node, list):
        for i, v in enumerate(node):
            yield from number_paths(v, path + (i,))


def set_path(doc, path, value):
    for key in path[:-1]:
        doc = doc[key]
    doc[path[-1]] = value


def fuzz(app, pool, limit):
    sources = [f for f in models(ROOT / "testmodels") + models(FIXTURES / "valid") if f.suffix == ".glb"]
    failures = []
    out_dir = BUILD / "failures"
    with tempfile.TemporaryDirectory() as tmp:
        for src in sources:
            doc, rest = read_glb(src)
            jobs = [(p, v) for s in SECTIONS for p in number_paths(doc.get(s, []), (s,)) for v in NASTY]
            if limit != "all" and len(jobs) > int(limit):
                jobs = random.Random(src.name).sample(jobs, int(limit))  # same sample on every run

            def one(numbered):
                n, job = numbered
                mutated = json.loads(json.dumps(doc))
                set_path(mutated, *job)
                f = Path(tmp) / f"{src.stem}-{n}.glb"
                write_glb(mutated, rest, f)
                result = run(app, {"PEEK3D_SELFTEST": str(f)})[0]
                if result in ("crash", "hang"):
                    out_dir.mkdir(parents=True, exist_ok=True)
                    f.replace(out_dir / f.name)
                    return result, job, out_dir / f.name
                f.unlink()
                return result, job, None

            results = list(pool.map(one, enumerate(jobs)))
            counts = {k: sum(r[0] == k for r in results) for k in ("loaded", "rejected", "crash", "hang")}
            print(f"fuzz {src.name}: {len(jobs)} mutations, " + ", ".join(f"{v} {k}" for k, v in counts.items()))
            failures += [f"fuzz {src.name}: {r} with {'/'.join(map(str, p))} = {v} -> {f.relative_to(ROOT)}"
                         for r, (p, v), f in results if f]
    return failures


def fuzz_draco(app, pool, limit):
    """Damage the compressed bytes themselves: flip a few, cut the stream short,
    or both. The JSON stays valid, so the glTF validator lets these through and
    the Draco decoder is the one that has to cope."""
    sources = [f for f in models(FIXTURES / "valid") if f.suffix == ".glb" and "KHR_draco_mesh_compression" in read_glb(f)[0].get("extensionsUsed", [])]
    failures = []
    out_dir = BUILD / "failures"
    count = 1500 if limit == "all" else int(limit)
    with tempfile.TemporaryDirectory() as tmp:
        for src in sources:
            doc, rest = read_glb(src)
            draco_views = sorted({p["extensions"]["KHR_draco_mesh_compression"]["bufferView"]
                                  for m in doc["meshes"] for p in m["primitives"]
                                  if "KHR_draco_mesh_compression" in p.get("extensions", {})})

            def one(n):
                rng = random.Random(f"{src.name}-{n}")
                mutated, binary = json.loads(json.dumps(doc)), bytearray(rest)
                for index in draco_views:
                    view = mutated["bufferViews"][index]
                    first = 8 + view.get("byteOffset", 0)  # past the BIN chunk header
                    if rng.random() < 0.7:
                        for _ in range(rng.choice([1, 1, 2, 4, 8])):
                            binary[first + rng.randrange(view["byteLength"])] = rng.randrange(256)
                    if rng.random() < 0.4:
                        view["byteLength"] = rng.randrange(1, view["byteLength"] + 1)
                f = Path(tmp) / f"{src.stem}-draco-{n}.glb"
                write_glb(mutated, bytes(binary), f)
                result = run(app, {"PEEK3D_SELFTEST": str(f)})[0]
                if result in ("crash", "hang"):
                    out_dir.mkdir(parents=True, exist_ok=True)
                    f.replace(out_dir / f.name)
                    return result, out_dir / f.name
                f.unlink()
                return result, None

            results = list(pool.map(one, range(count)))
            counts = {k: sum(r[0] == k for r in results) for k in ("loaded", "rejected", "crash", "hang")}
            print(f"fuzz-draco {src.name}: {count} mutations, " + ", ".join(f"{v} {k}" for k, v in counts.items()))
            failures += [f"fuzz-draco {src.name}: {r} -> {f.relative_to(ROOT)}" for r, f in results if f]
    return failures


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--app", type=Path, help="app binary to test instead of building one")
    ap.add_argument("--fuzz", default="150", help="mutations per GLB: a number, 'all' or 0")
    args = ap.parse_args()
    app = args.app or build()

    with ThreadPoolExecutor(max_workers=os.cpu_count()) as pool:
        failures = (check_fixtures(app, pool) + check_deformation(app, pool) + check_compressed(app, pool)
                    + check_recovery(app, pool))
        if args.fuzz != "0":
            failures += fuzz(app, pool, args.fuzz) + fuzz_draco(app, pool, args.fuzz)

    for f in failures:
        print("FAIL " + f)
    print("OK" if not failures else f"{len(failures)} failure(s)")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
