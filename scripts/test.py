#!/usr/bin/env python3
"""Loader regression tests for Peek3D. Runs the Debug app's self-test hooks.

    scripts/test.py                  build, then fixtures + FBX deformation + recovery + 150 fuzz cases per GLB
    scripts/test.py --fuzz all       every mutation (thousands of runs, minutes)
    scripts/test.py --fuzz 0         no fuzzing
    scripts/test.py --app PATH       test an already built app (e.g. an old commit)

Fixtures have explicit expectations and are the actual test:
  testmodels/*, tests/fixtures/valid/*   must load
  tests/fixtures/invalid/*               must fail with a clean error
Fuzzing mutates the numbers in each valid GLB's JSON. A mutated file may
really be invalid, so a rejection is just a statistic; only a crash or a
hang fails the run. Failing mutations are saved in build/test/failures/.
"""
import argparse, json, os, platform, random, struct, subprocess, sys, tempfile
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


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--app", type=Path, help="app binary to test instead of building one")
    ap.add_argument("--fuzz", default="150", help="mutations per GLB: a number, 'all' or 0")
    args = ap.parse_args()
    app = args.app or build()

    with ThreadPoolExecutor(max_workers=os.cpu_count()) as pool:
        failures = check_fixtures(app, pool) + check_deformation(app, pool) + check_recovery(app, pool)
        if args.fuzz != "0":
            failures += fuzz(app, pool, args.fuzz)

    for f in failures:
        print("FAIL " + f)
    print("OK" if not failures else f"{len(failures)} failure(s)")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
