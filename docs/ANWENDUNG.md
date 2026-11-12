# RVK-Klassifikationsassistent – Anwendung und Überblick

*Fassung der Informationsmail an die Nutzenden der UB Bern (Herbst 2026). Zugangsdaten entfernt.*

Ich habe in den letzten Wochen ein Werkzeug gebaut, das für neue Titel einen
RVK-Notationsvorschlag macht. Es ist jetzt so weit, dass ihr es ausprobieren
könnt. Diese Mail ist bewusst ausführlich: Teil 1 ist das Praktische, Teil 2
erklärt in zwei Absätzen, was dahintersteckt, Teil 3 geht ins Detail für alle,
die es genauer wissen wollen, Teil 4 beschreibt, wie es weitergeht. Wer nur
loslegen will, liest Teil 1 und ignoriert den Rest.

---

## 1. Wie es in der Praxis funktioniert

### Zugang

Adresse und Zugangswort werden separat mitgeteilt.

Läuft im Browser, ohne VPN, ohne Installation, auch von zu Hause. Bitte das
Zugangswort nicht weitergeben und nicht in offene Verteiler schreiben – die
Adresse ist öffentlich erreichbar, das Passwort ist die einzige Hürde.

### Systematik wählen

Oben links stehen drei Modi. Die Wahl ist wichtig, sie verändert das Ergebnis
deutlich:

- **RVK vonRoll** – für die sozialwissenschaftliche Bibliothek. Berücksichtigt
  unser Gesamtregister (gesperrte Notationen, lokale Stichwörter,
  Sonderlösungen) und unseren Bestand.
- **RVK BWW** – für die Wirtschaftsbibliothek. Ohne unser Gesamtregister, aber
  mit dem BWW-Bestand, und bei gleichwertigen Alternativen wird der Q-Bereich
  bevorzugt.
- **RVK Standard** – reine RVK ohne jede lokale Anpassung. Gedacht für den
  Blick von aussen oder zum Vergleich, im Alltag braucht man ihn kaum.

### Einzeltitel

Der Normalfall. Titel und Untertitel in ein Feld, auf **Klassifizieren**, nach
etwa fünf bis zehn Sekunden steht das Ergebnis da.

Ein **Klappentext** lässt sich optional ergänzen, ist aber meistens unnötig.
Sinnvoll nur bei Titeln, die für sich genommen nichts hergeben – „Soziale
Entwicklung" oder ähnlich Nichtssagendes.

### Mehrere Titel

Zweiter Reiter, ein Titel pro Zeile, maximal 25 auf einmal. Die Verarbeitung
läuft nacheinander und lässt sich abbrechen. Es gibt eine Kartenansicht, eine
Tabellenansicht zum schnellen Überfliegen und einen CSV-Export.

### Das Ergebnis lesen

Ihr bekommt:

- **Notation und Benennung** – der Vorschlag, mit Kopierknopf
- **Pfad** – wo die Stelle in der RVK-Hierarchie sitzt
- **Begründung** – zwei, drei Sätze, warum
- **Alternative** – eine zweite vertretbare Stelle, ebenfalls mit Begründung
- **Ähnliche Titel im Bestand** – welche vergleichbaren Bücher wir schon haben
  und unter welcher Signatur sie stehen
- **Konfidenz** – hoch, mittel oder niedrig, samt Angabe, worauf sie beruht

### Und jetzt die Erwartungen

**Das Werkzeug liegt nicht immer richtig, und „richtig" ist ohnehin die falsche
Kategorie.** Die RVK wird von Bibliotheken sehr unterschiedlichen
Spezialisierungsgrades genutzt. Für viele Bücher gibt es deshalb mehrere
sachlich vertretbare Stellen – eine reine Erziehungswissenschafts-Bibliothek
stellt Soziologisches nach DU, eine reine Soziologie-Bibliothek dieselben Titel
nach MS. Wir liegen dazwischen. Wo genau, ist bei uns über Jahre gewachsen und
steht nirgends vollständig geschrieben.

Aus einem Test mit 51 Titeln, deren Notation wir kennen: In 92 % der Fälle war
die tatsächlich vergebene Notation unter den Kandidaten, und in rund 70 % traf
der erste Vorschlag sie genau. Bei manueller Durchsicht waren rund 90 % der
Vorschläge fachlich vertretbar – die Abweichungen waren fast durchweg Fälle mit
mehreren sinnvollen Stellen, nicht Fehlgriffe.

**Der nützlichste Teil der Ausgabe ist deshalb oft nicht der Vorschlag selbst,
sondern die Liste der ähnlichen Titel aus dem Bestand.** Dort seht ihr direkt,
wo vergleichbare Bücher bei uns tatsächlich stehen. Das ist häufig
aussagekräftiger als jede Begründung – und deckt auch auf, wo wir selbst
uneinheitlich sind.

Behandelt den Vorschlag also als das, was er ist: ein gut belegter
Ausgangspunkt, nicht als Entscheidung.

### Zwei Einschränkungen

**Recht (P).** Wir nutzen dort die St. Galler Systematik, nicht die
Standard-RVK. Das Werkzeug kennt sie nicht. Bei einem Rechtstitel erscheint ein
entsprechender Hinweis, und der Vorschlag muss von Hand abgeglichen werden.

**Bestandsstand.** Die Bestandsdaten sind ein Auszug vom Sommer 2026. Ganz neue
Erwerbungen sind noch nicht dabei.

### Rückmeldungen

Unter jedem Ergebnis stehen zwei Knöpfe: **Übernommen**, wenn ihr den Vorschlag
verwendet, und **Abweichung melden** samt Feld für die Notation, die ihr
stattdessen vergeben habt.

Das ist der wichtigste Teil für die Weiterentwicklung, und es dauert zwei
Sekunden. Die Erfassung ist anonym. Wenn dieselbe Abweichung mehrfach auftaucht,
ist das fast immer eine hausinterne Konvention, die bisher nirgends dokumentiert
ist – die kann ich dann ins Gesamtregister aufnehmen, und das Werkzeug wendet
sie künftig selbst an.

### Erweiterte Optionen

In der Seitenleiste zugeklappt. Enthält die Wahl des Sprachmodells und ein paar
Stellschrauben. Im Alltag nicht nötig – die Voreinstellung ist das, was in
unseren Tests am besten abgeschnitten hat. Wer mag, kann aber gerne mit
verschiedenen Modellen vergleichen.

---

## 2. Was dahintersteckt, in zwei Absätzen

Das Werkzeug **rät die Notation nicht, es sucht sie**. Ein Sprachmodell kommt
nur an zwei Stellen vor: einmal ganz am Anfang, um den Buchtitel in
Bibliotheksvokabular zu übersetzen, und einmal ganz am Schluss, um aus einer
fertig zusammengestellten Liste auszuwählen. Dazwischen liegt normale
Datenbankarbeit.

Der entscheidende Punkt: Beim letzten Schritt sieht das Modell nur rund 50
Kandidaten samt Pfad, Registerbegriffen, Bemerkungen und Bestandshinweisen. Es
kann nichts vorschlagen, was nicht auf dieser Liste steht. Genau das war die
Schwäche meiner ersten Versuche mit einem einfachen Chatbot: Der hat regelmässig
Notationen erfunden, die es gar nicht gibt, und man konnte nicht nachvollziehen,
woher ein Vorschlag kam. Hier ist beides ausgeschlossen – erfinden geht nicht,
und die Belege stehen unter jedem Ergebnis.

---

## 3. Ausführlicher, für Interessierte

### Wie es entstanden ist

Ausgangspunkt war ein „Gem" bei Google Gemini, dem ich einen Ausschnitt der RVK
als Datei mitgegeben hatte. Das funktionierte in etwa 80 bis 90 % der Fälle,
hatte aber drei Probleme: Es erfand gelegentlich Notationen, ich konnte nicht
nachvollziehen, wie ein Vorschlag zustande kam, und die Qualität konnte sich
jederzeit ändern, wenn Google im Hintergrund etwas umstellt. Ausserdem war
unklar, wie gross die Referenzdatei überhaupt sein darf.

Daraus wurde der Entschluss, das Nachschlagen von der Beurteilung zu trennen –
Suchen und Filtern macht die Datenbank, entschieden wird erst am Schluss aus
einer geprüften Liste.

### Die RVK als Datenbank

Die RVK gibt es als XML-Datei, 155 MB, rund 783 000 Einträge. Die habe ich
einmalig in eine Datenbank überführt, mit Notation, Benennung, vollständigem
Pfad, Registerbegriffen und Bemerkungen pro Eintrag.

Der Pfad ist dabei wichtiger, als man denkt. Sehr viele RVK-Stellen heissen
schlicht „Allgemeines". Was damit gemeint ist, steht ausschliesslich im Pfad:
`Politologie > Politische Systeme einzelner Länder > Europa, Nordamerika >
Westeuropa > Schweiz > Politisches System`. Ohne den Pfad sind solche Einträge
schlicht nicht auffindbar.

### Vier Suchwege

Für jeden Titel laufen vier Suchen parallel:

**Stichwortsuche.** Klassische Volltextsuche über Benennungen und
Registerbegriffe. Findet wörtliche Treffer zuverlässig, versagt aber bei
Synonymen und bei deutschen Komposita.

**Bedeutungssuche.** Jeder RVK-Eintrag ist zusätzlich als Zahlenreihe
hinterlegt, die seinen inhaltlichen Gehalt abbildet – ein sogenanntes Embedding.
Zwei Texte mit ähnlicher Bedeutung ergeben ähnliche Zahlenreihen, auch über
Sprachgrenzen hinweg. Deshalb findet „migration" auch „Einwanderung", und ein
englischer Titel findet eine deutsche Systemstelle. Alle 675 000 zuweisbaren
Notationen sind so hinterlegt.

**Bestandssuche.** Dasselbe Verfahren, aber angewendet auf die Titel unserer
eigenen 66 000 Bände. Gesucht wird nicht nach der passenden Systemstelle,
sondern nach ähnlichen Büchern – und dann nachgesehen, wo die stehen.

**Lokale Zusatznotationen.** Stellen, die es nur bei uns gibt, etwa die
DX-Sonderlösung für Bilderbücher.

Die vier Ergebnislisten werden anschliessend nach einem etablierten Verfahren
zusammengeführt: Eine Notation, die mehrere Suchwege unabhängig voneinander
finden, steigt nach oben.

### Warum der Bestandskanal so viel bringt

Das war die grösste Einzelverbesserung im ganzen Projekt: Die Trefferquote stieg
dadurch von 59 auf 92 %.

Der Grund ist, dass dieser Kanal etwas weiss, was in der RVK nirgends steht:
unsere eigene Einordnungspraxis. Ein Beispiel – die Notation DK 1010 heisst
„Allgemeines und Deutschland". Über diese Beschreibung ist sie für ein
englischsprachiges Buch über Schulsysteme praktisch nicht zu finden; das Wort
„Deutschland" führt sogar aktiv in die Irre, denn gemeint ist „allgemeine
Literatur zu diesem Thema". Über die 74 Bücher, die bei uns bereits dort stehen,
ist sie dagegen sofort gefunden.

Dieselbe Logik gilt für MS 3600 (Migration, 300 Titel bei uns), DF 3000 (476
Titel) und etliche andere Arbeitspferde unseres Bestands.

### Das Gesamtregister

Unser hausinternes Register ist vollständig eingelesen: rund 1000 Regeln, davon
148 gesperrte Bereiche. Gesperrte Notationen fallen automatisch aus der
Kandidatenliste, lokale Stichwörter fliessen in die Suche ein, und die
Erläuterungen bekommt das Modell im Wortlaut mit – lokale Regeln gehen der
allgemeinen RVK-Praxis vor.

### Gemessen statt vermutet

Fast jede Entscheidung im Projekt beruht auf einem Test mit 51 Titeln, deren
Notation bekannt war. Zwei Beispiele, was das gebracht hat:

Ein Problem war lange, dass die RVK dasselbe Unterthema für jedes Land
wiederholt. Eine Suche zu Migration lieferte zehnmal „Aus- und Einwanderung,
Rückwanderung" für zehn verschiedene Länder – die halbe Kandidatenliste war
belegt, bevor etwas Interessantes kam. Solche Wiederholungen werden jetzt
zusammengefasst.

Ein anderes: Die Selbsteinschätzung des Sprachmodells zur eigenen Sicherheit war
komplett wertlos – bei „hoch" lag es in etwa so oft richtig wie sonst. Die
angezeigte Konfidenz beruht deshalb nicht darauf, sondern auf nachprüfbaren
Signalen, vor allem der Frage, wie viele ähnliche Titel im Bestand unter der
vorgeschlagenen Notation stehen.

Sieben Sprachmodelle wurden unter identischen Bedingungen verglichen, von
kommerziellen bis zu freien. Erstes Ausschlusskriterium war nicht die
Trefferquote, sondern ob ein Modell sich an die Kandidatenliste hält.

### Technik

R mit einer Shiny-Weboberfläche, SQLite als Datenbank. Die Embeddings kommen von
OpenAI, ebenso das Standardmodell für die Auswahl. Das Ganze läuft in einem
Docker-Container, vorerst auf meinem privaten NAS zu Hause, erreichbar über
einen verschlüsselten Tunnel (Tailscale).

### Was das Haus verlässt

Wichtig zu wissen: **Buchtitel werden an OpenAI übermittelt** – für die
Titelanalyse und für die Auswahl. Es handelt sich um publizierte
bibliografische Daten, keine Personendaten und nichts Vertrauliches. Wer
trotzdem einen Titel lieber nicht extern verarbeitet sehen will, gibt ihn
einfach nicht ein.

Nicht übermittelt werden: unser Bestand, unser Gesamtregister und die
Rückmeldungen. Die bleiben lokal.

### Kosten

Rund 0,3 Rappen pro Titel. Bei 3000 Titeln im Jahr sind das etwa 10 Franken.
Der einmalige Aufbau der Datenbasis hat rund 1.50 Franken gekostet.

---

## 4. Wie es weitergeht

**Jetzt: testen.** Nutzt es im Alltag und meldet zurück, wo es danebenliegt.
Nach einigen hundert Rückmeldungen lässt sich sagen, wo die Schwächen
systematisch sind – und ob die Konfidenzanzeige verlässlich genug ist, um ihr zu
trauen.

**Danach: ordentliches Hosting.** Ein privates NAS ist kein Dauerzustand. Wenn
sich das Werkzeug bewährt, möchte ich mit den Informatikdiensten über einen
richtigen Server sprechen. Das hat neben der Ausfallsicherheit einen konkreten
Vorteil: Die Universität betreibt eine eigene GPU-Umgebung (GPUStack) mit frei
nutzbaren Sprachmodellen. Eines davon hat in unseren Tests genauso gut
abgeschnitten wie das kommerzielle Modell. Es ist zurzeit nur nicht nutzbar,
weil der Zugang VPN voraussetzt, das auf dem NAS nicht läuft. Im Uni-Netz fiele
die Auslagerung an einen externen Anbieter komplett weg – und die Kosten auch.

**Laufend: Pflege.** Drei Aktualisierungen sind vorgesehen und dokumentiert:

- **Bestand**, jährlich aus einem neuen Alma-Export. Je aktueller, desto besser
  der stärkste Suchkanal.
- **RVK**, ebenfalls jährlich. Erscheint quartalsweise, ändert sich aber selten
  in einem Ausmass, das für uns relevant wäre.
- **Gesamtregister**, wenn sich etwas ändert – und insbesondere dann, wenn die
  Rückmeldungen eine wiederkehrende Abweichung zeigen.

**Perspektivisch:** Eine Anbindung an Zotero, sodass Titel aus unseren
Erwerbungsordnern automatisch einen Notationsvorschlag als Notiz bekommen. Der
Unterbau ist dafür vorbereitet, gebaut ist es noch nicht.

