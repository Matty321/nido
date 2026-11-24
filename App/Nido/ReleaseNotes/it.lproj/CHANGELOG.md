# Novità di Nido

Le versioni di Nido, dalla più recente. L'app mostra la sezione della versione installata al primo avvio dopo un aggiornamento (menu Aiuto › Novità di Nido per rivederla).

## [0.10.1] – 2026-11-24

### Un Mac per gli agenti
- **L’agente vede la barra dei menu e il Dock.** Dopo i controlli dell’app, `ui_tree` ora elenca i menu dell’app che possiede la barra dei menu, le icone di stato a destra e il Dock, ognuno sotto la sua intestazione. Serve Nido Agent 1.0.7.
- **L’agente legge il testo che non ha controlli.** La nuova azione `read_text` (lo strumento MCP `read_text`, o `nido act <vm> ocr`) legge il testo sullo schermo della VM (immagini, canvas, alcune pagine web) con la posizione di ogni riga, così l’agente può cliccarla. Il testo viene riconosciuto sul tuo Mac da una cattura nitida dello schermo della VM: nella VM non si installa nulla e nulla esce dal tuo Mac.
- **Appunti.** `set_clipboard` mette del testo negli appunti della VM (fino a 1 MiB), così l’agente incolla un testo lungo con ⌘V invece di digitarlo; `get_clipboard` legge quello che un’app nella VM ha copiato (`nido act <vm> clipboard-set` e `clipboard`). Un elemento segnato come nascosto, come la copia della password di Nido o quella di un gestore di password, non viene mai mostrato. Gli appunti del tuo Mac non vengono mai toccati e il registro delle attività tiene solo il numero di caratteri.

### Correzioni
- **Permettere un dominio su una base salta le copie nuove chiuse nel frattempo**; se l’elenco di una copia è danneggiato, Nido ti dice di eseguire `nido net reset`.

### Nido Agent 1.0.8
- Aggiunge barra dei menu e Dock a `ui_tree` (1.0.7) e gli appunti (1.0.8). Aggiornalo da **Impostazioni › Agent** della VM o con `nido agent setup <vm>`.

## [0.10.0] – 2026-11-22

### Mac Intel (sperimentale)
- **Nido ora funziona sui Mac Intel con macOS 26, per le VM Linux.** Debian 13 e Ubuntu Server 26.04 e 24.04 usano le loro immagini cloud amd64, verificate come sui Mac con chip Apple. Nido è ora un’unica app universale con un unico comando `nido` universale.
- **Cosa manca sui Mac Intel:** le VM macOS e il Mac per agenti, Rosetta, la sospensione e gli snapshot di una VM accesa (gli snapshot di una VM ferma funzionano). Ollama usa la CPU della VM: scegli un modello piccolo.
- **Una VM creata su un tipo di Mac non si avvia sull’altro.** Nido lo dice prima di toccarla; puoi comunque mostrarla nel Finder o eliminarla.
- **Sperimentale:** questa versione non ha ancora avviato una VM su un Mac Intel. Se ne hai uno, provala e racconta com’è andata in una segnalazione sulla pagina GitHub di Nido.

### Mac con chip Apple
- Per le tue VM non cambia nulla. Le nuove VM Linux ricevono Guest Tools 1.6.0.

### Guest Tools 1.6.0
- Installa Ollama anche nelle VM amd64.

## [0.9.4] – 2026-11-22

### Un Mac per gli agenti
- **Un agente può leggere i controlli dell’app sullo schermo.** La nuova azione `ui_tree` (lo strumento MCP `ui_tree`, o `nido act <vm> ui-tree`) elenca pulsanti, campi e testi dell’app in primo piano, con nome e posizione. Il valore di un campo password non esce mai dalla VM.
- **Vedi cosa ha fatto un agente.** **Attività dell’agente** (l’icona a elenco nella barra della VM, o **Attività…** in Impostazioni › Agent) e `nido agent log <vm>` mostrano le azioni di ogni sessione: cosa ha guardato l’agente, dove ha cliccato, quali tasti ha premuto. Il testo digitato non viene mai registrato, solo la sua lunghezza.
- **Checkpoint.** Prima di un passo rischioso un agente può salvare la VM con la sua memoria (`checkpoint`) e tornare a quel momento se il passo va male (`rollback`). Ne tiene al massimo 3, vede solo i suoi e non tocca mai le tue istantanee; nell’elenco delle istantanee hanno l’etichetta **Agente**.
- **File dentro e fuori.** `put_file` e `get_file` copiano file dentro e fuori da `~/NidoTransfer` nella VM (fino a 1 MiB per un agente; `nido act <vm> put-file` e `get-file` fino a 16 MiB). Nessuna cartella condivisa.
- **Un Mac nuovo per ogni sessione.** `nido mcp --fresh <base>` dà a ogni sessione dell’agente una copia tutta sua di una VM macOS spenta, avviata senza finestra ed eliminata con i suoi file a fine sessione. `--keep` tiene la copia come una VM normale.
- **L’agente sa cosa ha bloccato la rete.** Sulla rete controllata un agente viene informato dei domini bloccati da Nido, così si ferma e ti chiede di eseguire `nido net allow` invece di pensare che il sito sia giù. Un dominio permesso su una base vale subito anche per le sue copie nuove.

### Correzioni
- **Quando lo schermo della VM è bloccato, l’agente lo sa**, invece di ricevere un errore di cattura.
- **Avviare una terza VM macOS spiega il limite di Apple**: al massimo due VM macOS insieme.

### Nido Agent 1.0.6
- Aggiunge `ui_tree` (1.0.5) e il trasferimento di file (1.0.6). Aggiornalo da **Impostazioni › Agent** della VM o con `nido agent setup <vm>`.

## [0.9.3] – 2026-11-17

### Un Mac per gli agenti
- **Un agente può ingrandire per leggere il testo piccolo.** La nuova azione `zoom` (lo strumento MCP `zoom`, o `nido act <vm> zoom X Y W H`) mostra una parte dell’ultimo screenshot alla piena risoluzione dello schermo della VM. I clic usano ancora le coordinate dell’ultimo screenshot. Serve Nido Agent 1.0.4.

### Correzioni
- **`nido ssh` dice cosa fare quando una VM macOS è ferma alla finestra di login** (FileVault), invece di mostrare solo il “Permission denied” di ssh.
- **Impostazioni › Agent non interroga più il Portachiavi di continuo** mentre una password salvata non è utilizzabile, e l’avviso sparisce quando sistemi la password dal Terminale.
- **Quello che lascia una clonazione interrotta viene rimosso insieme al suo elemento del Portachiavi**, e la pulizia non tocca mai un’installazione ancora in corso.

### Nido Agent 1.0.4
- Aggiunge lo zoom. Aggiornalo da **Impostazioni › Agent** della VM o con `nido agent setup <vm>`.

## [0.9.2] – 2026-11-16

### Correzioni
- **A schermo intero la barra della VM scende sotto la barra dei menu.** Quando porti il puntatore in cima allo schermo, macOS mostra la barra dei menu e la barra del titolo della finestra, e ora la barra di Nido compare sotto di loro, come nelle app di sistema. Prima, su uno schermo senza tacca (per esempio un monitor esterno), la barra dei menu la copriva e i suoi pulsanti, Esci da schermo intero compreso, non si potevano cliccare.
- **Le note della 0.9.1 mostrano ogni carattere correttamente** in inglese e in tedesco.

## [0.9.1] – 2026-11-16

### Correzioni
- **Una password della VM illeggibile non viene più scambiata per una password mancante.** **Impostazioni › Agent** mostra il campo per inserirla di nuovo e `nido agent setup` la chiede; clonare o avviare quella VM ti indica dove farlo.
- **Quando il primo avvio non riesce ad autorizzare la chiave di Nido**, il campo della password compare subito in **Impostazioni › Agent** e l’avviso nella finestra della VM sparisce dopo 30 secondi.
- **Se la chiave è autorizzata ma il Portachiavi rifiuta la password**, la configurazione continua e te lo dice, invece di fallire.
- **La password va solo al `ssh` avviato da Nido**, e un’installazione interrotta a metà non lascia più la sua password nel Portachiavi.
- **Copia negli appunti della VM è disattivato quando non può funzionare** e dice perché, per esempio quando la VM non è in esecuzione in Nido.
- **Accesso da terminale** mostra i passaggi giusti per una VM creata con un account; la procedura Nuova VM controlla l’account quando smetti di scrivere; `nido start` non stampa più nulla dopo l’arresto della VM.

## [0.9.0] – 2026-11-15

### Un Mac per gli agenti
- **Un agente AI può usare una VM macOS separata mentre tu continui a usare il tuo Mac.** Prima Claude Code, poi qualsiasi client MCP: `nido mcp <vm>` avvia un server MCP (stato, screenshot, clic, trascinamento, scorrimento, testo, tasti, attesa), `nido act <vm> …` fa le stesse azioni dalla shell con output JSON, e `nido skill install` installa la skill che insegna all'agente a guardare, agire e controllare.
- **Il tuo Mac resta tuo.** Nido Agent, una piccola app firmata dentro la VM, cattura lo schermo e invia gli input lì dentro con un canale privato: puntatore, tastiera e appunti del tuo Mac non vengono mai toccati. Il canale è raggiungibile solo dal tuo utente sul tuo Mac, e solo per la VM indicata.
- **Spento per impostazione predefinita, per ogni VM**: lo attivi in **Impostazioni › Agent** o con `nido agent enable <vm>`, poi installi Nido Agent con **Installa Nido Agent** o `nido agent setup <vm>` e consenti Registrazione schermo e Accessibilità nella VM. Mentre un agente lavora, un banner appare nella finestra della VM e un segno nella libreria; la dimensione dello schermo della VM resta fissa finché l'accesso dell'agente è attivo.
- **Con FileVault nella VM**, un agente può lavorare solo dopo che accedi a ogni avvio. Nido lo spiega e non cambia mai FileVault.

### macOS 27: una VM pronta senza l'assistente iniziale
- **Su un Mac con macOS 27, con un'immagine macOS 27, la creazione guidata di una VM crea l'account per te** (come `nido create --ipsw … --account "Nome Cognome"`, con `--agent` per l'accesso dell'agente). Il primo avvio salta l'assistente iniziale, accede da solo e attiva Login remoto. Con l'accesso dell'agente attivo, Nido installa anche Nido Agent: resta solo il passaggio dei due permessi.
- **La password dell'account è generata per impostazione predefinita (o la scegli tu) e resta nel Portachiavi del tuo Mac**, un elemento per VM, eliminato con la VM. La vedi in **Impostazioni › Agent** dopo Touch ID, o con `nido agent password <vm>`; **Copia negli appunti della VM** la tiene lì per 60 secondi, così la incolli nella VM. Nido la usa una sola volta per autorizzare la sua chiave. Su Mac o immagini meno recenti, chiede la password una volta, quando serve.

### Scarica macOS da Apple
- **`nido image macos` mostra la versione di macOS che Apple offre per questo Mac e la sua dimensione**; con `--download` la scarica. Il download riprende se si interrompe, viene controllato prima dell'uso e arriva solo dai server di Apple. La creazione guidata ha **Scarica da Apple**, con una conferma prima. Nido non va mai online da solo.

### Accesso da terminale
- **Digita nella VM segue la tastiera della VM**: scegli la **Tastiera della VM** per ogni VM, e i comandi arrivano intatti anche se il Mac e la VM usano layout diversi.

### Nido Agent 1.0.3
- È la versione inclusa nell'app. Aggiornala da **Impostazioni › Agent** della VM.

### Correzioni
- **Le righe di avanzamento di `nido agent setup` compaiono man mano**, anche in una pipe o in un file.

## [0.8.1] – 2026-11-14

### Lingue
- **La lingua di Nido si sceglie in Impostazioni › Generale › Lingua**: inglese, italiano, tedesco, spagnolo, francese o come il sistema. Nido si chiude e si riapre nella lingua nuova; con una VM accesa prima chiede cosa farne, come quando esci. È la stessa impostazione di Impostazioni di Sistema › Generali › Lingua e Zona › Applicazioni.

### Libreria
- **Ogni VM ha il suo colore**: il suo simbolo nella libreria mostra il logo del sistema (la spirale di Debian, il logo di Apple per macOS; Ubuntu tiene la sua lettera) su una di otto tinte discrete. La creazione di una VM propone un colore che nessun'altra VM ha; lo cambi quando vuoi in **Impostazioni › Generale › Colore**.

### Correzioni
- **Le schede dei sistemi nella creazione di una VM sono allineate**: un nome o un dettaglio su due righe (“Ubuntu Server”, le traduzioni più lunghe) non rende più la sua scheda più alta delle altre e non le sposta.

## [0.8.0] – 2026-11-13

### Lingue
- **Nido parla inglese, italiano, tedesco, spagnolo e francese**: l'app, il comando `nido`, le note di versione e il README. L'inglese è la lingua di base; l'app segue la lingua di macOS, e con una lingua diversa da queste cinque è in inglese.
- Il comando `nido` segue la lingua del sistema; `NIDO_LANGUAGE` (`en`, `it`, `de`, `es` o `fr`) ne sceglie un'altra, per esempio negli script che leggono quello che scrive.

### Nido Guest Tools 1.5.0
- **I messaggi su Ollama e sui modelli arrivano nella tua lingua**: i Guest Tools mandano un codice stabile con ogni errore e avviso, e l'app mostra il suo testo. I Guest Tools precedenti mandano ancora i messaggi in italiano, che Nido mostra così come arrivano: reinstalla i Guest Tools dalle impostazioni della VM per averli nelle VM esistenti.

### Il comando nido dal menu
- **Nido › Installa il comando nido…** crea `~/.local/bin/nido`, un collegamento al comando che ora sta dentro l'app (insieme a `gvproxy`): il comando si aggiorna con l'app. Se `~/.local/bin` non è nel `PATH`, Nido lo dice. Una copia installata prima da `scripts/install.sh` viene sostituita solo dopo una conferma.
- **Nido › Rimuovi il comando nido** toglie il collegamento solo se punta a Nido.
- Aperto direttamente dal DMG, Nido non installa il comando e chiede di spostarlo prima in Applicazioni.

### Aggiornamenti
- **Nido › Cerca aggiornamenti…** controlla se c'è una nuova versione. Nido non contatta la rete da solo: il controllo automatico parte solo se lo scegli (alla domanda del secondo avvio o in **Impostazioni › Generale › Cerca aggiornamenti automaticamente**, spento di default).
- **Mai con una VM accesa**: finché una VM è accesa, nell'app o con `nido start`, l'aggiornamento scaricato aspetta. Viene installato all'uscita da Nido quando nessuna VM è accesa, e un avviso dice quali VM lo bloccano.
- Ogni aggiornamento è firmato (EdDSA) e scaricato su HTTPS; Nido rifiuta un aggiornamento o un elenco delle versioni senza una firma valida.

### Firma Developer ID
- **Nido è firmato con un certificato Developer ID e notarizzato da Apple**: si apre senza aggirare Gatekeeper. L'app, il comando `nido`, `gvproxy` e Sparkle hanno tutti la stessa firma, con Hardened Runtime.
- Accanto al DMG ci sono i checksum SHA-256 e l'elenco dei componenti (SBOM, SPDX).

### Portachiavi
- **Dopo il cambio di firma macOS può chiedere ancora una volta l'accesso al token di Hugging Face** salvato nel Portachiavi. Basta consentire una volta; se il token non si legge più, reinseriscilo in **Impostazioni › Hugging Face**.

### Sicurezza
- **Una VM non può più far chiudere Nido**: valori fuori scala mandati dal guest (le percentuali del monitor, le dimensioni e l'avanzamento dei modelli di Ollama) chiudevano l'app, e con lei tutte le VM accese. Ora vengono limitati prima di essere mostrati.
- **Chat e console non bloccano più l'app**: una risposta della chat locale o un'uscita della console costruite per rallentare Nido vengono lette a pezzi e in tempo lineare, senza fermare le altre VM. La risposta della chat ha anche un limite di dimensione.
- **L'indirizzo degli aggiornamenti è sempre quello di Nido**: un valore lasciato nelle preferenze dell'app non può più sostituirlo. Gli aggiornamenti restavano comunque firmati.

## [0.7.6] – 2026-11-10

### Immagini
- **`nido image check` mostra la build Debian** controllata, per esempio `debian-13: aggiornata (build 20261103-2651)`; `nido image update` dice quale build ha scaricato.
- **`nido image reset <id>`** dimentica la build e la firma già accettate di un'immagine, dopo una conferma. Serve solo se Nido continua a rifiutare una lista "più vecchia di quella già accettata"; il messaggio di rifiuto ora lo indica, al posto del file da cancellare a mano. L'immagine nella cache resta.

### Rete controllata
- Il suggerimento **Spegni** della scheda Rete e il conteggio del rumore nascosto sono coperti da un test dell'interfaccia.

## [0.7.5] – 2026-11-10

### Rete controllata
- **La scheda Rete propone di spegnere le richieste di sfondo** nelle VM Linux create prima di Nido 0.7.4: **Spegni** le ferma subito (con la VM accesa), **Non ora** non lo chiede più per quella VM. Resta anche in Impostazioni › Guest Tools.
- **La scheda Rete dice quante righe di rumore locale nasconde** (IPv6 multicast e link-local, broadcast) e come vederle con `nido net log --all`.

### Immagini
- **Debian: build controllata.** Nido legge anche il manifest della build che Debian pubblica accanto all'immagine e rifiuta file incoerenti o una build più vecchia di quella già accettata, prima del download. Debian non firma le immagini cloud: non è una firma, ma ferma una copia vecchia riproposta.
- **Ubuntu: pronta per un cambio di chiave.** Nido può accettare la chiave di firma attuale e quella annunciata come successiva, così un cambio di chiave non blocca i download.

### Finestra della VM
- La barra compatta (menu **Altro**) è coperta da un test dell'interfaccia: a finestra stretta Pausa e Arresta restano a vista e le voci di Altro funzionano.

## [0.7.4] – 2026-11-10

### Rete controllata più pulita
- **Debian non cerca più i changelog in rete**: `apt-listchanges` provava ogni ora a scaricarli da `metadata.ftp-master.debian.org` (l'immagine cloud non li contiene), e il registro si riempiva di blocchi. Le VM Linux nuove lo hanno spento; per quelle create prima basta **Impostazioni › Guest Tools › Richieste di sfondo · Spegni**.
- **Il rumore locale non compare più nel registro**: gli annunci IPv6 multicast e link-local (`ff02::…`) e i broadcast della scheda di rete della VM, che non escono mai dalla VM, non sono più stampati da `nido start` né mostrati nella scheda Rete. `nido net log` dice quante righe ha nascosto; `nido net log --all` le mostra.

### Immagini Ubuntu
- **Una lista dei checksum firmata prima dell'ultima già accettata è rifiutata**: chi riproponesse una lista vecchia (ma firmata) per fermare la cache su una build precedente viene fermato prima del download.
- **Se Ubuntu cambia la chiave di firma**, Nido lo dice ("firmata con una chiave che Nido non conosce", con l'ID della chiave) invece di un generico "firma non valida".

### Finestra della VM
- **In una finestra stretta** i pulsanti che non ci stanno (Sospendi, Snapshot, Impostazioni, Accesso da terminale, Schermo intero) finiscono nel menu **Altro**; Pausa, Riprendi, Avvia e Arresta restano sempre a vista.

## [0.7.3] – 2026-11-10

### Impostazioni con la VM accesa
- **Il pulsante Impostazioni c'è anche con la VM accesa**, nella finestra della VM e nella sua scheda in libreria. CPU e memoria restano bloccate finché la VM non è arrestata; le azioni nella VM (Guest Tools, **Richieste di sfondo · Spegni**) si usano proprio con la VM accesa.

## [0.7.2] – 2026-11-09

### Immagini Ubuntu: firma verificata
- **Nido verifica la firma di Ubuntu sulla lista dei checksum** (`SHA256SUMS.gpg`) prima di usarla, sia al download sia con `nido image check`. La chiave di Ubuntu è dentro Nido; non serve `gpg`. Se la firma manca o non torna, Nido non scarica l'immagine. Il passo Download lo indica: "checksum SHA-256 · firma di Ubuntu".
- Debian non pubblica una firma per le immagini cloud: lì resta la verifica del checksum su HTTPS.

### Rete controllata più pulita
- **Le query SRV di apt sono spente in ogni VM Linux nuova**, anche Debian (prima comparivano nel registro come blocchi a ogni `apt update`).
- **VM create prima**: Impostazioni della VM › Guest Tools › **Richieste di sfondo · Spegni** applica le stesse impostazioni via SSH, con la VM accesa. Su Ubuntu spegne anche snap, notizie, Ubuntu Pro e il controllo delle nuove versioni.
- Provato dal vivo anche su Ubuntu 24.04.

### Correzioni
- Cache delle immagini: se l'immagine nuova non si può salvare, il checksum nuovo non resta accanto a quella vecchia; un controllo della cache che si sovrappone a un download della stessa immagine non la scarica una seconda volta.

## [0.7.1] – 2026-11-09

### Ubuntu più silenziosa sulla rete controllata
- Le VM Ubuntu nuove non provano più a contattare snap (`api.snapcraft.io`), le notizie del messaggio di accesso (`motd.ubuntu.com`), Ubuntu Pro (`contracts.canonical.com`), il controllo delle nuove versioni (`changelogs.ubuntu.com`) e `entropy.ubuntu.com`, e apt non chiede più i record SRV: il registro della rete non si riempie più di blocchi. Pacchetti, aggiornamenti di sicurezza e orologio funzionano come prima.
- Per riattivarli nella VM: `sudo systemctl unmask snapd.service snapd.socket snapd.seeded.service` (e così per le altre unità), poi permetti il dominio dalla scheda Rete.
- Le VM Ubuntu create prima non cambiano.

### Correzioni
- **Immagini qcow2 più sicure**: un qcow2 che usa due volte lo stesso cluster, o che descrive molti più dati di quanti il file ne contenga, viene rifiutato prima di scrivere il disco. Riguarda solo `--image-file` con file costruiti apposta; le immagini di Ubuntu passano come prima.

## [0.7.0] – 2026-11-09

### Immagini: nuove build
- **Nido dice quando Debian o Ubuntu pubblicano una nuova build** dell'immagine già nella cache (di solito con correzioni di sicurezza). Prima la copia scaricata restava quella per sempre, senza avviso.
- Nella creazione guidata, passo Download: con l'immagine già nella cache c'è **Cerca una nuova build**. Se ce n'è una, il pulsante **Scarica** la scarica, la verifica e sostituisce la vecchia.
- Dal Terminale: `nido image list` (catalogo e cache, senza rete), `nido image check [id]` e `nido image update <id>`.
- Il controllo scarica solo la lista dei checksum, mai l'immagine, e parte solo quando lo chiedi. Le VM già create non cambiano.

### Correzioni
- **`nido ssh` usa la chiave con cui la VM è stata creata.** Con una VM creata da una chiave diversa da quelle predefinite di `~/.ssh` rispondeva "Permission denied (publickey)". Se la chiave privata sta solo in un agente (per esempio un gestore di password) funziona lo stesso. Un `-i` dopo `--` viene ancora provato.

## [0.6.0] – 2026-11-03

### Rete controllata: di nuovo per impostazione predefinita
- **Le VM nuove partono di nuovo sulla rete controllata** (Linux e macOS) e ora funziona anche con l'inoltro IP del Mac spento, cioè con l'impostazione predefinita di macOS. L'avviso della 0.5.1 sull'inoltro IP non c'è più: Nido non legge né cambia più `net.inet.ip.forwarding`.
- Dietro le quinte, ogni VM controllata ha il suo `gvproxy`, un piccolo programma di terzi che fa da NAT al posto di vmnet. Il filtro di Nido decide ancora prima di lui, per ogni pacchetto. Se `gvproxy` non parte o si ferma, la VM resta senza rete e Nido lo dice: mai il NAT di Apple al suo posto.
- `gvproxy` (gvisor-tap-vsock 0.9.0, Apache-2.0) è l'unico programma di terzi dentro Nido: versione e checksum sono fissati, non viene mai scaricato mentre l'app gira e porta la firma di Nido. Licenze e avvisi sono nell'app. Per un firewall del Mac il traffico permesso esce come `gvproxy`.
- **SSH su `127.0.0.1`**: `nido ssh`, `nido ip` e i comandi SSH dell'app raggiungono una VM controllata da una porta locale (cambia a ogni avvio; la chiave dell'host resta riconosciuta). La VM ha sempre l'indirizzo `192.168.127.2`. Le VM sul NAT di Apple non cambiano.
- **Togliere un dominio chiude davvero le connessioni aperte nella VM**: prima il relè le tagliava ma la VM non lo sapeva, e un download in corso restava appeso; ora riceve un reset e il programma dà subito errore.
- **Lista di base per macOS**: le VM macOS nuove partono con i server Apple per attivazione, controllo degli aggiornamenti e orologio (`albert`, `gdmf`, `mesu`, `swscan`, `swdist`, `time` di `apple.com`), non più con la lista vuota: l'assistente iniziale arriva alla scrivania e `softwareupdate --list` funziona. Per scaricare un aggiornamento servono anche `updates.cdn-apple.com` e `updates-http.cdn-apple.com`; Apple ID, iCloud e App Store restano da permettere a mano.
- **"Digita nella VM" scrive giusto anche i caratteri con Maiuscole** (come `$` e `"` su una tastiera tedesca): prima nella VM macOS arrivavano senza.
- Se una VM controllata della 0.5.x era sospesa, riparte da zero (stato salvato non compatibile).
- **VM Debian della 0.5.0 senza i pacchetti del primo avvio**: Nido non li installa in un secondo momento (cloud-init li installa solo al primo avvio). Con la VM accesa e in rete (`deb.debian.org` è nella lista di base) installali da SSH: `nido ssh <vm> -- sudo apt-get update`, poi `nido ssh <vm> -- sudo apt-get install -y ca-certificates curl wget git python3 python3-venv python3-pip openssh-server iproute2 procps util-linux jq tar zstd`. In alternativa ricrea la VM.

## [0.5.1] – 2026-11-02

### Ubuntu Server
- **Ubuntu Server 26.04 LTS e 24.04 LTS** come sistemi delle VM Linux, oltre a Debian 13: dalla creazione guidata (riquadro Ubuntu Server, con la scelta della versione) o con `nido create --image ubuntu-26.04` / `ubuntu-24.04`.
- Le immagini arrivano da `cloud-images.ubuntu.com` e sono verificate con SHA-256 prima dell'uso.
- Ubuntu pubblica le immagini arm64 solo in formato qcow2: Nido le converte da sé in un disco sparso, senza strumenti esterni. Vale anche per un'immagine locale con `--image-file`.
- La libreria e `nido list` mostrano la distribuzione di ogni VM.
- Guest Tools installabili anche su Ubuntu.
- Lista di base della rete controllata per Ubuntu: `archive.ubuntu.com`, `security.ubuntu.com`, `ports.ubuntu.com`, più Ollama e `time.cloudflare.com`. L'orologio delle VM Ubuntu nuove si sincronizza con `time.cloudflare.com`.

### Rete controllata: ora è una scelta
- **Le VM nuove partono sul NAT di Apple.** Con la 0.5.0 una VM nuova sulla rete controllata non raggiungeva nessun sito, nemmeno quelli permessi, su un Mac con l'impostazione predefinita: la rete controllata funziona solo con l'inoltro IP del Mac acceso (`net.inet.ip.forwarding`), di solito spento. Il motivo è descritto in `docs/SECURITY.md`.
- La rete controllata si attiva nelle impostazioni della VM, sezione Rete. Le VM Linux nuove hanno già la lista di base pronta, quelle macOS la lista vuota.
- Se l'inoltro IP è spento, la conferma per attivare la rete controllata lo dice, e ogni avvio di una VM controllata mostra un avviso (anche `nido start`). Nido legge l'impostazione ma non la cambia.
- Le VM create con la 0.5.0 restano sulla rete controllata: se non raggiungono Internet, disattivala nelle impostazioni della VM. Una VM Debian creata senza rete non ha installato i pacchetti del primo avvio.

## [0.5.0] – 2026-10-29

### Rete controllata delle VM
- **Le VM nuove escono su Internet solo verso i domini permessi.** Nido sta sul "cavo di rete" della VM: risponde alle sue richieste DNS e lascia passare solo i collegamenti verso gli indirizzi che ha risolto per un dominio della lista. Il resto è bloccato: indirizzi mai chiesti per nome, DNS verso altri server, IPv6, ICMP, i servizi del Mac (resta SSH dal Mac alla VM).
- Lista di base delle VM Linux: `deb.debian.org`, `registry.ollama.ai` e l'archivio dei modelli di Ollama, `time.cloudflare.com`. Le VM esistenti restano sul NAT di Apple finché non attivi la rete controllata nelle impostazioni della VM, sezione Rete.
- Se la rete controllata non parte, la VM resta senza rete e Nido lo dice: mai il NAT al suo posto.
- **Avvisi**: ogni blocco arriva come notifica di Nido, con la VM, la destinazione e la porta; i blocchi ripetuti si uniscono in un avviso con il conteggio. Con l'app chiusa, `nido start` scrive una riga nel Terminale e l'app mostra gli avvisi al prossimo avvio. Il rumore di rete dell'avvio (IPv6 locale, broadcast) resta solo nel registro.
- **Consenti** nell'avviso aggiunge il dominio alla lista, con Touch ID o la password del Mac, e vale subito, senza riavviare la VM. Togliere un dominio non chiede nulla e interrompe subito i suoi collegamenti aperti; anche disattivare la rete controllata chiede Touch ID.
- Registro della rete nella finestra della VM (scheda Rete) e con `nido net log`: ora, dominio, indirizzo, porta, byte, esito. Mai il contenuto del traffico.
- `nido net list|allow|deny|reset` gestisce la lista dal Terminale; `allow` e `reset` chiedono Touch ID.
- **Controllo del nome TLS**: una connessione HTTPS verso un indirizzo permesso che nomina un sito non permesso della stessa CDN viene interrotta, e "Consenti" offre quel nome. È un controllo in più, non completo (QUIC e alcuni browser non sono coperti: vedi `docs/SECURITY.md`).
- **VM macOS**: anche loro con la rete controllata, ma con la lista vuota: macOS non raggiunge i servizi Apple (attivazione, aggiornamenti, App Store, iCloud) finché non li permetti. Se l'assistente iniziale si ferma sull'attivazione, aggiungi `albert.apple.com` oppure disattiva la rete controllata per l'assistente.
- Le VM create o modificate con questa versione non si aprono con le versioni precedenti di Nido.

### Nido Guest Tools 1.4.0
- L'archivio di Ollama lo scarica il Mac (versione e SHA-256 fissati) e lo manda nella VM (`--archive-stdin`): la VM non contatta mai GitHub. La sezione AI mostra il download sul Mac, con Annulla.
- L'archivio resta in `~/Library/Caches/Nido/ollama`; le versioni vecchie non si cancellano da sole.
- L'orologio delle VM nuove si sincronizza con `time.cloudflare.com`.
- Per installare Ollama in una VM esistente servono i Guest Tools 1.4.0: reinstallali dalle impostazioni della VM.

## [0.4.0] – 2026-10-27

### VM macOS
- **Crea una VM macOS da un file IPSW** che scegli tu (Nido non scarica nulla e non tocca il file): dalla creazione guidata o con `nido create --ipsw`. Prima di creare qualunque file controlla che l'immagine sia adatta a questo Mac.
- L'installazione dura da 4 a 20 minuti, secondo il Mac e il disco, con avanzamento e Annulla; se si interrompe non resta nessuna VM a metà.
- La finestra della VM mostra lo schermo di macOS. Chiudere la finestra dovrebbe lasciare la VM accesa (da verificare).
- **Accesso da terminale**: un pannello guida ad attivare Login remoto e autorizzare la tua chiave; **Digita nella VM** scrive il comando nel Terminale del guest (non preme Invio). Poi `nido ssh` entra con l'account indicato alla creazione. Provato dal vivo con macOS 26.6.2 (tastiera tedesca): il comando usa `"$HOME"` invece di `~`, che su alcune tastiere si ottiene solo con un tasto morto.
- Sospensione, snapshot a VM ferma, ripristino e clone funzionano anche per macOS (provati con un IPSW reale); lo snapshot a VM accesa dall'app è da verificare; il clone ha un nuovo identificatore e mostra i passi da fare una volta nella copia (chiavi host SSH e nome del computer).
- Cartelle condivise (in sola lettura di default, dentro `/Volumes/My Shared Files`) e uscita audio, configurate ma da verificare nel guest. Niente appunti condivisi né microfono.
- Guest Tools, monitor, provisioning, Ollama, ponte AI e modelli di VM restano solo per Linux.

### Linux e app
- Un primo avvio Linux interrotto non lascia più la VM senza accesso SSH: le chiavi host mancanti si rigenerano a ogni avvio.
- Uscendo da Nido nel primo minuto del primo avvio, l'app lo segnala.
- `nido list` mostra la colonna SISTEMA.

## [0.3.1] – 2026-10-26

### Chat con i modelli locali
- I link web nelle risposte si aprono nel browser; gli indirizzi che nascondono la destinazione, quelli verso il Mac stesso e ogni altro tipo di indirizzo restano testo.
- Ogni risposta indica il modello che l'ha scritta.
- **Cancella la chat** chiede conferma prima di perdere la conversazione.
- Se Ollama è fermo, la chat dice di avviarlo con **Avvia**.

### Sicurezza e affidabilità
- Il ponte AI si chiude con la VM: fermando o sospendendo la VM, le richieste a Hugging Face in corso vengono annullate subito e non consumano altro budget.
- Gli errori di Hugging Face arrivano alla VM senza dati del tuo account: solo il codice e una spiegazione fissa.
- La chiave SSH di ogni VM è legata alla VM e non al suo indirizzo: se l'indirizzo cambia, Nido pretende la stessa chiave.
- Le connessioni del ponte in attesa non occupano più thread del Mac.

### Nido Guest Tools 1.3.0
- I servizi nella VM girano con restrizioni di sistema più strette.
- Gli aggiornamenti rimuovono i file che la nuova versione non usa più.
- Ollama fermato resta fermo anche dopo un riavvio della VM, finché non lo avvii, riavvii, reinstalli o aggiorni.
- Reinstalla i Guest Tools dalle impostazioni della VM per averli nelle VM esistenti.

## [0.3.0] – 2026-10-26

### Chat con i modelli locali
- Le risposte mostrano la formattazione Markdown: **grassetto**, *corsivo*, `codice`, elenchi, titoli, citazioni e blocchi di codice.
- La risposta arriva senza sfarfallii e la conversazione la segue; se scorri in alto resta dove sei e compare **Vai alla fine**.
- **Copia** porta una risposta negli appunti, così come l'ha scritta il modello.
- Sotto ogni risposta: quanto è durata e quanti token al secondo ha generato il modello.
- Mentre il modello prepara la risposta lo vedi subito; **Interrompi** (o Esc) la ferma.
- La chat resta nella VM e in memoria: Nido non la salva sul Mac e Ollama non è raggiungibile da fuori.

### Intelligenza artificiale nelle VM
- Nuove VM Debian già pronte: pacchetti essenziali e Nido Guest Tools al primo avvio.
- Ollama e i modelli scelti si installano nella VM con un clic, con versione e checksum verificati.
- Monitor della VM: CPU, memoria, disco e avvisi, letti dalla VM senza rete.
- Ponte AI facoltativo verso Hugging Face: il token resta nel Portachiavi, mai nella VM; limiti di token e richieste per ogni VM e un registro senza contenuti.
- Modelli di VM: salva una VM come modello e creane di nuove da lì.

### Macchine virtuali
- Snapshot, sospensione e ripresa con lo stato della memoria.
- Clona una VM spenta.
- Cartelle condivise: nessuna per impostazione predefinita, sola lettura salvo scelta diversa, revocabili subito anche a VM accesa; cloni e modelli non le ereditano.
- Rosetta per eseguire programmi x86-64 nelle VM Linux.
- Avviso quando la memoria delle VM accese supera quella che il Mac può dare, e riavvio automatico di una VM bloccata da un errore del kernel.

### Terminale
- `nido --version`, `nido template` e `nido create --from-template`.

### Correzioni
- Le modifiche alla configurazione di una VM fatte insieme dall'app e dal Terminale non si annullano più a vicenda.
- Il ponte AI libera le connessioni quando il Mac chiude la sua parte (Guest Tools 1.2.1: reinstallali nelle VM esistenti).

## [0.2.0] – 2026-10-23

### Prima versione dell'app
- Libreria delle VM con stato in tempo reale.
- Creazione guidata di VM Debian.
- Finestra della VM con schermo, console seriale, pausa e ripresa.
- Impostazioni della VM e preferenze di Nido.

## [0.1.0] – 2026-10-23

### Comando `nido`
- `nido create`, `list`, `start`, `stop`, `ip`, `ssh` e `delete`.
- Immagini Debian scaricate solo da fonti ammesse e verificate con SHA-512.
- Accesso alle VM solo con chiave SSH.
