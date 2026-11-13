# Localization

Nido speaks English (the source language) and Italian, German, Spanish and French: in the app,
the `nido` command, the release notes and the README. This page is the
reference for every string: the terms (glossary), the voice, the typography of each language,
and how strings, placeholders and plurals go into the String Catalogs. Tests keep the catalogs
complete (see [Catalog checks](#catalog-checks)).

The bar: **no wrong or stiff translations.** Each language reads like copy written for it, in
the conventions of macOS in that language, with the terms below.

## Contents

- [Languages and scope](#languages-and-scope)
- [Voice](#voice)
- [Glossary](#glossary)
- [Never translated](#never-translated)
- [Punctuation and typography](#punctuation-and-typography)
- [Numbers, units, dates](#numbers-units-dates)
- [Touch ID and password prompts](#touch-id-and-password-prompts)
- [The `nido` command](#the-nido-command)
- [Release notes](#release-notes)
- [Adding a string](#adding-a-string)
  - [The app's catalog and Xcode](#the-apps-catalog-and-xcode)
- [Placeholders](#placeholders)
- [Plurals](#plurals)
- [Catalog checks](#catalog-checks)

## Languages and scope

| Code | Language | Variant | Address |
|---|---|---|---|
| `en` | English | US (`canceled`, `catalog`, `color`) | — |
| `it` | Italian | Italy | `tu` |
| `de` | German | Germany | `du` (lower case, as macOS writes it) |
| `es` | Spanish | Spain, as macOS `es.lproj` (`ordenador`, `añadir`, `archivo`) | `tú` |
| `fr` | French | France, as macOS `fr.lproj` (`Réglages`, `Trousseau`) | `vous` |

Any other system language gets English. No other language is added without a new decision.

Localized: the app UI (menus, alerts, notifications, accessibility labels, help tags, the
copyright line in Info.plist), user-facing text from NidoCore (errors, progress, status), the
`nido` command (help, messages, errors, table headers), Guest Tools messages the app shows,
the release notes (Novità / What's New) and the README (`README.md`, `README.<lang>.md`).

English only: the contributor and security docs (`docs/SECURITY.md`, `docs/BUNDLE-FORMAT.md`,
`docs/DISK-CACHING.md`, `docs/LOCALIZATION.md`, `design/scripts/README.md`,
`guest/linux/README.md`).

Not localized: the AI bridge's HTTP error bodies sent to the guest (English, an API); log files
(`egress.log`, `ai-bridge.log`, `console.log`); `os_log`; build and release script output;
command names, flags and arguments of `nido`; accessibility identifiers.

**Italian is the current copy.** The Italian value of every key is today's Italian literal,
byte for byte (straight apostrophe `'`, `42 %` with a space, the existing word choices), unless
a test or the plan says otherwise. New Italian strings follow Nido's existing choices, even
where macOS says something else (Nido says `snapshot`, macOS `istantanea`; Nido
`Cerca aggiornamenti…`, macOS `Verifica aggiornamenti`; Nido `assistente iniziale`, macOS
`Impostazione Assistita`).
Where existing Italian text (release notes, docs) names a UI element with a label that does not
match the catalog, the label is corrected to the catalog's Italian value; nothing else changes.

## Voice

- Plain, short, active. Say what happens and what to do next. One idea per sentence.
- The same meaning in every language, not the same words: rebuild the sentence the way the
  language says it. Never translate word by word; never keep Italian or English word order
  when the language wants another.
- The user is addressed as in the table above: `tu`, `du`, `tú`, `vous`. German, Spanish and
  French use the imperative of that form (`Wähle`, `Elige`, `Choisissez`).
- The Mac is "the Mac" in every language (`il Mac`, `der Mac`, `el Mac`, `le Mac`), never
  "host"; the VM is "the VM" (feminine in it, de, es, fr: `la VM`, `die VM`, `la VM`, `la VM`).
- Capitalization:
  - `en`: Title Case for menu items, buttons, window and sheet titles, tab and section
    titles, and table column headers (`Create Snapshot…`, `Show in Finder`); sentence case for
    everything else (labels of toggles and fields, help text, alert messages, notifications,
    placeholders, errors).
  - `it`, `es`, `fr`: sentence case everywhere (`Crea snapshot…`, `Crear instantánea…`,
    `Créer un instantané…`).
  - `de`: sentence case everywhere; nouns keep their capital (`Schnappschuss erstellen …`).
- Alert titles that ask a question end with `?` (`Delete debian-13?`, `debian-13 löschen?`,
  `¿Eliminar debian-13?`, `Supprimer debian-13 ?`).
- Keep every string about as long as the English. German and French run ~30 % longer: prefer
  the shorter natural wording for buttons, badges, column headers and sheet titles.
- Errors: what went wrong, then what to do. No blame, no "please", no exclamation marks.

## Glossary

Sources: the German, Spanish and French terms marked **A** are macOS's own, read from the
system's localized resources (`/System/Applications/*.app`, Finder, System Settings panes,
LocalAuthentication, AppKit; `.loctable`/`.strings` files, read offline). The Italian column is
Nido's current copy. Unmarked terms are Nido's choices, made to read naturally next to Apple's.
Nouns are given with their gender where it matters (`m.`, `f.`, `n.`, `pl.`).

### Core objects

| English | Italian (Nido) | German | Spanish | French | Notes |
|---|---|---|---|---|---|
| virtual machine | macchina virtuale (f.) | virtuelle Maschine (f.) **A** | máquina virtual (f.) **A** | machine virtuelle (f.) **A** | Spelled out in titles and first mentions; `VM` elsewhere. |
| VM / VMs | VM / VM (f., invariable) | VM / VMs (f.) | VM / VM (f., invariable) | VM / VM (f., invariable) | `1 VM`, `2 VMs` (en, de); invariable in it, es, fr. |
| snapshot | snapshot (m., invariable) | Schnappschuss (m.), pl. Schnappschüsse **A** | instantánea (f.) **A** | instantané (m.) **A** | Apple's APFS term (Disk Utility). Italian keeps `snapshot`. |
| clone (verb) | clona | klonen | clonar | cloner | Copy of a VM (clonefile). |
| clone (noun) | clone / copia | Klon (m.) | clon (m.) | clone (m.) | |
| template | modello (m.) | Vorlage (f.) **A** | plantilla (f.) **A** | modèle (m.) **A** | A VM saved to make new VMs. Italian `modello` also means AI model: see *model*. |
| Save as Template | Salva come modello | Als Vorlage sichern | Guardar como plantilla | Enregistrer comme modèle | macOS German saves with `sichern`. |
| From Template | Da modello | Aus Vorlage | Desde plantilla | À partir d’un modèle | Wizard choice. |
| library | libreria (f.) | Bibliothek (f.) **A** | biblioteca (f.) **A** | bibliothèque (f.) **A** | The main window's list of VMs. |
| shared folder | cartella condivisa (f.) | geteilter Ordner (m.) **A** | carpeta compartida (f.) **A** | dossier partagé (m.) **A** | |
| read only / read & write | sola lettura / lettura e scrittura | Nur Lesen / Lesen & Schreiben **A** | Solo lectura / Lectura y escritura **A** | Lecture seule / Lecture et écriture **A** | Shared folder access. |
| bundle (VM folder) | cartella della VM | VM-Ordner (m.) | carpeta de la VM | dossier de la VM | Users see a folder, not a "bundle". |
| image (OS image) | immagine (f.) | Image (n.) | imagen (f.) | image (f.) | Cloud or local disk image of a system. |
| disk image | immagine disco | Image **A** | imagen de disco **A** | image disque **A** | |
| IPSW file | file IPSW (m.) | IPSW-Datei (f.) | archivo IPSW (m.) | fichier IPSW (m.) | |
| cache | cache (f.) | Cache (m.) **A** | caché (f.) **A** | cache (m.) **A** | `nella cache`, `im Cache`, `en la caché`, `en cache`. |
| build (of an image) | build (f.) | Build (m.) | compilación (f.) | build (m.) | A new cloud image of the same version. |
| catalog | catalogo | Katalog | catálogo | catalogue | Images or AI models to choose from. |
| checksum | checksum (m.) | Prüfsumme (f.) **A** | suma de control (f.) **A** | somme de contrôle (f.) **A** | |
| signature | firma | Signatur **A** | firma **A** | signature **A** | OpenPGP signatures of images. |
| guest | guest (m.) | Gastsystem (n.) | sistema invitado (m.) | système invité (m.) | The system inside the VM. |
| guest monitor | monitor del guest | Monitor im Gastsystem | monitor del sistema invitado | moniteur du système invité | Guest Tools service that reports CPU, memory, load. |
| Guest Tools | Guest Tools (m. pl.) | Guest Tools (pl.) | Guest Tools (f. pl.) | Guest Tools (m. pl.) | Product name, never translated. |
| console | console (f.) | Konsole (f.) **A** | consola (f.) **A** | console (f.) **A** | The VM's serial console. |
| log | registro (m.) / log | Protokoll (n.) **A** | registro (m.) **A** | journal (m.) | `Show Log`: `Mostra log`, `Protokoll anzeigen` **A**, `Mostrar registro` **A**, `Afficher le journal`. macOS French says `historique`, but next to Nido's lists of connections it reads as a browsing history; `journal` is the usual French word for a log. |
| first boot | primo avvio | erster Start | primer arranque | premier démarrage | cloud-init prepares the system. |
| saved state | stato salvato | gesicherter Zustand | estado guardado | état enregistré | What a suspended VM keeps on disk (German: what *Ruhezustand* keeps); the next start resumes from it. English: never *suspended session*. |
| Setup Assistant (macOS) | assistente iniziale | Systemassistent **A** | Asistente de Configuración **A** | Assistant réglages **A** | Inside a macOS VM. |
| Remote Login | Login remoto **A** | Entfernte Anmeldung **A** | Sesión remota **A** | Session à distance **A** | macOS Sharing setting. |
| hardware model | modello hardware | Hardwaremodell | modelo de hardware | modèle matériel | macOS VM identity. |

### VM states and actions

States are adjectives agreeing with the VM (feminine in it, es, fr). Badges use the same words.

| English | Italian (Nido) | German | Spanish | French | Notes |
|---|---|---|---|---|---|
| Start | Avvia | Starten **A** | Iniciar **A** | Démarrer **A** | |
| Starting | Avvio in corso | Wird gestartet | Iniciando | Démarrage en cours | Badge. |
| Running | In esecuzione | Läuft **A** | En ejecución | En marche | Badge and sentences (`debian-13 est en marche`); an invariable phrase, no agreement. `in esecuzione nel Terminale` → `läuft im Terminal`, `en ejecución en Terminal`, `en marche dans Terminal`. |
| Stop | Arresta | Stoppen **A** | Detener **A** | Arrêter **A** | Shuts the VM down. `nido stop`. |
| Stopping | Arresto in corso | Wird gestoppt | Deteniendo | Arrêt en cours | |
| Stopped | Arrestata | Gestoppt **A** | Detenida **A** | Arrêtée **A** | |
| Suspend | Sospendi | In Ruhezustand versetzen (toolbar button: `Ruhezustand`, as Apple menu › Ruhezustand) | Suspender | Suspendre | Saves memory to disk and stops; the next start resumes. See the note below. |
| Suspending | Sospensione in corso | Geht in Ruhezustand | Suspendiendo | Suspension en cours | Badge. |
| Suspended | Sospesa | Im Ruhezustand (sentences); `Ruhezustand` (badge) | Suspendida **A** | Suspendue **A** | |
| Resume | Riprendi | Fortsetzen **A** | Reanudar **A** | Reprendre **A** | From suspended or paused. |
| Resuming | Ripresa in corso | Wird fortgesetzt | Reanudando | Reprise en cours | |
| Pause | Pausa / Metti in pausa | Anhalten **A** | Pausar **A** | Mettre en pause **A** | Memory stays in RAM, for seconds (a snapshot of a running VM). |
| Paused | In pausa | Angehalten **A** | En pausa **A** | En pause **A** | |
| Restart | Riavvia | Neu starten | Reiniciar **A** | Redémarrer **A** | |
| cold boot / starts from scratch | avvio a freddo / parte a freddo | Kaltstart / führt einen Kaltstart aus | arranque en frío / arranca en frío | démarrage à froid / démarre à froid | A start without the saved state. German `startet neu` reads as *restarts*. |
| Busy | Occupata | Belegt | Ocupada | Occupée | Another Nido operation holds the VM. |
| Unreadable | Illeggibile | Nicht lesbar | Ilegible | Illisible | Badge for a damaged configuration. |
| Error | Errore | Fehler **A** | Error **A** | Erreur **A** | |
| Installing | Installazione | Wird installiert | Instalando | Installation en cours | Badge of a macOS install; a progress form like *Starting* (Italian keeps today's copy). |
| Create | Crea | Erstellen **A** | Crear **A** | Créer **A** | |
| Create and Start | Crea e avvia | Erstellen und starten | Crear e iniciar | Créer et démarrer | Wizard. |
| Create and Install | Crea e installa | Erstellen und installieren | Crear e instalar | Créer et installer | Wizard, macOS. |
| Delete | Elimina | Löschen **A** | Eliminar **A** | Supprimer **A** | Deletes a VM or snapshot for good. |
| Remove | Rimuovi | Entfernen **A** | Quitar | Retirer | Takes an item out of a list (a domain, a folder); nothing on disk is deleted. |
| Restore | Ripristina | Wiederherstellen **A** | Restaurar **A** | Restaurer **A** | A snapshot. |
| Reset (a list) | Ripristina | Zurücksetzen **A** | Restablecer | Réinitialiser **A** | Back to the base list. |
| Rename | Rinomina | Umbenennen **A** | Cambiar nombre **A** | Renommer **A** | |
| Install / Reinstall | Installa / Reinstalla | Installieren / Erneut installieren **A** | Instalar / Reinstalar **A** | Installer / Réinstaller **A** | |
| Uninstall | Disinstalla | Deinstallieren **A** | Desinstalar **A** | Désinstaller **A** | |
| Download (verb, button) | Scarica | Laden **A** | Descargar **A** | Télécharger **A** | Noun: `download`, `Download`, `descarga`, `téléchargement`. German: `Laden` only for the button and the `geladen` status (the cache column); in sentences, help, messages, the README and the release notes `herunterladen`/`heruntergeladen` (as *download a model*). |
| Try Again | Riprova | Erneut versuchen **A** | Reintentar **A** | Réessayer **A** | |
| Apply | Applica | Anwenden **A** | Aplicar **A** | Appliquer **A** | |
| Turn On / Turn Off | Attiva / Disattiva | Aktivieren / Deaktivieren **A** | Activar / Desactivar **A** | Activer / Désactiver **A** | Settings and features. |
| Type in VM | Digita nella VM | In der VM eingeben | Escribir en la VM | Saisir dans la VM | Sends text as keystrokes. |

**Suspend is not pause.** Nido shows both states, so each language needs two words that cannot
be confused. macOS German says `Anhalten`/`Angehalten` for *pause/paused* (the loctables map
"Pause" to `Anhalten` 57 times and "Paused" to `Angehalten` 23 times; "Suspended" to it only
once), so German keeps Apple's pair for pause, where users already read it that way, and gives
suspend `Ruhezustand`, macOS's own word for a Mac that sleeps and wakes where it left off — the
nearest German idea to a VM whose state waits on disk. Spanish (`suspender`/`en pausa`) and
French (`suspendre`/`en pause`) already keep the two apart, as macOS does (`Suspendida`,
`Suspendu` vs `En pausa`, `En pause`); French never writes `suspendu` for a paused VM.

### Wizard, settings and windows

| English | Italian (Nido) | German | Spanish | French | Notes |
|---|---|---|---|---|---|
| New VM | Nuova VM | Neue VM | Nueva VM | Nouvelle VM | Wizard title. |
| Step 2 of 5 | Passo 2 di 5 | Schritt 2 von 5 **A** | Paso 2 de 5 **A** | Étape 2 sur 5 **A** | |
| System (step) | Sistema | System **A** | Sistema **A** | Système **A** | |
| macOS Image / Download (step) | Immagine macOS / Download | macOS-Image / Download | Imagen de macOS / Descarga | Image macOS / Téléchargement | |
| Resources (step) | Risorse | Ressourcen **A** | Recursos **A** | Ressources **A** | CPU, memory, disk. |
| Access (and Software) (step) | Accesso (e software) | Zugriff (und Software) **A** | Acceso (y software) **A** | Accès (et logiciels) **A** | |
| Summary (step) | Riepilogo | Übersicht **A** | Resumen **A** | Résumé **A** | |
| Installation (step) | Installazione | Installation | Instalación | Installation | |
| Phase 1 · first boot | Fase 1 · primo avvio | Phase 1 · erster Start | Fase 1 · primer arranque | Phase 1 · premier démarrage | Provisioning steps. |
| Continue in Library | Continua nella libreria | In der Bibliothek fortfahren | Continuar en la biblioteca | Continuer dans la bibliothèque | |
| Settings (app) | Impostazioni | Einstellungen **A** | Ajustes **A** | Réglages **A** | Window title `Nido Settings`: `Impostazioni di Nido`, `Einstellungen`, `Ajustes de Nido`, `Réglages de Nido`. |
| VM Settings | Impostazioni VM | VM-Einstellungen | Ajustes de la VM | Réglages de la VM | |
| General (tab) | Generale | Allgemein **A** | General **A** | Général **A** | |
| Network (tab) | Rete | Netzwerk **A** | Red **A** | Réseau **A** | |
| Monitor (tab / view) | Monitor | Monitor | Monitor | Moniteur | Live CPU, memory and load of the guest. |
| CPU | CPU | CPU | CPU | CPU | `4 CPU` in it; `4 CPUs` en, de; `4 CPU` es, fr. |
| memory | memoria | Arbeitsspeicher | memoria **A** | mémoire **A** | RAM of the VM; German `Speicher` alone is ambiguous. |
| disk | disco | Festplatte **A** | disco **A** | disque **A** | The VM's virtual disk. |
| space on the Mac | spazio sul Mac | Speicherplatz auf dem Mac | espacio en el Mac | espace sur le Mac | |
| host name | nome host | Hostname **A** | nombre de host **A** | nom d’hôte **A** | |
| computer name | nome del computer | Computername | nombre del ordenador | nom de l’ordinateur | macOS guests. |
| user name | nome utente | Benutzername **A** | nombre de usuario **A** | nom d’utilisateur **A** | |
| short name (macOS account) | nome breve | Accountname **A** | nombre corto | nom abrégé **A** | The account `nido ssh` logs in to in a macOS VM. |
| MAC address | indirizzo MAC | MAC-Adresse **A** | dirección MAC **A** | adresse MAC **A** | |
| IP address | indirizzo IP | IP-Adresse **A** | dirección IP **A** | adresse IP **A** | |
| SSH public key | chiave SSH pubblica | öffentlicher SSH-Schlüssel | clave SSH pública | clé SSH publique | |
| terminal access | accesso da terminale | Zugriff über Terminal | acceso desde Terminal | accès depuis Terminal | |
| Keychain | Portachiavi **A** | Schlüsselbund **A** | Llavero **A** | Trousseau **A** | `Saved in the Mac’s Keychain`. French writes `trousseau` in running text (`dans le trousseau du Mac`); the capital is for names only (`Trousseau d’accès`, `Trousseau iCloud`) and headings. |
| access token | token di accesso | Zugriffstoken (n.) | token de acceso (m.) | jeton d’accès (m.) | Hugging Face. |
| hang protection settings | impostazioni anti-blocco | Schutz vor Systemhängern | ajustes contra bloqueos | réglages anti-blocage | Guest reboots 10 s after a kernel panic instead of hanging. |
| background requests | richieste di sfondo | Hintergrundanfragen | solicitudes en segundo plano | requêtes en arrière-plan | Guest telemetry and update checks Nido can turn off. |
| Rosetta for Linux | Rosetta per Linux | Rosetta für Linux | Rosetta para Linux | Rosetta pour Linux | Rosetta is f. in it, m. in es and fr (**A**: `Rosetta no está instalado`, `Rosetta n’est pas installé`). |

### Network

| English | Italian (Nido) | German | Spanish | French | Notes |
|---|---|---|---|---|---|
| controlled network | rete controllata (f.) | kontrolliertes Netzwerk (n.) | red controlada (f.) | réseau contrôlé (m.) | Every connection goes through Nido's allow-list. |
| Apple network | rete di Apple | Apple-Netzwerk | red de Apple | réseau Apple | The plain NAT of Virtualization. |
| allowed domains | domini permessi | erlaubte Domains | dominios permitidos | domaines autorisés | |
| domain | dominio | Domain (f.) **A** | dominio **A** | domaine **A** | |
| base list | lista di base | Basisliste | lista básica | liste de base | The default allowed domains of a system. |
| Add a domain | Aggiungi un dominio | Domain hinzufügen | Añadir un dominio | Ajouter un domaine | |
| block (event) | blocco | Blockierung (f.) | bloqueo | blocage | A connection the controlled network stopped. |
| blocked connection | connessione bloccata | blockierte Verbindung | conexión bloqueada | connexion bloquée | |
| cut (connection) | interrotto | getrennt | cortada (f.); `cortado` in the `nido net log` column | coupée (f.) | An open connection closed because its domain left the list. Kept apart from *interrupted* (the controlled network stopped): `unterbrochen`, `interrumpida`, `interrompu`. |
| local noise | rumore locale | lokaler Hintergrundverkehr | tráfico local de fondo | trafic local de fond | Multicast and broadcast chatter, hidden by default. |
| notice | avviso | Hinweis **A** | aviso **A** | avis **A** | A notification about blocks. |
| relay | relè | Relay | retransmisor (m.) | relais | Nido's egress relay (Spanish `relé` is an electrical relay). |
| network log | registro di rete | Verbindungsprotokoll | registro de red | journal réseau | The log of a VM's connections; German `Netzwerkprotokoll` would mean *network protocol*. |
| destination | destinazione | Ziel | destino | destination | |
| port | porta | Port **A** | puerto **A** | port **A** | |

### AI

| English | Italian (Nido) | German | Spanish | French | Notes |
|---|---|---|---|---|---|
| AI | AI | KI | IA | IA | macOS: `KI-Erweiterungen`, `extensiones de IA`, `extensions IA` **A**. |
| AI bridge | ponte AI (m.) | KI-Brücke (f.) | puente de IA (m.) | pont IA (m.) | Gives a VM access to AI providers through the Mac. |
| model (AI) | modello | Modell **A** | modelo **A** | modèle (d’IA) **A** | French: write `modèle d’IA` wherever *template* could be meant. |
| download a model | scaricare il modello | Modell herunterladen | descargar el modelo | télécharger le modèle | German: always `herunterladen` for models (Ollama, Hugging Face); `laden` alone reads as loading a model into memory. |
| provider | provider | Anbieter **A** | proveedor **A** | fournisseur **A** | |
| allowed models | modelli consentiti | erlaubte Modelle | modelos permitidos | modèles autorisés | |
| limits | limiti | Limits | límites **A** | limites **A** | |
| tokens per day | token al giorno | Tokens pro Tag | tokens al día | jetons par jour | |
| requests per minute | richieste al minuto | Anfragen pro Minute | solicitudes por minuto | requêtes par minute | |
| usage | uso | Nutzung **A** | uso **A** | utilisation **A** | |
| chat | chat (f.) | Chat (m.) | chat (m.) | conversation (f.) | `Clear Chat`: `Cancella la chat`, `Chat löschen`, `Borrar chat`, `Effacer la conversation`. |
| AI view | vista AI | KI-Ansicht | vista de IA | vue IA | |
| sample | campione | Messung | muestra | relevé | A monitor reading. |
| load | carico | Last | carga | charge | |
| swap | swap / area di swap | Swap | swap | swap | |

### App shell and common buttons

AppKit supplies the standard menu items (About, Hide, Quit, Window, Help…) in every language;
these are the ones Nido writes itself.

| English | Italian (Nido) | German | Spanish | French | Notes |
|---|---|---|---|---|---|
| About Nido | Informazioni su Nido | Über Nido | Acerca de Nido | À propos de Nido | |
| What’s New in Nido | Novità di Nido | Neue Funktionen in Nido **A** | Novedades de Nido **A** | Nouveautés de Nido **A** | |
| Check for Updates… | Cerca aggiornamenti… | Nach Updates suchen … **A** | Buscar actualizaciones… **A** | Rechercher les mises à jour… **A** | |
| Install the nido Command… / Remove the nido Command | Installa il comando nido… / Rimuovi il comando nido | nido-Befehl installieren … / nido-Befehl entfernen | Instalar el comando nido… / Eliminar el comando nido | Installer la commande nido… / Supprimer la commande nido | Nido menu. Removing deletes the link on disk, so es/fr say *delete*, not the list-item *remove*. |
| Install and Relaunch | Installa e riavvia | Installieren und neu starten | Instalar y reiniciar | Installer et relancer | Sparkle update. |
| Skip This Version | Salta questa versione | Diese Version überspringen | Omitir esta versión | Ignorer cette version | |
| Not Now | Non ora **A** | Später **A** | Ahora no **A** | Plus tard **A** | |
| Cancel | Annulla **A** | Abbrechen **A** | Cancelar **A** | Annuler **A** | |
| Continue | Continua **A** | Fortfahren **A** | Continuar **A** | Continuer **A** | |
| Done | Fine **A** | Fertig **A** | Aceptar **A** | Terminé **A** | |
| Quit | Esci **A** | Beenden **A** | Salir **A** | Quitter **A** | |
| Quit When Done | Esci al termine | Nach Abschluss beenden | Salir al terminar | Quitter une fois terminé | Quitting waits for an operation. |
| Close | Chiudi **A** | Schließen **A** | Cerrar **A** | Fermer **A** | |
| Back | Indietro **A** | Zurück **A** | Atrás **A** | Retour **A** | Wizard. |
| Choose… | Scegli… **A** | Auswählen … **A** | Seleccionar… **A** | Choisir… **A** | A file picker's button. |
| Replace | Sostituisci **A** | Ersetzen **A** | Reemplazar **A** | Remplacer **A** | |
| Quit Anyway | Esci comunque **A** | Trotzdem beenden **A** | Salir de todos modos **A** | Quitter malgré tout **A** | |
| Suspend and Quit | Sospendi ed esci | In Ruhezustand versetzen und beenden | Suspender y salir | Suspendre et quitter | Long in German, kept: the alert stacks its buttons, and every shorter German form is ungrammatical. |
| Stop and Quit | Arresta ed esci | Stoppen und beenden | Detener y salir | Arrêter et quitter | |
| Show in Finder | Mostra nel Finder **A** | Im Finder anzeigen **A** | Mostrar en el Finder **A** | Afficher dans le Finder **A** | |
| Open Terminal | Apri il Terminale | Terminal öffnen | Abrir Terminal | Ouvrir Terminal | The app is `Terminale`/`Terminal` **A**. |
| Enter Full Screen | Schermo intero | Vollbildmodus **A** | Usar pantalla completa **A** | Activer le mode plein écran **A** | |
| Exit Full Screen | Esci da schermo intero | Vollbildmodus beenden | Salir de pantalla completa **A** | Quitter le mode plein écran **A** | |
| Open Settings | Apri le Impostazioni | Einstellungen öffnen **A** | Abrir Ajustes **A** | Ouvrir les réglages | Nido's own; `Open System Settings`: `Systemeinstellungen öffnen`, `Abrir Ajustes del Sistema`, `Ouvrir Réglages Système` **A**. |
| notifications | notifiche **A** | Mitteilungen **A** | notificaciones **A** | notifications **A** | |
| clipboard | appunti **A** | Zwischenablage **A** | portapapeles **A** | presse-papiers **A** | |
| Copy | Copia **A** | Kopieren **A** | Copiar **A** | Copier **A** | |
| Search | Cerca **A** | Suchen **A** | Buscar **A** | Rechercher **A** | |
| toolbar | barra | Symbolleiste **A** | barra de herramientas **A** | barre d’outils **A** | The VM window's toolbar; English never says "the bar". |
| Home folder | cartella Inizio **A** | Benutzerordner **A** | carpeta de inicio **A** | dossier Départ **A** | |
| The nest is empty | Il nido è vuoto | Das Nest ist leer | El nido está vacío | Le nid est vide | Empty library; plays on the name (*nido* = nest). |

## Never translated

`Nido`, `nido` (the command and its subcommands, flags and arguments), `Guest Tools`,
`Ollama`, `Hugging Face`, `Rosetta`, `macOS`, `Linux`, `Ubuntu`, `Debian`, `Touch ID`, `Mac`,
`Finder`, `IPSW`, `SSH`, `DNS`, `DHCP`, `NAT`, `TCP`, `UDP`, `IPv6`, `CPU`, `GiB`, `MiB`, `KiB`,
`cloud-init`, `gvproxy`, `qcow2`, `arm64`, `x86_64`, `OpenPGP`, profile names (`Debian Base`,
`Ubuntu AI Starter`), file and folder names, VM names, domain names, model names, and anything
the guest sends (shown as it arrives), except Guest Tools messages with a code (below).

**Guest Tools messages.** `nido-provision` (Guest Tools 1.5.0 and later) reports a failure as
`<code>: <English message>` (and the memory warning of a model download the same way); the codes
are the `MESSAGES` table at the top of `guest/linux/nido_guest_tools/provision.py`. Nido shows
its own text for each code it knows (`GuestMessage`, keys in the NidoCore catalog, the values
read back from the English message, sizes in the language's number format). Older Guest Tools'
Italian text, and a code Nido does not know, are shown as they arrive. A new message gets a new
code in `MESSAGES`, the same English template in `GuestMessage.templates` and its catalog entry:
`GuestMessageTests` fails until all three agree.

## Punctuation and typography

| | English | Italian | German | Spanish | French |
|---|---|---|---|---|---|
| Quotes | “…” | `"…"` (straight, today's copy) | „…“ | “…” | « … » with a no-break space (U+00A0) inside |
| Apostrophe | ’ | `'` (today's copy) | ’ | — | ’ |
| Ellipsis | `…` attached | `…` attached | no-break space + `…` (`Auswählen …`) | `…` attached | `…` attached |
| Before `: ; ? !` | nothing | nothing | nothing | nothing | no-break space U+00A0 (`Erreur : …`, `Supprimer debian-13 ?`) |
| Questions, exclamations | `?` | `?` | `?` | `¿…?`, `¡…!` | ` ?` |
| Percent | `42%` | `42 %` (today's copy) | `42 %` (U+00A0) | `42 %` (U+00A0) | `42 %` (U+00A0) |
| Separator in metadata | ` · ` | ` · ` | ` · ` | ` · ` | ` · ` |

- The middle dot ` · ` joins facts on one line (`4 CPU · 8 GiB · disco 64 GiB`, `arm64 · nella
  cache`) in every language; it is not translated.
- The ellipsis `…` (U+2026, one character, never three dots) marks a command that opens a sheet
  or asks something (`Create Snapshot…`) and a progress line (`Downloading…`). Use it where the
  Italian uses it.
- The French no-break space is U+00A0 (macOS uses it, not the narrow U+202F). In a catalog
  value write the character itself.
- German compound nouns with a product name take a hyphen (`VM-Einstellungen`,
  `macOS-Image`, `IPSW-Datei`, `KI-Brücke`).
- No exclamation marks in product copy.

## Numbers, units, dates

- Numbers and dates follow the language the user sees: `L10n.locale` in NidoCore and the CLI,
  `Locale.current` in the app. Never a hardcoded `Locale(identifier: "it_IT")`.
- Format with Foundation (`formatted()`, `Date.FormatStyle`, `ByteSize.format`), not by hand:
  decimal separators (`9.8` en, `9,8` it/de/es/fr) and digit grouping come from the locale.
- Sizes use binary units `KiB`, `MiB`, `GiB`, the same in every language, separated from the
  number by a space (`8 GiB`).
- Percentages: prefer `Double.formatted(.percent)`; when a catalog string holds the sign, write
  it per language as in the table above (`%lld%%` en, `%lld %%` it, `%lld %%` with U+00A0
  de/es/fr) and mark the entry `[not a count]` (see [Plurals](#plurals)).
- Times: `10:38` in every language (24-hour in it, de, es, fr; the locale decides for en).
- Durations and "time remaining" go through `Duration`/`DateComponentsFormatter` or a plural
  entry, never `"\(n) min"` by hand.
  - Exception: the guest's uptime in the Monitor view (`MonitorView.uptime`) uses catalog
    entries with abbreviated units, `%lld d %lld h`, `%lld h %lld min` and `%lld min`, marked
    `[not a count]`. They keep the Italian literal byte for byte (`1 g 4 h`, `2 h 14 min`,
    `3 min`) and give every language the same spaced layout (`1 T. 4 Std.`, `1 j 4 h`);
    abbreviations do not change with the number. Foundation's `.units(width: .narrow)` gives the
    same Italian on macOS 27 but drops the spaces in en, de and fr (`2h 14m`, `2h 14min`), so the
    switch to it waits for a decision on that layout.

## Touch ID and password prompts

macOS builds the prompt around Nido's reason, so the reason is the end of a system sentence:

| | System sentence **A** | Reason Nido passes (example) |
|---|---|---|
| en | `Nido is trying to %@.` | `add example.com to the allowed domains of the VM debian` |
| it | `Nido sta cercando di %@.` | `aggiungere example.com ai domini permessi della VM debian` |
| de | `„Nido“ möchte %@.` | `example.com zu den erlaubten Domains der VM „debian“ hinzufügen` |
| es | `La app Nido está intentando %@.` | `añadir example.com a los dominios permitidos de la VM debian` |
| fr | `« Nido » souhaite %@.` | `ajouter example.com aux domaines autorisés de la VM debian` |

The reason starts in lower case, has no final period, and is an infinitive phrase that fits the
system sentence (German puts the verb last). "Touch ID or the Mac password" is
`Touch ID o la password del Mac`, `Touch ID oder das Passwort deines Mac`,
`Touch ID o la contraseña del Mac`, `Touch ID ou le mot de passe du Mac`.

## The `nido` command

- The language comes from the system; `NIDO_LANGUAGE=en|it|de|es|fr` overrides it (anything
  else: the system's choice). Scripts that read `nido` output set `NIDO_LANGUAGE`.
- Commands, subcommands, flags, argument names and values (`--suspend`, `on`/`off`) stay
  English; help text, messages, errors and table headers are translated. ArgumentParser's own
  scaffolding (`USAGE:`, `OPTIONS:`, `--help`, `--version`, parse errors) stays English.
- Help text: English abstracts and options in the imperative (`Delete a stopped VM and its
  disk.`, `Confirm the download without asking.`); German, Spanish and French abstracts in the
  third person (`Löscht …`, `Elimina …`, `Supprime …`) and options in the infinitive
  (`Ohne Rückfrage löschen.`, `Eliminar sin pedir confirmación.`, `Supprimer sans demander de
  confirmation.`); Italian keeps today's copy. Command groups follow the same rule (`Manage a
  VM’s snapshots: …`, `Verwaltet die Schnappschüsse einer VM: …`, `Gestiona las instantáneas
  de una VM: …`, `Gère les instantanés d’une VM : …`).
- A question ends with the yes letter and `N` in brackets, then a space: `[y/N] `, `[s/N] `,
  `[j/N] `, `[s/N] `, `[o/N] ` (`CLILanguageTests.promptsOfferTheLanguagesYes` checks that the
  letter answers yes).
- Table columns are as wide as the longest localized header or value, so columns stay aligned
  in every language.
- Confirmations accept `y`/`yes` and the language's own (`s`, `si`, `sì`; `j`, `ja`; `s`, `si`, `sí`;
  `o`, `oui`).

## Release notes

The notes the app shows (Help › What’s New in Nido) are one Markdown file per language:
`App/Nido/ReleaseNotes/<lang>.lproj/CHANGELOG.md`. Xcode's synchronized `Nido` folder makes them
one localized resource, so the built app has `<lang>.lproj/CHANGELOG.md` and
`ReleaseNotes.bundled()` reads the copy of the language the app runs in (English for any other
language). Dates are written for `Locale.current`.

- The repository's `CHANGELOG.md` is the English notes, byte for byte the same as
  `en.lproj/CHANGELOG.md` (`ReleaseNotesTests.bundledEnglishMatchesRoot`; `scripts/release.sh`
  checks it too). Sparkle's and GitHub's release notes come from it, so they are English.
- A new release gets its section in all five files in the same change: the same
  `## [x.y.z] – YYYY-MM-DD` heading, in the same order (`everyLanguageHasTheSameSections`), and
  the same `###` groups and bullets.
- Same in every language: version numbers, dates, Markdown structure, commands, paths, flags,
  domains and other code spans. A code span that quotes `nido` output is written as the command
  prints it in that language (`debian-13: up to date (build …)`, `debian-13: aktuell (Build …)`).
- A menu item, button or tab is named with its exact label from `App/Nido/Localizable.xcstrings`
  in that language (`Nido › nido-Befehl installieren …`, `Réglages › Général`); the glossary and
  the typography rules above apply as everywhere else (no-break spaces in French and before the
  German `…`).
- The Italian notes keep their wording as written at each release, except a menu item, button
  or tab named with a wrong label: it is corrected to the catalog's Italian value
  (`Impostazioni › Generale`, not `Generali`).

## Adding a string

The key is the English text. Write English in the code; the catalog holds the five values.

**NidoCore, NidoCLI, `nido`** — catalog `Sources/NidoCore/Resources/Localizable.xcstrings`:

```swift
let message = L10n.string("Can’t find the VM \(name).")   // key "Can’t find the VM %@."
let line = L10n.string("\(count) VMs running")            // key "%lld VMs running": a plural entry
```

- Two keys must differ in their words, not only in punctuation or case: SwiftPM generates a
  Swift symbol per key and rejects keys that map to the same one (`Warning: %@` and
  `Warning: %@.`; `Controlled network interrupted: %@.` and `controlled network interrupted: %@`).
- Pass one string literal to `L10n.string(`: interpolations are fine; a variable, a `+` or a
  ternary is not a key (build one key per sentence instead, with placeholders).
- SwiftPM does not extract keys: add the entry yourself, with `"extractionState" : "manual"`.

**App** — catalog `App/Nido/Localizable.xcstrings` (and `App/Nido/InfoPlist.xcstrings` for
Info.plist's copyright line): SwiftUI `Text("…")`, `Button("…")`, components taking
`LocalizedStringKey`, `String(localized: "…")` in models and AppKit (`NSAlert`), and
`LocalizedStringResource` for stored copy. Text that comes from outside (VM names, paths, guest
output) uses `Text(verbatim:)` or the components' `verbatim:` initializers. Add each key's entry
in all five languages yourself (see [The app's catalog and Xcode](#the-apps-catalog-and-xcode)).

```swift
NidoButton("Cancel") { … }                                  // key "Cancel"
NidoButton(verbatim: model.actionLabel) { … }               // shown as given
NidoNotice(kind: .error, title: "Can’t reach the guest", detail: "Start \(name) first.")  // all copy
NidoNotice(kind: .error, verbatim: String(localized: "Can’t reach the guest"),
           detail: error.localizedDescription)              // copy and runtime text mixed
alert.messageText = String(localized: "Update postponed")   // AppKit takes a String
```

- **Components** (`App/Nido/Design/Components`): each one's copy parameters are
  `LocalizedStringKey`, so an English literal is a key; each also has a `verbatim:` initializer
  whose strings are shown as given. A component with several texts has one `verbatim:` form for
  all of them: when a call mixes copy and runtime text, localize the copy with
  `String(localized:)` and use the `verbatim:` form. `NidoMarkdown` and the card and row data of
  `NidoVMCard` and `NidoSnapshotRow` are `String`s from the model, shown as given.
- **Identifiers never come from copy.** Components whose accessibility identifier used to be
  their text take an `id` with the `LocalizedStringKey` form (`NidoSettingsShell.Section(_:id:)`,
  `NidoProfileTile(_:id:…)`, `NidoResourceStepper(label:id:…)`); the `verbatim:` form uses the
  string itself, or its own `id` where the text is copy (`NidoProfileTile(verbatim:id:…)`,
  `NidoSettingsShell.Section(verbatim:id:)`). An identifier that used to be Italian text stays that
  text (`stepper-Memoria`, `profile-Da modello`, `clone-notes-Nuove chiavi host SSH`,
  `settings-section-Rete`, `vm-tab-Schermo`, `monitor-Disco`). UI tests find elements by
  identifier, or by their Italian text (they run in Italian).
- One English word that two places use with different meanings is two keys: the second gets a
  key of its own and the English as its `defaultValue`, with an `en` value in the catalog
  (`String(localized: "Download (step)", defaultValue: "Download", comment: …)`, the wizard's step,
  a noun, next to the button `Download`, a verb: `Download`/`Laden` in German). A homonym with a
  placeholder writes the placeholder in the key and interpolates the `defaultValue`: the compiler
  extracts the key with the default as its value, and at run time the translation is formatted
  with the interpolated arguments (`String(localized: "%@ is stopped (heading)",
  defaultValue: "\(name) is stopped", comment: …)`, the VM window's heading next to the library's
  `%@ is stopped`).
- Sentences are whole keys even when a part varies: one key per variant
  (`The VM will go back to its state as of %@; later changes will be lost.` and the same with
  `…and the saved state of %@…`), never a translated fragment put into another key.
  Facts joined by ` · ` are separate strings, joined in code.
- A key with a number that is not a count says so in the code's comment, which Xcode copies into
  the catalog: `Text("Step \(step) of \(count)", comment: "The wizard's progress. [not a count]")`.
- An integer in a localized string is formatted for the locale, digit grouping included
  (`17.179.869.183 GiB` in Italian). Every size the app shows goes through one helper,
  `ByteSize.text` (`App/Nido/Design/ByteSizeText.swift`, `ByteSize.format(_:locale: .current)`);
  dates go through `Date.FormatStyle` with the locale (`SnapshotsModel.dateText`).
- Do not build the text of a `LocalizedStringKey` from a value that is not a `String`, a number
  or a `Text` (a `VMName`, a URL): SwiftUI writes its debug description. Interpolate
  `name.rawValue`, or use `verbatim:`.

### The app's catalog and Xcode

`SWIFT_EMIT_LOC_STRINGS = YES` makes the compiler extract every key the app's code uses: each
source file gets a `.stringsdata` next to its object file. What happens to the committed catalog
depends on who builds:

- **`xcodebuild` (the command line, the tests, the release script) never writes
  `Localizable.xcstrings`.** It reads the catalog, compiles it into each `<lang>.lproj`, and
  leaves the file in the repository as it was (checked on Xcode 27.2: the file's hash is the
  same before and after a full build).
- **A build in Xcode's window syncs the catalog**: it adds every extracted key that is missing,
  as an empty entry (no translations), and marks entries no code uses as `stale`. Synced with the
  app's `.stringsdata` (`xcrun xcstringstool sync`, the tool Xcode runs), today's catalog keeps
  all its entries unchanged and gains 187 empty ones: the Italian literals of the areas not yet in
  English.

The rule that keeps the catalog and `AppCatalogTests` meaningful:

- **The committed catalog holds only entries translated in all five languages.** An empty entry
  Xcode added for code that is still Italian is never committed: delete the empty entries Xcode
  added (the ones without `localizations`) before committing, and keep the entries you wrote. A
  plain `git checkout App/Nido/Localizable.xcstrings` is fine only when you added nothing in the
  editor since the last commit; otherwise it throws your new translations away.
  `everyKeyHasAllLanguages` stays strict and fails on any entry Xcode added.
- **`extractedKeysExistInCatalog` checks the other direction:** every key the compiler extracted
  from the parts of the app whose copy is English has its entry. The parts are listed in
  `AppCatalogTests.localizedSources`; an area joins the list in the task that localizes it (Tasks
  6–8), and the list becomes the whole app when the last one does. A key added in English without
  its entry fails this test on the command line too, without opening Xcode.
  `localizedSourcesExist` fails when an entry of the list matches no compiled file (a typo, a
  renamed file), so the list never checks nothing by accident.
- **`catalogKeysAreUsed`:** every entry of the catalog is a key some code of the app still uses
  (anywhere in the app, extracted by the compiler); an entry whose code is gone fails and is
  deleted.
- `.stringsdata` files whose source file no longer exists (left in derived data by an earlier,
  incremental build) are ignored by these checks.
- Entries are written as Xcode writes an extracted key (no `extractionState`), so a sync in Xcode
  leaves them as they are and marks them `stale` once no code uses them; delete stale entries.
- **`InfoPlist.xcstrings` is not covered by this evidence.** Whether a build in Xcode's window
  also adds Info.plist keys (`CFBundleName`, `CFBundleDisplayName`…) to it could not be checked
  from the command line: `xcodebuild` writes no `.stringsdata` for Info.plist, and
  `xcstringstool` has no Info.plist extraction. Before committing, look at its diff with the same
  rule: only entries translated in all five languages (or marked "Don't translate").

**Editing a catalog.** With Xcode's String Catalog editor, or with a script that loads the
JSON, changes it and writes it back byte for byte the way Xcode writes it — never by
hand-editing fragments. Xcode's layout (as `xcrun xcstringstool sync`, Xcode's catalog tool,
writes it): keys sorted by code point at every level, two-space indent,
`" : "` between key and value, UTF-8 text unescaped, an empty object written as `{` + blank line
+ `}`, no newline at the end of the file. This writes exactly that:

```python
import json, re
path = "Sources/NidoCore/Resources/Localizable.xcstrings"
catalog = json.load(open(path, encoding="utf-8"))
catalog["strings"]["Cancel"] = {"extractionState": "manual", "localizations": {
    lang: {"stringUnit": {"state": "translated", "value": value}}
    for lang, value in {"it": "Annulla", "de": "Abbrechen", "es": "Cancelar", "fr": "Annuler"}.items()}}
text = json.dumps(catalog, indent=2, sort_keys=True, ensure_ascii=False, separators=(",", " : "))
text = re.sub(r"^( *)(.*)\{\}(,?)$", lambda m: m.group(1) + m.group(2) + "{\n\n" + m.group(1) + "}" + m.group(3), text, flags=re.M)
open(path, "w", encoding="utf-8").write(text)   # no final newline, as Xcode
```

To check that a catalog is in Xcode's layout, let `xcstringstool` rewrite a copy and compare.
It only rewrites a file it changes, so the copy gets a throwaway key, removed again before the
comparison:

```sh
catalog=Sources/NidoCore/Resources/Localizable.xcstrings   # or App/Nido/Localizable.xcstrings
d=$(mktemp -d); mkdir "$d/Localizable"
cp "$catalog" "$d/Localizable/Localizable.xcstrings"
echo 'import Foundation; let probe = String(localized: "!!format-probe")' > "$d/probe.swift"
xcrun xcstringstool extract "$d/probe.swift" --modern-localizable-strings -o "$d"
xcrun xcstringstool sync "$d/Localizable/Localizable.xcstrings" --stringsdata "$d"/*.stringsdata --skip-marking-strings-stale
python3 -I -c '
import sys
t = open(sys.argv[1], encoding="utf-8").read()
t = t.replace("{\n    \"!!format-probe\" : {\n\n    }\n  }", "{\n\n  }").replace("    \"!!format-probe\" : {\n\n    },\n", "")
sys.exit(t != open(sys.argv[2], encoding="utf-8").read())' "$d/Localizable/Localizable.xcstrings" "$catalog" && echo "Xcode layout: $catalog" || echo "NOT Xcode layout: $catalog"
```

- English needs no entry when the key is the English text; it needs one for plural
  variations.
- Every value is `"state" : "translated"`. A value someone still has to check is not
  committed (`needs_review` fails the checks).
- Add a `comment` when the English alone is ambiguous (what a `%@` is, where the text appears).
- Delete entries Xcode marks `stale` once no code uses them.

## Placeholders

| In code | In the key | Notes |
|---|---|---|
| `\(text)` (`String`, objects) | `%@` | |
| `\(count)` (`Int`) | `%lld` | A count: plural entry, see below. |
| `\(n)` (`UInt`) | `%llu` | |
| `\(x)` (`Double`) | `%lf` | Prefer formatting the number first and passing a `String`. |
| `\(x, specifier: "%.1f")` | `%.1f` | |
| a literal `%` | `%%` when the string has a placeholder, `%` when it has none | |

- Each translation has the same placeholders as the key, same types. To reorder, number them:
  `Copy %@ to %@` → `%2$@ … %1$@` is fine.
- Never build a sentence from translated pieces (`"\(step) " + "failed"`); one key holds the
  whole sentence with placeholders, so each language can order it.
- Do not put user-visible units, plurals or punctuation in code around a placeholder.

## Plurals

A key whose integer placeholder is a count has plural variations in every language, English
included; never `count == 1 ? … : …` in code.

```json
"%lld VMs running" : {
  "extractionState" : "manual",
  "localizations" : {
    "en" : { "variations" : { "plural" : {
      "one" : { "stringUnit" : { "state" : "translated", "value" : "%lld VM running" } },
      "other" : { "stringUnit" : { "state" : "translated", "value" : "%lld VMs running" } } } } },
    "it" : { "variations" : { "plural" : {
      "one" : { "stringUnit" : { "state" : "translated", "value" : "%lld in esecuzione" } },
      "other" : { "stringUnit" : { "state" : "translated", "value" : "%lld in esecuzione" } } } } },
    "de" : …, "es" : …, "fr" : …
  }
}
```

- Every language has at least `one` and `other`. French `one` covers 0 and 1; German, Italian,
  Spanish and English `one` is only 1. Add `many` for French or Spanish only when a test needs
  it (millions).
- The `one` case may spell the number out (`One VM`), the `other` case keeps `%lld`.
- Gender and agreement live in the values (`1 blocco nascosto` / `3 blocchi nascosti`,
  `1 instantánea` / `3 instantáneas`).
- Two counts in one sentence: use substitutions (`%#@vms@` with its own plural variations), or
  two sentences. Example: `%lld of %lld models` (the AI catalog's filter), whose plural follows the
  second number: each language's value is `%lld of %#@models@`, and `substitutions.models` has
  `argNum` 2, `formatSpecifier` `lld` and plural cases written with `%arg` (`%arg model`,
  `%arg models`). Leave the first `%lld` without a position: the checks read `%2$#@…@` as a
  string argument.
- An integer that is not a count (a port, a PID, a percentage, a version number) needs no plural:
  put `[not a count]` in the entry's `comment`.
- `xcstringstool` (the SwiftPM and Xcode compiler of catalogs) rejects plural variations on a
  key without a number placeholder: a string that only varies by count but never shows the
  number is two keys.

## Catalog checks

Tests keep both catalogs complete; every task keeps them green.

| Test | NidoCore catalog (`LocalizationCatalogTests`) | App catalogs (`AppCatalogTests`) |
|---|---|---|
| `everyKeyHasAllLanguages` | ✓ | ✓ (`Localizable`, `InfoPlist`) |
| `placeholdersMatch` | ✓ | ✓ (`Localizable`, `InfoPlist`) |
| `pluralKeysHaveVariations` | ✓ | ✓ (`Localizable`, `InfoPlist`) |
| `codeKeysExistInCatalog` | ✓ (scans `Sources/**`) | — |
| `extractedKeysExistInCatalog` | — | ✓ (the compiler's `.stringsdata`, `localizedSources`) |
| `localizedSourcesExist` | — | ✓ (each `localizedSources` entry matches a compiled file) |
| `catalogKeysAreUsed` | — | ✓ (every entry is a key the app's code uses) |

- `everyKeyHasAllLanguages`: `sourceLanguage` is `en`, `version` is `1.0`; each entry has a
  non-empty, `translated` value in en, it, de, es, fr (English may be the key itself when the
  entry has no variations); entries marked "Don't translate" (`shouldTranslate: false`) are
  skipped.
- `placeholdersMatch`: each language takes the same arguments as the key, by position and
  type; plural cases are taken together.
- `pluralKeysHaveVariations`: integer placeholder ⇒ plural variations with `one` and `other` in
  every language, unless the comment says `[not a count]`.
- `codeKeysExistInCatalog`: every literal passed to `L10n.string(` in `Sources/**` is a key,
  read the way Swift builds the key at run time: interpolations become placeholders (any
  placeholder matches an interpolation, since source text does not say its type; a wrong
  `%@`/`%lld` in the catalog shows up in the tests that check the localized text), a literal `%`
  becomes `%%` next to a placeholder, escapes and multi-line `"""` literals are decoded, calls
  may span lines and sit inside other interpolations. Not checked: keys that are not a single
  literal (variables, `+`, ternaries), raw strings `#"…"#`, calls inside comments.
- `extractedKeysExistInCatalog`: every key the Swift compiler extracted from the app's files
  listed in `AppCatalogTests.localizedSources` is in `Localizable.xcstrings` (see
  [The app's catalog and Xcode](#the-apps-catalog-and-xcode)). It reads the `.stringsdata` of
  the build that hosts the tests, so it sees exactly the keys SwiftUI and `String(localized:)`
  look up, placeholders included.

`AppLanguageTests` (App/NidoTests) checks the app's copy from the built app's `<lang>.lproj`:
each area lists its keys with today's Italian, and every key must resolve in it, de, es and fr
(not as the English), with the Italian byte for byte. Each task that localizes an area adds its
keys there.

The rules are one file, `Tests/NidoCoreTests/CatalogRules.swift`, compiled into both test
targets (the Xcode project refers to it from `NidoTests`). `CatalogRulesTests` and
`CodeKeysTests` test the rules themselves.

Run them:

```sh
swift test --filter 'LocalizationCatalogTests|CatalogRulesTests|CodeKeysTests'
xcodebuild build-for-testing -project App/Nido.xcodeproj -scheme Nido -destination 'platform=macOS' -derivedDataPath App/build -quiet
xcodebuild test-without-building -project App/Nido.xcodeproj -scheme Nido -destination 'platform=macOS' -derivedDataPath App/build -only-testing:NidoTests/AppCatalogTests
```
