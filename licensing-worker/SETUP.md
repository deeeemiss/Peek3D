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

| Cosa | Stato |
|---|---|
| Codice worker + test | fatto |
| ID Polar (org / prodotto / benefit) in `wrangler.toml` e `PolarLicenseConfig.swift` | fatto (2026-08-14) |
| Coppia di chiavi Ed25519 di produzione | **da fare** (punto 2) |
| `LicenseVerifier.trustedPublicKeys` nell'app | **vuoto** — l'app rifiuta ogni licenza finché non lo popoli (punto 2) |
| 4 segreti su Cloudflare | **da fare** (punti 2–4) |
| Deploy del Worker | **da fare** (punto 5) |
| Endpoint webhook su Polar | **da fare** (punto 6) |
| Dominio verificato su Resend | **da fare** (punto 4) |

## Gli step

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

1. Verifica il dominio `peek3d.app` su Resend (record SPF/DKIM nel DNS).
   Senza questo passaggio le email non partono e basta — il mittente
   configurato è `Peek3D <licenze@peek3d.app>` in `wrangler.toml`.
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
