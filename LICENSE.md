MIT License

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

---

## Third-party notices

Peek3D bundles or depends on the following open-source software. All are
permissively licensed and compatible with the MIT license above.

- **[GLTFKit2](https://github.com/warrenm/GLTFKit2)** by Warren Moore — MIT.
  Loads `.glb`/`.gltf`. Vendors two further dependencies:
  - **[cgltf](https://github.com/jkuhlmann/cgltf)** by Johannes Kuhlmann — MIT.
  - **[KTX-Software](https://github.com/KhronosGroup/KTX-Software)** by The
    Khronos Group — Apache License 2.0 (unused in Peek3D: KTX2 textures are
    not wired up, see README § Known limits).
- **[ufbx](https://github.com/ufbx/ufbx)** by Samuli Raivio — MIT / Unlicense
  (dual-licensed, vendored under `Peek3D/ThirdParty/ufbx`). Loads `.fbx`.

Full license texts are included with each dependency's source.
