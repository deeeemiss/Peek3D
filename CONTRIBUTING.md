# Contributing to Peek3D

Thanks for wanting to help. Peek3D is a small, focused app — a fast native
viewer for 3D files, nothing more — so the best contributions keep it that way.

## Build and run

You need Xcode (free on the Mac App Store). No Apple certificate or developer
account is required.

```sh
git clone https://github.com/deeeemiss/Peek3D.git
cd Peek3D
./scripts/run.sh
```

The script builds a universal Release app into `build/` and opens it. You can
also open `Peek3D.xcodeproj` in Xcode and hit Run.

## Reporting a bug

Open an issue with:

- what you did, what you expected, and what happened instead;
- your macOS version and Mac model (Apple silicon or Intel);
- if a file won't open or looks wrong, the file itself (or a link to it) —
  most bugs in a 3D viewer are specific to one file.

## Suggesting a feature

Open an issue first and describe the problem you want to solve. Peek3D is a
**viewer**: editing, exporting and format conversion are deliberately out of
scope.

## Pull requests

- One change per pull request, with a short description of what and why.
- Build with `./scripts/run.sh` and try the change on a few real files
  (`testmodels/` has some) before opening the PR.
- Match the surrounding code: SwiftUI + SceneKit, `simd` types over
  `SCNVector3`, comments that explain *why*.
- User-facing text goes through the String Catalog
  (`Peek3D/Localizable.xcstrings`). English is the source language; leave other
  languages untranslated if you don't speak them, a maintainer will fill them in.

## Translations

Peek3D ships in 11 languages. If you're a native speaker and spot an awkward or
wrong translation, an issue or a PR against `Localizable.xcstrings` is very
welcome — especially for Arabic, Japanese, Korean, Chinese and Russian.

## License

By contributing, you agree that your contributions are licensed under the
[MIT License](LICENSE.md).
