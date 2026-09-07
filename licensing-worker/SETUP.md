# Setup operativo — da zero a licenze funzionanti

Checklist di esercizio, non di progettazione. Il codice è finito e testato
(50 test verdi, `npm test`); quello che manca sono **account, chiavi e un
deploy**. `TODO.md` è un'altra cosa: elenca le assunzioni sull'API di Polar
da confermare col primo ordine vero, e si legge dopo il punto 8 qui sotto.

## Cos'è `wrangler`

È la CLI di Cloudflare Workers. Fa tre cose che servono qui:

- `wrangler secret put NOME` — carica un valore segreto sul Worker. I segreti
  non stanno mai in git: `wrangler.toml` contiene solo i valori non sensibili
  (`[vars]`), i quattro segreti vivono solo su Cloudflare.
- `wrangler deploy` — pubblica il Worker. Da quel momento esiste un URL
  pubblico `https://peek3d-licensing.<tuo-subdominio>.workers.dev` a cui
  Polar manderà i webhook.
- `wrangler dev` — lo esegue in locale leggendo i segreti da `.dev.vars`
  (stesso formato `CHIAVE=valore`, gitignorato). Serve solo per provare a
  mano con `curl`, non è un passaggio obbligatorio.

`wrangler.toml` è già configurato: nome del Worker, entry point, gli ID
Polar reali e il binding di rate limiting per `/recover`.

## Stato attuale

Catena verificata end-to-end il 2026-09-06 con un ordine reale (sconto
100%): webhook firmato → ordine → grant → licenza firmata → email
consegnata. Vedi il punto 8 di `TODO.md` per il difetto di firma trovato e
risolto in quell'occasione.

| Cosa | Stato |
|---|---|
| Dominio per email e supporto | deciso 2026-09-05: sottodominio di `sebdemichelis.dev`, niente `peek3d.app` (punto 0) |
| Codice worker + test | fatto |
| ID Polar (org / prodotto / benefit) in `wrangler.toml` e `PolarLicenseConfig.swift` | fatto (2026-08-14) |
| Coppia di chiavi Ed25519 di produzione | fatto (2026-09-05) |
| `LicenseVerifier.trustedPublicKeys` nell'app | fatto (2026-09-05) — chiave di produzione, test di pin verde |
| 4 segreti su Cloudflare | fatto (2026-09-05): tutti e quattro caricati |
| Deploy del Worker | fatto (2026-09-05) — `https://peek3d-licensing.demichelis-studios.workers.dev`, `/health` risponde 200 |
| Endpoint webhook su Polar | fatto (2026-09-05) — registrato, signing secret caricato; il worker rifiuta le richieste non firmate con `401 invalid_signature` |
| Sottodominio verificato su Resend | fatto (2026-09-05) — `Verified`, pronto a inviare |

## Gli step

### 0. Dominio: sottodominio di `sebdemichelis.dev`, non `peek3d.app`

Deciso il 2026-09-05. `peek3d.app` era libero a 14,18 €/anno, ma si è
preferito riusare il dominio personale già posseduto.

Assetto scelto, e il motivo per cui non è un unico indirizzo:

| Ruolo | Indirizzo | Perché |
|---|---|---|
| Invio email | `licenze@peek3d.sebdemichelis.dev` | Sottodominio dedicato: i record SPF/DKIM di Resend stanno lì e **non toccano il record SPF dell'apex**, che serve a iCloud+ per la posta personale. Sbagliare quella fusione manderebbe in spam la posta personale. Isola anche la reputazione di invio. |
| Risposte e supporto | `peek3d@sebdemichelis.dev` | Il sottodominio di invio non ha MX, quindi non riceve niente: `RESEND_REPLY_TO` dirotta le risposte su un alias iCloud+ reale. È anche l'indirizzo pubblicato in FAQ e informativa privacy (esercizio dei diritti GDPR), quindi deve restare vivo finché esistono clienti. |
| Link d'acquisto | link di checkout ospitato da Polar | Il prodotto è configurato come *private*: si vende solo tramite link diretto, non c'è una vetrina pubblica da linkare. |

Il DNS di `sebdemichelis.dev` è delegato a **Vercel** (`ns1/ns2.vercel-dns.com`),
quindi i record che Resend chiederà al punto 4 vanno aggiunti nel pannello DNS
di Vercel — non su Cloudflare, dove sta solo il Worker.

Da fare a mano, fuori dal repo:
1. Creare l'alias `peek3d@sebdemichelis.dev` nelle impostazioni iCloud+
   (Custom Email Domain) e verificare che riceva davvero.
2. Aggiungere i record DNS di Resend su Vercel per
   `peek3d.sebdemichelis.dev` (punto 4).

### 1. Login su Cloudflare

```bash
cd licensing-worker
npx wrangler login
```

Apre il browser. Se non hai ancora un account Workers, il piano gratuito
basta ampiamente per questo carico.

### 2. Chiavi di firma delle licenze

```bash
npm run keygen
```

Stampa **chiave privata** e **chiave pubblica** in esadecimale, e non le
salva da nessuna parte.

- La privata va su Cloudflare e poi cancellata dallo scrollback:
  ```bash
  npx wrangler secret put LICENSE_ED25519_PRIVATE_KEY   # incolla la privata
  ```
- La pubblica va incastonata nell'app, in
  `PeekLicenseKit/Sources/PeekLicenseKit/LicenseVerifier.swift`, dentro
  `trustedPublicKeys` (oggi è un array vuoto, che è un default fail-closed:
  nessuna licenza viene mai accettata).

Perdere la privata significa rigenerarla e spedire una nuova build con la
nuova pubblica: tutte le licenze già emesse smettono di verificare. Fanne un
backup in un password manager, non in git.

### 3. Token API di Polar

Polar → Settings → API tokens. Servono gli scope di lettura su ordini,
customer, benefit e license keys.

```bash
npx wrangler secret put POLAR_ACCESS_TOKEN
```

Nota: l'ambiente **sandbox** di Polar ha token, ID e base URL diversi
(`https://sandbox-api.polar.sh`). Se vuoi provare con un acquisto finto,
servono un secondo set di ID in `[vars]` e un deploy separato — non mescolare
i due.

### 4. Resend

Richiede il punto 0 fatto.

1. ~~Aggiungere il sottodominio su Resend e i record nel DNS~~ — **fatto il
   2026-09-05.** Dominio `peek3d.sebdemichelis.dev` creato su Resend con
   region Irlanda (eu-west-1), verifica **manuale** e non tramite
   l'integrazione "Auto configure": quest'ultima avrebbe dato a Resend
   accesso in scrittura all'intera zona DNS, dove vivono gli MX di iCloud.

   I tre record aggiunti su Vercel, tutti su sottodomini, nessuno sull'apex:

   | Nome (relativo, come va scritto su Vercel) | Tipo | Valore |
   |---|---|---|
   | `resend._domainkey.peek3d` | TXT | chiave pubblica DKIM (`p=MIGfMA0GCSq…`) |
   | `send.peek3d` | MX (priorità 10) | `feedback-smtp.eu-west-1.amazonses.com` |
   | `send.peek3d` | TXT | `v=spf1 include:amazonses.com ~all` |

   Verificato dopo l'inserimento che l'apex sia rimasto intatto:
   `v=spf1 include:icloud.com ~all` e gli MX `mx01/mx02.mail.icloud.com`
   invariati.

   **Non aggiunti di proposito**: il record DMARC (`_dmarc`, sull'apex —
   riguarderebbe anche la posta personale iCloud, e non serve per inviare)
   e l'MX di "Enable Receiving" (`inbound-smtp…`, serve solo per *ricevere*
   posta su Resend, cosa che non facciamo: si riceve su iCloud).
2. Crea una API key:
   ```bash
   npx wrangler secret put RESEND_API_KEY
   ```

### 5. Primo deploy

```bash
npm run deploy
```

Annota l'URL che stampa. Se si lamenta del blocco `[[unsafe.bindings]]` con
`type = "ratelimit"`, è il punto 5 di `TODO.md`: la sintassi del binding può
essere cambiata — aggiornala, **non** rimuovere il rate limiting, altrimenti
`/recover` diventa un oracolo per enumerare indirizzi email.

### 6. Endpoint webhook su Polar

Polar → Settings → Webhooks → Add endpoint:

- URL: `https://peek3d-licensing.<subdominio>.workers.dev/webhooks/polar`
- Formato: **Raw** (Standard Webhooks) — non Discord/Slack.
- Evento: `order.paid`.

Polar mostra un **signing secret**:

```bash
npx wrangler secret put POLAR_WEBHOOK_SECRET
```

I segreti hanno effetto subito, non serve ri-deployare.

### 7. Prova a vuoto

Dal pannello webhook di Polar, invia un evento di test (o ri-consegna una
delivery). Controlla i log:

```bash
npx wrangler tail
```

Cosa aspettarsi:
- `400 missing_order_id` → punto 3 di `TODO.md`: la forma dell'envelope non è
  quella prevista, si aggiusta una riga in `handleWebhook`.
- `503` → punto 4 di `TODO.md`: il grant del benefit non esiste ancora quando
  il webhook parte. Polar riprova da solo.
- `200` → ordine trovato, licenza firmata, email spedita.

### 8. Primo acquisto vero

Compra il prodotto (o usa la sandbox). Verifica:

1. Che l'email arrivi, con dentro una stringa `PK3D-...`.
2. Che l'app la accetti — serve la build col punto 2 fatto.
3. Che `POST /recover` con quella email rispedisca **la stessa identica**
   stringa (è deterministica).

Poi rileggi `TODO.md` con l'ordine vero sotto mano: quasi tutti i punti si
chiudono guardando i dati di quell'ordine.
