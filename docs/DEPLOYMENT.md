# Inbetriebnahme auf der Synology DS224+

Getestet gegen DSM 7.4.1, Container Manager 24.0.2, Tailscale 1.58.2.
Zeitbedarf: rund eine Stunde, davon 30–40 Minuten Warten (Datenübertragung
und Image-Bau).

---

## Schritt 0 — Vorbereitung auf dem PC

**a) Passwort setzen.** Die App ist nach der Funnel-Freigabe öffentlich
erreichbar. Vorher ein Zugangswort festlegen — ohne gesetzte Variable
`RVK_APP_PASSWORD` fragt die App gar nicht erst danach.

**b) Optional, aber auf der NAS spürbar: Embeddings unkomprimiert speichern.**
Die `_norm.rds`-Dateien sind gzip-komprimiert. Das Entpacken von 3.6 GB
kostet auf dem Celeron der NAS mehrere Minuten bei jedem Start. Unkomprimiert
sind die Dateien etwa 25 % grösser, werden aber nur noch von der Platte
gelesen:

```r
for (f in c("embeddings_norm.rds",
            "holdings_emb_B500_norm.rds",
            "holdings_emb_B589_norm.rds")) {
  p <- here::here("RVK_data", f)
  if (file.exists(p)) {
    cat(f, "...\n")
    saveRDS(readRDS(p), p, compress = FALSE)
  }
}
```

**c) Google-Fonts-Abhängigkeit entfernen (empfohlen).** `bs_theme()` lädt die
Schrift beim Start von Google. Schlägt das fehl — gesperrtes Netz, Zeitüberschreitung —
startet die App nicht. In `app.R` ersetzen:

```r
app_theme <- bs_theme(
  version = 5,
  base_font = font_google("Source Sans 3"),
  heading_font = font_google("Source Sans 3"),
  primary = "#1F5673",
  "font-size-root" = "17px"
)
```

durch:

```r
app_theme <- bs_theme(
  version = 5,
  primary = "#1F5673",
  "font-size-root" = "17px",
  base_font = font_face(family = "system-ui",
                        src = "local('system-ui')")
)
```

Alternativ einfach `base_font` und `heading_font` weglassen — dann nimmt
Bootstrap seinen eigenen Systemschrift-Stack, was auf Windows und macOS gut
aussieht.

---

## Schritt 1 — Ordner auf der NAS anlegen

File Station öffnen. Falls der Ordner `docker` noch nicht existiert, wird er
beim ersten Container-Manager-Projekt automatisch erstellt; sonst manuell
anlegen.

Struktur:

```
/volume1/docker/rvk/
├── Dockerfile
├── docker-compose.yml
├── .env                  ← Schlüssel, kommt in Schritt 3
├── .here                 ← leere Datei, wichtig für das here-Paket
├── app.R
└── RVK_data/
    ├── rvk.db
    ├── embeddings_norm.rds
    ├── holdings_emb_B500_norm.rds
    ├── holdings_emb_B589_norm.rds
    ├── lib_*.R
    ├── 05_retrieve.R
    └── cache_enrichment/   ← wird bei Bedarf selbst angelegt
```

Die `.here` ist eine leere Datei. In DSM lässt sie sich schlecht anlegen —
am einfachsten auf dem PC erzeugen und mitkopieren:

```r
file.create(here::here(".here"))
```

Ohne sie findet `here()` im Container den Projektstamm nicht, weil dort keine
`.Rproj`-Datei liegt.

**Was NICHT kopiert werden muss:** die Roh-XML, die xlsx-Exporte, die
`*_partial_*`-Checkpoint-Ordner, die unkomprimierten `embeddings.rds` ohne
`_norm`. Das spart mehrere Gigabyte Übertragung.

**Übertragung.** Rund 4–5 GB. Über File Station im Browser ist das zäh;
schneller geht es über eine SMB-Netzwerkfreigabe (im Explorer als Laufwerk
verbinden) oder mit Synology Drive.

---

## Schritt 2 — Container Manager: Projekt anlegen

1. **Container Manager** öffnen → links **Projekt** → **Erstellen**.
2. Projektname: `rvk`
3. Pfad: `/volume1/docker/rvk` auswählen.
4. Quelle: **docker-compose.yml verwenden** — die Datei liegt bereits dort und
   wird erkannt.
5. Weiter, dann **Fertig**. Der Bau startet.

Der erste Bau dauert 15–30 Minuten: R-Basisimage laden, Systembibliotheken,
dann 15 R-Pakete. Die kommen als fertige Linux-Binaries, werden also nicht
kompiliert. Das Log läuft im Fenster mit.

---

## Schritt 3 — Schlüssel hinterlegen

Die Schlüssel gehören **nicht** in `docker-compose.yml`, sondern in eine Datei
`.env` im selben Ordner. Docker liest sie automatisch.

Inhalt (ohne Anführungszeichen, keine Leerzeichen um das `=`):

```
OPENAI_API_KEY=sk-...
OPENROUTER_API_KEY=sk-or-...
RVK_APP_PASSWORD=ein-gutes-passwort
```

Anlegen am einfachsten auf dem PC in einem Texteditor und mitkopieren — DSM
verbirgt Dateien mit führendem Punkt teilweise.

Danach im Container Manager das Projekt **anhalten und neu starten**, damit die
Variablen greifen.

---

## Schritt 4 — Erster Start prüfen

Im Container Manager: Projekt `rvk` → Container → **Protokoll**.

Erwartet:

```
Lade Indizes ...
  excluding 361 non-assignable notations from the vector index
  loading holdings index 'B500'...
  loading holdings index 'B589'...
Bereit nach 180 s
Listening on http://0.0.0.0:3838
```

Der Start dauert auf der NAS deutlich länger als auf dem PC — mehrere Minuten
sind normal. Der Healthcheck ist deshalb auf zehn Minuten Karenz gesetzt.

Test im LAN, im Browser: `http://<NAS-IP>:3838` — **funktioniert absichtlich
nicht**, weil der Port in der compose-Datei nur auf `127.0.0.1` liegt. Zum
Testen vorübergehend auf `"3838:3838"` ändern, prüfen, danach zurückstellen.

---

## Schritt 5 — Tailscale Funnel einrichten

Funnel macht die App über eine feste HTTPS-Adresse öffentlich erreichbar. Die
Nutzerinnen und Nutzer brauchen dafür **nichts** zu installieren — das ist der
Grund für diesen Weg, weil auf den Arbeitsgeräten kein Tailscale erlaubt ist.

**a) Voraussetzungen in der Tailscale-Admin-Konsole** (login.tailscale.com):

- **DNS** → MagicDNS aktiviert
- **DNS** → HTTPS-Zertifikate aktiviert

**b) SSH auf der NAS aktivieren:**
Systemsteuerung → Terminal & SNMP → **SSH-Dienst aktivieren**.

**c) Verbinden** (vom PC aus, PowerShell oder Terminal):

```
ssh dein-dsm-benutzer@<NAS-IP>
```

**d) Funnel starten:**

```
sudo /var/packages/Tailscale/target/bin/tailscale funnel --bg 3838
```

Beim ersten Mal erscheint ein Link zur Admin-Konsole, um das Attribut `funnel`
für dieses Gerät freizugeben. Link öffnen, bestätigen, Befehl wiederholen.

**e) Prüfen:**

```
sudo /var/packages/Tailscale/target/bin/tailscale funnel status
```

Zeigt die öffentliche Adresse, etwa
`https://nas-name.dein-tailnet.ts.net`. Die DNS-Verbreitung kann beim ersten
Mal bis zu zehn Minuten dauern.

**f) Abschalten**, falls nötig:

```
sudo /var/packages/Tailscale/target/bin/tailscale funnel --bg off
```

`--bg` sorgt dafür, dass die Freigabe einen Neustart der NAS übersteht.

---

## Schritt 6 — Erreichbarkeit und Absicherung

Adresse aus Schritt 5e im Browser aufrufen. Es muss die Passwortabfrage
erscheinen. **Erscheint sie nicht, ist `RVK_APP_PASSWORD` nicht angekommen —
sofort Funnel abschalten** und Schritt 3 prüfen.

Zur Erinnerung: Funnel ist wirklich öffentlich. Wer die Adresse kennt, sieht
die Anmeldemaske. Das Passwort ist die einzige Hürde, also ein ordentliches
wählen und nicht per unverschlüsselter Mail verteilen.

Reicht das später nicht mehr — etwa weil das Werkzeug offiziell wird —
ist Cloudflare Tunnel mit E-Mail-Anmeldung der nächste Schritt. Braucht eine
eigene Domain, bietet dafür echte Zugangskontrolle.

---

## Schritt 7 — Sicherung einrichten

Nur eine Datei ist unersetzlich: `RVK_data/feedback.db`. Alles andere lässt
sich neu erzeugen.

In **Hyper Backup** eine Aufgabe für `/volume1/docker/rvk/RVK_data/feedback.db`
und `/volume1/docker/rvk/.env` anlegen, wöchentlich. Die grossen
`*_norm.rds` bewusst ausschliessen — sie sind reproduzierbar und würden jede
Sicherung aufblähen.

---

## Wiederkehrende Handgriffe

**Code geändert** (app.R oder lib_*.R): Datei auf der NAS ersetzen, im
Container Manager den Container neu starten. Kein Neubau nötig.

**Daten aktualisiert** (siehe WARTUNG.md): neue Dateien nach `RVK_data/`
kopieren, Container neu starten.

**Neues R-Paket nötig:** in den Dockerfile aufnehmen, im Container Manager
Projekt → **Erstellen** (Rebuild).

**Protokoll ansehen:** Container Manager → Projekt → Container → Protokoll.
Fehler beim Klassifizieren erscheinen dort im Klartext.

---

## Wenn etwas klemmt

| Symptom | Wahrscheinliche Ursache |
|---|---|
| Container startet, beendet sich sofort | `.here` fehlt, oder `app.R` liegt nicht direkt in `/volume1/docker/rvk` |
| „OPENAI_API_KEY ist nicht gesetzt" | `.env` fehlt oder falsch formatiert; Projekt neu starten |
| „Die Indizes konnten nicht geladen werden" | `_norm.rds` oder `rvk.db` fehlen in `RVK_data/` |
| Start bricht nach Minuten ab | Speicherlimit zu knapp — `mem_limit` erhöhen |
| Funnel-Adresse antwortet nicht | DNS-Verbreitung abwarten; `funnel status` prüfen |
| Keine Passwortabfrage | `RVK_APP_PASSWORD` nicht angekommen — Funnel sofort abschalten |
