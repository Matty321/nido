// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import Nido

/// The app's copy is English in the code and five languages in its String Catalogs
/// (App/Nido/Localizable.xcstrings, App/Nido/InfoPlist.xcstrings). Each area of the app adds its
/// copy here: every key resolves in it, de, es and fr from the built app's `<lang>.lproj`, and
/// the Italian is today's Italian copy, byte for byte (the app's tests run in Italian).
struct AppLanguageTests {
    static let translations = ["it", "de", "es", "fr"]

    /// `key` looked up in the app's `<language>.lproj`, independent of the process's language.
    static func localized(_ key: String, _ language: String, table: String? = nil) -> String? {
        guard let path = Bundle.main.path(forResource: language, ofType: "lproj"),
              let bundle = Bundle(path: path)
        else { return nil }
        let missing = "\u{1}missing"
        let value = bundle.localizedString(forKey: key, value: missing, table: table)
        return value == missing ? nil : value
    }

    static func bundle(_ language: String) throws -> Bundle {
        let path = try #require(Bundle.main.path(forResource: language, ofType: "lproj"), "no \(language).lproj in the app")
        return try #require(Bundle(path: path))
    }

    /// Checks `copy` (English key → today's Italian) in every language.
    static func expectTranslated(_ copy: KeyValuePairs<String, String>, table: String? = nil,
                                 sameAsEnglishAllowed: Set<String> = []) {
        for (key, italian) in copy {
            for language in translations {
                let value = localized(key, language, table: table)
                #expect(value?.isEmpty == false, "\(key): no \(language)")
                if let value, language != "it", !sameAsEnglishAllowed.contains("\(language):\(key)") {
                    #expect(value != key, "\(key): \(language) is the English")
                }
            }
            #expect(localized(key, "it", table: table) == italian, "\(key): Italian is not today's copy")
        }
    }

    // MARK: - App shell: scene titles, menus, alerts

    static let shellCopy: KeyValuePairs<String, String> = [
        // NidoApp.swift: scene titles and the startup error.
        "What’s New in Nido": "Novità di Nido",
        "Virtual Machine": "Macchina virtuale",
        "VM Settings": "Impostazioni VM",
        "Snapshots": "Snapshot",
        "Can’t start Nido": "Impossibile avviare Nido",
        // CommandLinkCommands.swift: the Nido menu and the command link's alerts.
        "Check for Updates…": "Cerca aggiornamenti…",
        "Install the nido Command…": "Installa il comando nido…",
        "Remove the nido Command": "Rimuovi il comando nido",
        "Replace %@?": "Sostituire %@?",
        "It’s a regular file (maybe an old copy of nido). Nido replaces it with a link to the command inside the app.":
            "È un file normale (forse una copia vecchia di nido). Nido lo sostituisce con un collegamento al comando dentro l'app.",
        "Replace": "Sostituisci",
        "Cancel": "Annulla",
        "Also remove the old copy of gvproxy": "Togli anche la vecchia copia di gvproxy",
        "The nido command is installed": "Comando nido installato",
        "The nido command is at %@.": "Il comando nido è in %@.",
        "That folder isn’t in your PATH. Add this line to ~/.zshrc:":
            "Quella cartella non è nel PATH. Aggiungi questa riga a ~/.zshrc:",
        "Couldn’t complete the operation": "Impossibile completare l'operazione",
        // AppDelegate.swift: quitting.
        "Update pending": "Aggiornamento in attesa",
        "Quitting now would install the update while a VM is running, so Nido stays open: stop the VMs with nido stop, then quit.":
            "Uscendo adesso l'aggiornamento verrebbe installato con una VM accesa, quindi Nido resta aperto: arresta le VM con nido stop, poi esci.",
        "Quit": "Esci",
        "Snapshot operation in progress": "Operazione sugli snapshot in corso",
        "Nido will quit as soon as the snapshot operation on %@ is done, so the VM’s files stay intact.":
            "Nido esce appena l'operazione sugli snapshot di %@ è finita, così i file della VM restano integri.",
        "Nido will quit as soon as the snapshot operations on %@ are done, so the VMs’ files stay intact.":
            "Nido esce appena le operazioni sugli snapshot di %@ sono finite, così i file delle VM restano integri.",
        "Quit When Done": "Esci al termine",
        "VM creation in progress": "Creazione in corso",
        "Nido is downloading the Linux image. Quitting stops the download and deletes the partial file.":
            "Nido sta scaricando l'immagine di Linux. Uscendo il download si interrompe e il file parziale viene eliminato.",
        "Stop Download and Quit": "Interrompi ed esci",
        "Nido is creating the virtual machine. Nido will quit as soon as the VM is ready, so no half-made VM is left behind.":
            "Nido sta creando la macchina virtuale. Esce appena la creazione è finita, così non resta una VM a metà.",
        // Updates: UpdateController.swift and UpdateGate.swift.
        "Update postponed": "Aggiornamento rimandato",
        "Nido will update when no VM is running. Running now: %@.":
            "Nido si aggiornerà quando nessuna VM sarà accesa. Accese ora: %@.",
    ]

    @Test func shellCopyExistsInAllLanguages() {
        Self.expectTranslated(Self.shellCopy)
    }

    // MARK: - Design components' own copy

    static let componentCopy: KeyValuePairs<String, String> = [
        "Back": "Indietro",
        "Step %lld of %lld": "Passo %lld di %lld",
        "Close": "Chiudi",
        "Try Again": "Riprova",
        "In progress": "In corso",
        "Decrease %@": "Diminuisci %@",
        "Increase %@": "Aumenta %@",
        "Choose…": "Scegli…",
        "Coming soon": "In arrivo",
        "AI bridge active": "Ponte AI attivo",
        "%lld%%": "%lld %%",
        "Stopped": "Arrestata",
        "Starting": "Avvio in corso",
        "Running": "In esecuzione",
        "Paused": "In pausa",
        "Error": "Errore",
        "Unreadable": "Illeggibile",
        "Suspended": "Sospesa",
        "Busy": "Occupata",
        "Installing": "Installazione",
        "Running (Terminal)": "In esecuzione (Terminale)",
        "The nest is empty": "Il nido è vuoto",
        "Create your first virtual machine: Nido downloads Debian 13 or Ubuntu Server, verifies the image and sets up the VM in a few minutes.":
            "Crea la prima macchina virtuale: Nido scarica Debian 13 o Ubuntu Server, ne verifica l'immagine e la prepara in pochi minuti.",
        "Create VM": "Crea VM",
        "with saved state": "con stato salvato",
        "Creating…": "Creazione in corso…",
        "Create Snapshot…": "Crea snapshot…",
        "Restore": "Ripristina",
        "Delete": "Elimina",
        "Delete %@?": "Eliminare %@?",
        "The VM and its disk (%@) will be deleted from this Mac. This can’t be undone.":
            "La VM e il suo disco (%@) saranno eliminati da questo Mac. L'operazione non si può annullare.",
        "The VM and its disk will be deleted from this Mac. This can’t be undone.":
            "La VM e il suo disco saranno eliminati da questo Mac. L'operazione non si può annullare.",
        "Code": "Codice",
        "%@ code": "Codice %@",
    ]

    @Test func componentCopyExistsInAllLanguages() {
        // The same word as the English is right here (Apple's own: es "Error", de/fr "Code").
        Self.expectTranslated(Self.componentCopy, sameAsEnglishAllowed: ["es:Error", "de:Code", "fr:Code"])
    }

    /// AppDelegate's "N virtual machines were stopped" after a suspend at quit: a plural entry.
    @Test func stoppedAtQuitFollowsTheCount() throws {
        func stopped(_ count: Int, _ language: String) throws -> String {
            String(localized: "\(count) virtual machines were stopped",
                   bundle: try Self.bundle(language), locale: Locale(identifier: language))
        }
        #expect(try stopped(1, "it") == "Una macchina virtuale è stata arrestata")
        #expect(try stopped(3, "it") == "3 macchine virtuali sono state arrestate")
        #expect(try stopped(1, "en") == "A virtual machine was stopped")
        #expect(try stopped(3, "en") == "3 virtual machines were stopped")
        for language in ["de", "es", "fr"] {
            #expect(try stopped(1, language) != stopped(3, language), "\(language): no plural")
            #expect(try stopped(3, language).contains("3"), "\(language)")
        }
    }

    // MARK: - Wizard, library, snapshots

    /// Wizard/, Library/ and Snapshots/: every key with today's Italian (model text included).
    static let wizardLibrarySnapshotsCopy: KeyValuePairs<String, String> = [
        "from an IPSW file": "da file IPSW",
        "macOS installs from an IPSW file you download from Apple’s developer site, betas included: Nido only reads it. Installing takes 4 to 20 minutes, depending on the Mac and the disk; you complete macOS Setup Assistant in the VM’s window.": "macOS si installa da un file IPSW che scarichi tu dal sito sviluppatori di Apple, anche beta: Nido lo legge soltanto. L'installazione dura da 4 a 20 minuti, secondo il Mac e il disco; l'assistente iniziale di macOS lo completi tu nella finestra della VM.",
        "Official Ubuntu Server cloud image from cloud-images.ubuntu.com, verified with SHA-256 before use. Windows is coming in a future version.": "Immagine cloud ufficiale di Ubuntu Server da cloud-images.ubuntu.com, verificata con SHA-256 prima dell'uso. Windows arriverà nelle prossime versioni.",
        "Official Debian cloud image from cloud.debian.org, verified with SHA-512 before use. Windows is coming in a future version.": "Immagine cloud ufficiale di Debian da cloud.debian.org, verificata con SHA-512 prima dell'uso. Windows arriverà nelle prossime versioni.",
        "Monitor, Guest Tools, Ollama, AI bridge and VM templates are Linux-only for now.": "Monitor, Guest Tools, Ollama, ponte AI e modelli di VM sono per ora solo per Linux.",
        "A macOS VM supports the screen, snapshots, suspend, clones, shared folders and nido ssh.": "Una VM macOS ha schermo, snapshot, sospensione, cloni, cartelle condivise e nido ssh.",
        "Version": "Versione",
        "Latest · supported until 2031": "La più recente · supporto fino al 2031",
        "Supported until 2029": "Supporto fino al 2029",
        "Profile": "Profilo",
        "No templates": "Nessun modello",
        "Save a stopped VM as a template from the library, then create new ones from here.": "Salva una VM arrestata come modello dalla libreria, poi creane di nuove da qui.",
        "The new VM is an instant copy of the template: no extra space until the disks change. It has a new identity and starts without shared folders and with the AI bridge off.": "La nuova VM è una copia istantanea del modello: nessuno spazio in più finché i dischi non cambiano. Ha un'identità nuova e parte senza cartelle condivise e con il ponte AI spento.",
        "Download failed": "Download non riuscito",
        "IPSW file": "File IPSW",
        "Change…": "Cambia…",
        "Checking the image": "Controllo dell'immagine",
        "Nido reads the IPSW and checks that this Mac can install it: usually a few seconds.": "Nido legge l'IPSW e verifica che questo Mac possa installarlo: di solito pochi secondi.",
        "Download the IPSW from Apple’s developer site; a beta works too.": "Scarica l'IPSW dal sito sviluppatori di Apple, anche una beta.",
        "Nido only reads it: it doesn’t download, copy, move or change it.": "Nido lo legge soltanto: non lo scarica, non lo copia, non lo sposta e non lo modifica.",
        "Choose the macOS IPSW file": "Scegli il file IPSW di macOS",
        "Choose": "Scegli",
        "Memory": "Memoria",
        "Disk": "Disco",
        "SSH public key": "Chiave SSH pubblica",
        "macOS user name": "Nome utente in macOS",
        "The short name of the account you’ll create in Setup Assistant. Only nido ssh uses it, and you can change it later.": "Il nome breve dell'account che creerai nell'assistente iniziale. Serve solo a nido ssh e si può cambiare dopo.",
        "name": "nome",
        "Nido never asks for or saves passwords.": "Nido non chiede né salva password.",
        "After Setup Assistant, turn on Remote Login in macOS: the Terminal Access panel in the VM’s window guides you.": "Dopo l'assistente iniziale attiva Login remoto in macOS: il pannello Accesso da terminale della finestra della VM ti guida.",
        "Essential packages": "Pacchetti essenziali",
        "curl, git, python3, openssh-server, jq and other basic tools. No full system upgrade.": "curl, git, python3, openssh-server, jq e altri strumenti di base. Nessun aggiornamento completo del sistema.",
        "CPU, memory and disk monitoring over vsock, without the network. Ollama and the AI bridge need them.": "Monitor di CPU, memoria e disco via vsock, senza rete. Servono per Ollama e per il ponte AI.",
        "Install Ollama after first boot": "Installa Ollama dopo il primo avvio",
        "Nido installs it from the official sources once the VM is ready: you can already use the VM while it downloads.": "Nido lo installa dalle fonti ufficiali quando la VM è pronta: puoi già usarla mentre scarica.",
        "Ollama needs the Nido Guest Tools: turn them on to choose Ollama.": "Servono i Nido Guest Tools: attivali per scegliere Ollama.",
        "Model (optional)": "Modello (facoltativo)",
        "Choose the SSH public key": "Scegli la chiave SSH pubblica",
        "Quitting Nido cancels the installation.": "Uscire da Nido annulla l'installazione.",
        "Nido asks before quitting; the files it created are deleted and the IPSW stays where it is.": "Prima di uscire Nido te lo chiede; i file creati vengono cancellati, l'IPSW resta dov'è.",
        "Installation failed": "Installazione non riuscita",
        "Name": "Nome",
        "Creation failed": "Creazione non riuscita",
        "Nido stops the installation and deletes the files created so far. The IPSW stays where it is.": "Nido ferma l'installazione e cancella i file creati finora. L'IPSW resta dov'è.",
        "Cancel Installation": "Annulla l'installazione",
        "Continue": "Continua",
        "From Template": "Da modello",
        "Can’t limit the choice to .ipsw files on this Mac.": "Impossibile limitare la scelta ai file .ipsw su questo Mac.",
        "Choose a macOS %lld IPSW (a %lld.x beta works too). Nido hasn’t created any files.": "Scegli un IPSW di macOS %lld (anche una beta %lld.x). Nido non ha creato alcun file.",
        "Choose the macOS .ipsw file downloaded from Apple’s developer site. Nido hasn’t created any files.": "Scegli il file .ipsw di macOS scaricato dal sito sviluppatori di Apple. Nido non ha creato alcun file.",
        "No file chosen": "Nessun file scelto",
        "This Mac": "Questo Mac",
        "Compatible": "Compatibile",
        "Virtualization supports the image and its hardware model.": "Virtualization supporta l'immagine e il suo modello hardware.",
        "Minimum requirements": "Requisiti minimi",
        "Installation": "Installazione",
        "4 to 20 minutes, depending on the Mac and the disk": "da 4 a 20 minuti, secondo il Mac e il disco",
        "Enter the short name of the account you’ll create in macOS.": "Scrivi il nome breve dell'account che creerai in macOS.",
        "Installing macOS %@": "Installazione di macOS %@",
        "Cancel installing %@?": "Annullare l'installazione di %@?",
        "A copy of a VM saved as a template": "Copia di una VM salvata come modello",
        "Invalid model name: use Ollama’s name, for example llama3.2:1b.": "Nome del modello non valido: usa il nome di Ollama, ad esempio llama3.2:1b.",
        "Only one, downloaded after Ollama. With %lld GiB a small model is best: this is a suggestion, not a guarantee.": "Uno solo, scaricato dopo Ollama. Con %lld GiB conviene un modello piccolo: è un consiglio, non una garanzia.",
        "%@. Nido starts the VM anyway if you choose to.": "%@. Nido avvia comunque la VM se lo scegli.",
        "System": "Sistema",
        "macOS Image": "Immagine macOS",
        "Download (step)": "Download",
        "Resources": "Risorse",
        "Access": "Accesso",
        "Access and Software": "Accesso e software",
        "Summary": "Riepilogo",
        "Choose the template for the new virtual machine.": "Scegli il modello da cui creare la nuova macchina virtuale.",
        "Choose the system and profile of the new virtual machine.": "Scegli il sistema e il profilo della nuova macchina virtuale.",
        "Nido downloads the official image and checks its integrity before using it.": "Nido scarica l'immagine ufficiale e ne controlla l'integrità prima di usarla.",
        "Choose how much of the Mac’s CPU, memory and disk to give %@.": "Scegli quanta CPU, memoria e disco del Mac assegnare a %@.",
        "Sign in to %@ over SSH with your key, no password, and choose what to set up at first boot.": "Accedi a %@ via SSH con la tua chiave, senza password, e scegli cosa preparare al primo avvio.",
        "Check your choices: Nido copies %@ to %@ and starts it.": "Controlla le scelte: Nido copia %@ in %@ e la avvia.",
        "Check your choices: Nido creates %@ and starts it as soon as it’s ready.": "Controlla le scelte: Nido crea %@ e la avvia appena è pronta.",
        "Choose the system of the new virtual machine.": "Scegli il sistema della nuova macchina virtuale.",
        "Choose the macOS IPSW file you downloaded: Nido checks that this Mac can install it.": "Scegli il file IPSW di macOS che hai scaricato: Nido controlla che questo Mac possa installarlo.",
        "Sign in to %@ from Terminal with nido ssh and your key, no password.": "Accedi a %@ da terminale con nido ssh e la tua chiave, senza password.",
        "Nido is installing macOS %@ on %@. You can close the wizard: the progress stays in the library.": "Nido installa macOS %@ in %@. Puoi chiudere la procedura: l'avanzamento resta nella libreria.",
        "Check your choices: Nido installs macOS on %@ and starts it for Setup Assistant.": "Controlla le scelte: Nido installa macOS in %@ e la avvia per l'assistente iniziale.",
        "Download": "Scarica",
        "Continue in Library": "Continua nella libreria",
        "Create and Install": "Crea e installa",
        "Create and Start": "Crea e avvia",
        "Next": "Avanti",
        "Wait for the build check to finish.": "Attendi il controllo della build.",
        "The image is still being checked.": "Controllo dell'immagine in corso.",
        "Choose a macOS IPSW file.": "Scegli un file IPSW di macOS.",
        "No templates: first save a VM as a template from the library.": "Nessun modello: salva prima una VM come modello dalla libreria.",
        "Choose a template.": "Scegli un modello.",
        "Choose an SSH public key.": "Scegli una chiave SSH pubblica.",
        "arm64 · cached": "arm64 · nella cache",
        "arm64 · cloud image": "arm64 · immagine cloud",
        "arm64 · local image": "arm64 · immagine locale",
        "%@, verified": "%@, verificata",
        "up to %@ to download · new build": "fino a %@ da scaricare · nuova build",
        "%@ in the cache · up to %@ if it isn’t valid": "%@ nella cache · se non valida fino a %@",
        "up to %@ to download": "fino a %@ da scaricare",
        "Source": "Origine",
        "File": "File",
        "Size": "Dimensione",
        "Verification": "Verifica",
        "%@ checksum": "checksum %@",
        "%@ checksum · Ubuntu signature": "checksum %@ · firma di Ubuntu",
        "unknown": "sconosciuta",
        "local file (debug only)": "file locale (solo debug)",
        "none (local file)": "nessuna (file locale)",
        "Verifying the image": "Verifica dell'immagine",
        "Downloading %@": "Download di %@",
        "Verifying the %@ checksum": "Verifica del checksum %@",
        "%@ of %@": "%@ di %@",
        "less than a minute": "meno di un minuto",
        "local file": "file locale",
        "Image already in the cache.": "Immagine già nella cache.",
        "%@ publishes new builds with security fixes. The check downloads only the checksum list.": "%@ pubblica nuove build con le correzioni di sicurezza. Il controllo scarica solo la lista dei checksum.",
        "Check for a New Build": "Cerca una nuova build",
        "Checking for a new build…": "Controllo della build in corso…",
        "The cached copy is the current build.": "La copia nella cache è la build attuale.",
        "A new build is available.": "È disponibile una nuova build.",
        "Download gets it and replaces the cached copy once it’s verified. Existing VMs don’t change.": "Il pulsante Scarica la scarica e sostituisce quella nella cache dopo la verifica. Le VM già create non cambiano.",
        "The check failed.": "Controllo non riuscito.",
        "at most %lld (this Mac’s cores)": "al massimo %lld (core di questo Mac)",
        "At least %lld for macOS %@ · %@": "Almeno %lld per macOS %@ · %@",
        "Recommended: %lld · %@": "Consigliate %lld · %@",
        "Over the limit: at most %lld (this Mac’s cores).": "Oltre il limite: al massimo %lld (core di questo Mac).",
        "At least %lld GiB for macOS %@ · at most %lld GiB": "Almeno %lld GiB per macOS %@ · al massimo %lld GiB",
        "Recommended: %lld GiB · at most %lld GiB": "Consigliati %lld GiB · al massimo %lld GiB",
        "Over the limit: at most %lld GiB on this Mac.": "Oltre il limite: su questo Mac al massimo %lld GiB.",
        "macOS %@ needs at least %lld GiB of memory.": "macOS %@ richiede almeno %lld GiB di memoria.",
        "At least %lld GiB is needed.": "Servono almeno %lld GiB.",
        "Recommended: at least %lld GiB": "Consigliati almeno %lld GiB",
        "Recommended: at least %lld GiB · free space on the Mac: %@": "Consigliati almeno %lld GiB · spazio libero sul Mac: %@",
        "Free space on the Mac: %@": "Spazio libero sul Mac: %@",
        "The disk takes space on the Mac only when the VM writes data.": "Il disco occupa spazio sul Mac solo quando la VM scrive dati.",
        "The disk must be at least 1 GiB.": "Il disco deve essere di almeno 1 GiB.",
        "Disk size too large: at most %lld GiB.": "Dimensione del disco troppo grande: al massimo %lld GiB.",
        "The disk must hold the image: at least %lld GiB.": "Il disco deve contenere l'immagine: almeno %lld GiB.",
        "Can’t limit the choice to .pub files on this Mac.": "Impossibile limitare la scelta ai file .pub su questo Mac.",
        "No key chosen": "Nessuna chiave scelta",
        "A VM named %@ already exists.": "Esiste già una VM chiamata %@.",
        "macOS %@ · from %@": "macOS %@ · da %@",
        "no file": "nessun file",
        "nido ssh as %@ · %@": "nido ssh come %@ · %@",
        "no key": "nessuna chiave",
        "Network and folders": "Rete e cartelle",
        "Controlled, macOS base list · no shared folders": "Controllata, lista di base per macOS · nessuna cartella condivisa",
        "The VM can reach only Apple’s servers for activation, macOS updates and the clock. The App Store, iCloud and other sites stay blocked until you add their domains in the VM’s settings, Network section.": "La VM raggiunge solo l'attivazione, gli aggiornamenti di macOS e l'orologio. App Store, iCloud e gli altri siti restano bloccati finché non aggiungi i loro domini nelle impostazioni della VM, sezione Rete.",
        "Then you complete macOS Setup Assistant in the VM’s window.": "Poi completi l'assistente iniziale di macOS nella finestra della VM.",
        "Template": "Modello",
        "none": "nessuno",
        "%@, like the template": "%@, come il modello",
        "Space on the Mac": "Spazio sul Mac",
        "No extra space until the disks change": "Nessuno in più finché i dischi non cambiano",
        "Instant copy of the disk (clonefile).": "Copia istantanea del disco (clonefile).",
        "Identity": "Identità",
        "New: MAC address, host name, SSH host keys": "Nuova: indirizzo MAC, nome host, chiavi host SSH",
        "Shared folders and AI bridge": "Cartelle condivise e ponte AI",
        "None · off": "Nessuna · spento",
        "They don’t carry over from the template to the new VM: you choose them later.": "Non passano dal modello alla nuova VM: li scegli tu, dopo.",
        "User and network only": "Solo utente e rete",
        "First boot": "Primo avvio",
        "After first boot": "Dopo il primo avvio",
        "Ollama and the %@ model": "Ollama e il modello %@",
        "The VM is usable before then: the progress stays visible in its window.": "La VM è usabile prima: l'avanzamento resta visibile nella sua finestra.",
        "Network": "Rete",
        "Controlled · base list": "Controllata · lista di base",
        "The VM reaches only %@. You can add other domains in the VM’s settings, Network section.": "La VM raggiunge solo %@. Altri domini si aggiungono nelle impostazioni della VM, sezione Rete.",
        "The template’s key": "Quella del modello",
        "Creating %@": "Creazione di %@",
        "Instant copy of the template and a new identity": "Copia istantanea del modello e nuova identità",
        "Copying the disk (%lld GiB) and preparing cloud-init": "Copia del disco (%lld GiB) e preparazione di cloud-init",
        "disk too large": "disco troppo grande",
        "The %@ checksum doesn’t match: the downloaded file was deleted. Try again: Nido downloads the image again.": "Il checksum %@ non corrisponde: il file scaricato è stato eliminato. Riprova: Nido scarica di nuovo l'immagine.",
        "Not enough disk space: 64 GiB needed, 41 GiB left on the Mac. Free up space or make the disk smaller in the Resources step.": "Spazio su disco insufficiente: servono 64 GiB, sul Mac ne restano 41 GiB. Libera spazio o riduci il disco al passo Risorse.",
        "The disk ran out of space during the installation: 66 GiB needed, 41 GiB left on the Mac. Nido deleted the files it created; the IPSW stays where it is.": "Spazio su disco esaurito durante l'installazione: servono 66 GiB, sul Mac ne restano 41 GiB. Nido ha cancellato i file creati; l'IPSW resta dov'è.",
        "Canceling…": "Annullamento in corso…",
        "%@ left": "%@ rimanenti",
        "Canceling the macOS %@ installation…": "Annullamento dell'installazione di macOS %@…",
        "%@ Nido deleted the files it created; the IPSW stays where it is.": "%@ Nido ha cancellato i file creati; l'IPSW resta dov'è.",
        "Couldn’t install %@. %@": "Installazione di %@ non riuscita. %@",
        "Cancel the installation and quit?": "Annulla l'installazione ed esci?",
        "Nido stops installing %@ and deletes the files created so far. The IPSW stays where it is.": "Nido ferma l'installazione di %@ e cancella i file creati finora. L'IPSW resta dov'è.",
        "Continue Installation": "Continua l'installazione",
        "Cancel Installation and Quit": "Annulla l'installazione ed esci",
        "No virtual machines": "Nessuna macchina virtuale",
        "%@ on the Mac": "%@ sul Mac",
        "they don’t start: they’re for creating new VMs": "non si avviano: servono a creare nuove VM",
        "Space used not available": "Spazio occupato non disponibile",
        "Uses %@ on the Mac": "Occupa %@ sul Mac",
        "CPU, memory and disk unknown": "CPU, memoria e disco sconosciuti",
        "Unknown system": "Sistema sconosciuto",
        "Can’t read the VMs: %@": "Impossibile leggere le VM: %@",
        "Cloning in progress": "Clonazione in corso",
        "Snapshot in progress": "Snapshot in corso",
        "config.json is damaged: the VM can’t be opened.": "config.json danneggiato: la VM non si può aprire.",
        "config.json is damaged, but the VM is running: stop it before deleting it.": "config.json danneggiato, ma la VM è in esecuzione: arrestala prima di eliminarla.",
        "Start": "Avvia",
        "Open": "Apri",
        "Stop": "Arresta",
        "Settings": "Impostazioni",
        "Show in Finder": "Mostra nel Finder",
        "Resume": "Riprendi",
        "Details": "Dettagli",
        "Clone": "Clona",
        "Save as Template": "Salva come modello",
        "New VM…": "Nuova VM…",
        "Edit Template": "Modifica modello",
        "Clone…": "Clona…",
        "Save as Template…": "Salva come modello…",
        "Delete…": "Elimina…",
        "Can’t open %@: %@": "Impossibile aprire %@: %@",
        "Can’t resume %@: %@": "Impossibile riprendere %@: %@",
        "Can’t stop %@: %@": "Impossibile arrestare %@: %@",
        "Can’t delete %@: %@": "Impossibile eliminare %@: %@",
        "Can’t save %@: %@": "Impossibile salvare %@: %@",
        "Can’t edit %@: %@": "Impossibile modificare %@: %@",
        "Can’t resume %@: it’s open in another instance of Nido; resume it there.": "Impossibile riprendere %@: è aperta in un'altra istanza di Nido, riprendila da lì.",
        "Can’t stop %@: it’s open in another instance of Nido; stop it there.": "Impossibile arrestare %@: è aperta in un'altra istanza di Nido, arrestala da lì.",
        "New VM from %@": "Nuova VM da %@",
        "Clone %@?": "Clonare %@?",
        "The copy gets a new network address and a new machine identifier. Shared folders, snapshots and the suspended state aren’t copied.": "La copia avrà un nuovo indirizzo di rete e un nuovo identificatore della macchina. Cartelle condivise, snapshot e stato sospeso non vengono copiati.",
        "The copy gets a new network address and a new identity; at first boot it takes the new name as its host name. Rosetta is copied; shared folders, snapshots and the suspended state aren’t: the copy starts without shared folders. The AI bridge stays off.": "La copia avrà un nuovo indirizzo di rete e una nuova identità; al primo avvio prende il nuovo nome come nome host. Rosetta viene copiata; cartelle condivise, snapshot e stato sospeso no: la copia parte senza cartelle condivise. Il ponte AI resta spento.",
        "Inside macOS the copy stays identical to %@": "Dentro macOS la copia resta uguale a %@",
        "Same computer name, same account with its authorized keys, same SSH host keys. After cloning, Nido shows you the commands to change them in the copy.": "Stesso nome del computer, stesso account con le sue chiavi autorizzate, stesse chiavi host SSH. Dopo la clonazione Nido ti mostra i comandi per cambiarli nella copia.",
        "%@ is ready": "%@ è pronta",
        "Start it and change its identity inside macOS, with nido ssh %@ or in the VM’s Terminal.": "Avviala e cambia la sua identità dentro macOS, con nido ssh %@ o nel Terminale della VM.",
        "New SSH host keys": "Nuove chiavi host SSH",
        "New computer name": "Nuovo nome del computer",
        "Other steps": "Altri passi",
        "Can’t create %@ from %@: %@.": "Impossibile creare %@ da %@: %@.",
        "Can’t clone %@: %@.": "Impossibile clonare %@: %@.",
        "You can quit when the copy is done, or stop it: the partial copy is removed.": "Puoi uscire al termine della copia, oppure interromperla: la copia parziale viene rimossa.",
        "Cancel and Quit": "Annulla ed esci",
        "Can’t save %@ as a template: %@.": "Impossibile salvare %@ come modello: %@.",
        "Can’t edit the template %@: %@.": "Impossibile modificare il modello %@: %@.",
        "copy": "copia",
        "Edit %@?": "Modificare %@?",
        "The template becomes a VM again that you can start and update. When you’re done, save it as a template again. VMs already created from the template don’t change.": "Il modello torna una VM che puoi avviare e aggiornare. Quando hai finito, salvala di nuovo come modello. Le VM già create dal modello non cambiano.",
        "Library": "Libreria",
        "Search VMs": "Cerca tra le VM",
        "New VM": "Nuova VM",
        "Virtual Machines": "Macchine virtuali",
        "Show": "Mostra",
        "Cancel…": "Annulla…",
        "Copying…": "Copia in corso…",
        "Create": "Crea",
        "Copy Commands": "Copia i comandi",
        "Done": "Fine",
        "Templates": "Modelli",
        "Save %@ as a template?": "Salvare %@ come modello?",
        "%@ becomes a template: it no longer starts and is used to create new VMs with an instant copy of its disk. To update it, choose Edit Template, then save it again.": "%@ diventa un modello: non si avvia più e serve a creare nuove VM con una copia istantanea del disco. Per aggiornarlo scegli Modifica modello, poi salvalo di nuovo.",
        "VMs created from the template start without shared folders and with the AI bridge off.": "Le VM create dal modello partono senza cartelle condivise e con il ponte AI spento.",
        "Each one has a new identity: MAC address, host name and SSH host keys.": "Ognuna ha un'identità nuova: indirizzo MAC, nome host e chiavi host SSH.",
        "No snapshots": "Nessuno snapshot",
        "%@ is running in Terminal": "%@ in esecuzione nel Terminale",
        "%@ is busy with a nido command in Terminal": "%@ occupata da un comando nido nel Terminale",
        "%@ is open in another instance of Nido": "%@ aperta in un'altra copia di Nido",
        "%@ is running": "%@ in esecuzione",
        "%@ is paused": "%@ in pausa",
        "%@ is suspended": "%@ sospesa",
        "%@ has an error": "%@ in errore",
        "%@ is changing state": "%@ in transizione",
        "%@ is stopped": "%@ arrestata",
        "To restore a snapshot, stop %@ first.": "Per ripristinare uno snapshot arresta prima %@.",
        "To delete a snapshot, stop %@ first.": "Per eliminare uno snapshot arresta prima %@.",
        "%@ is running: Nido pauses it for a few seconds and saves its memory too.": "%@ è in esecuzione: Nido la mette in pausa per qualche secondo e salva anche la memoria.",
        "%@ is suspended: Nido saves its disk, settings and suspended state, which resumes where you left off after a restore.": "%@ è sospesa: Nido salva disco, impostazioni e lo stato sospeso, che dopo un ripristino riprende da dove l'hai lasciata.",
        "Nido saves the disk and settings of %@ as they are now.": "Nido salva disco e impostazioni di %@ così come sono adesso.",
        "%@ stays paused for a few seconds while Nido saves its memory and disk.": "%@ resta in pausa qualche secondo mentre Nido salva memoria e disco.",
        "Nido is copying the disk, settings and suspended state of %@.": "Nido copia disco, impostazioni e stato sospeso di %@.",
        "Nido is copying the disk and settings of %@.": "Nido copia disco e impostazioni di %@.",
        "Restore %@?": "Ripristinare %@?",
        "The VM will go back to its state as of %@; later changes will be lost.": "La VM tornerà allo stato del %@; le modifiche successive andranno perse.",
        "The VM will go back to its state as of %@; later changes and the saved state of %@ will be lost.": "La VM tornerà allo stato del %@; le modifiche successive e la sessione sospesa di %@ andranno perse.",
        "The snapshot and the memory saved with it will be deleted from this Mac; %@ stays as it is. This can’t be undone.": "Lo snapshot e la memoria salvata con esso saranno eliminati da questo Mac; %@ resta com'è. L'operazione non si può annullare.",
        "The snapshot will be deleted from this Mac; %@ stays as it is. This can’t be undone.": "Lo snapshot sarà eliminato da questo Mac; %@ resta com'è. L'operazione non si può annullare.",
        "Restore failed": "Ripristino non riuscito",
        "Delete failed": "Eliminazione non riuscita",
        "Snapshot failed": "Snapshot non riuscito",
        "The operation failed: %@": "Operazione non riuscita: %@",
        "%@ Free up space on the Mac and try again.": "%@ Libera spazio sul Mac e riprova.",
        "Snapshots of a running VM aren’t supported: %@. Stop %@ and try again.": "Snapshot a VM accesa non supportato: %@. Arresta %@ e riprova.",
        "Wait for %@ to finish starting or stopping, then try again.": "Attendi che %@ finisca di avviarsi o di arrestarsi, poi riprova.",
        "%@ is running in Terminal (nido start): stop it first.": "%@ è in esecuzione nel Terminale (nido start): arrestala prima.",
        "The restore failed and was only partly undone: the original file is kept at %@. Try again: Nido puts the files back in place before every operation.": "Ripristino non riuscito e annullato solo in parte: il file originale è conservato in %@. Riprova: Nido rimette a posto i file prima di ogni operazione.",
        "Snapshots of %@": "Snapshot di %@",
        "Invalid virtual machine name.": "Nome della macchina virtuale non valido.",
        "Can’t open the snapshots of %@: %@": "Impossibile aprire gli snapshot di %@: %@",
        "A snapshot keeps the disk of %@ as it is now, and its memory too if the VM is running. You can go back to it anytime.": "Uno snapshot conserva il disco di %@ così com'è adesso, e a VM accesa anche la memoria. Potrai tornarci quando vuoi.",
        "A snapshot keeps the VM’s disk and settings; taken while the VM is running, its memory too (with saved state). Restoring it takes %@ back to that moment.": "Uno snapshot conserva disco e impostazioni della VM; preso a VM accesa, anche la memoria (con stato salvato). Ripristinarlo riporta %@ a quel momento.",
        "Snapshots (%lld), newest first": "Snapshot (%lld), dal più recente",
        "Snapshots (%lld)": "Snapshot (%lld)",
        "Current state": "Stato attuale",
        "Changes since the last snapshot exist only here.": "Le modifiche dopo l'ultimo snapshot sono solo qui.",
        "Create a Snapshot of %@": "Crea uno snapshot di %@",
        "Letters, numbers, periods, hyphens and underscores; different from the other snapshots of %@.": "Lettere, numeri, punto, trattino e trattino basso; diverso dagli altri snapshot di %@.",
    ]

    @Test func wizardLibrarySnapshotsCopyExistsInAllLanguages() {
        // The same word as the English is right here (System, Version, Details, Name…).
        Self.expectTranslated(Self.wizardLibrarySnapshotsCopy, sameAsEnglishAllowed: [
            "de:Version", "fr:Version", "de:Name", "es:Compatible", "fr:Compatible", "de:Installation",
            "fr:Installation", "de:System", "fr:Source", "de:Details",
        ])
    }

    /// The wizard's step "Download" (a noun) and its button "Download" (a verb) are two keys.
    @Test func downloadStepAndButtonAreTwoKeys() {
        #expect(Self.localized("Download (step)", "en") == "Download")
        #expect(Self.localized("Download (step)", "de") == "Download")
        #expect(Self.localized("Download", "de") == "Laden")
        #expect(Self.localized("Download (step)", "fr") == "Téléchargement")
        #expect(Self.localized("Download", "fr") == "Télécharger")
    }

    /// The counts of the library, the wizard and the snapshots window: catalog plurals.
    @Test func libraryAndSnapshotCountsFollowTheCount() throws {
        func text(_ language: String, _ make: (Bundle, Locale) -> String) throws -> String {
            make(try Self.bundle(language), Locale(identifier: language))
        }
        func vms(_ count: Int, _ language: String) throws -> String {
            try text(language) { String(localized: "\(count) virtual machines", bundle: $0, locale: $1) }
        }
        func snapshots(_ count: Int, _ language: String) throws -> String {
            try text(language) { String(localized: "\(count) snapshots", bundle: $0, locale: $1) }
        }
        func resources(_ count: Int, _ language: String) throws -> String {
            try text(language) {
                String(localized: "\(count) CPUs · \("8 GiB") of memory · \("64 GiB") disk", bundle: $0, locale: $1)
            }
        }
        #expect(try vms(1, "it") == "1 macchina virtuale")
        #expect(try vms(4, "it") == "4 macchine virtuali")
        #expect(try vms(1, "en") == "1 virtual machine")
        #expect(try vms(4, "en") == "4 virtual machines")
        #expect(try snapshots(3, "it") == "3 snapshot")
        #expect(try snapshots(1, "en") == "1 snapshot")
        #expect(try snapshots(3, "en") == "3 snapshots")
        #expect(try snapshots(3, "de") == "3 Schnappschüsse")
        #expect(try resources(4, "it") == "4 CPU · 8 GiB di memoria · disco 64 GiB")
        #expect(try resources(1, "en") == "1 CPU · 8 GiB of memory · 64 GiB disk")
        #expect(try resources(4, "en") == "4 CPUs · 8 GiB of memory · 64 GiB disk")
        #expect(try resources(4, "de") == "4 CPUs · 8 GiB Arbeitsspeicher · 64 GiB Festplatte")
        for language in ["de", "es", "fr"] {
            #expect(try vms(2, language).replacingOccurrences(of: "2", with: "1") != vms(1, language),
                    "\(language): no plural")
            #expect(try snapshots(2, language).contains("2"), "\(language)")
        }
        let italian = try Self.bundle("it")
        let locale = Locale(identifier: "it")
        #expect(String(localized: "\(2) templates", bundle: italian, locale: locale) == "2 modelli")
        #expect(String(localized: "\(1) templates", bundle: italian, locale: locale) == "1 modello")
        #expect(String(localized: "\(2) running", bundle: italian, locale: locale) == "2 in esecuzione")
        #expect(String(localized: "\(1) installing", bundle: italian, locale: locale) == "1 in installazione")
        #expect(String(localized: "about \(2) min", bundle: italian, locale: locale) == "circa 2 min")
    }

    // MARK: - VM window, settings, monitor, provisioning, release notes view

    static let vmWindowSettingsMonitorCopy: KeyValuePairs<String, String> = [
        "Start failed": "Avvio non riuscito",
        "Suspend failed: %@": "Sospensione non riuscita: %@",
        "this session can’t save the VM’s state": "questa sessione non può salvare lo stato",
        "%@ is a template: choose Edit Template in the library before restoring a snapshot":
            "%@ è un modello: scegli Modifica modello nella libreria prima di ripristinare uno snapshot",
        "Nido is quitting: no new snapshot operations":
            "Nido si sta chiudendo: nessuna nuova operazione sugli snapshot",
        "suspend failed": "sospensione non riuscita",
        "%@ wasn’t suspended (%@): it was stopped.": "%@ non è stata sospesa (%@): è stata arrestata.",
        "Stop %@?": "Arrestare %@?",
        "Pause": "Pausa",
        "Suspend": "Sospendi",
        "Exit Full Screen": "Esci da schermo intero",
        "Enter Full Screen": "Schermo intero",
        "Terminal Access": "Accesso da terminale",
        "The settings changed after the suspend: the next start discards the saved state and the VM starts from scratch.":
            "Le impostazioni sono cambiate dopo la sospensione: al prossimo avvio lo stato salvato verrà scartato e la VM partirà da capo.",
        "The VM’s state is saved on the Mac: Resume to continue where you left off.":
            "Lo stato della VM è salvato sul Mac: Riprendi per continuare da dove l'hai lasciata.",
        "Start the VM from the toolbar: the disk and the settings stay as you left them.":
            "Avvia la VM dalla barra: il disco e le impostazioni restano come li hai lasciati.",
        "Last stopped today at %@. %@": "Ultimo arresto oggi alle %@. %@",
        "Last stopped on %@ at %@. %@": "Ultimo arresto il %@ alle %@. %@",
        "Nido is working on %@ (a clone or a snapshot): try again when it’s done.":
            "È in corso un'operazione su %@ in Nido (clonazione o snapshot): riprova al termine.",
        "%@ is already running in another process (pid %lld): stop it there before you open it in this window.":
            "%@ è già in esecuzione da un altro processo (pid %lld): arrestala lì prima di aprirla in questa finestra.",
        "%@ is already running in another process: stop it there before you open it in this window.":
            "%@ è già in esecuzione da un altro processo: arrestala lì prima di aprirla in questa finestra.",
        "The VM doesn’t respond to commands": "La VM non risponde ai comandi",
        "The VM stopped because of an error": "La VM si è fermata per un errore",
        "The VM may still be running: Nido keeps its lock until it stops. Stop it from the toolbar.":
            "La VM potrebbe essere ancora accesa: Nido tiene il suo lock finché non si ferma. Arrestala dalla barra.",
        "shared folder device": "dispositivo delle cartelle condivise",
        "Screen": "Schermo",
        "Monitor": "Monitor",
        "AI": "AI",
        "Nido asks %@ to shut down cleanly, then closes the window. If it’s still running after 30 seconds, Nido forces it to stop.":
            "Nido chiede a %@ di spegnersi in modo ordinato, poi chiude la finestra. Se dopo 30 secondi è ancora accesa, la arresta forzatamente.",
        "Stop and Close": "Arresta e chiudi",
        "OK": "OK",
        "Start Anyway": "Avvia comunque",
        "More": "Altro",
        "Suspending": "Sospensione in corso",
        "Pausing": "Pausa in corso",
        "Resuming": "Ripresa in corso",
        "Stopping": "Arresto in corso",
        "%@ stays in memory where you left it. Resume to continue.":
            "%@ resta in memoria dove l'hai lasciata. Riprendi per continuare.",
        "VM console: %@": "Console della VM: %@",
        "VM console": "Console della VM",
        "%@ is finishing its first boot: quitting now may leave it without SSH access":
            "%@ sta completando il primo avvio: uscire ora può lasciarla senza accesso SSH",
        "%@ are finishing their first boot: quitting now may leave them without SSH access":
            "%@ stanno completando il primo avvio: uscire ora può lasciarle senza accesso SSH",
        "The first boot takes about a minute: wait for it to finish, then quit.":
            "Il primo avvio dura circa un minuto: aspetta che finisca, poi esci.",
        "Quit Anyway": "Esci comunque",
        "Quit with %@ running?": "Uscire con %@ accesa?",
        "Suspend and Quit saves the state of %@ on the Mac: the next start continues where you left off. Stop and Quit asks it to shut down cleanly and, if it’s still running after 30 seconds, forces it to stop.":
            "Sospendi ed esci salva lo stato di %@ sul Mac: al prossimo avvio riparte da dove l'hai lasciata. Arresta ed esci le chiede di spegnersi in modo ordinato e, se dopo 30 secondi è ancora accesa, la arresta forzatamente.",
        "Suspend and Quit saves the state of each virtual machine on the Mac: the next start continues each one where you left off. Stop and Quit asks each one to shut down cleanly and forces those still running after 30 seconds to stop.":
            "Sospendi ed esci salva lo stato di ogni macchina virtuale sul Mac: al prossimo avvio ognuna riparte da dove l'hai lasciata. Arresta ed esci chiede a ognuna di spegnersi in modo ordinato e arresta forzatamente quelle ancora accese dopo 30 secondi.",
        "%@ can’t be suspended in its current configuration: it will be stopped.":
            "%@ non si può sospendere con la sua configurazione: verrà arrestata.",
        "%@ can’t be suspended in their current configuration: they will be stopped.":
            "%@ non si possono sospendere con la loro configurazione: verranno arrestate.",
        "Suspend and Quit": "Sospendi ed esci",
        "Stop and Quit": "Arresta ed esci",
        "The VM’s public key isn’t a one-line OpenSSH key: Nido doesn’t type it.":
            "La chiave pubblica della VM non è una chiave OpenSSH su una riga: Nido non la digita.",
        "The character %@ can’t be typed with this Mac’s keyboard: type the command yourself in the VM.":
            "Il carattere %@ non si può digitare con la tastiera di questo Mac: scrivi il comando a mano nella VM.",
        "The VM’s screen isn’t shown: start the VM and try again. If typing had begun, the command may be only partly typed: clear the line in the VM’s Terminal before you try again.":
            "Lo schermo della VM non è visibile: avvia la VM e riprova. Se avevi cominciato a digitare, il comando potrebbe essere scritto solo in parte: cancella la riga nel Terminale della VM prima di riprovare.",
        "The VM is no longer running: the command may be only partly typed. Clear the line in the VM’s Terminal before you try again.":
            "La VM non è più in esecuzione: il comando potrebbe essere scritto solo in parte. Cancella la riga nel Terminale della VM prima di riprovare.",
        "To use %@ with nido ssh, once, after Setup Assistant. Nido never asks for or saves passwords.":
            "Per usare %@ con nido ssh, una volta sola dopo l'assistente iniziale. Nido non chiede né salva password.",
        "Complete Setup Assistant": "Completa l'assistente iniziale",
        "Create the account %@: it’s the name nido ssh uses. You can change it in the VM’s settings.":
            "Crea l'account %@: è il nome che usa nido ssh. Puoi cambiarlo nelle impostazioni della VM.",
        "Turn on Remote Login": "Attiva Login remoto",
        "In the VM: System Settings › General › Sharing › Remote Login.":
            "Nella VM: Impostazioni di Sistema › Generali › Condivisione › Login remoto.",
        "Authorize your key": "Autorizza la tua chiave",
        "Open Terminal in the VM, then click Type in VM: Nido types the command with your public key. You can also type it yourself.":
            "Apri il Terminale nella VM, poi Digita nella VM: Nido scrive il comando con la tua chiave pubblica. Puoi anche digitarlo a mano.",
        "Connect from the Mac": "Collegati dal Mac",
        "In Terminal on the Mac:": "Nel Terminale del Mac:",
        "<key>": "<chiave>",
        "The panel opens automatically until nido ssh has worked once; after that, open it with Terminal Access in the toolbar.":
            "Il pannello si apre da solo finché nido ssh non è riuscito almeno una volta; poi dalla barra, Accesso da terminale.",
        "Nido uses this Mac’s keyboard layout: if the VM’s is different, type the command yourself. Keep Caps Lock off in the VM.":
            "Nido usa la disposizione della tastiera di questo Mac: se nella VM è diversa, digita il comando a mano. Tieni spento Blocco maiuscole nella VM.",
        "The VM’s public key (authorized_key.pub) can’t be read safely: type the command yourself with your key.":
            "La chiave pubblica della VM (authorized_key.pub) non si può leggere in sicurezza: scrivi il comando a mano con la tua chiave.",
        "The VM’s public key (authorized_key.pub) isn’t in its folder: type the command yourself with your key.":
            "La chiave pubblica della VM (authorized_key.pub) non si trova nella sua cartella: scrivi il comando a mano con la tua chiave.",
        "This Mac’s keyboard layout can’t be read: type the command yourself in the VM.":
            "La disposizione della tastiera di questo Mac non si può leggere: scrivi il comando a mano nella VM.",
        "Command typed in the VM: press Return in the VM’s Terminal.":
            "Comando scritto nella VM: premi Invio nel Terminale della VM.",
        "Copy": "Copia",
        "Typing…": "Digitazione…",
        "Type in VM": "Digita nella VM",
        "The nido command isn’t in your PATH: install it, or connect with ssh and the VM’s key.":
            "Il comando nido non è nel PATH: installalo, oppure collegati con ssh e la chiave della VM.",
        "The VM’s disk (disk.img) can’t be read. Check the free space on the Mac and start it again.":
            "Il disco della VM (disk.img) non è leggibile. Controlla lo spazio libero sul Mac e avviala di nuovo.",
        "General": "Generale",
        "Hardware": "Hardware",
        "Sharing": "Condivisione",
        "User name for nido ssh": "Nome utente per nido ssh",
        "The macOS account nido ssh logs in to the VM with: the one created in Setup Assistant.":
            "L'account di macOS con cui nido ssh entra nella VM: quello creato nell'assistente iniziale.",
        "Can’t save the user name: %@": "Impossibile salvare il nome utente: %@",
        "%@ is a template: choose Edit Template in the library to change it.":
            "%@ è un modello: scegli Modifica modello nella libreria per cambiarlo.",
        "The settings of %@ changed after the suspend: the next start discards the saved state and the VM starts from scratch.":
            "Le impostazioni di %@ sono cambiate dopo la sospensione: al prossimo avvio lo stato salvato verrà scartato e la VM partirà da capo.",
        "%@ is suspended: if you change CPU, memory, shared folders or Rosetta, the next start discards the saved state and the VM starts from scratch.":
            "%@ è sospesa: se cambi CPU, memoria, cartelle condivise o Rosetta, al prossimo avvio lo stato salvato verrà scartato e la VM partirà da capo.",
        "%@ is suspended: if you change CPU, memory or shared folders, the next start discards the saved state and the VM starts from scratch.":
            "%@ è sospesa: se cambi CPU, memoria o cartelle condivise, al prossimo avvio lo stato salvato verrà scartato e la VM partirà da capo.",
        "CPU and memory apply from the next start of %@.": "CPU e memoria valgono dal prossimo avvio di %@.",
        "Can’t be changed while %@ is running": "Non modificabile mentre %@ è in esecuzione",
        "Stop %@ to change CPU and memory.": "Arresta %@ per cambiare CPU e memoria.",
        "%@ is running: changes to the allowed domains apply right away; the controlled network can be turned on or off only while the VM is stopped.":
            "%@ è in esecuzione: i domini permessi cambiano subito; la rete controllata si attiva o disattiva a VM arrestata.",
        "Out of range: %lld to %lld CPUs.": "Fuori limite: da %lld a %lld CPU.",
        "Out of range: %lld to %lld GiB.": "Fuori limite: da %lld a %lld GiB.",
        "Can’t save the settings: %@": "Impossibile salvare le impostazioni: %@",
        "Folders on the Mac that the VM sees in %@. Adding or removing a folder or changing its access takes effect right away, even while the VM is running in Nido.":
            "Cartelle del Mac visibili nella VM in %@. Aggiungere o togliere una cartella e cambiare la sola lettura hanno effetto subito, anche a VM accesa da Nido.",
        "Folders on the Mac that the VM sees in %@. Adding or removing a folder or changing its access takes effect right away, even while the VM is running in Nido. This VM, created with an earlier version of Nido, sees the folders only after it runs the command below once.":
            "Cartelle del Mac visibili nella VM in %@. Aggiungere o togliere una cartella e cambiare la sola lettura hanno effetto subito, anche a VM accesa da Nido. Questa VM, creata con una versione precedente di Nido, vede le cartelle solo dopo aver eseguito una volta il comando qui sotto.",
        "%@ is running: changes to shared folders apply right away.": "%@ è in esecuzione: le cartelle condivise cambiano subito.",
        "Stop %@ to change the shared folders.": "Arresta %@ per cambiare le cartelle condivise.",
        "Rosetta can be changed only while the VM is stopped: stop %@ to change it.":
            "Rosetta si cambia solo a VM arrestata: arresta %@ per cambiarla.",
        "Stop %@ to change the shared folders and Rosetta.": "Arresta %@ per cambiare le cartelle condivise e Rosetta.",
        "Applied at once: %@ is running and now sees the folders as you set them.":
            "Ha effetto subito: %@ in esecuzione vede ora le cartelle come le hai impostate.",
        "This VM sees them in %@ only after it runs the command below once.":
            "Questa VM le vede in %@ solo dopo aver eseguito una volta il comando qui sotto.",
        "Saved, but not applied to the running VM: %@ It applies from the next start.":
            "Salvato, ma non applicato alla VM in esecuzione: %@ Vale dal prossimo avvio.",
        "Can be changed only with the VM stopped.": "Si può cambiare solo a VM arrestata.",
        "%@ The VM starts without Rosetta until it’s available.":
            "%@ La VM parte senza Rosetta finché non è disponibile.",
        "%@ Install it to turn it on.": "%@ Installala per attivarla.",
        "The VM runs Linux programs for Intel (x86_64) with Rosetta.":
            "La VM esegue i programmi Linux per Intel (x86_64) con Rosetta.",
        "Runs Linux programs for Intel (x86_64) in the VM with Rosetta.":
            "Esegue nella VM i programmi Linux per Intel (x86_64) con Rosetta.",
        "macOS will download and install Rosetta for Linux, a system component. It may ask you to confirm again.":
            "macOS scaricherà e installerà Rosetta per Linux, un componente di sistema. Potrebbe chiederti di confermare di nuovo.",
        "Couldn’t install Rosetta: %@": "Installazione di Rosetta non riuscita: %@",
        "VM running: stop %@ to change Rosetta.": "VM in esecuzione: arresta %@ per cambiare Rosetta.",
        "Not found on the Mac: the VM starts without this folder.":
            "Non trovata sul Mac: la VM parte senza questa cartella.",
        "Left out at start: %@": "Esclusa all'avvio: %@",
        "VM running outside this window (for example with nido start): stop %@ to change the shared folders.":
            "VM in esecuzione fuori da questa finestra (ad esempio con nido start): arresta %@ per cambiare le cartelle condivise.",
        "VM running: stop %@ to change CPU and memory.": "VM in esecuzione: arresta %@ per cambiare CPU e memoria.",
        "%@ Settings": "Impostazioni di %@",
        "Can’t open the settings of %@: %@": "Impossibile aprire le impostazioni di %@: %@",
        "Install Rosetta?": "Installare Rosetta?",
        "Install": "Installa",
        "Nido’s software inside the VM: the monitor, the Ollama setup and the AI bridge. Nido installs it over SSH with the VM’s key; packages, files and models stay as they are.":
            "Il software di Nido dentro la VM: monitor, preparazione di Ollama e ponte AI. Nido lo installa via SSH con la chiave della VM; pacchetti, file e modelli restano come sono.",
        "With the controlled network, every connection of the VM goes through Nido: only connections to the allowed domains get through; everything else is blocked, logged without its content and reported.":
            "Con la rete controllata ogni collegamento della VM passa da Nido: escono solo i domini permessi, il resto viene bloccato, registrato senza contenuto e segnalato.",
        "The virtual machine’s details, its color, its snapshots and the account nido ssh logs in to macOS with.":
            "Dati della macchina virtuale, il suo colore, i suoi snapshot e l'account con cui nido ssh entra in macOS.",
        "The virtual machine’s details, its color and its snapshots.":
            "Dati della macchina virtuale, il suo colore e i suoi snapshot.",
        // Generale › Colore and S06: a VM's tint (VMTint).
        "Color": "Colore",
        "Tells this VM apart in the library.": "Distingue questa VM nella libreria.",
        "Tells this VM apart in the library. You can change it later in its settings.":
            "Distingue questa VM nella libreria. Puoi cambiarlo più tardi nelle sue impostazioni.",
        "Slate": "Ardesia",
        "Indigo": "Indaco",
        "Plum": "Prugna",
        "Rose": "Rosa",
        "Clay": "Argilla",
        "Olive": "Oliva",
        "Sea": "Mare",
        "Graphite": "Grafite",
        "The name is chosen when the VM is created.": "Il nome si sceglie alla creazione.",
        "MAC address": "Indirizzo MAC",
        "Assigned when the VM was created.": "Assegnato alla creazione della VM.",
        "Manage Snapshots…": "Gestisci snapshot…",
        "Saved. nido ssh now uses this account.": "Salvato. nido ssh usa ora questo account.",
        "Save": "Salva",
        "The disk size is chosen when the VM is created.": "La dimensione del disco si sceglie alla creazione.",
        "No shared folders": "Nessuna cartella condivisa",
        "The VM can’t see any files on the Mac. Add a folder to make it visible in %@.":
            "La VM non vede alcun file del Mac. Aggiungi una cartella per renderla visibile in %@.",
        "Rosetta (x86_64 binaries)": "Rosetta (binari x86_64)",
        "Rosetta isn’t installed on this Mac": "Rosetta non è installata su questo Mac",
        "It’s a macOS system component; installing it needs your confirmation.":
            "L'installazione è un componente di sistema di macOS e richiede la tua conferma.",
        "Installing…": "Installazione…",
        "Install Rosetta…": "Installa Rosetta…",
        "Rosetta: VM created with an earlier version of Nido": "Rosetta: VM creata con una versione precedente di Nido",
        "To use Rosetta, run this once in the VM:\n%@": "Per usare Rosetta, esegui una volta nella VM:\n%@",
        "Remove": "Rimuovi",
        "Read only": "Sola lettura",
        "The VM reads the files but can’t change or delete them.":
            "La VM legge i file ma non può modificarli né cancellarli.",
        "The VM can change and delete the files in this folder on the Mac: turn this on only if you need it.":
            "La VM può modificare e cancellare i file di questa cartella sul Mac: attiva solo se ti serve.",
        "Shared folders: VM created with an earlier version of Nido":
            "Cartelle condivise: VM creata con una versione precedente di Nido",
        "To see the folders in %@, run this once in the VM:\n%@":
            "Per vedere le cartelle in %@, esegui una volta nella VM:\n%@",
        "Add Folder…": "Aggiungi cartella…",
        "Share": "Condividi",
        "Choose a folder on the Mac to show in %@ (read only).":
            "Scegli una cartella del Mac da mostrare in %@ (in sola lettura).",
        "Manual installation": "Installazione manuale",
        "To install them yourself you need access to the VM: an SSH session that works (even from another Mac) or a password you set earlier for the user nido (VMs created by Nido have none). Paste the commands in that session: they fit in a single paste, even in Nido’s console. From Terminal, nido ssh %@ uses the same key as the VM.":
            "Per installarli a mano serve un accesso alla VM: una sessione SSH che funziona (anche da un altro Mac) oppure una password che hai impostato prima per l'utente nido (le VM create da Nido non ne hanno). Incolla i comandi in quella sessione: stanno in un solo incolla anche nella console di Nido. Dal Terminale, nido ssh %@ usa la stessa chiave della VM.",
        "Open Terminal": "Apri il Terminale",
        "SSH key of %@": "Chiave SSH di %@",
        "Choose the public key (.pub) the VM was created with.":
            "Scegli la chiave pubblica (.pub) con cui la VM è stata creata.",
        "Install Guest Tools": "Installa Guest Tools",
        "Reinstall Guest Tools": "Reinstalla Guest Tools",
        "Hang protection settings": "Impostazioni anti-blocco",
        "If the kernel panics, the message appears in the console log and the VM restarts after 10 seconds instead of hanging. They apply from the next restart.":
            "Se il kernel va in panic, il messaggio compare nel registro della console e la VM si riavvia dopo 10 secondi invece di restare bloccata. Valgono dal prossimo riavvio.",
        "Applying…": "Applicazione…",
        "Apply": "Applica",
        "Background requests": "Richieste di sfondo",
        "Turn Off": "Spegni",
        "This needs %@ running and its SSH key. Nido never changes a VM by itself.":
            "Servono %@ accesa e la sua chiave SSH. Nido non modifica mai una VM da solo.",
        "Guest Tools not installed": "Guest Tools non installati",
        "%@ was created without Guest Tools or with an earlier version of Nido. The monitor starts responding after the next restart.":
            "%@ è stata creata senza Guest Tools o con una versione di Nido precedente. Il monitor risponde dal prossimo riavvio.",
        "Installed and up to date: the monitor and the AI bridge use them.":
            "Installati e aggiornati: il monitor e il ponte AI li usano.",
        "This version of Nido comes with Guest Tools %@: reinstall them to update them.":
            "Questa versione di Nido porta i Guest Tools %@: reinstallali per aggiornarli.",
        "Saved. The changes apply from the next start.": "Salvato. Le novità valgono dal prossimo avvio.",
        "Nido Settings": "Impostazioni di Nido",
        "About": "Informazioni",
        "Nido keeps the VMs in a folder it shares with the nido command.":
            "Nido conserva le VM in una cartella condivisa con il comando nido.",
        "VM folder": "Cartella delle VM",
        "read only": "sola lettura",
        "Check for updates automatically": "Cerca aggiornamenti automaticamente",
        "Language": "Lingua",
        "Same as the system": "Come il sistema",
        "Nido closes and reopens in the chosen language. With a VM running, it asks first.":
            "Nido si chiude e si riapre nella lingua scelta. Con una VM accesa, prima chiede.",
        "License": "Licenza",
        "Nido is free software: its code is public.": "Nido è software libero: il codice è pubblico.",
        "Once a day Nido checks for a new version and asks before installing it. With a VM running, the installation waits.":
            "Nido controlla una volta al giorno se c'è una versione nuova e chiede prima di installarla. Con una VM accesa l'installazione aspetta.",
        "One token for all VMs, used only by the AI bridge to reach router.huggingface.co. Nido keeps it in the Mac’s Keychain: it never reaches the VMs, the logs or error messages.":
            "Un solo token per tutte le VM, usato solo dal ponte AI verso router.huggingface.co. Nido lo tiene nel Portachiavi del Mac: non arriva mai nelle VM, nei log o nei messaggi d'errore.",
        "The token isn’t valid: paste it without spaces or special characters inside.":
            "Il token non è valido: incollalo senza spazi interni né caratteri speciali.",
        "The Keychain isn’t available in this session of Nido: the token can’t be saved.":
            "Il Portachiavi non è disponibile in questa sessione di Nido: il token non si può salvare.",
        "The Keychain doesn’t respond: try again.": "Il Portachiavi non risponde: riprova.",
        "The Keychain didn’t save the token: try again.": "Il Portachiavi non ha salvato il token: riprova.",
        "The Keychain didn’t remove the token: try again.": "Il Portachiavi non ha rimosso il token: riprova.",
        "VMs with the AI bridge on": "VM con il ponte AI attivo",
        "If you remove the token, the bridge answers 401 in the VMs and nothing leaves the Mac.":
            "Se rimuovi il token, il ponte risponde 401 nelle VM e nulla esce dal Mac.",
        "Access token": "Token di accesso",
        "Saved in the Keychain. It can’t be shown again: to change it, paste a new one.":
            "Salvato nel Portachiavi. Non si può rivedere: per cambiarlo, incollane uno nuovo.",
        "Replace…": "Sostituisci…",
        "On huggingface.co, create a fine-grained token with only the “Make calls to Inference Providers” permission.":
            "Crea su huggingface.co un token fine-grained con il solo permesso \"Make calls to Inference Providers\".",
        "%@ was created before Nido 0.7.4 and still makes background requests that end up in the log as blocks. Turn Off stops them right away, with the VM running; it’s also in Settings › Guest Tools.":
            "%@ è stata creata prima di Nido 0.7.4 e fa ancora richieste di sfondo che finiscono nel registro come blocchi. Spegni le ferma da subito, con la VM accesa; resta anche in Impostazioni › Guest Tools.",
        "Turns off snap, the news in the login message, Ubuntu Pro, the check for new releases, apt’s SRV queries and the changelogs apt-listchanges downloads: on the controlled network they only end up in the log as blocks. New Ubuntu VMs already have them off.":
            "Spegne snap, le notizie del messaggio di accesso, Ubuntu Pro, il controllo delle nuove versioni, le query SRV di apt e i changelog scaricati da apt-listchanges: sulla rete controllata finiscono solo nel registro come blocchi. Le VM Ubuntu nuove le hanno già spente.",
        "Turns off the SRV queries apt makes before each archive and the changelogs apt-listchanges downloads every hour: on the controlled network they only end up in the log as blocks. New VMs already have them off.":
            "Spegne le query SRV che apt fa prima di ogni archivio e i changelog che apt-listchanges scarica ogni ora: sulla rete controllata finiscono solo nel registro come blocchi. Le VM nuove li hanno già spenti.",
        "Start %@ to install the Guest Tools.": "Avvia %@ per installare i Guest Tools.",
        "Start %@ to apply the hang protection settings.": "Avvia %@ per applicare le impostazioni anti-blocco.",
        "Start %@ to turn off the background requests.": "Avvia %@ per spegnere le richieste di sfondo.",
        "The Guest Tools of %@ are already up to date.": "I Guest Tools di %@ sono già aggiornati.",
        "Guest Tools installed in %@. The monitor starts responding after the next restart, if it isn’t already.":
            "Guest Tools installati in %@. Il monitor risponde dal prossimo riavvio, se non risponde già.",
        "Hang protection settings applied: they take effect from the next restart of %@.":
            "Impostazioni anti-blocco applicate: valgono dal prossimo riavvio di %@.",
        "Background requests turned off in %@: this takes effect right away.":
            "Richieste di sfondo spente in %@: valgono da subito.",
        "Choose the SSH key of %@": "Scegli la chiave SSH di %@",
        "This VM has no recorded SSH key: choose the public key (.pub) it was created with.":
            "Questa VM non ha una chiave SSH registrata: scegli la chiave pubblica (.pub) con cui è stata creata.",
        "This key isn’t authorized in %@: choose the one used to create it.":
            "Questa chiave non è autorizzata in %@: scegli quella usata alla creazione.",
        "Automatic installation failed": "Installazione automatica non riuscita",
        "Hang protection settings not applied": "Impostazioni anti-blocco non applicate",
        "Background requests not turned off": "Richieste di sfondo non spente",
        "You can install the Guest Tools yourself with the commands below, from a session in the VM.":
            "Puoi installare i Guest Tools a mano con i comandi qui sotto, da una sessione nella VM.",
        "Check that the VM is running and the ssh service is on, then click Try Again, or install the Guest Tools yourself with the commands below, from a session in the VM.":
            "Controlla che la VM sia accesa e che il servizio ssh sia attivo e premi Riprova, oppure installa i Guest Tools a mano con i comandi qui sotto, da una sessione nella VM.",
        "Automatic installation failed: %@ doesn’t respond over SSH":
            "Installazione automatica non riuscita: %@ non risponde via SSH",
        "The VM isn’t running": "La VM non è in esecuzione",
        "Waiting for the guest monitor": "In attesa del monitor del guest",
        "Guest Tools version not recognized": "Versione dei Guest Tools non riconosciuta",
        "Monitor can’t be reached": "Monitor non raggiungibile",
        "Last sample before the VM stopped": "Ultimo campione prima dell'arresto",
        "Stale data": "Dati vecchi",
        "High CPU": "CPU elevata",
        "Low available RAM": "RAM disponibile ridotta",
        "Disk almost full": "Disco quasi pieno",
        "No guest monitor: install the Guest Tools": "Monitor del guest assente: installa i Guest Tools",
        "Stale data: the guest hasn’t responded for more than 10 seconds":
            "Dati vecchi: il guest non risponde da più di 10 secondi",
        "Can’t connect to the monitor: %@": "Errore di connessione al monitor: %@",
        "Guest Tools version not recognized (unknown)": "Versione dei Guest Tools non riconosciuta (sconosciuta)",
        "Guest Tools version not recognized (%@)": "Versione dei Guest Tools non riconosciuta (%@)",
        "the guest monitor doesn’t respond": "il monitor del guest non risponde",
        "no response within 2 seconds": "nessuna risposta entro 2 secondi",
        "invalid response": "risposta non valida",
        "version %@ not recognized": "versione %@ non riconosciuta",
        "Monitor not available": "Monitor non disponibile",
        "The monitor is available for VMs started by Nido. This VM is running from Terminal (nido start).":
            "Il monitor è disponibile per le VM avviate da Nido. Questa VM è in esecuzione dal Terminale (nido start).",
        "Start %@ to see CPU, memory and disk. The monitor reads the data from the guest over vsock, without going through the network.":
            "Avvia %@ per vedere CPU, memoria e disco. Il monitor legge i dati dal guest via vsock, senza passare dalla rete.",
        "%@ is still starting. On the first boot cloud-init installs packages and Guest Tools: this can take a few minutes.":
            "%@ sta completando l'avvio. Al primo avvio cloud-init installa pacchetti e Guest Tools: possono servire alcuni minuti.",
        "%@ has no guest monitor: it was created without Guest Tools or with an earlier version of Nido. Nido installs them over SSH without touching packages, files and models; the monitor starts responding after the next restart.":
            "%@ non ha il monitor del guest: è stata creata senza Guest Tools o con una versione di Nido precedente. Nido li installa via SSH senza toccare pacchetti, file e modelli; il monitor risponde dal prossimo riavvio.",
        "The Guest Tools of %@ report an unknown version. Update Nido, or reinstall the Guest Tools that come with your version of Nido.":
            "I Guest Tools di %@ rispondono con la versione sconosciuta, che questa versione di Nido non conosce. Aggiorna Nido, oppure reinstalla i Guest Tools della versione di Nido che usi.",
        "The Guest Tools of %@ report version %@, which this version of Nido doesn’t recognize. Update Nido, or reinstall the Guest Tools that come with your version of Nido.":
            "I Guest Tools di %@ rispondono con la versione %@, che questa versione di Nido non conosce. Aggiorna Nido, oppure reinstalla i Guest Tools della versione di Nido che usi.",
        "%@ Nido retries automatically every 3 seconds: the VM keeps working normally.":
            "%@ Nido riprova da solo ogni 3 secondi: la VM continua a funzionare normalmente.",
        "Try Again Now": "Riprova ora",
        "Nido asks the guest every 3 seconds": "Nido chiede al guest ogni 3 secondi",
        "%@ stopped on its own at %@. These are the values from %@; the monitor resumes at the next start.":
            "%@ si è fermata alle %@ senza che lo chiedessi. Questi sono i valori delle %@; il monitor riparte al prossimo avvio.",
        "Refresh": "Aggiorna",
        "Updated at %@ · every 3 seconds, only while this view is open":
            "Aggiornato alle %@ · ogni 3 secondi, solo mentre questa vista è aperta",
        "Sample from %@ · the VM is stopped": "Campione delle %@ · la VM è arrestata",
        "vCPUs unknown": "vCPU sconosciute",
        "1-minute load average %@": "carico medio 1 min %@",
        "load not available": "carico non disponibile",
        "%@ used": "%@ usati",
        "%@ available": "%@ disponibili",
        "total unknown": "totale sconosciuto",
        "values not available": "valori non disponibili",
        "Not set up": "Non configurata",
        "The VM has no swap area": "La VM non ha un'area di swap",
        "usage not available": "uso non disponibile",
        "%@ free": "%@ liberi",
        "Warnings": "Avvisi",
        "No warnings in the last sample.": "Nessun avviso nell'ultimo campione.",
        "No warnings: CPU, memory and disk are within the Guest Tools’ thresholds.":
            "Nessun avviso: CPU, memoria e disco sono entro le soglie dei Guest Tools.",
        "Host name": "Nome host",
        "Architecture": "Architettura",
        "Kernel": "Kernel",
        "Uptime": "Acceso da",
        "protocol %@": "protocollo %@",
        "%lld d %lld h": "%lld g %lld h",
        "%lld h %lld min": "%lld h %lld min",
        "%lld min": "%lld min",
        "Settings…": "Impostazioni…",
        "In the VM the step isn’t recorded as done. Click Try Again, or look at the log.":
            "Nella VM il passo non risulta completato. Premi Riprova, oppure guarda il log.",
        "Nido can’t connect to %@ over SSH": "Nido non riesce a collegarsi a %@ via SSH",
        "Couldn’t install Ollama": "Installazione di Ollama non riuscita",
        "Couldn’t download the model": "Download del modello non riuscito",
        "The check failed": "Verifica non riuscita",
        "Setting up %@": "Preparazione di %@",
        "Essential packages and Guest Tools ready at %@": "Pacchetti essenziali e Guest Tools pronti alle %@",
        "Ollama and %@ verified at %@": "Ollama e %@ verificati alle %@",
        "Ollama verified at %@": "Ollama verificato alle %@",
        "First boot: cloud-init is preparing the system": "Primo avvio: cloud-init prepara il sistema",
        "Ollama chosen at creation": "Ollama scelto alla creazione",
        "Ollama and the model chosen at creation": "Ollama e il modello scelti alla creazione",
        "The Guest Tools of %@ don’t respond": "I Guest Tools di %@ non rispondono",
        "The first boot didn’t start the guest monitor within 5 minutes. Look at the console in the Screen view; if cloud-init has finished, install the Guest Tools over SSH.":
            "Il primo avvio non ha avviato il monitor del guest entro 5 minuti. Guarda la console nella vista Schermo; se cloud-init ha finito, installa i Guest Tools via SSH.",
        "Use Ollama from the AI view, or in the VM at 127.0.0.1:11434.":
            "Usa Ollama dalla vista AI, oppure nella VM su 127.0.0.1:11434.",
        "%@ will be usable at the end of phase 1.": "%@ sarà usabile alla fine della fase 1.",
        "%@ will be usable at the end of phase 1. Ollama and the model come later, without blocking it.":
            "%@ sarà usabile alla fine della fase 1. Ollama e il modello arrivano dopo, senza bloccarla.",
        "Nido stopped waiting: the operation goes on in the VM and the AI view shows how it ends.":
            "Nido ha smesso di attendere: l'operazione continua nella VM e la vista AI ne mostra l'esito.",
        "%@ is ready: you can use it while Nido downloads Ollama.":
            "%@ è già pronta: puoi usarla mentre Nido scarica Ollama.",
        "%@ is ready: you can use it while Nido downloads the model.":
            "%@ è già pronta: puoi usarla mentre Nido scarica il modello.",
        "Phase 1 · packages and Guest Tools": "Fase 1 · pacchetti e Guest Tools",
        "Done at %@": "Fatto alle %@",
        "Essential packages and Guest Tools": "Pacchetti essenziali e Guest Tools",
        "VM created": "VM creata",
        "Debian started": "Debian avviato",
        "Guest ready (the monitor responds)": "Guest pronto (risponde il monitor)",
        "Model %@": "Modello %@",
        "Waiting": "In attesa",
        "Failed": "Non riuscito",
        "Phase 1 · first boot": "Fase 1 · primo avvio",
        "Phase 2 · after the start": "Fase 2 · dopo l'avvio",
        "/var/log/nido-provision.log in %@ · last lines, read over SSH":
            "/var/log/nido-provision.log in %@ · ultime righe, lette via SSH",
        "Reading the log…": "Lettura del log…",
        "Hide": "Nascondi",
        "Open AI View": "Apri la vista AI",
        "Stop Waiting": "Smetti di attendere",
        "Don’t Install": "Non installare",
        "Hide Log": "Nascondi log",
        "Show Log": "Mostra log",
        "Release notes for this version aren’t available.": "Le note di questa versione non sono disponibili.",
        "Installed version: %@": "Versione installata: %@",
        "This version": "Questa versione",
    ]

    @Test func vmWindowSettingsMonitorCopyExistsInAllLanguages() {
        // The same word as the English is right here (names, units, Linux terms).
        Self.expectTranslated(Self.vmWindowSettingsMonitorCopy, sameAsEnglishAllowed: [
            "de:Monitor", "es:Monitor", "de:Hardware", "es:Hardware", "de:Kernel", "es:Kernel", "de:OK", "fr:OK",
            "fr:Architecture", "es:%lld d %lld h", "es:%lld h %lld min", "fr:%lld h %lld min", "es:%lld min", "fr:%lld min",
            "es:General",
            // VM colours that keep their name.
            "es:Color", "de:Indigo", "fr:Indigo", "fr:Rose", "fr:Olive", "fr:Graphite",
        ])
    }

    /// Words that two places use with different meanings are two keys (docs/LOCALIZATION.md).
    @Test func vmWindowHomonymsAreTheirOwnKeys() throws {
        #expect(Self.localized("Done (step)", "en") == "Done")
        #expect(Self.localized("Done (step)", "it") == "Fatto")
        #expect(Self.localized("Done", "it") == "Fine")
        #expect(Self.localized("Remove (token)", "en") == "Remove")
        #expect(Self.localized("Remove (token)", "it") == "Rimuovi")
        #expect(Self.localized("Remove (token)", "fr") == "Supprimer")
        #expect(Self.localized("Remove", "fr") == "Retirer")
        #expect(Self.localized("%@ is stopped (heading)", "en") == "%@ is stopped")
        #expect(Self.localized("%@ is stopped (heading)", "it") == "%@ è arrestata")
        #expect(Self.localized("%@ is stopped", "it") == "%@ arrestata")
        #expect(Self.localized("%@ is suspended (heading)", "it") == "%@ è sospesa")
        #expect(Self.localized("%@ is suspended (heading)", "en") == "%@ is suspended")
        #expect(Self.localized("None (VMs)", "en") == "None")
        #expect(Self.localized("None (VMs)", "it") == "Nessuna")
        #expect(Self.localized("None (VMs)", "fr") == "Aucune")
        // The heading's key is a plain literal; its interpolated default value carries the name.
        func heading(_ language: String, suspended: Bool) throws -> String {
            let bundle = try Self.bundle(language)
            let locale = Locale(identifier: language)
            let name = "debian-13"
            return suspended
                ? String(localized: "%@ is suspended (heading)", defaultValue: "\(name) is suspended",
                         bundle: bundle, locale: locale, comment: "Heading of a suspended VM’s window; %@ is the VM’s name.")
                : String(localized: "%@ is stopped (heading)", defaultValue: "\(name) is stopped",
                         bundle: bundle, locale: locale, comment: "Heading of a stopped VM’s window; %@ is the VM’s name.")
        }
        #expect(try heading("it", suspended: false) == "debian-13 è arrestata")
        #expect(try heading("it", suspended: true) == "debian-13 è sospesa")
        #expect(try heading("en", suspended: false) == "debian-13 is stopped")
        #expect(try heading("en", suspended: true) == "debian-13 is suspended")
        #expect(try heading("de", suspended: true) == "debian-13 ist im Ruhezustand")
        // German puts the reason after the sentence, with numbered placeholders.
        func notSuspended(_ language: String) throws -> String {
            let (name, reason) = ("debian-13", "Fehler 5")
            return String(localized: "\(name) wasn’t suspended (\(reason)): it was stopped.",
                          bundle: try Self.bundle(language), locale: Locale(identifier: language))
        }
        #expect(try notSuspended("de") == "debian-13 wurde nicht in den Ruhezustand versetzt, sondern gestoppt. Grund: Fehler 5")
        #expect(try notSuspended("it") == "debian-13 non è stata sospesa (Fehler 5): è stata arrestata.")
        // A product name, never translated.
        for language in Self.translations {
            #expect(Self.localized("Guest Tools", language) ?? "Guest Tools" == "Guest Tools")
        }
    }

    /// The counts of the VM window, the quit alert, the settings and the monitor: catalog plurals.
    @Test func vmWindowCountsFollowTheCount() throws {
        func text(_ language: String, _ make: (Bundle, Locale) -> String) throws -> String {
            make(try Self.bundle(language), Locale(identifier: language))
        }
        func quit(_ count: Int, _ language: String) throws -> String {
            try text(language) { String(localized: "Quit with \(count) virtual machines running?", bundle: $0, locale: $1) }
        }
        func warnings(_ count: Int, _ language: String) throws -> String {
            try text(language) { String(localized: "\(count) warnings at startup", bundle: $0, locale: $1) }
        }
        func blocks(_ count: Int, _ language: String) throws -> String {
            try text(language) { String(localized: "\(count) blocks without a notice", bundle: $0, locale: $1) }
        }
        func silent(_ count: Int, _ language: String) throws -> String {
            try text(language) {
                String(localized: "Last sample at \("10:42:18") · no response for \(count) seconds", bundle: $0, locale: $1)
            }
        }
        func snapshots(_ count: Int, _ language: String) throws -> String {
            try text(language) {
                String(localized: "\(count) snapshots · the latest, \("dopo-docker"), from \("24 ott 2026, 16:05")",
                       bundle: $0, locale: $1)
            }
        }
        func vcpus(_ count: Int, _ language: String) throws -> String {
            try text(language) { String(localized: "\(count) vCPUs", bundle: $0, locale: $1) }
        }
        #expect(try quit(3, "it") == "Uscire con 3 macchine virtuali accese?")
        #expect(try quit(1, "it") == "Uscire con 1 macchina virtuale accesa?")
        #expect(try quit(1, "en") == "Quit with 1 virtual machine running?")
        #expect(try quit(3, "en") == "Quit with 3 virtual machines running?")
        #expect(try quit(3, "de") == "Beenden, während 3 virtuelle Maschinen laufen?")
        #expect(try quit(3, "fr") == "Quitter alors que 3 machines virtuelles sont en marche\u{a0}?")
        #expect(try warnings(2, "it") == "2 avvisi all'avvio")
        #expect(try warnings(1, "en") == "1 warning at startup")
        #expect(try blocks(1, "it") == "1 blocco senza avviso")
        #expect(try blocks(4, "it") == "4 blocchi senza avviso")
        #expect(try blocks(4, "es") == "4 bloqueos sin aviso")
        #expect(try silent(12, "it") == "Ultimo campione alle 10:42:18 · nessuna risposta da 12 secondi")
        #expect(try silent(1, "en") == "Last sample at 10:42:18 · no response for 1 second")
        #expect(try snapshots(3, "it") == "3 snapshot · l'ultimo, dopo-docker, del 24 ott 2026, 16:05")
        #expect(try snapshots(1, "en") == "1 snapshot · dopo-docker, from 24 ott 2026, 16:05")
        #expect(try snapshots(3, "de") == "3 Schnappschüsse · der neueste, dopo-docker, vom 24 ott 2026, 16:05")
        #expect(try vcpus(4, "it") == "4 vCPU")
        #expect(try vcpus(4, "en") == "4 vCPUs")
        for language in ["de", "es", "fr"] {
            #expect(try quit(2, language).contains("2"), "\(language)")
            #expect(try warnings(2, language) != warnings(1, language).replacingOccurrences(of: "1", with: "2"),
                    "\(language): no plural")
        }
    }

    // MARK: - AI and network

    /// The AI view (Local and Remote), the chat, the network log, the network settings and the
    /// block notifications: each key with today's Italian.
    static let aiNetworkCopy: KeyValuePairs<String, String> = [
        "$%@ / $%@":
            "%@ $ / %@ $",
        "%@ Adding asks for Touch ID or the Mac password; removing doesn’t.":
            "%@ Aggiungere chiede Touch ID o la password del Mac; togliere no.",
        "%@ added to the allowed domains of %@: it applies within a few seconds, even with the VM running":
            "%@ aggiunto ai domini permessi di %@: vale entro pochi secondi, anche a VM accesa",
        "%@ and every subdomain of it.":
            "%@ e ogni suo sottodominio.",
        "%@ applies to every name under %@: the sites and services of anyone with an address there, not a single site. Add it only if you really need it; after this confirmation, Touch ID or the Mac password is needed too.":
            "%@ vale per ogni nome sotto %@: siti e servizi di chiunque vi abbia un indirizzo, non di un solo sito. Aggiungilo solo se ti serve davvero; dopo questa conferma serve anche Touch ID o la password del Mac.",
        "%@ is already one of the allowed domains of %@":
            "%@ è già tra i domini permessi di %@",
        "%@ is answering":
            "%@ sta rispondendo",
        "%@ is preparing the answer…":
            "%@ sta preparando la risposta…",
        "%@ tokens/s":
            "%@ token/s",
        "%@: %@":
            "%@: %@",
        "%@: %@ in the VM.":
            "%@: %@ nella VM.",
        "%@: %@.":
            "%@: %@.",
        "%@’s egress.json is replaced with the base list (%@).":
            "egress.json di %@ viene sostituito con la lista di base (%@).",
        "%@’s egress.json isn’t valid: the VM stays on the last valid list. Reset to the base list from the VM’s settings (Network) or with nido net reset %@":
            "egress.json di %@ non è valido: la VM resta sull'ultima lista valida. Ripristina la lista di base dalle impostazioni della VM (Rete) o con nido net reset %@",
        "20 requests per minute":
            "20 richieste al minuto",
        "200 000 tokens per day":
            "200 000 token al giorno",
        "A domain applies only to itself; *.example.com also applies to its subdomains. Changes apply within a few seconds, even with the VM running.":
            "Un dominio vale solo per sé; *.esempio.com vale anche per i suoi sottodomini. Le modifiche valgono entro pochi secondi, anche a VM accesa.",
        "AI bridge":
            "Ponte AI",
        "Active":
            "Attivo",
        "Add %@?":
            "Aggiungere %@?",
        "Add Anyway":
            "Aggiungi comunque",
        "Add a domain":
            "Aggiungi un dominio",
        "Adds exactly %@ to the allowed domains, after Touch ID or the Mac password.":
            "Aggiunge esattamente %@ ai domini permessi, dopo Touch ID o la password del Mac.",
        "Add…":
            "Aggiungi…",
        "Allow":
            "Consenti",
        "Allow %@":
            "Consenti %@",
        "Allow adds exactly %@ to the allowed domains.":
            "Consenti aggiunge esattamente %@ ai domini permessi.",
        "Allowed Domains…":
            "Domini permessi…",
        "Allowed Models for %@":
            "Modelli consentiti per %@",
        "Allowed models · provider prices per million tokens, for reference":
            "Modelli consentiti · prezzi dei provider per milione di token, indicativi",
        "Allow…":
            "Consenti…",
        "Also delete the models":
            "Cancella anche i modelli",
        "Answer stopped.":
            "Risposta interrotta.",
        "Answer too long: Nido stopped it at %@ characters.":
            "Risposta troppo lunga: Nido l'ha interrotta a %@ caratteri.",
        "Apple network":
            "Rete di Apple",
        "Apple network (NAT): the VM connects to the internet unchecked and no connection is logged. You can turn on the controlled network in the settings, with the VM stopped.":
            "Rete di Apple (NAT): la VM esce senza controlli e nessun collegamento viene registrato. Puoi attivare la rete controllata dalle impostazioni, a VM arrestata.",
        "Apply Limits":
            "Applica i limiti",
        "Background requests still on":
            "Richieste di sfondo ancora accese",
        "Blocks only":
            "Solo i blocchi",
        "Blocks stay in this log and the Network tab shows how many there are until you open it. To get notices: System Settings › Notifications › Nido.":
            "I blocchi restano in questo registro e la scheda Rete ne mostra il numero finché non la apri. Per ricevere gli avvisi: Impostazioni di Sistema › Notifiche › Nido.",
        "Cancel Download":
            "Annulla download",
        "Chat":
            "Chat",
        "Choose from Catalog…":
            "Scegli dal catalogo…",
        "Clear":
            "Cancella",
        "Clear Chat":
            "Cancella la chat",
        "Clear the chat?":
            "Cancellare la chat?",
        "Controlled network":
            "Rete controllata",
        "Controlled network interrupted":
            "Rete controllata interrotta",
        "Controlled network turns off at the next start.":
            "Rete controllata disattivata dal prossimo avvio.",
        "Controlled network turns on at the next start.":
            "Rete controllata attiva dal prossimo avvio.",
        "Controlled network on, but the base list wasn’t written: %@. The VM stays without a network until you add a domain or reset to the base list.":
            "Rete controllata attiva, ma la lista di base non è stata scritta: %@. La VM resta senza rete finché non aggiungi un dominio o ripristini la lista di base.",
        "Controlled network still on: confirmation canceled or failed.":
            "Rete controllata ancora attiva: conferma annullata o non riuscita.",
        "Copied":
            "Copiato",
        "Copy the answer to the clipboard":
            "Copia la risposta negli appunti",
        "Couldn’t add the domain: %@":
            "Impossibile aggiungere il dominio: %@",
        "Couldn’t remove the domain: %@":
            "Impossibile togliere il dominio: %@",
        "Couldn’t reset the list: %@":
            "Impossibile ripristinare la lista: %@",
        "Couldn’t save the bridge settings: %@":
            "Impostazioni del ponte non salvate: %@",
        "Couldn’t save: %@":
            "Impossibile salvare: %@",
        "DNS other than Nido’s":
            "DNS diverso da quello di Nido",
        "Download (model)":
            "Scarica",
        "Download a model":
            "Scarica un modello",
        "Downloading":
            "Download in corso",
        "Downloading %@…":
            "Download di %@ in corso…",
        "Duration":
            "Durata",
        "Error %lld":
            "Errore %lld",
        "From the Hugging Face Inference Providers catalog. The VM sees only the models you choose; prices are the providers’, per million input / output tokens, for reference only.":
            "Dal catalogo di Hugging Face Inference Providers. La VM vede solo i modelli scelti; i prezzi sono dei provider, per milione di token in ingresso / in uscita, solo indicativi.",
        "From the Ollama library. For a small VM, choose a light model, for example %@.":
            "Dalla libreria di Ollama. Per una VM piccola scegli un modello leggero, per esempio %@.",
        "From the next start, every connection of the VM goes through Nido: it can reach only the domains on the list, and everything else is blocked, logged and reported. If the VM doesn’t have a domain list yet, it starts with the base list (%@). If the controlled network doesn’t start, the VM stays without a network instead of connecting unchecked. Ollama is installed by downloading it on the Mac: the VM doesn’t contact GitHub. The VM’s saved state, if any, isn’t resumed.":
            "Dal prossimo avvio ogni collegamento della VM passa da Nido: esce solo verso i domini della lista e il resto viene bloccato, registrato e segnalato. Se la VM non ha ancora una lista di domini, parte con la lista di base (%@). Se la rete controllata non parte, la VM resta senza rete invece di uscire senza controlli. Ollama si installa scaricandolo sul Mac: la VM non contatta GitHub. Uno stato sospeso della VM non viene ripreso.",
        "From the next start, every connection of the VM goes through Nido: it can reach only the domains on the list, and everything else is blocked, logged and reported. If the VM doesn’t have a domain list yet, it starts with the base list for macOS (%@): activation, macOS updates and the clock. The App Store, iCloud and other sites stay blocked until you add their domains. If the controlled network doesn’t start, the VM stays without a network instead of connecting unchecked. The VM’s saved state, if any, isn’t resumed.":
            "Dal prossimo avvio ogni collegamento della VM passa da Nido: esce solo verso i domini della lista e il resto viene bloccato, registrato e segnalato. Se la VM non ha ancora una lista di domini, parte con la lista di base per macOS (%@): attivazione, aggiornamenti di macOS e orologio. App Store, iCloud e gli altri siti restano bloccati finché non aggiungi i loro domini. Se la rete controllata non parte, la VM resta senza rete invece di uscire senza controlli. Uno stato sospeso della VM non viene ripreso.",
        "From the next start, the VM connects to the internet through Apple’s NAT, to any destination, and nothing is logged. The domain list is kept for when you turn it back on. You confirm with Touch ID or the Mac password.":
            "Dal prossimo avvio la VM esce su Internet con il NAT di Apple, verso qualsiasi destinazione e senza registro. La lista dei domini resta per quando la riattivi. Serve la tua conferma con Touch ID o la password del Mac.",
        "Generated in %@":
            "Generata in %@",
        "Go to End":
            "Vai alla fine",
        "Hugging Face rejected the token: check it in Nido Settings.":
            "Hugging Face ha rifiutato il token: controllalo nelle Impostazioni di Nido.",
        "Hugging Face through Nido’s bridge: the text leaves the Mac.":
            "Hugging Face tramite il ponte di Nido: i testi escono dal Mac.",
        "IPv6 doesn’t go out":
            "IPv6 non esce",
        "In the VM, with any API key":
            "Nella VM, con una chiave API qualsiasi",
        "Install Ollama":
            "Installa Ollama",
        "Installing Ollama…":
            "Installazione di Ollama in corso…",
        "Invalid VM name.":
            "Nome della VM non valido.",
        "Invalid domain list":
            "Lista dei domini non valida",
        "Invalid model name: use name:variant, for example llama3.2:1b.":
            "Nome del modello non valido: usa nome:variante, per esempio llama3.2:1b.",
        "Keychain status not available":
            "Stato del Portachiavi non disponibile",
        "Limits for %@":
            "Limiti per %@",
        "List not changed: confirmation canceled or failed.":
            "Lista non cambiata: conferma annullata o non riuscita.",
        "List reset to the base list.":
            "Lista di base ripristinata.",
        "Local":
            "Locale",
        "Log":
            "Registro",
        "Model":
            "Modello",
        "Model and Provider":
            "Modello e provider",
        "Models":
            "Modelli",
        "Models and Limits":
            "Modelli e limiti",
        "Nido downloads it again from the Ollama library and replaces the one in the VM.":
            "Nido lo scarica di nuovo dalla libreria di Ollama e sostituisce quello nella VM.",
        "Nido installs Ollama from the official sources, in the version Nido has verified, and runs it as a service of the VM on 127.0.0.1:11434.":
            "Nido installa Ollama dalle fonti ufficiali, nella versione verificata da Nido, e lo avvia come servizio della VM su 127.0.0.1:11434.",
        "Nido stopped waiting: the operation continues in the VM and the status updates automatically.":
            "Nido ha smesso di attendere: l'operazione continua nella VM e lo stato si aggiorna da solo.",
        "Nido stops the service and removes Ollama from the VM. The models stay, unless you choose to delete them.":
            "Nido ferma il servizio e rimuove Ollama dalla VM. I modelli restano, a meno che tu non scelga di cancellarli.",
        "Nido’s notifications are turned off":
            "Le notifiche di Nido sono disattivate",
        "No allowed domains":
            "Nessun dominio permesso",
        "No blocks logged.":
            "Nessun blocco registrato.",
        "No calls logged.":
            "Nessuna chiamata registrata.",
        "No connections logged.":
            "Nessuna connessione registrata.",
        "No domain added: confirmation canceled or failed":
            "Nessun dominio aggiunto: conferma annullata o non riuscita",
        "No models allowed: while the list is empty, the VM can’t use any model.":
            "Nessun modello consentito: finché la lista è vuota, la VM non può usare alcun modello.",
        "No models in the VM.":
            "Nessun modello nella VM.",
        "No models in the VM: download one from the Models view to use the chat.":
            "Nessun modello nella VM: scaricane uno dalla vista Modelli per usare la chat.",
        "Not Now":
            "Non ora",
        "Not added yet: add it in Nido Settings":
            "Non ancora inserito: aggiungilo nelle Impostazioni di Nido",
        "Not allowed":
            "Non consentita",
        "Not installed":
            "Non installato",
        "Off":
            "Spento",
        "Off: the VM connects to the internet through Apple’s NAT, unchecked.":
            "Spenta: la VM esce su Internet con il NAT di Apple, senza controlli.",
        "Ollama and the chat are managed here only for VMs started by Nido: %@ was started from Terminal (nido start).":
            "Ollama e la chat si gestiscono qui solo per le VM avviate da Nido: %@ è in esecuzione dal Terminale (nido start).",
        "Ollama download canceled: nothing in the VM was changed. Try again whenever you want.":
            "Download di Ollama annullato: la VM non è stata toccata. Riprova quando vuoi.",
        "Ollama inside %@: the text doesn’t leave the Mac.":
            "Ollama dentro %@: i testi non escono dal Mac.",
        "Ollama is managed through Nido’s Guest Tools: install them from the Monitor view or the VM’s settings.":
            "Ollama si gestisce con i Guest Tools di Nido: installali dalla vista Monitor o dalle Impostazioni della VM.",
        "Ollama uses the VM’s CPU: Virtualization offers no GPU to Linux guests, so a small model is best. It takes a few minutes; you can use the VM in the meantime.":
            "Ollama usa la CPU della VM: Virtualization non offre una GPU ai guest Linux, quindi conviene un modello piccolo. Ci vuole qualche minuto; puoi usare la VM nel frattempo.",
        "Ollama’s status not available":
            "Stato di Ollama non disponibile",
        "On":
            "Acceso",
        "On the Mac":
            "Sul Mac",
        "On the base list.":
            "Nella lista di base.",
        "One operation at a time: wait for the current one to finish.":
            "Un'operazione alla volta: attendi la fine di quella in corso.",
        "Only this name.":
            "Solo questo nome.",
        "Open Log":
            "Apri il registro",
        "Open Settings":
            "Apri le Impostazioni",
        "Open VM Settings":
            "Apri le Impostazioni",
        "Outcome":
            "Esito",
        "Over the limit":
            "Oltre il limite",
        "Overwrite":
            "Sovrascrivi",
        "Preparing the download…":
            "Download in preparazione…",
        "Reading Ollama’s status…":
            "Lettura dello stato di Ollama…",
        "Recent calls":
            "Ultime chiamate",
        "Remote":
            "Remoto",
        "Remove %@ from %@?":
            "Rimuovere %@ da %@?",
        "Remove (domain)":
            "Togli",
        "Remove (model)":
            "Rimuovi",
        "Removed %@: open connections to it are cut.":
            "Tolto %@: le connessioni aperte verso di lui vengono interrotte.",
        "Remove…":
            "Rimuovi…",
        "Removing %@…":
            "Rimozione di %@ in corso…",
        "Requests per minute":
            "Richieste al minuto",
        "Requests per minute must be between 1 and 1 000.":
            "Le richieste al minuto devono essere tra 1 e 1 000.",
        "Reset":
            "Ripristina",
        "Reset to Base List…":
            "Ripristina lista di base…",
        "Reset to the base list?":
            "Ripristinare la lista di base?",
        "Restart":
            "Riavvia",
        "Restarting Ollama…":
            "Riavvio di Ollama in corso…",
        "Saved in the Mac’s Keychain":
            "Salvato nel Portachiavi del Mac",
        "Search the catalog":
            "Cerca nel catalogo",
        "Send":
            "Invia",
        "Start %@ to manage Ollama, the models and the chat.":
            "Avvia %@ per gestire Ollama, i modelli e la chat.",
        "Starting Ollama…":
            "Avvio di Ollama in corso…",
        "Default limits":
            "Limiti predefiniti",
        "Default limits, which you can change: 200 000 tokens per day, 20 requests per minute, max_tokens 4 096.":
            "Limiti predefiniti, modificabili: 200 000 token al giorno, 20 richieste al minuto, max_tokens 4 096.",
        "Stop (answer)":
            "Interrompi",
        "Stop (service)":
            "Ferma",
        "Stop generating (Esc)":
            "Interrompi la generazione (Esc)",
        "Stopped (service)":
            "Fermo",
        "Stopping Ollama…":
            "Arresto di Ollama in corso…",
        "Succeeded":
            "Riuscita",
        "The AI bridge isn’t available in this session":
            "Il ponte AI non è disponibile in questa sessione",
        "The AI bridge isn’t available in this session: the VM’s requests don’t reach Hugging Face. Restart the VM to try again.":
            "Il ponte AI non è disponibile in questa sessione: le richieste della VM non arrivano a Hugging Face. Riavvia la VM per riprovare.",
        "The AI bridge works only for VMs started by Nido: %@ was started from Terminal (nido start).":
            "Il ponte AI funziona solo per le VM avviate da Nido: %@ è in esecuzione dal Terminale (nido start).",
        "The Hugging Face token is missing":
            "Manca il token di Hugging Face",
        "The Hugging Face token is missing: add it in Nido Settings. Until then, the VM’s requests get a 401 error and nothing leaves the Mac.":
            "Manca il token di Hugging Face: aggiungilo nelle Impostazioni di Nido. Finché manca, le richieste della VM ricevono un errore 401 e nulla esce dal Mac.",
        "The VM can’t reach any site. %@":
            "La VM non raggiunge nessun sito. %@",
        "The VM is running: connections to domains outside the base list are cut.":
            "La VM è accesa: le connessioni verso domini fuori dalla lista di base vengono interrotte.",
        "The VM isn’t running: start it to manage Ollama.":
            "La VM non è in esecuzione: avviala per gestire Ollama.",
        "The VM isn’t running: start it to use the chat.":
            "La VM non è in esecuzione: avviala per usare la chat.",
        "The VM reaches only the domains on the list. Every block ends up in the log and in a notice.":
            "La VM raggiunge solo i domini della lista. Ogni blocco finisce nel registro e in un avviso.",
        "The VM’s configuration can’t be read.":
            "Configurazione della VM non leggibile.",
        "The bridge answers only while %@ is running in Nido. The token stays on the Mac.":
            "Il ponte risponde solo mentre %@ è in esecuzione in Nido. Il token resta sul Mac.",
        "The chat stays in %@: nothing leaves the Mac and Nido doesn’t save it.":
            "La chat resta in %@: nulla esce dal Mac e Nido non la salva.",
        "The conversation with %@ will be cleared: Nido keeps no copy.":
            "La conversazione con %@ sparisce: Nido non ne tiene copia.",
        "The conversation with %@ will be cleared: Nido keeps no copy. The answer in progress is stopped.":
            "La conversazione con %@ sparisce: Nido non ne tiene copia. La risposta in arrivo viene interrotta.",
        "The first time you turn it on, Nido shows you what leaves the Mac. Local mode is always available.":
            "Alla prima attivazione Nido ti mostra cosa esce dal Mac. La modalità Locale resta sempre disponibile.",
        "The list applies when you turn on the controlled network.":
            "La lista vale quando attivi la rete controllata.",
        "The log also shows the allowed connections, with the bytes sent and received.":
            "Il registro mostra anche i collegamenti permessi, con i byte inviati e ricevuti.",
        "The log never contains prompts or answers.":
            "Il registro non contiene mai prompt né risposte.",
        "The log shows blocks, cut connections and summaries. Turn this off to also see the allowed connections.":
            "Il registro mostra blocchi, connessioni interrotte e riepiloghi. Disattiva per vedere anche i collegamenti permessi.",
        "The maximum tokens per request must be between 1 and 1 000 000.":
            "Il massimo di token per richiesta deve essere tra 1 e 1 000 000.",
        "The model %@ is already in the VM: download it again and overwrite it?":
            "Il modello %@ esiste già nella VM: scaricarlo di nuovo e sovrascriverlo?",
        "The model (%@) is deleted from the VM. You can download it again whenever you want.":
            "Il modello (%@) viene cancellato dalla VM. Puoi scaricarlo di nuovo quando vuoi.",
        "The model catalog Hugging Face sent isn’t valid: try again later.":
            "Il catalogo dei modelli ricevuto da Hugging Face non è valido: riprova più tardi.",
        "The model catalog can’t be reached: check the Mac’s connection and try again.":
            "Il catalogo dei modelli non è raggiungibile: controlla la connessione del Mac e riprova.",
        "The model catalog isn’t available (Hugging Face answered %lld): try again later.":
            "Il catalogo dei modelli non è disponibile (Hugging Face ha risposto %lld): riprova più tardi.",
        "The model is deleted from the VM. You can download it again whenever you want.":
            "Il modello viene cancellato dalla VM. Puoi scaricarlo di nuovo quando vuoi.",
        "The model is preparing the answer…":
            "Il modello sta preparando la risposta…",
        "The models already allowed stay valid: the VM keeps using them.":
            "I modelli già consentiti restano validi: la VM continua a usarli.",
        "Time":
            "Ora",
        "Time, model, tokens and outcome; never prompts or answers":
            "Ora, modello, token ed esito; mai prompt né risposte",
        "Today’s usage":
            "Uso di oggi",
        "Token":
            "Token",
        "Token rejected":
            "Token rifiutato",
        "Tokens":
            "Token",
        "Tokens per day":
            "Token al giorno",
        "Tokens per day must be between 1 and 100 000 000.":
            "I token al giorno devono essere tra 1 e 100 000 000.",
        "Turn Off (network)":
            "Disattiva",
        "Turn On":
            "Attiva",
        "Turn On the Bridge":
            "Attiva il ponte",
        "Turn On the Bridge…":
            "Attiva il ponte…",
        "Turn off the controlled network for %@?":
            "Disattivare la rete controllata per %@?",
        "Turn on the AI bridge for %@?":
            "Attivare il ponte AI per %@?",
        "Turn on the controlled network for %@?":
            "Attivare la rete controllata per %@?",
        "Turning Off…":
            "Spegnimento…",
        "Uninstall":
            "Disinstalla",
        "Uninstall Ollama from %@?":
            "Disinstallare Ollama da %@?",
        "Uninstalling Ollama…":
            "Disinstallazione di Ollama in corso…",
        "Uninstall…":
            "Disinstalla…",
        "Update":
            "Aggiorna",
        "Updating Ollama…":
            "Aggiornamento di Ollama in corso…",
        "Usage and Log":
            "Uso e registro",
        "VM not started":
            "VM non avviata",
        "Verify":
            "Verifica",
        "Verifying Ollama…":
            "Verifica di Ollama in corso…",
        "View":
            "Vista",
        "With the bridge on, the text that programs in the VM send to the bridge leaves the Mac and reaches Hugging Face and the provider that serves the model, with your token. Nido doesn’t log prompts or answers, only the model, the tokens used and the outcome. Local mode (Ollama in the VM) is always available.":
            "Con il ponte attivo, i testi che i programmi della VM inviano al ponte escono dal Mac e arrivano a Hugging Face e al provider che serve il modello, con il tuo token. Nido non registra prompt né risposte, solo modello, token usati ed esito. La modalità Locale (Ollama nella VM) resta sempre disponibile.",
        "With the bridge, programs in %@ use models from Hugging Face Inference Providers as an OpenAI-compatible API. Your token stays on the Mac: the VM never receives it.":
            "Con il ponte, i programmi di %@ usano i modelli di Hugging Face Inference Providers come un'API compatibile OpenAI. Il tuo token resta sul Mac: la VM non lo riceve mai.",
        "Write a message":
            "Scrivi un messaggio",
        "You confirm with Touch ID or the Mac password.":
            "Serve la tua conferma con Touch ID o la password del Mac.",
        "add %@ to the allowed domains of the VM %@":
            "aggiungere %@ ai domini permessi della VM %@",
        "address never resolved for an allowed domain":
            "indirizzo mai risolto per un dominio permesso",
        "allowed":
            "permesso",
        "blocked":
            "bloccato",
        "blocked connection":
            "connessione bloccata",
        "context %@":
            "contesto %@",
        "controlled network interrupted":
            "rete controllata interrotta",
        "controlled network interrupted: the VM has no network until it next starts":
            "rete controllata interrotta: la VM resta senza rete fino al prossimo avvio",
        "cut":
            "interrotto",
        "domain not allowed":
            "dominio non permesso",
        "domain removed from the list: connection cut":
            "dominio tolto dalla lista: connessione interrotta",
        "egress.json isn’t valid or isn’t safe: the running VM stays on the last valid list, and at the next start it has no network. Reset to the base list from the settings (Network) or with nido net reset %@.":
            "egress.json non è valido o non è sicuro: la VM accesa resta sull'ultima lista valida, e al prossimo avvio non ha rete. Ripristina la lista di base dalle impostazioni (Rete) o con nido net reset %@.",
        "egress.json isn’t valid or isn’t safe: the running VM stays on the last valid list, and at the next start it has no network. Rewrite it with the base list below, or from Terminal with nido net reset %@.":
            "egress.json non è valido o non è sicuro: la VM accesa resta sull'ultima lista valida, e al prossimo avvio non ha rete. Riscrivilo con la lista di base qui sotto oppure dal Terminale con nido net reset %@.",
        "example.com":
            "esempio.com",
        "for an alias, only A, AAAA, CNAME and HTTPS queries":
            "per un alias solo richieste A, AAAA, CNAME e HTTPS",
        "gvproxy isn’t running anymore: the VM has no network and nothing gets out by any other route. Stop and start the VM again to restore the network.":
            "gvproxy non è più acceso: la VM è senza rete e non esce niente, nemmeno per altre vie. Arresta e avvia di nuovo la VM per ripristinare la rete.",
        "interrupted":
            "interrotta",
        "invalid name":
            "nome non valido",
        "multicast or broadcast":
            "multicast o broadcast",
        "name not allowed":
            "nome non permesso",
        "name:variant, for example llama3.2:1b":
            "nome:variante, per esempio llama3.2:1b",
        "network log not available":
            "registro di rete non disponibile",
        "not logged one by one: %@":
            "non registrati uno per uno: %@",
        "of %@ tokens · resets at midnight":
            "di %@ token · si azzera a mezzanotte",
        "on %@’s CPU":
            "sulla CPU di %@",
        "only DHCP, DNS and SSH can reach the Mac":
            "verso il Mac passano solo DHCP, DNS e SSH",
        "only TCP and UDP can go out":
            "solo TCP e UDP possono uscire",
        "open":
            "aperto",
        "other blocks":
            "altri blocchi",
        "other destinations":
            "altre destinazioni",
        "port %@":
            "porta %@",
        "price not given":
            "prezzo non indicato",
        "relay summary":
            "riepilogo del relè",
        "rewrite the list of allowed domains of the VM %@":
            "riscrivere la lista dei domini permessi della VM %@",
        "sent %@, received %@":
            "inviati %@, ricevuti %@",
        "source address isn’t the VM’s":
            "indirizzo di origine non della VM",
        "summary":
            "riepilogo",
        "blocking stays on, but blocks aren’t logged or reported":
            "i blocchi restano attivi ma non vengono registrati né notificati",
        "the details are in the VM’s log":
            "i dettagli sono nel registro della VM",
        "turn off the controlled network of the VM %@":
            "disattivare la rete controllata della VM %@",
        "unknown reason":
            "motivo sconosciuto",
        "unrecognized packet":
            "pacchetto non riconosciuto",
    ]

    @Test func aiNetworkCopyExistsInAllLanguages() {
        // The same text as the English is right here (names, symbols, punctuation only).
        Self.expectTranslated(Self.aiNetworkCopy, sameAsEnglishAllowed: [
            "es:%@ tokens/s", "de:%@: %@", "es:%@: %@", "de:%@: %@.", "es:%@: %@.", "de:Chat", "es:Chat",
            "es:Error %lld", "es:Local", "fr:Local", "de:Remote", "de:Token", "es:Token", "de:Tokens", "es:Tokens",
            "fr:port %@",
        ])
        // German says the VM's traffic "leaves the VM" (as the CLI), never the calque "geht hinaus".
        for (key, _) in Self.aiNetworkCopy {
            #expect(!(Self.localized(key, "de") ?? "").contains("hinaus"), "\(key): de")
        }
        #expect(Self.localized("only TCP and UDP can go out", "de") == "Nur TCP und UDP dürfen die VM verlassen")
        #expect(Self.localized("Allow adds exactly %@ to the allowed domains.", "es")?.hasPrefix("“Permitir” añade") == true)
        #expect(Self.localized("Open Settings", "fr") == "Ouvrir les réglages")
    }

    /// Words of the AI and network views that other places use with another meaning (or another
    /// Italian) are keys of their own.
    @Test func aiNetworkHomonymsAreTheirOwnKeys() {
        // Ollama's service is "fermo", the VM "arrestata".
        #expect(Self.localized("Stop (service)", "en") == "Stop")
        #expect(Self.localized("Stop (service)", "it") == "Ferma")
        #expect(Self.localized("Stop", "it") == "Arresta")
        #expect(Self.localized("Stopped (service)", "en") == "Stopped")
        #expect(Self.localized("Stopped (service)", "it") == "Fermo")
        #expect(Self.localized("Stop (answer)", "en") == "Stop")
        #expect(Self.localized("Stop (answer)", "it") == "Interrompi")
        // A model is deleted from the VM; a domain or an allowed model only leaves a list.
        #expect(Self.localized("Remove (model)", "en") == "Remove")
        #expect(Self.localized("Remove (model)", "es") == "Eliminar")
        #expect(Self.localized("Remove (model)", "fr") == "Supprimer")
        #expect(Self.localized("Remove", "es") == "Quitar")
        #expect(Self.localized("Remove (domain)", "en") == "Remove")
        #expect(Self.localized("Remove (domain)", "it") == "Togli")
        #expect(Self.localized("Remove (domain)", "fr") == "Retirer")
        // German downloads models with "herunterladen": "Laden" reads as loading one into memory.
        #expect(Self.localized("Download (model)", "en") == "Download")
        #expect(Self.localized("Download (model)", "de") == "Herunterladen")
        #expect(Self.localized("Download (model)", "it") == "Scarica")
        #expect(Self.localized("Turn Off (network)", "en") == "Turn Off")
        #expect(Self.localized("Turn Off (network)", "it") == "Disattiva")
        #expect(Self.localized("Turn Off", "it") == "Spegni")
        // The API's parameter name, never translated.
        for language in Self.translations {
            #expect(Self.localized("max_tokens", language) ?? "max_tokens" == "max_tokens")
        }
    }

    /// The counts of the AI and network views: catalog plurals (and one substitution, where the
    /// plural follows the second number).
    @Test func aiNetworkCountsFollowTheCount() throws {
        func text(_ language: String, _ make: (Bundle, Locale) -> String) throws -> String {
            make(try Self.bundle(language), Locale(identifier: language))
        }
        func models(_ shown: Int, _ total: Int, _ language: String) throws -> String {
            try text(language) { String(localized: "\(shown) of \(total) models", bundle: $0, locale: $1) }
        }
        func others(_ count: Int, _ language: String) throws -> String {
            try text(language) { String(localized: "\(count) other destinations", bundle: $0, locale: $1) }
        }
        func domains(_ count: Int, _ language: String) throws -> String {
            try text(language) {
                String(localized: "Controlled network: \(count) allowed domains. Everything else is blocked and logged here, without the traffic’s content.",
                       bundle: $0, locale: $1)
            }
        }
        func noise(_ count: Int, _ language: String) throws -> String {
            try text(language) {
                String(localized: "\(count) local-noise blocks hidden: IPv6 multicast and link-local, broadcast. They don’t leave the VM; to see them: nido net log \("agenti") --all.",
                       bundle: $0, locale: $1)
            }
        }
        func times(_ count: Int, _ language: String) throws -> String {
            try text(language) {
                String(localized: "\("example.com:53") (\(count) times): \("nome non permesso").", bundle: $0, locale: $1)
            }
        }
        func full(_ count: Int, _ language: String) throws -> String {
            try text(language) { String(localized: "\("agenti")’s list is full (\(count) domains): remove some first", bundle: $0, locale: $1) }
        }
        func blocks(_ count: Int, _ language: String) throws -> String {
            try text(language) { String(localized: "\(count) blocks", bundle: $0, locale: $1) }
        }
        #expect(try models(3, 120, "it") == "3 di 120 modelli")
        #expect(try models(1, 1, "it") == "1 di 1 modello")
        #expect(try models(0, 1, "en") == "0 of 1 model")
        #expect(try models(3, 120, "en") == "3 of 120 models")
        #expect(try models(3, 120, "de") == "3 von 120 Modellen")
        #expect(try models(1, 1, "de") == "1 von 1 Modell")
        #expect(try others(1, "it") == "un'altra destinazione")
        #expect(try others(4, "it") == "altre 4 destinazioni")
        #expect(try others(1, "en") == "one other destination")
        #expect(try others(4, "fr") == "4 autres destinations")
        #expect(try domains(1, "it").hasPrefix("Rete controllata: 1 dominio permesso. "))
        #expect(try domains(3, "it").hasPrefix("Rete controllata: 3 domini permessi. "))
        #expect(try domains(1, "en").hasPrefix("Controlled network: 1 allowed domain. "))
        #expect(try domains(0, "fr").hasPrefix("Réseau contrôlé\u{a0}: 0 domaine autorisé. "))
        #expect(try noise(1, "it").hasPrefix("1 blocco di rumore locale nascosto: "))
        #expect(try noise(2, "it").hasPrefix("2 blocchi di rumore locale nascosti: "))
        #expect(try noise(2, "it").hasSuffix("nido net log agenti --all."))
        #expect(try times(3, "it") == "example.com:53 (3 volte): nome non permesso.")
        #expect(try times(3, "de") == "example.com:53 (3-mal): nome non permesso.")
        #expect(try times(3, "fr") == "example.com:53 (3 fois)\u{a0}: nome non permesso.")
        #expect(try full(512, "it") == "La lista di agenti è piena (512 domini): togline qualcuno prima")
        #expect(try full(1, "en") == "agenti’s list is full (1 domain): remove it first")
        func repeats(_ count: Int, _ language: String) throws -> String {
            try text(language) { String(localized: "\("nome non permesso") (and \(count) more times before)", bundle: $0, locale: $1) }
        }
        #expect(try repeats(1, "it") == "nome non permesso (e un'altra volta prima)")
        #expect(try repeats(3, "it") == "nome non permesso (e altre 3 volte prima)")
        #expect(try repeats(3, "es") == "nome non permesso (y otras 3 veces antes)")
        #expect(try repeats(3, "fr") == "nome non permesso (et déjà 3 fois auparavant)")
        #expect(try repeats(1, "fr") == "nome non permesso (et déjà une fois auparavant)")
        #expect(try blocks(1, "it") == "1 blocco")
        #expect(try blocks(3, "es") == "3 bloqueos")
        for language in ["de", "es", "fr"] {
            #expect(try others(2, language).contains("2"), "\(language)")
            #expect(try blocks(2, language) != blocks(1, language).replacingOccurrences(of: "1", with: "2"),
                    "\(language): no plural")
        }
    }

    /// The copyright line in Info.plist, from InfoPlist.xcstrings.
    @Test func copyrightExistsInAllLanguages() {
        Self.expectTranslated(
            ["NSHumanReadableCopyright": "© 2026 Mattia Pichierri. Software libero con licenza Apache-2.0."],
            table: "InfoPlist")
        #expect(Self.localized("NSHumanReadableCopyright", "en", table: "InfoPlist")
            == "© 2026 Mattia Pichierri. Free software under the Apache-2.0 license.")
    }
}
