# Neue Funktionen in Nido

Alle Versionen von Nido, die neueste zuerst. Beim ersten Öffnen nach einem Update zeigt Nido die Neuerungen der installierten Version (unter Hilfe › Neue Funktionen in Nido kannst du sie erneut lesen).

## [0.8.1] – 2026-11-13

### Sprachen
- **Die Sprache von Nido wählst du unter Einstellungen › Allgemein › Sprache**: Englisch, Italienisch, Deutsch, Spanisch, Französisch oder wie das System. Nido wird beendet und in der neuen Sprache wieder geöffnet; läuft eine VM, fragt Nido vorher wie beim Beenden, was mit ihr geschehen soll. Es ist dieselbe Einstellung wie unter Systemeinstellungen › Allgemein › Sprache & Region › Apps.

## [0.8.0] – 2026-11-13

### Sprachen
- **Nido spricht jetzt Englisch, Italienisch, Deutsch, Spanisch und Französisch**: die App, der Befehl `nido`, die Versionshinweise und das README. Englisch ist die Basissprache. Die App folgt der Sprache, die du in macOS verwendest, und erscheint bei jeder anderen Sprache auf Englisch.
- Der Befehl `nido` folgt der Systemsprache. Mit `NIDO_LANGUAGE` (`en`, `it`, `de`, `es` oder `fr`) wählst du eine andere, etwa für Skripte, die seine Ausgabe lesen.

### Nido Guest Tools 1.5.0
- **Meldungen zu Ollama und den Modellen erscheinen in deiner Sprache**: Die Guest Tools senden zu jedem Fehler und jeder Warnung einen festen Code, und die App zeigt dazu ihren eigenen Text. Ältere Guest Tools senden ihre Meldungen weiterhin auf Italienisch, und Nido zeigt sie so, wie sie ankommen: Installiere die Guest Tools in den Einstellungen der VM erneut, um die neue Version in bestehenden VMs zu erhalten.

### Der Befehl nido im Menü
- **Nido › nido-Befehl installieren …** erstellt `~/.local/bin/nido`, einen Link auf den Befehl, der jetzt in der App liegt (zusammen mit `gvproxy`): Der Befehl wird mit der App aktualisiert. Ist `~/.local/bin` nicht in deinem `PATH`, weist Nido darauf hin. Eine zuvor mit `scripts/install.sh` installierte Kopie wird erst nach deiner Bestätigung ersetzt.
- **Nido › nido-Befehl entfernen** entfernt den Link nur, wenn er auf Nido zeigt.
- Direkt aus dem DMG geöffnet, installiert Nido den Befehl nicht und bittet dich, die App zuerst in den Ordner „Programme“ zu bewegen.

### Updates
- **Nido › Nach Updates suchen …** prüft, ob es eine neue Version gibt. Nido geht nie von selbst online: Die automatische Suche läuft nur, wenn du sie aktivierst (auf die Frage beim zweiten Start oder unter **Einstellungen › Allgemein › Automatisch nach Updates suchen**, standardmäßig deaktiviert).
- **Nie mit laufender VM**: Solange eine VM läuft, in der App oder mit `nido start`, wartet ein heruntergeladenes Update. Es wird installiert, wenn du Nido beendest und keine VM läuft, und ein Hinweis nennt die VMs, die es aufhalten.
- Jedes Update ist signiert (EdDSA) und wird über HTTPS heruntergeladen; Nido lehnt ein Update oder eine Versionsliste ohne gültige Signatur ab.

### Developer-ID-Signatur
- **Nido ist mit einem Developer-ID-Zertifikat signiert und von Apple notarisiert**: Die App öffnet sich, ohne dass du Gatekeeper umgehen musst. Die App, der Befehl `nido`, `gvproxy` und Sparkle tragen alle dieselbe Signatur, mit Hardened Runtime.
- Neben dem DMG liegen die SHA-256-Prüfsummen und die Liste der Komponenten (SBOM, SPDX).

### Schlüsselbund
- **Nach dem Wechsel der Signatur fragt macOS eventuell noch einmal nach dem Zugriff auf das Token für Hugging Face** im Schlüsselbund. Erlaube ihn einmal; lässt sich das Token nicht mehr lesen, gib es unter **Einstellungen › Hugging Face** erneut ein.

### Sicherheit
- **Eine VM kann Nido nicht mehr zum Beenden bringen**: Werte außerhalb des gültigen Bereichs, die das Gastsystem sendete (die Prozentwerte des Monitors, Größe und Fortschritt der Ollama-Modelle), brachten die App zum Absturz und mit ihr alle laufenden VMs. Jetzt werden sie begrenzt, bevor sie erscheinen.
- **Chat und Konsole blockieren die App nicht mehr**: Eine Antwort des lokalen Chats oder eine Konsolenausgabe, die Nido ausbremsen soll, wird in Teilen und in linearer Zeit gelesen, ohne die anderen VMs zu blockieren. Antworten im Chat haben außerdem eine Größenbegrenzung.
- **Die Adresse für Updates ist immer die von Nido**: Ein in den Einstellungen der App zurückgebliebener Wert kann sie nicht mehr ersetzen. Die Updates waren ohnehin signiert.

## [0.7.6] – 2026-11-10

### Images
- **`nido image check` zeigt den geprüften Debian-Build**, zum Beispiel `debian-13: aktuell (Build 20261103-2651)`; `nido image update` nennt den heruntergeladenen Build.
- **`nido image reset <id>`** vergisst nach einer Bestätigung den bereits akzeptierten Build und die Signatur eines Images. Das brauchst du nur, wenn Nido eine Liste immer wieder ablehnt, weil sie älter als die bereits akzeptierte sei; die Ablehnung weist jetzt darauf hin, statt eine Datei zu nennen, die du von Hand löschen musst. Das Image im Cache bleibt erhalten.

### Kontrolliertes Netzwerk
- Der Vorschlag **Deaktivieren** im Tab „Netzwerk“ und die Anzahl der ausgeblendeten Zeilen lokalen Hintergrundverkehrs sind jetzt durch einen UI-Test abgedeckt.

## [0.7.5] – 2026-11-10

### Kontrolliertes Netzwerk
- **Der Tab „Netzwerk“ schlägt vor, die Hintergrundanfragen zu deaktivieren**, in Linux-VMs, die vor Nido 0.7.4 erstellt wurden: **Deaktivieren** stoppt sie sofort (bei laufender VM), **Später** fragt für diese VM nicht mehr. Die Option bleibt auch unter Einstellungen › Guest Tools.
- **Der Tab „Netzwerk“ zeigt, wie viele Zeilen lokalen Hintergrundverkehrs er ausblendet** (IPv6-Multicast und Link-Local, Broadcast), und wie du sie mit `nido net log --all` siehst.

### Images
- **Debian: geprüfter Build.** Nido liest auch das Manifest des Builds, das Debian neben dem Image veröffentlicht, und lehnt vor dem Download widersprüchliche Dateien oder einen Build ab, der älter als der bereits akzeptierte ist. Debian signiert seine Cloud-Images nicht: Das ist keine Signatur, stoppt aber eine alte, erneut angebotene Kopie.
- **Ubuntu: bereit für einen Schlüsselwechsel.** Nido kann den aktuellen Signaturschlüssel und den als Nachfolger angekündigten akzeptieren, damit ein Schlüsselwechsel die Downloads nicht blockiert.

### VM-Fenster
- Die kompakte Leiste (Menü **Mehr**) ist jetzt durch einen UI-Test abgedeckt: In einem schmalen Fenster bleiben „Anhalten“ und „Stoppen“ sichtbar, und die Einträge unter „Mehr“ funktionieren.

## [0.7.4] – 2026-11-10

### Aufgeräumtes kontrolliertes Netzwerk
- **Debian sucht nicht mehr online nach Changelogs**: `apt-listchanges` versuchte stündlich, sie von `metadata.ftp-master.debian.org` herunterzuladen (das Cloud-Image enthält sie nicht), und das Protokoll füllte sich mit Blockierungen. Neue Linux-VMs haben es deaktiviert; für früher erstellte VMs genügt **Einstellungen › Guest Tools › Hintergrundanfragen · Deaktivieren**.
- **Lokaler Hintergrundverkehr erscheint nicht mehr im Protokoll**: IPv6-Multicast- und Link-Local-Ankündigungen (`ff02::…`) und Broadcasts der Netzwerkschnittstelle der VM, die die VM nie verlassen, gibt `nido start` nicht mehr aus, und der Tab „Netzwerk“ zeigt sie nicht mehr an. `nido net log` sagt, wie viele Zeilen ausgeblendet wurden; `nido net log --all` zeigt sie an.

### Ubuntu-Images
- **Eine Prüfsummenliste, die vor der zuletzt akzeptierten signiert wurde, wird abgelehnt**: Wer eine alte (aber signierte) Liste erneut anbietet, um den Cache auf einem früheren Build festzuhalten, wird vor dem Download gestoppt.
- **Wechselt Ubuntu den Signaturschlüssel**, sagt Nido das („mit einem Schlüssel signiert, den Nido nicht kennt“, mit der Schlüssel-ID), statt nur „ungültige Signatur“ zu melden.

### VM-Fenster
- **In einem schmalen Fenster** landen die Tasten, die nicht mehr passen („Ruhezustand“, „Schnappschüsse“, „Einstellungen“, „Zugriff über Terminal“, „Vollbildmodus“), im Menü **Mehr**; „Anhalten“, „Fortsetzen“, „Starten“ und „Stoppen“ bleiben immer sichtbar.

## [0.7.3] – 2026-11-10

### Einstellungen bei laufender VM
- **Die Taste „Einstellungen“ gibt es auch bei laufender VM**, im Fenster der VM und auf ihrer Karte in der Bibliothek. CPU und Arbeitsspeicher bleiben gesperrt, bis die VM gestoppt ist; die Aktionen in der VM (Guest Tools, **Hintergrundanfragen · Deaktivieren**) sind gerade für die laufende VM gedacht.

## [0.7.2] – 2026-11-09

### Ubuntu-Images: Signatur geprüft
- **Nido prüft die Signatur von Ubuntu auf der Prüfsummenliste** (`SHA256SUMS.gpg`), bevor es sie verwendet, sowohl beim Download als auch mit `nido image check`. Der Schlüssel von Ubuntu ist in Nido enthalten; `gpg` brauchst du nicht. Fehlt die Signatur oder stimmt sie nicht, lädt Nido das Image nicht herunter. Der Schritt „Download“ zeigt es an: „SHA-256-Prüfsumme · Ubuntu-Signatur“.
- Debian veröffentlicht für seine Cloud-Images keine Signatur: Dort bleibt es bei der Prüfung der Prüfsumme über HTTPS.

### Aufgeräumtes kontrolliertes Netzwerk
- **Die SRV-Abfragen von apt sind in jeder neuen Linux-VM deaktiviert**, auch unter Debian (bisher erschienen sie bei jedem `apt update` als Blockierungen im Protokoll).
- **Früher erstellte VMs**: VM-Einstellungen › Guest Tools › **Hintergrundanfragen · Deaktivieren** wendet dieselben Einstellungen bei laufender VM über SSH an. Unter Ubuntu deaktiviert es auch Snap, die Nachrichten, Ubuntu Pro und die Suche nach neuen Versionen.
- Auch live mit Ubuntu 24.04 getestet.

### Fehlerbehebungen
- Image-Cache: Lässt sich das neue Image nicht sichern, bleibt seine neue Prüfsumme nicht neben dem alten liegen; eine Prüfung des Caches, die sich mit einem Download desselben Images überschneidet, lädt es kein zweites Mal herunter.

## [0.7.1] – 2026-11-09

### Ein ruhigeres Ubuntu im kontrollierten Netzwerk
- Neue Ubuntu-VMs versuchen nicht mehr, Snap (`api.snapcraft.io`), die Nachrichten der Anmeldemeldung (`motd.ubuntu.com`), Ubuntu Pro (`contracts.canonical.com`), die Suche nach neuen Versionen (`changelogs.ubuntu.com`) und `entropy.ubuntu.com` zu erreichen, und apt fragt keine SRV-Einträge mehr ab: Das Verbindungsprotokoll füllt sich nicht mehr mit Blockierungen. Pakete, Sicherheitsupdates und die Uhr funktionieren wie bisher.
- Zum erneuten Aktivieren in der VM: `sudo systemctl unmask snapd.service snapd.socket snapd.seeded.service` (und ebenso für die anderen Units), dann die Domain im Tab „Netzwerk“ erlauben.
- Früher erstellte Ubuntu-VMs ändern sich nicht.

### Fehlerbehebungen
- **Sicherere qcow2-Images**: Ein qcow2, das denselben Cluster zweimal verwendet oder viel mehr Daten beschreibt, als die Datei enthält, wird abgelehnt, bevor etwas auf die Festplatte geschrieben wird. Das betrifft nur `--image-file` mit eigens präparierten Dateien; die Images von Ubuntu funktionieren wie bisher.

## [0.7.0] – 2026-11-09

### Images: neue Builds
- **Nido meldet, wenn Debian oder Ubuntu einen neuen Build** eines Images veröffentlicht, das schon im Cache liegt (meist mit Sicherheitskorrekturen). Bisher blieb die heruntergeladene Kopie für immer dieselbe, ohne Hinweis.
- Im Assistenten „Neue VM“, Schritt „Download“: Liegt das Image schon im Cache, gibt es **Nach neuem Build suchen**. Gibt es einen, holt ihn die Taste „Laden“, prüft ihn und ersetzt damit den alten.
- Im Terminal: `nido image list` (Katalog und Cache, ohne Netzwerk), `nido image check [id]` und `nido image update <id>`.
- Die Prüfung lädt nur die Prüfsummenliste herunter, nie das Image, und läuft nur, wenn du sie anforderst. Bestehende VMs ändern sich nicht.

### Fehlerbehebungen
- **`nido ssh` verwendet den Schlüssel, mit dem die VM erstellt wurde.** Bei einer VM, die mit einem anderen als den Standardschlüsseln in `~/.ssh` erstellt wurde, kam „Permission denied (publickey)“. Liegt der private Schlüssel nur in einem Agent (zum Beispiel einem Passwortmanager), funktioniert es trotzdem. Ein `-i` nach `--` wird weiterhin versucht.

## [0.6.0] – 2026-11-03

### Kontrolliertes Netzwerk: wieder Standard
- **Neue VMs starten wieder im kontrollierten Netzwerk** (Linux und macOS), und es funktioniert jetzt auch bei deaktivierter IP-Weiterleitung des Mac, also mit der Standardeinstellung von macOS. Die Warnung zur IP-Weiterleitung aus 0.5.1 gibt es nicht mehr: Nido liest und ändert `net.inet.ip.forwarding` nicht mehr.
- Im Hintergrund hat jede kontrollierte VM ihr eigenes `gvproxy`, ein kleines Programm eines Drittanbieters, das anstelle von vmnet das NAT übernimmt. Der Filter von Nido entscheidet weiterhin zuerst, für jedes Paket. Startet `gvproxy` nicht oder beendet es sich, bleibt die VM ohne Netzwerk, und Nido meldet es: Nie springt das NAT von Apple ein.
- `gvproxy` (gvisor-tap-vsock 0.9.0, Apache-2.0) ist das einzige Programm eines Drittanbieters in Nido: Version und Prüfsumme sind festgelegt, es wird nie heruntergeladen, während die App läuft, und es trägt die Signatur von Nido. Lizenzen und Hinweise findest du in der App. Für eine Firewall auf dem Mac geht erlaubter Datenverkehr als `gvproxy` hinaus.
- **SSH über `127.0.0.1`**: `nido ssh`, `nido ip` und die SSH-Befehle der App erreichen eine kontrollierte VM über einen lokalen Port (er ändert sich bei jedem Start; der Hostschlüssel wird weiterhin erkannt). Die VM hat immer die Adresse `192.168.127.2`. VMs im NAT von Apple ändern sich nicht.
- **Das Entfernen einer Domain schließt die offenen Verbindungen in der VM wirklich**: Bisher trennte das Relay sie, ohne dass die VM es merkte, und ein laufender Download hing fest; jetzt erhält die VM ein Reset, und das Programm meldet sofort einen Fehler.
- **Basisliste für macOS**: Neue macOS-VMs starten mit den Servern von Apple für Aktivierung, Update-Suche und Uhr (`albert`, `gdmf`, `mesu`, `swscan`, `swdist`, `time` von `apple.com`) statt mit einer leeren Liste: Der Systemassistent kommt bis zum Schreibtisch, und `softwareupdate --list` funktioniert. Zum Herunterladen eines Updates brauchst du auch `updates.cdn-apple.com` und `updates-http.cdn-apple.com`; Apple-ID, iCloud und App Store musst du weiterhin selbst erlauben.
- **„In der VM eingeben“ tippt jetzt auch Zeichen mit Umschalttaste richtig** (wie `$` und `"` auf einer deutschen Tastatur): Bisher kamen sie in der macOS-VM ohne Umschalttaste an.
- War eine kontrollierte VM aus 0.5.x im Ruhezustand, startet sie von vorn (der gesicherte Zustand ist nicht kompatibel).
- **Debian-VMs aus 0.5.0 ohne die Pakete des ersten Starts**: Nido installiert sie nicht nachträglich (cloud-init installiert sie nur beim ersten Start). Installiere sie bei laufender VM mit Netzwerk (`deb.debian.org` steht in der Basisliste) über SSH: `nido ssh <vm> -- sudo apt-get update`, dann `nido ssh <vm> -- sudo apt-get install -y ca-certificates curl wget git python3 python3-venv python3-pip openssh-server iproute2 procps util-linux jq tar zstd`. Oder erstelle die VM neu.

## [0.5.1] – 2026-11-02

### Ubuntu Server
- **Ubuntu Server 26.04 LTS und 24.04 LTS** als Systeme für Linux-VMs, neben Debian 13: im Assistenten „Neue VM“ (Kachel „Ubuntu Server“, mit Auswahl der Version) oder mit `nido create --image ubuntu-26.04` / `ubuntu-24.04`.
- Die Images kommen von `cloud-images.ubuntu.com` und werden vor der Verwendung mit SHA-256 geprüft.
- Ubuntu veröffentlicht die arm64-Images nur im Format qcow2: Nido wandelt sie selbst in eine Festplatte um, die nur den belegten Platz verbraucht, ohne externe Werkzeuge. Das gilt auch für ein lokales Image mit `--image-file`.
- Die Bibliothek und `nido list` zeigen die Distribution jeder VM.
- Die Guest Tools lassen sich auch unter Ubuntu installieren.
- Basisliste des kontrollierten Netzwerks für Ubuntu: `archive.ubuntu.com`, `security.ubuntu.com`, `ports.ubuntu.com`, dazu Ollama und `time.cloudflare.com`. Die Uhr neuer Ubuntu-VMs synchronisiert sich mit `time.cloudflare.com`.

### Kontrolliertes Netzwerk: jetzt optional
- **Neue VMs starten im NAT von Apple.** Mit 0.5.0 erreichte eine neue VM im kontrollierten Netzwerk auf einem Mac mit Standardeinstellungen keine einzige Website, auch keine erlaubte: Das kontrollierte Netzwerk funktioniert nur bei aktivierter IP-Weiterleitung des Mac (`net.inet.ip.forwarding`), die meist deaktiviert ist. Den Grund erklärt `docs/SECURITY.md`.
- Das kontrollierte Netzwerk aktivierst du in den Einstellungen der VM, Bereich „Netzwerk“. Neue Linux-VMs haben die Basisliste schon bereit, macOS-VMs eine leere Liste.
- Ist die IP-Weiterleitung deaktiviert, weist die Bestätigung zum Aktivieren des kontrollierten Netzwerks darauf hin, und jeder Start einer kontrollierten VM zeigt eine Warnung (auch `nido start`). Nido liest die Einstellung, ändert sie aber nicht.
- Mit 0.5.0 erstellte VMs bleiben im kontrollierten Netzwerk: Erreichen sie das Internet nicht, deaktiviere es in den Einstellungen der VM. Eine ohne Netzwerk erstellte Debian-VM hat die Pakete des ersten Starts nicht installiert.

## [0.5.0] – 2026-10-29

### Kontrolliertes Netzwerk für VMs
- **Neue VMs erreichen im Internet nur erlaubte Domains.** Nido sitzt am „Netzwerkkabel“ der VM: Es beantwortet ihre DNS-Anfragen und lässt nur Verbindungen zu den Adressen durch, die es für eine Domain der Liste aufgelöst hat. Alles andere wird blockiert: nie per Name abgefragte Adressen, DNS zu anderen Servern, IPv6, ICMP, die Dienste des Mac (SSH vom Mac zur VM bleibt möglich).
- Basisliste der Linux-VMs: `deb.debian.org`, `registry.ollama.ai` und der Modellspeicher von Ollama, `time.cloudflare.com`. Bestehende VMs bleiben im NAT von Apple, bis du das kontrollierte Netzwerk in den Einstellungen der VM aktivierst, Bereich „Netzwerk“.
- Startet das kontrollierte Netzwerk nicht, bleibt die VM ohne Netzwerk, und Nido meldet es: Nie springt das NAT ein.
- **Hinweise**: Jede Blockierung kommt als Mitteilung von Nido, mit VM, Ziel und Port; wiederholte Blockierungen werden zu einem Hinweis mit ihrer Anzahl zusammengefasst. Ist die App geschlossen, schreibt `nido start` eine Zeile ins Terminal, und die App zeigt die Hinweise beim nächsten Öffnen. Der Hintergrundverkehr beim Start (lokales IPv6, Broadcast) bleibt nur im Protokoll.
- **Erlauben** im Hinweis fügt die Domain mit Touch ID oder dem Passwort deines Mac zur Liste hinzu und gilt sofort, ohne Neustart der VM. Das Entfernen einer Domain fragt nichts und trennt sofort ihre offenen Verbindungen; auch das Deaktivieren des kontrollierten Netzwerks verlangt Touch ID.
- Verbindungsprotokoll im Fenster der VM (Tab „Netzwerk“) und mit `nido net log`: Uhrzeit, Domain, Adresse, Port, Bytes, Ergebnis. Nie der Inhalt des Datenverkehrs.
- `nido net list|allow|deny|reset` verwaltet die Liste im Terminal; `allow` und `reset` verlangen Touch ID.
- **Prüfung des TLS-Namens**: Eine HTTPS-Verbindung zu einer erlaubten Adresse, die eine nicht erlaubte Website desselben CDN nennt, wird getrennt, und „Erlauben“ bietet diesen Namen an. Das ist eine zusätzliche Prüfung, keine vollständige (QUIC und einige Browser sind nicht abgedeckt: siehe `docs/SECURITY.md`).
- **macOS-VMs**: Auch sie nutzen das kontrollierte Netzwerk, aber mit leerer Liste: macOS erreicht die Dienste von Apple (Aktivierung, Updates, App Store, iCloud) erst, wenn du sie erlaubst. Bleibt der Systemassistent bei der Aktivierung stehen, füge `albert.apple.com` hinzu oder deaktiviere das kontrollierte Netzwerk für den Systemassistenten.
- Mit dieser Version erstellte oder geänderte VMs lassen sich mit früheren Versionen von Nido nicht öffnen.

### Nido Guest Tools 1.4.0
- Das Archiv von Ollama lädt der Mac herunter (Version und SHA-256 festgelegt) und schickt es in die VM (`--archive-stdin`): Die VM kontaktiert GitHub nie. Die KI-Ansicht zeigt den Download auf dem Mac, mit „Abbrechen“.
- Das Archiv bleibt in `~/Library/Caches/Nido/ollama`; alte Versionen werden nicht automatisch gelöscht.
- Die Uhr neuer VMs synchronisiert sich mit `time.cloudflare.com`.
- Um Ollama in einer bestehenden VM zu installieren, brauchst du die Guest Tools 1.4.0: Installiere sie in den Einstellungen der VM erneut.

## [0.4.0] – 2026-10-27

### macOS-VMs
- **Erstelle eine macOS-VM aus einer IPSW-Datei** deiner Wahl (Nido lädt nichts herunter und lässt die Datei unverändert): im Assistenten „Neue VM“ oder mit `nido create --ipsw`. Bevor eine Datei angelegt wird, prüft Nido, ob das Image zu diesem Mac passt.
- Die Installation dauert je nach Mac und Festplatte 4 bis 20 Minuten, mit Fortschritt und „Abbrechen“; wird sie unterbrochen, bleibt keine halbfertige VM zurück.
- Das Fenster der VM zeigt den Bildschirm von macOS. Das Schließen des Fensters sollte die VM weiterlaufen lassen (noch nicht überprüft).
- **Zugriff über Terminal**: Ein Bereich führt dich durch das Aktivieren von „Entfernte Anmeldung“ und das Autorisieren deines Schlüssels; **In der VM eingeben** tippt den Befehl ins Terminal des Gastsystems (ohne den Zeilenschalter zu drücken). Danach meldet sich `nido ssh` mit dem Account an, den du beim Erstellen angegeben hast. Live getestet mit macOS 26.6.2 (deutsche Tastatur): Der Befehl verwendet `"$HOME"` statt `~`, das auf manchen Tastaturen nur über eine Tottaste erreichbar ist.
- Ruhezustand, Schnappschüsse einer gestoppten VM, Wiederherstellen und Klonen funktionieren auch für macOS (mit einer echten IPSW getestet); der Schnappschuss einer laufenden VM aus der App ist noch nicht überprüft; ein Klon erhält eine neue Kennung und zeigt die Schritte, die in der Kopie einmal nötig sind (SSH-Hostschlüssel und Computername).
- Geteilte Ordner (standardmäßig nur lesend, unter `/Volumes/My Shared Files`) und Audioausgabe sind eingerichtet, im Gastsystem aber noch nicht überprüft. Keine geteilte Zwischenablage und kein Mikrofon.
- Guest Tools, Monitor, Provisioning, Ollama, KI-Brücke und VM-Vorlagen bleiben Linux vorbehalten.

### Linux und App
- Ein unterbrochener erster Start unter Linux lässt die VM nicht mehr ohne SSH-Zugriff: Fehlende Hostschlüssel werden bei jedem Start neu erzeugt.
- Beendest du Nido in der ersten Minute des ersten Starts, weist die App darauf hin.
- `nido list` zeigt die Spalte SYSTEM.

## [0.3.1] – 2026-10-26

### Chat mit lokalen Modellen
- Weblinks in Antworten öffnen sich im Browser; Adressen, die ihr Ziel verbergen, Adressen zum Mac selbst und jede andere Art von Adresse bleiben Text.
- Jede Antwort nennt das Modell, das sie geschrieben hat.
- **Chat löschen** fragt nach, bevor die Unterhaltung verloren geht.
- Ist Ollama gestoppt, sagt der Chat, dass du es mit **Starten** starten kannst.

### Sicherheit und Zuverlässigkeit
- Die KI-Brücke schließt mit der VM: Stoppst du die VM oder versetzt du sie in den Ruhezustand, werden laufende Anfragen an Hugging Face sofort abgebrochen und verbrauchen kein weiteres Budget.
- Fehler von Hugging Face erreichen die VM ohne Daten deines Accounts: nur der Code und eine feste Erklärung.
- Der SSH-Schlüssel jeder VM ist an die VM gebunden, nicht an ihre Adresse: Ändert sich die Adresse, verlangt Nido denselben Schlüssel.
- Wartende Verbindungen der Brücke belegen keine Threads des Mac mehr.

### Nido Guest Tools 1.3.0
- Die Dienste in der VM laufen mit strengeren Systembeschränkungen.
- Updates entfernen Dateien, die die neue Version nicht mehr verwendet.
- Ein gestopptes Ollama bleibt auch nach einem Neustart der VM gestoppt, bis du es startest, neu startest, neu installierst oder aktualisierst.
- Installiere die Guest Tools in den Einstellungen der VM erneut, um sie in bestehenden VMs zu erhalten.

## [0.3.0] – 2026-10-26

### Chat mit lokalen Modellen
- Antworten zeigen Markdown-Formatierung: **fett**, *kursiv*, `Code`, Listen, Überschriften, Zitate und Codeblöcke.
- Die Antwort erscheint ohne Flackern, und die Unterhaltung folgt ihr; scrollst du nach oben, bleibt sie, wo du bist, und **Zum Ende** erscheint.
- **Kopieren** legt eine Antwort in die Zwischenablage, genau so, wie das Modell sie geschrieben hat.
- Unter jeder Antwort: wie lange sie gedauert hat und wie viele Tokens pro Sekunde das Modell erzeugt hat.
- Während das Modell die Antwort vorbereitet, siehst du es sofort; **Stoppen** (oder Esc) bricht sie ab.
- Der Chat bleibt in der VM und im Arbeitsspeicher: Nido sichert ihn nicht auf dem Mac, und Ollama ist von außen nicht erreichbar.

### KI in VMs
- Neue Debian-VMs, sofort einsatzbereit: grundlegende Pakete und Nido Guest Tools beim ersten Start.
- Ollama und die gewählten Modelle werden mit einem Klick in der VM installiert, mit geprüfter Version und Prüfsumme.
- Monitor der VM: CPU, Arbeitsspeicher, Festplatte und Warnungen, ohne Netzwerk aus der VM gelesen.
- Optionale KI-Brücke zu Hugging Face: Das Token bleibt im Schlüsselbund, nie in der VM; Limits für Tokens und Anfragen pro VM und ein Protokoll ohne Inhalte.
- VM-Vorlagen: Sichere eine VM als Vorlage und erstelle daraus neue VMs.

### Virtuelle Maschinen
- Schnappschüsse, Ruhezustand und Fortsetzen mit dem Zustand des Arbeitsspeichers.
- Klone eine gestoppte VM.
- Geteilte Ordner: standardmäßig keine, nur lesend, sofern du nichts anderes wählst, und jederzeit widerrufbar, auch bei laufender VM; Klone und Vorlagen übernehmen sie nicht.
- Rosetta, um x86-64-Programme in Linux-VMs auszuführen.
- Eine Warnung, wenn der Arbeitsspeicher der laufenden VMs mehr beträgt, als der Mac bereitstellen kann, und automatischer Neustart einer VM, die nach einer Kernel-Panic hängt.

### Terminal
- `nido --version`, `nido template` und `nido create --from-template`.

### Fehlerbehebungen
- Änderungen an der Konfiguration einer VM, die gleichzeitig in der App und im Terminal vorgenommen werden, heben sich nicht mehr gegenseitig auf.
- Die KI-Brücke gibt ihre Verbindungen frei, wenn der Mac seine Seite schließt (Guest Tools 1.2.1: Installiere sie in bestehenden VMs erneut).

## [0.2.0] – 2026-10-23

### Erste Version der App
- Bibliothek der VMs mit Live-Status.
- Assistent zum Erstellen von Debian-VMs.
- Fenster der VM mit Bildschirm, serieller Konsole, Anhalten und Fortsetzen.
- Einstellungen der VMs und von Nido.

## [0.1.0] – 2026-10-23

### Der Befehl `nido`
- `nido create`, `list`, `start`, `stop`, `ip`, `ssh` und `delete`.
- Debian-Images, nur aus zugelassenen Quellen heruntergeladen und mit SHA-512 geprüft.
- Zugriff auf die VMs nur mit SSH-Schlüssel.
