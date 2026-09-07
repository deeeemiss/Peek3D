# Peek3D — Informativa privacy

*[English](PRIVACY.en.md)*

**Ultimo aggiornamento:** [data da inserire prima della pubblicazione]

Questa informativa spiega quali dati personali tratta il sistema di licenze
di Peek3D quando acquisti e attivi una licenza, per quale scopo, per quanto
tempo, e quali diritti hai su questi dati. Non copre eventuali segnalazioni
diagnostiche/di crash opzionali di Peek3D — se esistono, vanno aggiunte qui
prima della pubblicazione (vedi la nota interna in fondo a questo
documento).

## Chi è responsabile dei tuoi dati

**Sebastiano Demichelis** — [ragione sociale, indirizzo, partita IVA o
codice fiscale da inserire] — è il **titolare del trattamento** per i dati
personali descritti in questa informativa: quelli trattati per far
funzionare il sistema di licenze di Peek3D.

**Polar.sh** è un titolare del trattamento distinto e autonomo per il
pagamento in sé — vedi "Polar.sh, il merchant of record" più sotto.

Domande o richieste sui tuoi dati: **peek3d@sebdemichelis.dev**.

## Quali dati trattiamo

Quando acquisti e attivi una licenza Peek3D, il nostro sistema di
attivazione conserva:

| Dato | Cos'è | Perché lo abbiamo |
|---|---|---|
| **Email dell'acquirente** | L'indirizzo email usato per acquistare la licenza. | Per identificare la licenza, inviarti la chiave, e permetterti di recuperarla se persa. |
| **Identificativo del dispositivo** | Un hash deterministico e non reversibile dell'identificativo hardware del tuo Mac. **Non conserviamo mai il valore hardware grezzo** — solo l'output di una funzione di hash, che non può essere ricondotto al valore originale. | Per contare e far rispettare quanti Mac una licenza può attivare (un Mac per licenza, o tanti quanti ne include il pacchetto acquistato). |
| **Timestamp di attivazione** | Il momento in cui un dato Mac ha attivato la licenza. | Per gestire i posti disponibili e per distinguere le attivazioni in caso di assistenza (es. "a quale Mac corrisponde questo posto"). |
| **Timestamp di ultima verifica** | Il momento dell'ultima riverifica online riuscita della licenza. | Per far funzionare il margine offline di 30 giorni descritto nella [FAQ sulla licenza](FAQ.it.md) — è il valore con cui l'app confronta il tempo trascorso per sapere se è ancora dentro il margine. |

**Non** raccogliamo il contenuto dei file 3D che apri, i loro nomi, i loro
percorsi, né alcuna informazione sull'uso quotidiano di Peek3D. Il sistema
di licenze vede solo i dati elencati sopra.

## Perché li trattiamo, e su quale base giuridica

- **Email dell'acquirente, identificativo del dispositivo, timestamp di
  attivazione e verifica** sono trattati per eseguire il contratto che
  stipuli acquistando una licenza — cioè per fornire ed effettivamente far
  valere la licenza che hai pagato (art. 6.1.b GDPR, esecuzione di un
  contratto).
- L'**identificativo del dispositivo** in particolare è trattato anche sulla
  base del nostro legittimo interesse a far rispettare in modo equo e
  uniforme, per tutti i clienti, i termini "una licenza, un Mac" (art. 6.1.f
  GDPR) — senza di esso non avremmo alcun modo di distinguere le
  attivazioni.

## Per quanto tempo li conserviamo

Conserviamo questi dati per tutto il tempo necessario a far funzionare il
sistema di licenze — cioè per tutto il tempo in cui la tua licenza può
essere usata per attivare o riverificare Peek3D. Poiché le licenze Peek3D
non scadono, questo corrisponde normalmente alla vita operativa del
prodotto.

Se ci chiedi di cancellare i tuoi dati (vedi "I tuoi diritti" più sotto), lo
facciamo — fermo restando che questo disattiva anche la tua licenza, dato
che il record che cancelliamo è lo stesso che l'app controlla per
confermare che sia ancora valida.

## Polar.sh, il merchant of record

Il flusso di acquisto di Peek3D è gestito da **[Polar.sh](https://polar.sh)**,
il nostro merchant of record. Polar.sh tratta i dati del tuo pagamento —
nome, indirizzo di fatturazione, metodo di pagamento, dati della
transazione — come **titolare del trattamento autonomo**, secondo la
propria informativa privacy, non su nostre istruzioni. Noi non vediamo né
conserviamo mai i dati della tua carta.

In sintesi: **noi** siamo responsabili della tua email, dell'identificativo
del dispositivo e dei timestamp di attivazione/verifica, descritti sopra.
**Polar.sh** è responsabile dei tuoi dati di pagamento e fatturazione. Vedi
l'[informativa privacy di Polar.sh](https://polar.sh/legal/privacy) per
come li tratta.

## Altri fornitori tecnici

Per far funzionare il sistema di licenze ci affidiamo a fornitori di
infrastruttura che agiscono come **responsabili del trattamento** su nostre
istruzioni:

- Una piattaforma di hosting/edge che gestisce il servizio di verifica
  delle licenze.
- Un servizio di invio email che spedisce le email di licenza e di
  recupero.

Alcuni di questi fornitori potrebbero trattare dati anche fuori dallo
Spazio Economico Europeo. In tal caso, ci affidiamo alle garanzie previste
dal GDPR (come le clausole contrattuali standard della Commissione
Europea) — vedi la nota interna in fondo a questo documento per cosa resta
da confermare prima della pubblicazione.

## La tua chiave di licenza contiene la tua email — di proposito

La tua chiave di licenza include la tua email di acquisto **in chiaro**,
come parte del suo contenuto firmato. È una scelta di design deliberata: è
ciò che permette a Peek3D di mostrare a chi appartiene la licenza attiva su
un dato Mac senza contattare un server ogni volta che apri l'app.

Una conseguenza pratica: se pubblichi la tua chiave di licenza in un luogo
pubblico — un forum, una issue pubblica su GitHub, uno screenshot
condiviso — stai pubblicando anche il tuo indirizzo email. Trattala con la
stessa riservatezza di qualsiasi altro indirizzo email.

## I tuoi diritti

Secondo il GDPR, puoi chiederci in qualsiasi momento di:

- **Accedere** ai dati che conserviamo su di te.
- **Correggerli**, se sono sbagliati (es. hai attivato con l'email
  sbagliata e vuoi correggerla).
- **Cancellarli** (vedi "Per quanto tempo li conserviamo" sopra per cosa
  comporta per la tua licenza).
- **Limitare** o **opporti** al loro trattamento.
- **Riceverne una copia** in formato portabile.

Per esercitare uno di questi diritti, scrivi a **peek3d@sebdemichelis.dev**. Se
ritieni che i tuoi dati siano stati trattati in modo scorretto, hai anche
diritto a presentare reclamo alla tua autorità di controllo — in Italia, il
[Garante per la protezione dei dati personali](https://www.garanteprivacy.it/).

## Sicurezza

Le chiavi di licenza sono firmate con una chiave crittografica privata che
controlliamo noi; è la firma che l'app verifica offline, e non può essere
falsificata senza quella chiave. Gli identificativi del dispositivo sono
conservati come hash non reversibili, mai come identificativi hardware
grezzi.

## Modifiche a questa informativa

Potremmo aggiornare questa informativa con l'evolversi del sistema di
licenze. Le modifiche sostanziali saranno riportate qui con una data di
"Ultimo aggiornamento" aggiornata; ricontrolla di tanto in tanto se vuoi
restare aggiornato.
