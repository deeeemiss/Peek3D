# Peek3D — Privacy Notice

*[Italiano](PRIVACY.it.md)*

**Last updated:** [date to be filled in before publishing]

This notice explains what personal data Peek3D's license system collects
when you buy and activate a license, why, for how long, and what rights you
have over it. It does not cover Peek3D's optional crash/diagnostic
reporting (if any) separately — if that exists, it should be added here
before publishing (see the internal note at the end of this document).

## Who is responsible for your data

**Sebastiano Demichelis** — [legal name / business name, registered
address, VAT or fiscal code to be filled in] — is the **data controller**
for the personal data described in this notice: the data processed to run
Peek3D's license system.

**Polar.sh** is a separate, independent data controller for the payment
itself — see "Polar.sh, the merchant of record" below.

Questions or requests about your data: **peek3d@sebdemichelis.dev**.

## What we collect

When you buy and activate a Peek3D license, our activation system stores:

| Data | What it is | Why we have it |
|---|---|---|
| **Purchase email** | The email address you used to buy your license. | To identify your license, send you the license key, and let you recover it if lost. |
| **Device identifier** | A one-way, deterministic hash of your Mac's hardware identifier. **We never store the raw hardware identifier** — only the output of a hash function, which cannot be reversed back into the original value. | To count and enforce how many Macs a license is activated on (one Mac per license, or as many as your pack includes). |
| **Activation timestamp** | When a given Mac activated the license. | To manage seats and to help you and us tell activations apart when troubleshooting (e.g. "which Mac is this seat"). |
| **Last verification timestamp** | When the license was last successfully re-checked online. | To run the 30-day offline grace period described in the [license FAQ](FAQ.en.md) — this is what the app compares against to know it's still within grace. |

We do **not** collect the content of the 3D files you open, file names, file
paths, or anything about how you use Peek3D day to day. The license system
only ever sees the data above.

## Why we process it, and on what legal basis

- **Purchase email, device identifier, activation and verification
  timestamps** are processed to perform the contract you enter into when
  you buy a license — i.e., to actually deliver and enforce the license you
  paid for (GDPR Art. 6(1)(b)).
- The **device identifier** specifically is also processed on the basis of
  our legitimate interest in enforcing the "one license, one Mac" terms
  fairly and consistently for every customer (GDPR Art. 6(1)(f)) — without
  it, we'd have no way to tell activations apart at all.

## How long we keep it

We keep this data for as long as it's needed to run the license system —
that is, for as long as your license can be used to activate or re-verify
Peek3D. Since Peek3D licenses don't expire, this is ordinarily the
operational lifetime of the product.

If you ask us to delete your data (see "Your rights" below), we will —
understanding that this also deactivates your license, since the record we
delete is the same one the app checks to confirm it's still valid.

## Polar.sh, the merchant of record

Peek3D's purchase flow is handled by **[Polar.sh](https://polar.sh)**, our
merchant of record. Polar.sh processes your payment details — name,
billing address, payment method, transaction data — as an **independent
data controller**, under its own privacy policy, not on our instructions.
We never see or store your card details.

In short: **we** are responsible for your email, device identifier, and
activation/verification timestamps, described above. **Polar.sh** is
responsible for your payment and billing data. See
[Polar.sh's privacy policy](https://polar.sh/legal/privacy) for how they
handle it.

## Other technical processors

To run the license system, we rely on infrastructure providers acting as
**data processors** on our instructions:

- A hosting/edge platform that runs the license verification service.
- An email delivery service that sends license and recovery emails.

Some of these providers may process data outside the European Economic
Area. Where that's the case, we rely on the safeguards required by the
GDPR (such as the European Commission's Standard Contractual Clauses) —
see the internal note at the end of this document for what still needs
confirming before publishing.

## Your license key contains your email — on purpose

Your license key embeds your purchase email **in plain text**, as part of
its signed contents. This is a deliberate design choice: it's what lets
Peek3D show whose license is active on a given Mac without contacting a
server every time you open the app.

A practical consequence: if you post your license key somewhere public — a
forum, a public GitHub issue, a shared screenshot — you're also posting
your email address. Keep it as private as you would any other email
address.

## Your rights

Under the GDPR, you can ask us at any time to:

- **Access** the data we hold about you.
- **Correct** it, if it's wrong (e.g. you activated with the wrong email
  and want it fixed).
- **Delete** it (see "How long we keep it" above for what this means for
  your license).
- **Restrict** or **object to** our processing of it.
- **Receive a copy** of it in a portable format.

To exercise any of these, email **peek3d@sebdemichelis.dev**. If you believe
we've mishandled your data, you also have the right to lodge a complaint
with your local data protection authority — in Italy, the
[Garante per la protezione dei dati personali](https://www.garanteprivacy.it/).

## Security

License keys are signed with a private cryptographic key we control; the
signature is what the app verifies offline, and it can't be forged without
that key. Device identifiers are stored as one-way hashes, never as raw
hardware identifiers.

## Changes to this notice

We may update this notice as the license system evolves. Material changes
will be reflected here with an updated "Last updated" date; check back
occasionally if you want to stay current.
