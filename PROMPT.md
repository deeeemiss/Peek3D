# Peek3D — brief per Claude Code

## Obiettivo

App macOS **nativa** (Swift + SwiftUI + SceneKit), **open source**, con
un solo scopo: **visualizzare** file 3D — non editing, non conversione,
non export in altri formati. UI minimale, dark, stile "tool professionale",
vedi `reference-ui.png` allegato (screenshot di un viewer online simile a
quello che voglio, per stile/layout — non per stack tecnico, quello è
mio qui sotto).

Nome progetto: **Peek3D**.

## Formati da supportare

- **Primari**: `.glb`, `.gltf` → via **GLTFKit2**
  (`https://github.com/warrenm/GLTFKit2`, MIT license, aggiungibile via
  Swift Package Manager con `File → Add Package Dependencies`, URL del
  repo — ha un `Package.swift` proprio, non serve compilare framework a
  mano). Bridging diretto a SceneKit: `SCNScene(gltfAsset:)` dopo aver
  caricato l'asset con `GLTFAsset.load(with:options:completion:)`.
- **Secondari**: `.obj`, `.stl`, `.usd`, `.usdz`, `.usda`, `.usdc`, `.dae`
  → via **Model I/O** (framework nativo Apple, nessuna dipendenza
  esterna): `MDLAsset(url:)` → `SCNScene(mdlAsset:)`.

Entrambi i path devono convergere in un `SCNScene` unico, così il resto
dell'app (camera, UI, stats) non deve sapere da dove viene il modello.

## Funzionalità (v1, scope volutamente stretto)

- Drag & drop del file nella finestra (sia a finestra vuota che con un
  modello già caricato, per sostituirlo)
- File picker alternativo al drag&drop
- Camera orbit/pan/zoom (va benissimo `SCNView.allowsCameraControl = true`
  come base, poi migliorabile)
- Bottone "fit to view" che inquadra automaticamente il modello caricato
- Toggle wireframe
- Toggle griglia di riferimento a terra
- Screenshot della viewport (salvataggio PNG via `NSSavePanel`)
- Fullscreen toggle
- Pannello info con: numero triangoli, numero vertici, numero mesh,
  numero materiali, dimensioni bounding box, dimensione file, nome file
- Piccolo gizmo assi XYZ colorato (rosso/verde/blu) che ruota in sync con
  l'orientamento della camera principale, angolo in basso a destra

**Non fare in v1**: editing della scena, timeline animazioni, export/
conversione tra formati, supporto multi-file/tab, texture editing.

## Vincoli tecnici

- Deployment target: **macOS 13** minimo (se usi la view `Grid` di
  SwiftUI nel pannello info; se preferisci restare compatibile con
  macOS 12 sostituiscila con VStack/HStack manuali — decidi tu, non è
  un requisito rigido)
- App Sandbox attiva (default Xcode): serve abilitare **File Access →
  User Selected File (Read Only)** nelle Capabilities, altrimenti
  drag&drop e file picker falliscono silenziosamente senza errori
  evidenti — occhio a questo, è un gotcha facile da perdere
- Se un `.glb` usa compressione **Draco** o texture **KTX2/BasisU**,
  GLTFKit2 le supporta ma richiede dipendenze extra descritte nel loro
  README (plugin system per il decoder Draco, xcframework per KTX2) —
  non è necessario in v1, ma se un file non carica prova a controllarlo
  prima di pensare a un bug nostro
- SceneKit su macOS mischia storicamente `CGFloat`/`Float` a seconda
  dell'API (tipo `SCNVector3` vs le proprietà `simd*`); dove possibile
  preferisci le API `simd` (`simdPosition`, `simdWorldFront`,
  `simdOrientation`, `SCNVector3ToFloat3`/`SCNVector3FromFloat3`) per
  evitare cast continui

## UI — riferimento visivo (vedi reference-ui.png)

- Sfondo nero pieno, modello renderizzato al centro
- Badge nome file in alto a sinistra, pillola semi-trasparente con
  bordo sottile
- Pannello info in basso a sinistra, stesso stile pillola, testo
  monospace per i valori numerici
- Toolbar verticale a destra con icone: zoom+, zoom-, fit-to-view,
  toggle mesh/wireframe, griglia, screenshot, fullscreen
- Gizmo assi XYZ piccolo in basso a destra
- Stato vuoto (nessun file caricato): zona drag&drop centrata con bordo
  tratteggiato e bottone per aprire il file picker

## Come procedere

1. Crea il progetto Xcode (macOS App, SwiftUI, Swift) con questa
   struttura, oppure in alternativa un package SPM eseguibile se lo
   ritieni più comodo per iterare da riga di comando — decidi tu in base
   a cosa riesci a buildare e verificare più velocemente da qui
2. Aggiungi GLTFKit2 come dipendenza
3. Implementa in ordine: caricamento modello (con almeno un file .glb di
   test — puoi scaricarne uno dai sample models del Khronos Group,
   `github.com/KhronosGroup/glTF-Sample-Models`) → render base →
   camera/fit → UI overlay → toolbar azioni → gizmo
4. **Compila dopo ogni pezzo**, non aspettare la fine — è il vantaggio
   di farlo fare a te rispetto a codice scritto senza poter buildare
5. Verifica che l'app giri davvero con un file reale prima di
   considerare finito ogni step

## Nota

Ho già un abbozzo di questo stesso progetto scritto da Claude (chat,
senza possibilità di compilare) — se ti è comodo come riferimento
concettuale per l'architettura va bene, ma **non copiarlo alla cieca**:
non è stato verificato, quindi trattalo come bozza di discussione, non
come codice da riusare direttamente. Preferisco che tu scriva e verifichi
da zero.
