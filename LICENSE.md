Copyright (c) 2026 Sebastiano Demichelis

# Elastic License 2.0 (ELv2) — adattata per Peek3D

Questa licenza è basata sul template Elastic License 2.0
(https://www.elastic.co/licensing/elastic-license), con un'aggiunta
specifica per Peek3D nella sezione "License Key Functionality" più sotto.
NON è una licenza open source riconosciuta OSI — è "source-available":
il codice è leggibile e ispezionabile pubblicamente, ma il suo uso reale
resta condizionato ai termini seguenti.

## Accettazione
Usando il software accetti tutti i termini e le condizioni sottostanti.

## Licenza di copyright
Il licenziante ti concede una licenza non esclusiva, royalty-free,
mondiale, non subconcedibile e non trasferibile per usare, copiare,
distribuire, rendere disponibile e preparare opere derivate del software,
in ciascun caso soggetta ai limiti e alle condizioni seguenti.

## Limitazioni
- Non puoi fornire il software a terzi come servizio ospitato o gestito,
  laddove il servizio dia accesso a un insieme sostanziale delle
  funzionalità del software.
- Non puoi spostare, modificare, disabilitare o aggirare la funzionalità
  di license key presente nel software, né rimuovere od oscurare
  funzionalità protette da tale meccanismo.
- Non puoi alterare, rimuovere od oscurare avvisi di licenza, copyright o
  altri avvisi del licenziante presenti nel software.

## Funzionalità di license key (definizione specifica di Peek3D)
Ai fini della limitazione precedente, per "funzionalità di license key" si
intende, senza limitarsi a: il conteggio del periodo di prova, qualunque
verifica della firma Ed25519 della chiave di licenza, il flusso di
attivazione tramite Polar, e in generale qualunque logica contenuta in
`LicenseState.swift`, `LicenseActivationService.swift`,
`LicenseVerifier.swift`, `PeekLicenseKit/` e `licensing-worker/` il cui
scopo sia determinare se un'istanza del software è autorizzata a superare
le limitazioni della versione di prova. Costruire, modificare o
ridistribuire il software con questa logica rimossa, disattivata o
aggirata in altro modo costituisce violazione di questa licenza, a
prescindere da eventuali intenzioni non commerciali di chi lo fa.

## Brevetti
Il licenziante ti concede una licenza, su qualunque rivendicazione
brevettuale che possa o riesca a concedere in licenza, per produrre, far
produrre, usare, vendere, offrire in vendita, importare e far importare
il software, soggetta ai limiti di questa licenza. Questa licenza non
copre rivendicazioni brevettuali causate da modifiche o aggiunte al
software. Se tu o la tua azienda affermate per iscritto che il software
viola o contribuisce alla violazione di un brevetto, la vostra licenza
brevettuale su questo software termina immediatamente.

## Avvisi
Devi assicurarti che chiunque riceva da te una copia di qualunque parte
del software riceva anche una copia di questi termini.
Se modifichi il software, devi includere nelle copie modificate avvisi
evidenti che dichiarino che il software è stato modificato.

## Nessun altro diritto
Questi termini non implicano licenze diverse da quelle espressamente
concesse qui.

## Cessazione
Se usi il software in violazione di questi termini, tale uso non è
autorizzato e le tue licenze terminano automaticamente. Se il licenziante
ti notifica la violazione e tu la cessi entro 30 giorni dalla notifica,
le tue licenze sono ripristinate retroattivamente. Una violazione
successiva a tale ripristino causa la cessazione automatica e permanente.

## Nessuna garanzia
Nei limiti consentiti dalla legge, il software è fornito "così com'è",
senza garanzie di alcun tipo, e il licenziante non è responsabile per
danni derivanti da questi termini o dall'uso del software.

---

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
