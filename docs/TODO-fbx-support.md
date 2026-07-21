# Supporto formato FBX

Stato: **v1 implementata** (geometria + materiali/texture + unità), più
**animazioni node-transform** (branch `feature/fbx-animations`, vedi sotto).
Branch v1: `feature/fbx-support`.

## Perché

FBX è il formato più richiesto tra quelli non ancora supportati: standard
de-facto per modelli esportati da Maya, 3ds Max, Blender, e per asset scaricati
da marketplace (Sketchfab, TurboSquid). Model I/O di Apple non lo legge
nativamente e GLTFKit2 legge solo glTF, quindi serviva una libreria terza.

## Fase 0 — libreria scelta: ufbx (non Assimp)

Confronto ufbx vs Assimp per lo scope v1 (sola visualizzazione):

- **ufbx** (SCELTA): singolo `ufbx.c` + `ufbx.h`, licenza MIT / public-domain.
  Si integra come sorgente diretto (nessun CMake, submodule o binario
  precompilato), quindi niente attriti di sandbox/firma. Gestisce nativamente
  proprio i punti critici dello scope: normalizzazione unità
  (`target_unit_meters`), conversione assi/coordinate (`target_axes` +
  `space_conversion`), texture embedded ed esterne (`load_external_files`,
  `texture.content`) e skip pulito delle animazioni (`ignore_animation`).
- **Assimp**: molto più pesante (C++, decine di file, CMake, tanti parser di
  formati che non ci servono), storia di sandbox/firma più complicata, nessun
  vantaggio reale per uno scope ristretto a geometria + materiali. Scartata.

Versione vendorizzata: **ufbx v0.23.0**, in `GLBViewer/ThirdParty/ufbx/`.

## Cosa fa la v1 (implementata)

- Terzo backend nel `ModelLoader`, accanto a GLTFKit2 e Model I/O; converge
  nello stesso `SCNScene` usato dal resto dell'app (viewer, wireframe, shading,
  preset di illuminazione).
- Bridge Objective-C++ `GLBViewer/FBX/FBXSceneBuilder.mm` che chiama ufbx e
  costruisce nodi/geometrie/materiali SceneKit.
- Geometria triangolata (poligoni n-gon inclusi), normali (generate se assenti).
- Materiali: base color / diffuse, con texture **embedded** (funziona in sandbox
  senza accessi extra) ed **esterne** (leggibili solo dove la sandbox concede
  accesso).
- Unità: cubo di 1 m rientra a 1.0 (non 100 cm né 0.01) — verificato.

## Animazioni FBX — node-transform (IMPLEMENTATO)

Branch: `feature/fbx-animations`. Le animazioni di **trasformazione dei nodi**
(rigide/gerarchiche: un nodo/mesh che trasla/ruota/scala nel tempo) sono ora
supportate e confluiscono nella stessa struttura `animations: [ModelAnimation]`
del ramo glTF — timeline, play/pause, selezione clip e wireframe durante il
play funzionano identici, senza modifiche a `ContentView`/`ViewerController`.

Come:
- Rimosso `ignore_animation`; le curve vengono lette e **bakate** con
  `ufbx_bake_anim`, che restituisce keyframe TRS per-nodo già in spazio target
  (l'`ADJUST_TRANSFORMS` ha piegato unità/assi dentro i transform dei nodi).
- La scena SceneKit ora **rispecchia la gerarchia dei nodi FBX** (un `SCNNode`
  per nodo con il suo transform LOCALE, meshe agganciate con `geometry_to_node`)
  invece di appiattire ogni mesh sulla root con `geometry_to_world` bakato: è
  ciò che permette di keyare il transform locale di ogni nodo. Bind pose
  identico al build statico precedente — verificato numericamente
  (`geometry_to_world == node_to_world * geometry_to_node`) e visivamente.
- Ogni anim-stack → un `CAAnimationGroup` con canali
  `/<nodeName>.position|orientation|scale` (stessa convenzione di GLTFKit2),
  loop via `repeatDuration = FLT_MAX`, avvolto in `SCNAnimationPlayer`.
- Nomi nodo sanificati e resi univoci (prefisso `typed_id`) per il key-path.
- Asset di test: `testmodels/cube_animated.fbx` (cubo, 60 key di rotazione,
  `bake_anim`). Self-test dedicato in `SelfTest.swift` (`BINDPOSE`) + il check
  wall-clock generico dimostrano che un frame a metà clip differisce dal bind.

## FUORI SCOPE (fase futura ulteriore)

- **Deformazione scheletrica/skinned** (`SCNSkinner`: vertici legati a bone).
  Un file skinned si carica e mostra il bind pose; i nodi-bone ricevono comunque
  la loro animazione di transform, ma la mesh **non** viene deformata. Serve
  mappare `skin_deformers`/`skin_clusters` su `SCNSkinner` (bone weights/indices
  + inverse bind matrices).
- **Blend shape / morph target** (`mesh->blend_deformers`) — non applicati.
- **Animazione di proprietà** (visibilità, parametri materiale) — le stack che
  animano solo proprietà non producono clip (nessun transform di nodo keyato).

## Insidie note (registrate durante la v1)

- Orientamento UV: FBX ha origine UV in basso-sinistra, SceneKit campiona in
  alto-sinistra → nel bridge si applica `v' = 1 - v`. Verificato visivamente
  (griglia con lettere leggibili e dritte).
- Texture esterne vs sandbox: le embedded sono sempre sicure; le esterne
  dipendono dai permessi di file concessi alla sandbox.
