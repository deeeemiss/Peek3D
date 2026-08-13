export interface EmailSender {
  send(to: string, subject: string, text: string): Promise<void>;
}

export interface ResendConfig {
  apiKey: string;
  fromEmail: string;
}

export class ResendEmailSender implements EmailSender {
  constructor(private readonly config: ResendConfig) {}

  async send(to: string, subject: string, text: string): Promise<void> {
    const response = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: {
        Authorization: `Bearer ${this.config.apiKey}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        from: this.config.fromEmail,
        to,
        subject,
        text,
      }),
    });

    if (!response.ok) {
      const body = await response.text().catch(() => "");
      throw new Error(`Resend send failed: ${response.status} ${body}`);
    }
  }
}

/** Test double: records every send instead of hitting the network. */
export class FakeEmailSender implements EmailSender {
  sent: Array<{ to: string; subject: string; text: string }> = [];

  async send(to: string, subject: string, text: string): Promise<void> {
    this.sent.push({ to, subject, text });
  }
}

export function licenseEmailBody(licenseString: string): string {
  return [
    "Grazie per aver acquistato Peek3D!",
    "",
    "Ecco la tua chiave di licenza (testo semplice, copiabile):",
    "",
    licenseString,
    "",
    "Incollala nella finestra di attivazione di Peek3D per sbloccare l'app.",
    "",
    "Se in futuro perdi questa email, puoi richiederne una copia da:",
    "https://peek3d.app/recover (o l'endpoint di recupero che esponi pubblicamente)",
    "inserendo lo stesso indirizzo email usato per l'acquisto.",
  ].join("\n");
}
