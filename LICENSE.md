# MIT License

Copyright (c) 2026 Sebastiano Demichelis

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

## Third-party notices

Peek3D bundles or depends on the following open-source software. All are
permissively licensed and compatible with the MIT license above. This list
reflects what is actually compiled into the distributed binary (verified
with `nm`/`strings` on `GLTFKit2.framework` in a Release build), not just
what Peek3D's own Swift code calls directly — attribution obligations for
MIT/Apache-2.0/BSD-3-Clause are triggered by distribution, regardless of
which code paths this app exercises at runtime. Full texts (not summaries)
are also shown in-app under **Peek3D ▸ Licenze open source…**.

- **[GLTFKit2](https://github.com/warrenm/GLTFKit2)** by Warren Moore — MIT.
  Loads `.glb`/`.gltf`. Statically links three further dependencies, all
  confirmed present in the shipped `GLTFKit2.framework` binary:
  - **[cgltf](https://github.com/jkuhlmann/cgltf)** by Johannes Kuhlmann — MIT.
  - **[KTX-Software (libktx)](https://github.com/KhronosGroup/KTX-Software)**
    by The Khronos Group Inc. — Apache License 2.0. Compiled into the
    binary regardless of whether Peek3D's own code reads KTX2 textures —
    the Apache 2.0 obligation attaches to distributing the compiled code,
    not to exercising it.
  - **[Basis Universal](https://github.com/BinomialLLC/basis_universal)**
    by Binomial LLC — Apache License 2.0. Vendored inside libktx as the
    transcoder for KTX2's supercompressed texture format; ~1000 of its
    symbols are present in the shipped binary.
  - **[Zstandard](https://github.com/facebook/zstd)** by Meta Platforms,
    Inc. and affiliates — BSD 3-Clause License. Vendored inside libktx for
    KTX2 Zstd supercompression; its full compressor/decompressor is
    present in the shipped binary.
  - **Draco is *not* included here.** GLTFKit2 recognizes the
    `KHR_draco_mesh_compression` glTF extension and exposes a
    `dracoDecompressorClassName` hook so a host app can register an
    external decoder class — but no actual Draco decoder code is compiled
    into `GLTFKit2.framework` (confirmed: zero `draco::` symbols in the
    binary), and Peek3D never registers one. No Draco code is distributed,
    so no Draco attribution applies. Re-check this if GLTFKit2 or Peek3D
    ever start bundling a real Draco decoder.
- **[ufbx](https://github.com/ufbx/ufbx)** by Samuli Raivio — MIT / Unlicense
  (dual-licensed, vendored under `Peek3D/ThirdParty/ufbx`). Loads `.fbx`.

Full license texts are included with each dependency's source, and are
reproduced in full in the app's **Licenze open source…** window
(`Peek3D/OpenSourceLicensesView.swift`).
