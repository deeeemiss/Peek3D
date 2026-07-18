# TODO — Supporto formato FBX

Stato: pianificato, non ancora iniziato. Branch dedicato: `feature/fbx-support`.

## Perché

FBX è il formato più richiesto tra quelli non ancora supportati: standard
de-facto per modelli esportati da Maya, 3ds Max, Blender, e per asset
scaricati da marketplace (Sketchfab, TurboSquid). Attualmente GLBViewer apre
solo: `glb`, `gltf`, `obj`, `stl`, `usd`, `usdz`, `usda`, `usdc`, `dae`, `ply`,
`abc` (vedi `ModelLoader.supportedExtensions`).

## Perché manca

FBX è un formato proprietario Autodesk. Model I/O di Apple non lo legge
nativamente, GLTFKit2 legge solo glTF. Serve una libreria terza.

## Approccio proposto

- Integrare **Assimp** (open source, C++) come terzo backend di parsing,
  accanto a GLTFKit2 e Model I/O.
- Serve un layer-ponte Objective-C++/C tra Assimp e Swift (non un semplice
  `import` SPM).
- Convertire l'output di Assimp (mesh, materiali, scheletro/animazioni) nella
  stessa struttura `SCNScene` già usata dagli altri due loader, così il resto
  dell'app (viewer, wireframe, shading, animazioni) non deve sapere da dove
  viene il modello.

## Insidie note

- Scheletri/animazioni FBX modellati diversamente da glTF — serve mappatura
  attenta per non rompere il player esistente.
- Texture: possono essere embedded nel file o referenziate come file esterni
  — entrambi i casi vanno gestiti.
- Unità di misura: FBX non ha un'unità fissa (cm vs m più comuni) — senza
  compensazione i modelli importati possono apparire enormi o minuscoli.

## Scope stimato

Nuova dipendenza esterna (C++) + nuovo dominio (parsing binario) + modifiche
a loader, conversione scena, probabilmente UI di caricamento (estensioni
supportate, messaggi di errore). Da pianificare con `@tech-lead-orchestrator`
quando si parte, non un fix isolato.
