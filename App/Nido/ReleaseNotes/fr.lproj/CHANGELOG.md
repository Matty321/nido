# Nouveautés de Nido

Toutes les versions de Nido, de la plus récente à la plus ancienne. À la première ouverture après une mise à jour, Nido affiche les nouveautés de la version installée (pour les relire, choisissez Aide › Nouveautés de Nido).

## [0.8.1] – 2026-11-13

### Langues
- **La langue de Nido se choisit dans Réglages › Général › Langue** : anglais, italien, allemand, espagnol, français ou comme le système. Nido se ferme et se rouvre dans la nouvelle langue ; si une VM est en marche, Nido demande d’abord quoi en faire, comme quand vous quittez. C’est le même réglage que Réglages Système › Général › Langue et région › Apps.

## [0.8.0] – 2026-11-13

### Langues
- **Nido parle désormais anglais, italien, allemand, espagnol et français** : l’app, la commande `nido`, les notes de version et le README. L’anglais est la langue de base. L’app suit la langue que vous utilisez dans macOS et s’affiche en anglais pour toute autre langue.
- La commande `nido` suit la langue du système. `NIDO_LANGUAGE` (`en`, `it`, `de`, `es` ou `fr`) permet d’en choisir une autre, par exemple dans les scripts qui lisent sa sortie.

### Nido Guest Tools 1.5.0
- **Les messages sur Ollama et les modèles d’IA s’affichent dans votre langue** : les Guest Tools envoient un code stable avec chaque erreur et chaque avertissement, et l’app affiche son propre texte. Les Guest Tools précédents envoient toujours leurs messages en italien, que Nido affiche tels quels : réinstallez les Guest Tools depuis les réglages de la VM pour obtenir la nouvelle version dans les VM existantes.

### La commande nido dans le menu
- **Nido › Installer la commande nido…** crée `~/.local/bin/nido`, un lien vers la commande, qui se trouve désormais dans l’app (avec `gvproxy`) : la commande se met à jour avec l’app. Si `~/.local/bin` ne figure pas dans votre `PATH`, Nido vous le signale. Une copie installée auparavant par `scripts/install.sh` n’est remplacée qu’après votre confirmation.
- **Nido › Supprimer la commande nido** supprime le lien seulement s’il pointe vers Nido.
- Ouvert directement depuis le DMG, Nido n’installe pas la commande et vous demande d’abord de le déplacer dans Applications.

### Mises à jour
- **Nido › Rechercher les mises à jour…** vérifie si une nouvelle version existe. Nido ne se connecte jamais au réseau de lui-même : la vérification automatique ne démarre que si vous la choisissez (quand Nido vous le demande à la deuxième ouverture, ou dans **Réglages › Général › Rechercher les mises à jour automatiquement**, désactivée par défaut).
- **Jamais avec une VM en marche** : tant qu’une VM est en marche, dans l’app ou avec `nido start`, la mise à jour téléchargée attend. Elle s’installe quand vous quittez Nido sans VM en marche, et un avis indique quelles VM la bloquent.
- Chaque mise à jour est signée (EdDSA) et téléchargée en HTTPS ; Nido refuse une mise à jour ou une liste de versions sans signature valide.

### Signature Developer ID
- **Nido est signé avec un certificat Developer ID et notarié par Apple** : il s’ouvre sans contourner Gatekeeper. L’app, la commande `nido`, `gvproxy` et Sparkle portent tous la même signature, avec le Hardened Runtime.
- À côté du DMG se trouvent les sommes de contrôle SHA-256 et la liste des composants (SBOM, SPDX).

### Trousseau
- **Après le changement de signature, macOS peut demander une nouvelle fois l’accès au jeton Hugging Face** enregistré dans le trousseau. Il suffit d’autoriser l’accès une fois ; si le jeton n’est plus lisible, saisissez-le de nouveau dans **Réglages › Hugging Face**.

### Sécurité
- **Une VM ne peut plus faire quitter Nido** : des valeurs hors limites envoyées par le système invité (les pourcentages du moniteur, la taille et la progression des modèles d’IA d’Ollama) faisaient planter l’app, et avec elle toutes les VM en marche. Elles sont désormais plafonnées avant d’être affichées.
- **La conversation et la console ne bloquent plus l’app** : une réponse de la conversation locale ou une sortie de console conçues pour ralentir Nido sont lues par morceaux et en temps linéaire, sans freiner les autres VM. Les réponses de la conversation ont aussi une taille maximale.
- **L’adresse des mises à jour est toujours celle de Nido** : une valeur restée dans les préférences de l’app ne peut plus la remplacer. Les mises à jour restaient de toute façon signées.

## [0.7.6] – 2026-11-10

### Images
- **`nido image check` affiche le build Debian** vérifié, par exemple `debian-13 : à jour (build 20261103-2651)` ; `nido image update` indique quel build il a téléchargé.
- **`nido image reset <id>`** oublie le build et la signature déjà acceptés d’une image, après confirmation. Ce n’est utile que si Nido continue de refuser une liste « plus ancienne que celle déjà acceptée » ; le message de refus l’indique désormais, au lieu de désigner un fichier à supprimer à la main. L’image en cache est conservée.

### Réseau contrôlé
- La suggestion **Désactiver** de l’onglet Réseau et le décompte des lignes de trafic local masquées sont désormais couverts par un test de l’interface.

## [0.7.5] – 2026-11-10

### Réseau contrôlé
- **L’onglet Réseau propose de désactiver les requêtes en arrière-plan** dans les VM Linux créées avant Nido 0.7.4 : **Désactiver** les arrête aussitôt (avec la VM en marche), **Plus tard** ne le demande plus pour cette VM. L’option reste aussi dans Réglages › Guest Tools.
- **L’onglet Réseau indique combien de lignes de trafic local de fond il masque** (multicast et link-local IPv6, broadcast) et comment les voir avec `nido net log --all`.

### Images
- **Debian : build vérifié.** Nido lit aussi le manifeste du build que Debian publie à côté de l’image et refuse, avant le téléchargement, des fichiers incohérents ou un build plus ancien que celui déjà accepté. Debian ne signe pas ses images cloud : ce n’est pas une signature, mais cela bloque une ancienne copie proposée à nouveau.
- **Ubuntu : prêt pour un changement de clé.** Nido peut accepter la clé de signature actuelle et celle annoncée comme la suivante, pour qu’un changement de clé ne bloque pas les téléchargements.

### Fenêtre de la VM
- La barre compacte (menu **Plus**) est désormais couverte par un test de l’interface : dans une fenêtre étroite, Mettre en pause et Arrêter restent visibles et les éléments de Plus fonctionnent.

## [0.7.4] – 2026-11-10

### Un réseau contrôlé plus propre
- **Debian ne cherche plus les journaux de modifications en ligne** : `apt-listchanges` tentait chaque heure de les télécharger depuis `metadata.ftp-master.debian.org` (l’image cloud ne les contient pas), et le journal se remplissait de blocages. Les nouvelles VM Linux l’ont désactivé ; pour celles créées auparavant, utilisez **Réglages › Guest Tools › Requêtes en arrière-plan · Désactiver**.
- **Le trafic local de fond n’apparaît plus dans le journal** : les annonces IPv6 multicast et link-local (`ff02::…`) et les broadcasts de l’interface réseau de la VM, qui ne quittent jamais la VM, ne sont plus affichés par `nido start` ni dans l’onglet Réseau. `nido net log` indique combien de lignes il a masquées ; `nido net log --all` les affiche.

### Images Ubuntu
- **Une liste de sommes de contrôle signée avant la dernière déjà acceptée est refusée** : quiconque proposerait une ancienne liste (mais signée) pour bloquer le cache sur un build précédent est arrêté avant le téléchargement.
- **Si Ubuntu change de clé de signature**, Nido le dit (« signée avec une clé que Nido ne connaît pas », avec l’ID de la clé) au lieu d’un simple « signature non valide ».

### Fenêtre de la VM
- **Dans une fenêtre étroite**, les boutons qui ne tiennent pas (Suspendre, Instantanés, Réglages, Accès depuis Terminal, Activer le mode plein écran) passent dans le menu **Plus** ; Mettre en pause, Reprendre, Démarrer et Arrêter restent toujours visibles.

## [0.7.3] – 2026-11-10

### Réglages avec la VM en marche
- **Le bouton Réglages est aussi là quand la VM est en marche**, dans la fenêtre de la VM et sur sa carte dans la bibliothèque. Le CPU et la mémoire restent verrouillés tant que la VM n’est pas arrêtée ; les actions dans la VM (Guest Tools, **Requêtes en arrière-plan · Désactiver**) s’utilisent justement avec la VM en marche.

## [0.7.2] – 2026-11-09

### Images Ubuntu : signature vérifiée
- **Nido vérifie la signature d’Ubuntu sur la liste des sommes de contrôle** (`SHA256SUMS.gpg`) avant de l’utiliser, au téléchargement comme avec `nido image check`. La clé d’Ubuntu est intégrée à Nido ; `gpg` n’est pas nécessaire. Si la signature manque ou ne correspond pas, Nido ne télécharge pas l’image. L’étape Téléchargement l’indique : « somme de contrôle SHA-256 · signature d’Ubuntu ».
- Debian ne publie pas de signature pour ses images cloud : pour Debian, Nido vérifie toujours la somme de contrôle en HTTPS.

### Un réseau contrôlé plus propre
- **Les requêtes SRV d’apt sont désactivées dans chaque nouvelle VM Linux**, Debian comprise (auparavant, elles apparaissaient dans le journal comme blocages à chaque `apt update`).
- **VM créées auparavant** : Réglages de la VM › Guest Tools › **Requêtes en arrière-plan · Désactiver** applique les mêmes réglages via SSH, avec la VM en marche. Sur Ubuntu, cela désactive aussi snap, les actualités, Ubuntu Pro et la recherche de nouvelles versions.
- Également testé en conditions réelles sur Ubuntu 24.04.

### Corrections
- Cache des images : si la nouvelle image ne peut pas être enregistrée, sa nouvelle somme de contrôle ne reste plus à côté de l’ancienne ; une vérification du cache qui chevauche un téléchargement de la même image ne la télécharge plus une deuxième fois.

## [0.7.1] – 2026-11-09

### Ubuntu plus discret sur le réseau contrôlé
- Les nouvelles VM Ubuntu n’essaient plus de contacter snap (`api.snapcraft.io`), les actualités du message de connexion (`motd.ubuntu.com`), Ubuntu Pro (`contracts.canonical.com`), la recherche de nouvelles versions (`changelogs.ubuntu.com`) ni `entropy.ubuntu.com`, et apt ne demande plus d’enregistrements SRV : le journal réseau ne se remplit plus de blocages. Les paquets, les mises à jour de sécurité et l’horloge fonctionnent comme avant.
- Pour les réactiver dans la VM : `sudo systemctl unmask snapd.service snapd.socket snapd.seeded.service` (et de même pour les autres unités), puis autorisez le domaine depuis l’onglet Réseau.
- Les VM Ubuntu créées auparavant ne changent pas.

### Corrections
- **Images qcow2 plus sûres** : un qcow2 qui utilise deux fois le même cluster, ou qui décrit beaucoup plus de données que le fichier n’en contient, est refusé avant toute écriture sur le disque. Cela ne concerne que `--image-file` avec des fichiers conçus à cet effet ; les images d’Ubuntu fonctionnent comme avant.

## [0.7.0] – 2026-11-09

### Images : nouveaux builds
- **Nido vous prévient quand Debian ou Ubuntu publient un nouveau build** d’une image déjà en cache (en général avec des correctifs de sécurité). Jusqu’ici, la copie téléchargée restait la même pour toujours, sans avertissement.
- Dans l’assistant Nouvelle VM, étape Téléchargement : si l’image est déjà en cache, le bouton **Rechercher un nouveau build** apparaît. S’il y en a un, le bouton Télécharger le récupère, le vérifie et remplace l’ancien.
- Depuis Terminal : `nido image list` (catalogue et cache, sans réseau), `nido image check [id]` et `nido image update <id>`.
- La vérification ne télécharge que la liste des sommes de contrôle, jamais l’image, et ne se lance que si vous la demandez. Les VM déjà créées ne changent pas.

### Corrections
- **`nido ssh` utilise la clé avec laquelle la VM a été créée.** Pour une VM créée avec une clé autre que celles par défaut de `~/.ssh`, il répondait « Permission denied (publickey) ». Cela fonctionne aussi si la clé privée se trouve uniquement dans un agent (un gestionnaire de mots de passe, par exemple). Un `-i` après `--` est toujours essayé.

## [0.6.0] – 2026-11-03

### Réseau contrôlé : de nouveau par défaut
- **Les nouvelles VM démarrent de nouveau sur le réseau contrôlé** (Linux et macOS), et cela fonctionne désormais aussi avec le transfert IP du Mac désactivé, c’est-à-dire avec le réglage par défaut de macOS. L’avertissement de la 0.5.1 sur le transfert IP a disparu : Nido ne lit ni ne modifie plus `net.inet.ip.forwarding`.
- En coulisses, chaque VM contrôlée a son propre `gvproxy`, un petit programme tiers qui assure le NAT à la place de vmnet. Le filtre de Nido décide toujours en premier, pour chaque paquet. Si `gvproxy` ne démarre pas ou s’arrête, la VM reste sans réseau et Nido vous le signale : jamais le NAT d’Apple à sa place.
- `gvproxy` (gvisor-tap-vsock 0.9.0, Apache-2.0) est le seul programme tiers dans Nido : sa version et sa somme de contrôle sont figées, il n’est jamais téléchargé pendant que l’app tourne et il porte la signature de Nido. Les licences et les mentions légales se trouvent dans l’app. Pour un coupe-feu du Mac, le trafic autorisé sort sous le nom `gvproxy`.
- **SSH sur `127.0.0.1`** : `nido ssh`, `nido ip` et les commandes SSH de l’app atteignent une VM contrôlée par un port local (il change à chaque démarrage ; la clé d’hôte reste reconnue). La VM a toujours l’adresse `192.168.127.2`. Les VM sur le NAT d’Apple ne changent pas.
- **Retirer un domaine ferme vraiment les connexions ouvertes dans la VM** : auparavant, le relais les coupait sans que la VM le sache, et un téléchargement en cours restait bloqué ; désormais, la VM reçoit un reset et le programme échoue aussitôt.
- **Liste de base pour macOS** : les nouvelles VM macOS démarrent avec les serveurs d’Apple pour l’activation, la recherche de mises à jour et l’horloge (`albert`, `gdmf`, `mesu`, `swscan`, `swdist`, `time` de `apple.com`), et non plus avec une liste vide : l’Assistant réglages arrive jusqu’au bureau et `softwareupdate --list` fonctionne. Pour télécharger une mise à jour, il faut aussi `updates.cdn-apple.com` et `updates-http.cdn-apple.com` ; l’identifiant Apple, iCloud et l’App Store restent à autoriser à la main.
- **« Saisir dans la VM » tape désormais correctement les caractères avec Maj** (comme `$` et `"` sur un clavier allemand) : auparavant, ils arrivaient dans la VM macOS sans Maj.
- Si une VM contrôlée de la 0.5.x était suspendue, elle repart de zéro (l’état enregistré n’est pas compatible).
- **VM Debian de la 0.5.0 sans les paquets du premier démarrage** : Nido ne les installe pas après coup (cloud-init ne les installe qu’au premier démarrage). Avec la VM en marche et en ligne (`deb.debian.org` figure dans la liste de base), installez-les via SSH : `nido ssh <vm> -- sudo apt-get update`, puis `nido ssh <vm> -- sudo apt-get install -y ca-certificates curl wget git python3 python3-venv python3-pip openssh-server iproute2 procps util-linux jq tar zstd`. Vous pouvez aussi recréer la VM.

## [0.5.1] – 2026-11-02

### Ubuntu Server
- **Ubuntu Server 26.04 LTS et 24.04 LTS** comme systèmes des VM Linux, en plus de Debian 13 : depuis l’assistant Nouvelle VM (vignette Ubuntu Server, avec le choix de la version) ou avec `nido create --image ubuntu-26.04` / `ubuntu-24.04`.
- Les images proviennent de `cloud-images.ubuntu.com` et sont vérifiées avec SHA-256 avant utilisation.
- Ubuntu ne publie les images arm64 qu’au format qcow2 : Nido les convertit lui-même en un disque qui n’occupe que l’espace utilisé, sans outil externe. Cela vaut aussi pour une image locale avec `--image-file`.
- La bibliothèque et `nido list` affichent la distribution de chaque VM.
- Les Guest Tools s’installent aussi sur Ubuntu.
- Liste de base du réseau contrôlé pour Ubuntu : `archive.ubuntu.com`, `security.ubuntu.com`, `ports.ubuntu.com`, plus Ollama et `time.cloudflare.com`. L’horloge des nouvelles VM Ubuntu se synchronise avec `time.cloudflare.com`.

### Réseau contrôlé : désormais un choix
- **Les nouvelles VM démarrent sur le NAT d’Apple.** Avec la 0.5.0, une nouvelle VM sur le réseau contrôlé n’atteignait aucun site, pas même les sites autorisés, sur un Mac aux réglages par défaut : le réseau contrôlé ne fonctionne qu’avec le transfert IP du Mac activé (`net.inet.ip.forwarding`), généralement désactivé. La raison est expliquée dans `docs/SECURITY.md`.
- Le réseau contrôlé s’active dans les réglages de la VM, section Réseau. Les nouvelles VM Linux ont déjà la liste de base, les VM macOS une liste vide.
- Si le transfert IP est désactivé, la confirmation d’activation du réseau contrôlé le signale, et chaque démarrage d’une VM contrôlée affiche un avertissement (`nido start` aussi). Nido lit le réglage mais ne le modifie pas.
- Les VM créées avec la 0.5.0 restent sur le réseau contrôlé : si elles n’atteignent pas Internet, désactivez-le dans les réglages de la VM. Une VM Debian créée sans réseau n’a pas installé les paquets du premier démarrage.

## [0.5.0] – 2026-10-29

### Réseau contrôlé des VM
- **Les nouvelles VM ne sortent sur Internet que vers les domaines autorisés.** Nido se place sur le « câble réseau » de la VM : il répond à ses requêtes DNS et ne laisse passer que les connexions vers les adresses qu’il a résolues pour un domaine de la liste. Tout le reste est bloqué : adresses jamais demandées par nom, DNS vers d’autres serveurs, IPv6, ICMP, les services du Mac (le SSH du Mac vers la VM reste possible).
- Liste de base des VM Linux : `deb.debian.org`, `registry.ollama.ai` et le stockage des modèles d’Ollama, `time.cloudflare.com`. Les VM existantes restent sur le NAT d’Apple jusqu’à ce que vous activiez le réseau contrôlé dans les réglages de la VM, section Réseau.
- Si le réseau contrôlé ne démarre pas, la VM reste sans réseau et Nido vous le signale : jamais le NAT à sa place.
- **Avis** : chaque blocage arrive sous forme de notification de Nido, avec la VM, la destination et le port ; les blocages répétés sont regroupés dans un avis avec leur nombre. Quand l’app est fermée, `nido start` écrit une ligne dans Terminal et l’app affiche les avis à sa prochaine ouverture. Le trafic de fond du démarrage (IPv6 local, broadcast) reste uniquement dans le journal.
- **Autoriser** dans l’avis ajoute le domaine à la liste, avec Touch ID ou le mot de passe du Mac, et s’applique aussitôt, sans redémarrer la VM. Retirer un domaine ne demande rien et coupe aussitôt ses connexions ouvertes ; désactiver le réseau contrôlé demande aussi Touch ID.
- Journal réseau dans la fenêtre de la VM (onglet Réseau) et avec `nido net log` : heure, domaine, adresse, port, octets, résultat. Jamais le contenu du trafic.
- `nido net list|allow|deny|reset` gère la liste depuis Terminal ; `allow` et `reset` demandent Touch ID.
- **Contrôle du nom TLS** : une connexion HTTPS vers une adresse autorisée qui nomme un site non autorisé du même CDN est coupée, et « Autoriser » propose ce nom. C’est un contrôle supplémentaire, pas complet (QUIC et certains navigateurs ne sont pas couverts : voir `docs/SECURITY.md`).
- **VM macOS** : elles ont aussi le réseau contrôlé, mais avec une liste vide : macOS n’atteint pas les services d’Apple (activation, mises à jour, App Store, iCloud) tant que vous ne les autorisez pas. Si l’Assistant réglages s’arrête à l’activation, ajoutez `albert.apple.com` ou désactivez le réseau contrôlé le temps de l’assistant.
- Les VM créées ou modifiées avec cette version ne s’ouvrent pas avec les versions précédentes de Nido.

### Nido Guest Tools 1.4.0
- L’archive d’Ollama est téléchargée par le Mac (version et SHA-256 figés) et envoyée dans la VM (`--archive-stdin`) : la VM ne contacte jamais GitHub. La vue IA affiche le téléchargement sur le Mac, avec Annuler.
- L’archive reste dans `~/Library/Caches/Nido/ollama` ; les anciennes versions ne sont pas supprimées automatiquement.
- L’horloge des nouvelles VM se synchronise avec `time.cloudflare.com`.
- Pour installer Ollama dans une VM existante, il faut les Guest Tools 1.4.0 : réinstallez-les depuis les réglages de la VM.

## [0.4.0] – 2026-10-27

### VM macOS
- **Créez une VM macOS à partir d’un fichier IPSW** de votre choix (Nido ne télécharge rien et ne modifie pas le fichier) : depuis l’assistant Nouvelle VM ou avec `nido create --ipsw`. Avant de créer le moindre fichier, Nido vérifie que l’image convient à ce Mac.
- L’installation dure de 4 à 20 minutes selon le Mac et le disque, avec sa progression et Annuler ; si elle est interrompue, aucune VM à moitié créée ne subsiste.
- La fenêtre de la VM affiche l’écran de macOS. Fermer la fenêtre devrait laisser la VM en marche (à vérifier).
- **Accès depuis Terminal** : un panneau vous guide pour activer Session à distance et autoriser votre clé ; **Saisir dans la VM** tape la commande dans le Terminal du système invité (sans appuyer sur Retour). Ensuite, `nido ssh` se connecte avec le compte indiqué à la création. Testé en conditions réelles avec macOS 26.6.2 (clavier allemand) : la commande utilise `"$HOME"` au lieu de `~`, qui sur certains claviers ne s’obtient qu’avec une touche morte.
- La suspension, les instantanés d’une VM arrêtée, la restauration et le clonage fonctionnent aussi pour macOS (testés avec un vrai IPSW) ; l’instantané d’une VM en marche depuis l’app reste à vérifier ; le clone reçoit un nouvel identifiant et affiche les étapes à effectuer une fois dans la copie (clés d’hôte SSH et nom de l’ordinateur).
- Dossiers partagés (en lecture seule par défaut, dans `/Volumes/My Shared Files`) et sortie audio : configurés, mais encore à vérifier dans le système invité. Ni presse-papiers partagé ni micro.
- Les Guest Tools, le moniteur, le provisionnement, Ollama, le pont IA et les modèles de VM restent réservés à Linux.

### Linux et app
- Un premier démarrage Linux interrompu ne laisse plus la VM sans accès SSH : les clés d’hôte manquantes sont régénérées à chaque démarrage.
- Si vous quittez Nido pendant la première minute du premier démarrage, l’app vous le signale.
- `nido list` affiche la colonne SYSTÈME.

## [0.3.1] – 2026-10-26

### Conversation avec les modèles d’IA locaux
- Les liens web des réponses s’ouvrent dans le navigateur ; les adresses qui masquent leur destination, celles qui visent le Mac lui-même et tout autre type d’adresse restent du texte.
- Chaque réponse indique le modèle qui l’a écrite.
- **Effacer la conversation** demande confirmation avant de tout effacer.
- Si Ollama est arrêté, la conversation vous invite à le démarrer avec **Démarrer**.

### Sécurité et fiabilité
- Le pont IA se ferme avec la VM : quand vous arrêtez ou suspendez la VM, les requêtes en cours vers Hugging Face sont annulées aussitôt et ne consomment plus de budget.
- Les erreurs de Hugging Face parviennent à la VM sans données de votre compte : seulement le code et une explication fixe.
- La clé SSH de chaque VM est liée à la VM et non à son adresse : si l’adresse change, Nido exige la même clé.
- Les connexions du pont en attente n’occupent plus de threads du Mac.

### Nido Guest Tools 1.3.0
- Les services dans la VM tournent avec des restrictions système plus strictes.
- Les mises à jour suppriment les fichiers que la nouvelle version n’utilise plus.
- Un Ollama arrêté reste arrêté même après un redémarrage de la VM, jusqu’à ce que vous le démarriez, le redémarriez, le réinstalliez ou le mettiez à jour.
- Réinstallez les Guest Tools depuis les réglages de la VM pour en bénéficier dans les VM existantes.

## [0.3.0] – 2026-10-26

### Conversation avec les modèles d’IA locaux
- Les réponses affichent la mise en forme Markdown : **gras**, *italique*, `code`, listes, titres, citations et blocs de code.
- La réponse arrive sans scintillement et la conversation la suit ; si vous faites défiler vers le haut, elle reste où vous êtes et **Aller à la fin** apparaît.
- **Copier** place une réponse dans le presse-papiers, telle que le modèle l’a écrite.
- Sous chaque réponse : sa durée et le nombre de jetons par seconde générés par le modèle.
- Vous voyez tout de suite quand le modèle prépare sa réponse ; **Interrompre** (ou Échap) l’arrête.
- La conversation reste dans la VM et en mémoire : Nido ne l’enregistre pas sur le Mac et Ollama n’est pas joignable de l’extérieur.

### Intelligence artificielle dans les VM
- Nouvelles VM Debian prêtes à l’emploi : paquets essentiels et Nido Guest Tools au premier démarrage.
- Ollama et les modèles d’IA choisis s’installent dans la VM en un clic, avec version et somme de contrôle vérifiées.
- Moniteur de la VM : CPU, mémoire, disque et alertes, lus depuis la VM sans réseau.
- Pont IA facultatif vers Hugging Face : le jeton reste dans le trousseau, jamais dans la VM ; limites de jetons et de requêtes pour chaque VM et un journal sans contenu.
- Modèles de VM : enregistrez une VM comme modèle et créez-en de nouvelles à partir de celui-ci.

### Machines virtuelles
- Instantanés, suspension et reprise avec l’état de la mémoire.
- Clonez une VM arrêtée.
- Dossiers partagés : aucun par défaut, en lecture seule sauf choix contraire, révocables à tout moment même quand la VM est en marche ; les clones et les modèles n’en héritent pas.
- Rosetta pour exécuter des programmes x86-64 dans les VM Linux.
- Un avertissement quand la mémoire des VM en marche dépasse ce que le Mac peut fournir, et le redémarrage automatique d’une VM bloquée par une panique du noyau.

### Terminal
- `nido --version`, `nido template` et `nido create --from-template`.

### Corrections
- Les modifications de la configuration d’une VM faites en même temps depuis l’app et depuis Terminal ne s’annulent plus mutuellement.
- Le pont IA libère ses connexions quand le Mac ferme son côté (Guest Tools 1.2.1 : réinstallez-les dans les VM existantes).

## [0.2.0] – 2026-10-23

### Première version de l’app
- Bibliothèque des VM avec leur état en temps réel.
- Assistant de création de VM Debian.
- Fenêtre de la VM avec écran, console série, pause et reprise.
- Réglages des VM et de Nido.

## [0.1.0] – 2026-10-23

### Commande `nido`
- `nido create`, `list`, `start`, `stop`, `ip`, `ssh` et `delete`.
- Images Debian téléchargées uniquement depuis des sources admises et vérifiées avec SHA-512.
- Accès aux VM uniquement par clé SSH.
