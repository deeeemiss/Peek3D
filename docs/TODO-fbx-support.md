# Supporto formato FBX

Stato: **v1 implementata** (geometria + materiali/texture + unità). Branch: `feature/fbx-support`.

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

## FUORI SCOPE (fase futura): animazioni scheletriche FBX

Non implementate volutamente in questo giro. ufbx è caricato con
`ignore_animation = true`, quindi la scena FBX non porta player di animazione.

Per riprenderle in futuro serve:
- Rimuovere `ignore_animation` e leggere `scene->anim_stacks` / curve.
- Mappare skin/cluster/bone ufbx sullo scheletro SceneKit
  (`SCNSkinner`) e costruire `SCNAnimationPlayer` compatibili col player
  esistente (attenzione: modello scheletrico FBX diverso da glTF).
- Popolare l'array `animations` in `ModelLoader` anche per il ramo FBX.
- Asset di test già pronto: `testmodels/cube_animated.fbx` (cubo con rotazione,
  esportato con `bake_anim`).

## Insidie note (registrate durante la v1)

- Orientamento UV: FBX ha origine UV in basso-sinistra, SceneKit campiona in
  alto-sinistra → nel bridge si applica `v' = 1 - v`. Verificato visivamente
  (griglia con lettere leggibili e dritte).
- Texture esterne vs sandbox: le embedded sono sempre sicure; le esterne
  dipendono dai permessi di file concessi alla sandbox.
