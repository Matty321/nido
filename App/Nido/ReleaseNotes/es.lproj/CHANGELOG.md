# Novedades de Nido

Todas las versiones de Nido, de la más reciente a la más antigua. La primera vez que Nido se abre tras una actualización, muestra las novedades de la versión instalada (para volver a verlas, elige Ayuda › Novedades de Nido).

## [0.8.1] – 2026-11-14

### Idiomas
- **El idioma de Nido se elige en Ajustes › General › Idioma**: inglés, italiano, alemán, español, francés o igual que el sistema. Nido se cierra y se vuelve a abrir en el idioma nuevo; si hay una VM en ejecución, antes pregunta qué hacer con ella, como al salir. Es el mismo ajuste que Ajustes del Sistema › General › Idioma y región › Apps.

### Biblioteca
- **Cada VM tiene su propio color**: su símbolo en la biblioteca muestra el logotipo del sistema (la espiral de Debian, el logotipo de Apple para macOS; Ubuntu conserva su letra) sobre uno de ocho tonos discretos. El asistente Nueva VM propone un color que ninguna otra VM tiene; puedes cambiarlo cuando quieras en **Ajustes › General › Color**.

### Correcciones
- **Las tarjetas de sistema del asistente Nueva VM quedan alineadas**: un nombre o un detalle en dos líneas (“Ubuntu Server”, las traducciones más largas) ya no hace su tarjeta más alta que las demás ni las desplaza.

## [0.8.0] – 2026-11-13

### Idiomas
- **Nido ya habla inglés, italiano, alemán, español y francés**: la app, el comando `nido`, las notas de la versión y el README. El inglés es el idioma base. La app sigue el idioma que usas en macOS y, con cualquier otro idioma, se muestra en inglés.
- El comando `nido` sigue el idioma del sistema. Con `NIDO_LANGUAGE` (`en`, `it`, `de`, `es` o `fr`) eliges otro, por ejemplo en scripts que leen su salida.

### Nido Guest Tools 1.5.0
- **Los mensajes sobre Ollama y los modelos aparecen en tu idioma**: las Guest Tools envían un código fijo con cada error y cada aviso, y la app muestra su propio texto. Las Guest Tools anteriores siguen enviando sus mensajes en italiano, y Nido los muestra tal como llegan: reinstala las Guest Tools desde los ajustes de la VM para tener la nueva versión en las VM existentes.

### El comando nido en el menú
- **Nido › Instalar el comando nido…** crea `~/.local/bin/nido`, un enlace al comando, que ahora está dentro de la app (junto con `gvproxy`): el comando se actualiza con la app. Si `~/.local/bin` no está en tu `PATH`, Nido te lo indica. Una copia instalada antes con `scripts/install.sh` solo se sustituye después de que lo confirmes.
- **Nido › Eliminar el comando nido** elimina el enlace solo si apunta a Nido.
- Si abres Nido directamente desde el DMG, no instala el comando y te pide que primero lo muevas a Aplicaciones.

### Actualizaciones
- **Nido › Buscar actualizaciones…** comprueba si hay una nueva versión. Nido nunca se conecta a la red por su cuenta: la comprobación automática solo se activa si tú lo eliges (cuando te lo pregunta la segunda vez que abres Nido, o en **Ajustes › General › Buscar actualizaciones automáticamente**, desactivada por omisión).
- **Nunca con una VM en ejecución**: mientras haya una VM en ejecución, en la app o con `nido start`, la actualización descargada espera. Se instala al salir de Nido si no hay ninguna VM en ejecución, y un aviso indica qué VM la están bloqueando.
- Cada actualización está firmada (EdDSA) y se descarga por HTTPS; Nido rechaza una actualización o una lista de versiones sin una firma válida.

### Firma Developer ID
- **Nido está firmado con un certificado Developer ID y notarizado por Apple**: se abre sin tener que sortear Gatekeeper. La app, el comando `nido`, `gvproxy` y Sparkle llevan la misma firma, con Hardened Runtime.
- Junto al DMG están las sumas de control SHA-256 y la lista de componentes (SBOM, SPDX).

### Llavero
- **Tras el cambio de firma, puede que macOS vuelva a pedir acceso al token de Hugging Face** guardado en el Llavero. Basta con permitirlo una vez; si el token ya no se puede leer, vuelve a introducirlo en **Ajustes › Hugging Face**.

### Seguridad
- **Una VM ya no puede cerrar Nido**: los valores fuera de rango enviados por el sistema invitado (los porcentajes del monitor, el tamaño y el progreso de los modelos de Ollama) cerraban la app y, con ella, todas las VM en ejecución. Ahora se limitan antes de mostrarse.
- **El chat y la consola ya no bloquean la app**: una respuesta del chat local o una salida de la consola preparadas para ralentizar Nido se leen por partes y en tiempo lineal, sin frenar las demás VM. Las respuestas del chat también tienen un límite de tamaño.
- **La dirección de las actualizaciones es siempre la de Nido**: un valor que quede en las preferencias de la app ya no puede sustituirla. Las actualizaciones seguían estando firmadas de todos modos.

## [0.7.6] – 2026-11-10

### Imágenes
- **`nido image check` muestra la compilación de Debian** comprobada, por ejemplo `debian-13: actualizada (compilación 20261103-2651)`; `nido image update` indica qué compilación ha descargado.
- **`nido image reset <id>`** olvida la compilación y la firma ya aceptadas de una imagen, tras una confirmación. Solo hace falta si Nido sigue rechazando una lista “más antigua que la ya aceptada”; el mensaje de rechazo ahora lo indica, en lugar de señalar un archivo que había que eliminar a mano. La imagen en la caché se conserva.

### Red controlada
- La sugerencia **Desactivar** de la pestaña Red y el recuento de líneas de tráfico local oculto están cubiertos por una prueba de la interfaz.

## [0.7.5] – 2026-11-10

### Red controlada
- **La pestaña Red propone desactivar las solicitudes en segundo plano** en las VM Linux creadas antes de Nido 0.7.4: **Desactivar** las detiene al momento (con la VM en ejecución) y **Ahora no** deja de preguntarlo para esa VM. La opción sigue estando en Ajustes › Guest Tools.
- **La pestaña Red indica cuántas líneas de tráfico local de fondo oculta** (multicast y link-local de IPv6, broadcast) y cómo verlas con `nido net log --all`.

### Imágenes
- **Debian: compilación comprobada.** Nido también lee el manifiesto de la compilación que Debian publica junto a la imagen y, antes de la descarga, rechaza archivos incoherentes o una compilación más antigua que la ya aceptada. Debian no firma sus imágenes cloud: no es una firma, pero frena una copia antigua servida de nuevo.
- **Ubuntu: lista para un cambio de clave.** Nido puede aceptar la clave de firma actual y la anunciada como siguiente, para que un cambio de clave no bloquee las descargas.

### Ventana de la VM
- La barra compacta (menú **Más**) está cubierta por una prueba de la interfaz: con la ventana estrecha, Pausar y Detener siguen a la vista y las opciones de Más funcionan.

## [0.7.4] – 2026-11-10

### Una red controlada más limpia
- **Debian ya no busca los registros de cambios en la red**: `apt-listchanges` intentaba descargarlos cada hora desde `metadata.ftp-master.debian.org` (la imagen cloud no los incluye) y el registro se llenaba de bloqueos. Las VM Linux nuevas lo tienen desactivado; para las creadas antes, basta con **Ajustes › Guest Tools › Solicitudes en segundo plano · Desactivar**.
- **El tráfico local de fondo ya no aparece en el registro**: `nido start` ya no imprime los anuncios multicast y link-local de IPv6 (`ff02::…`) ni los broadcasts de la interfaz de red de la VM, que nunca salen de la VM, y la pestaña Red ya no los muestra. `nido net log` indica cuántas líneas ha ocultado; `nido net log --all` las muestra.

### Imágenes de Ubuntu
- **Se rechaza una lista de sumas de control firmada antes que la última ya aceptada**: quien sirviera una lista antigua (pero firmada) para mantener la caché en una compilación anterior queda bloqueado antes de la descarga.
- **Si Ubuntu cambia la clave de firma**, Nido lo indica (“firmada con una clave que Nido no conoce”, con el ID de la clave) en lugar de un genérico “firma no válida”.

### Ventana de la VM
- **Con la ventana estrecha**, los botones que no caben (Suspender, Instantáneas, Ajustes, Acceso desde Terminal, Usar pantalla completa) pasan al menú **Más**; Pausar, Reanudar, Iniciar y Detener siempre están a la vista.

## [0.7.3] – 2026-11-10

### Ajustes con la VM en ejecución
- **El botón Ajustes también está disponible con la VM en ejecución**, en la ventana de la VM y en su tarjeta de la biblioteca. La CPU y la memoria siguen bloqueadas hasta que la VM se detiene; las acciones dentro de la VM (Guest Tools, **Solicitudes en segundo plano · Desactivar**) son precisamente para usarlas con la VM en ejecución.

## [0.7.2] – 2026-11-09

### Imágenes de Ubuntu: firma verificada
- **Nido verifica la firma de Ubuntu en la lista de sumas de control** (`SHA256SUMS.gpg`) antes de usarla, tanto en la descarga como con `nido image check`. La clave de Ubuntu viene dentro de Nido; no necesitas `gpg`. Si falta la firma o no coincide, Nido no descarga la imagen. El paso Descarga lo indica: “suma de control SHA-256 · firma de Ubuntu”.
- Debian no publica una firma para sus imágenes cloud: en su caso se mantiene la verificación de la suma de control por HTTPS.

### Una red controlada más limpia
- **Las consultas SRV de apt están desactivadas en todas las VM Linux nuevas**, también en Debian (antes aparecían en el registro como bloqueos en cada `apt update`).
- **VM creadas antes**: Ajustes de la VM › Guest Tools › **Solicitudes en segundo plano · Desactivar** aplica los mismos ajustes por SSH, con la VM en ejecución. En Ubuntu también desactiva snap, las noticias, Ubuntu Pro y la comprobación de nuevas versiones.
- Probado en vivo también en Ubuntu 24.04.

### Correcciones
- Caché de imágenes: si la imagen nueva no se puede guardar, su nueva suma de control ya no se queda junto a la antigua; una comprobación de la caché que coincide con una descarga de la misma imagen ya no la descarga por segunda vez.

## [0.7.1] – 2026-11-09

### Ubuntu, más silenciosa en la red controlada
- Las VM Ubuntu nuevas ya no intentan contactar con snap (`api.snapcraft.io`), las noticias del mensaje de inicio de sesión (`motd.ubuntu.com`), Ubuntu Pro (`contracts.canonical.com`), la comprobación de nuevas versiones (`changelogs.ubuntu.com`) ni `entropy.ubuntu.com`, y apt ya no pide registros SRV: el registro de red ya no se llena de bloqueos. Los paquetes, las actualizaciones de seguridad y el reloj funcionan como antes.
- Para reactivarlos en la VM: `sudo systemctl unmask snapd.service snapd.socket snapd.seeded.service` (y lo mismo con las demás unidades); luego permite el dominio desde la pestaña Red.
- Las VM Ubuntu creadas antes no cambian.

### Correcciones
- **Imágenes qcow2 más seguras**: un qcow2 que usa dos veces el mismo clúster, o que describe muchos más datos de los que contiene el archivo, se rechaza antes de escribir nada en el disco. Solo afecta a `--image-file` con archivos preparados a propósito; las imágenes de Ubuntu funcionan como antes.

## [0.7.0] – 2026-11-09

### Imágenes: nuevas compilaciones
- **Nido avisa cuando Debian o Ubuntu publican una nueva compilación** de una imagen que ya está en la caché (normalmente con correcciones de seguridad). Antes, la copia descargada se quedaba así para siempre, sin aviso.
- En el asistente Nueva VM, paso Descarga: si la imagen ya está en la caché, aparece **Buscar una nueva compilación**. Si hay una, el botón Descargar la obtiene, la verifica y sustituye a la antigua.
- Desde Terminal: `nido image list` (catálogo y caché, sin red), `nido image check [id]` y `nido image update <id>`.
- La comprobación solo descarga la lista de sumas de control, nunca la imagen, y solo se hace cuando la pides. Las VM ya creadas no cambian.

### Correcciones
- **`nido ssh` usa la clave con la que se creó la VM.** Con una VM creada con una clave distinta de las predeterminadas de `~/.ssh`, respondía “Permission denied (publickey)”. Funciona igual si la clave privada solo está en un agente (por ejemplo, un gestor de contraseñas). Un `-i` después de `--` se sigue probando.

## [0.6.0] – 2026-11-03

### Red controlada: de nuevo por omisión
- **Las VM nuevas vuelven a arrancar en la red controlada** (Linux y macOS), y ahora también funciona con el reenvío IP del Mac desactivado, es decir, con el ajuste por omisión de macOS. El aviso de la 0.5.1 sobre el reenvío IP ya no existe: Nido ya no lee ni cambia `net.inet.ip.forwarding`.
- Entre bastidores, cada VM controlada tiene su propio `gvproxy`, un pequeño programa de terceros que hace de NAT en lugar de vmnet. El filtro de Nido sigue decidiendo primero, paquete a paquete. Si `gvproxy` no se inicia o se detiene, la VM se queda sin red y Nido lo indica: nunca el NAT de Apple en su lugar.
- `gvproxy` (gvisor-tap-vsock 0.9.0, Apache-2.0) es el único programa de terceros dentro de Nido: su versión y su suma de control están fijadas, nunca se descarga mientras la app está abierta y lleva la firma de Nido. Las licencias y los avisos legales están en la app. Para un cortafuegos del Mac, el tráfico permitido sale como `gvproxy`.
- **SSH en `127.0.0.1`**: `nido ssh`, `nido ip` y los comandos SSH de la app llegan a una VM controlada a través de un puerto local (cambia en cada arranque; la clave del host se sigue reconociendo). La VM siempre tiene la dirección `192.168.127.2`. Las VM en el NAT de Apple no cambian.
- **Quitar un dominio cierra de verdad las conexiones abiertas en la VM**: antes, el retransmisor las cortaba sin que la VM lo supiera, y una descarga en curso se quedaba colgada; ahora la VM recibe un reset y el programa da error al instante.
- **Lista básica para macOS**: las VM macOS nuevas empiezan con los servidores de Apple para la activación, la comprobación de actualizaciones y el reloj (`albert`, `gdmf`, `mesu`, `swscan`, `swdist`, `time` de `apple.com`), ya no con la lista vacía: el Asistente de Configuración llega al escritorio y `softwareupdate --list` funciona. Para descargar una actualización también hacen falta `updates.cdn-apple.com` y `updates-http.cdn-apple.com`; el ID de Apple, iCloud y el App Store hay que seguir permitiéndolos a mano.
- **“Escribir en la VM” ahora escribe bien los caracteres con Mayúsculas** (como `$` y `"` en un teclado alemán): antes llegaban a la VM macOS sin Mayúsculas.
- Si una VM controlada de la 0.5.x estaba suspendida, arranca desde cero (el estado guardado no es compatible).
- **VM Debian de la 0.5.0 sin los paquetes del primer arranque**: Nido no los instala más tarde (cloud-init solo los instala en el primer arranque). Con la VM en ejecución y con red (`deb.debian.org` está en la lista básica), instálalos por SSH: `nido ssh <vm> -- sudo apt-get update` y luego `nido ssh <vm> -- sudo apt-get install -y ca-certificates curl wget git python3 python3-venv python3-pip openssh-server iproute2 procps util-linux jq tar zstd`. También puedes volver a crear la VM.

## [0.5.1] – 2026-11-02

### Ubuntu Server
- **Ubuntu Server 26.04 LTS y 24.04 LTS** como sistemas de las VM Linux, además de Debian 13: desde el asistente Nueva VM (recuadro Ubuntu Server, con la elección de versión) o con `nido create --image ubuntu-26.04` / `ubuntu-24.04`.
- Las imágenes llegan de `cloud-images.ubuntu.com` y se verifican con SHA-256 antes de usarlas.
- Ubuntu solo publica las imágenes arm64 en formato qcow2: Nido las convierte por su cuenta en un disco disperso, sin herramientas externas. También vale para una imagen local con `--image-file`.
- La biblioteca y `nido list` muestran la distribución de cada VM.
- Las Guest Tools también se pueden instalar en Ubuntu.
- Lista básica de la red controlada para Ubuntu: `archive.ubuntu.com`, `security.ubuntu.com`, `ports.ubuntu.com`, además de Ollama y `time.cloudflare.com`. El reloj de las VM Ubuntu nuevas se sincroniza con `time.cloudflare.com`.

### Red controlada: ahora es opcional
- **Las VM nuevas arrancan en el NAT de Apple.** Con la 0.5.0, una VM nueva en la red controlada no llegaba a ningún sitio, ni siquiera a los permitidos, en un Mac con los ajustes por omisión: la red controlada solo funciona con el reenvío IP del Mac activado (`net.inet.ip.forwarding`), que suele estar desactivado. El motivo se explica en `docs/SECURITY.md`.
- La red controlada se activa en los ajustes de la VM, sección Red. Las VM Linux nuevas ya tienen preparada la lista básica; las de macOS, una lista vacía.
- Si el reenvío IP está desactivado, la confirmación para activar la red controlada lo indica, y cada arranque de una VM controlada muestra un aviso (también `nido start`). Nido lee el ajuste, pero no lo cambia.
- Las VM creadas con la 0.5.0 siguen en la red controlada: si no llegan a internet, desactívala en los ajustes de la VM. Una VM Debian creada sin red no ha instalado los paquetes del primer arranque.

## [0.5.0] – 2026-10-29

### Red controlada de las VM
- **Las VM nuevas solo salen a internet hacia los dominios permitidos.** Nido se sitúa en el “cable de red” de la VM: responde a sus consultas DNS y solo deja pasar las conexiones hacia las direcciones que ha resuelto para un dominio de la lista. Todo lo demás se bloquea: direcciones nunca pedidas por nombre, DNS hacia otros servidores, IPv6, ICMP, los servicios del Mac (el SSH del Mac a la VM sigue funcionando).
- Lista básica de las VM Linux: `deb.debian.org`, `registry.ollama.ai` y el almacén de modelos de Ollama, `time.cloudflare.com`. Las VM existentes siguen en el NAT de Apple hasta que actives la red controlada en los ajustes de la VM, sección Red.
- Si la red controlada no se inicia, la VM se queda sin red y Nido lo indica: nunca el NAT en su lugar.
- **Avisos**: cada bloqueo llega como notificación de Nido, con la VM, el destino y el puerto; los bloqueos repetidos se agrupan en un aviso con el recuento. Con la app cerrada, `nido start` escribe una línea en Terminal y la app muestra los avisos la próxima vez que se abre. El tráfico de red de fondo del arranque (IPv6 local, broadcast) solo queda en el registro.
- **Permitir** en el aviso añade el dominio a la lista, con Touch ID o la contraseña del Mac, y se aplica al momento, sin reiniciar la VM. Quitar un dominio no pide nada y corta al momento sus conexiones abiertas; desactivar la red controlada también pide Touch ID.
- Registro de red en la ventana de la VM (pestaña Red) y con `nido net log`: hora, dominio, dirección, puerto, bytes, resultado. Nunca el contenido del tráfico.
- `nido net list|allow|deny|reset` gestiona la lista desde Terminal; `allow` y `reset` piden Touch ID.
- **Comprobación del nombre TLS**: una conexión HTTPS hacia una dirección permitida que nombra un sitio no permitido de la misma CDN se corta, y “Permitir” ofrece ese nombre. Es una comprobación adicional, no completa (QUIC y algunos navegadores no están cubiertos: consulta `docs/SECURITY.md`).
- **VM macOS**: también usan la red controlada, pero con la lista vacía: macOS no llega a los servicios de Apple (activación, actualizaciones, App Store, iCloud) hasta que los permitas. Si el Asistente de Configuración se detiene en la activación, añade `albert.apple.com` o desactiva la red controlada mientras dure el asistente.
- Las VM creadas o modificadas con esta versión no se abren con versiones anteriores de Nido.

### Nido Guest Tools 1.4.0
- El archivo de Ollama lo descarga el Mac (versión y SHA-256 fijados) y lo envía a la VM (`--archive-stdin`): la VM nunca contacta con GitHub. La vista de IA muestra la descarga en el Mac, con Cancelar.
- El archivo se queda en `~/Library/Caches/Nido/ollama`; las versiones antiguas no se eliminan solas.
- El reloj de las VM nuevas se sincroniza con `time.cloudflare.com`.
- Para instalar Ollama en una VM existente necesitas las Guest Tools 1.4.0: reinstálalas desde los ajustes de la VM.

## [0.4.0] – 2026-10-27

### VM macOS
- **Crea una VM macOS a partir de un archivo IPSW** que elijas tú (Nido no descarga nada ni toca el archivo): desde el asistente Nueva VM o con `nido create --ipsw`. Antes de crear ningún archivo, comprueba que la imagen sea adecuada para este Mac.
- La instalación dura de 4 a 20 minutos, según el Mac y el disco, con progreso y Cancelar; si se interrumpe, no queda ninguna VM a medias.
- La ventana de la VM muestra la pantalla de macOS. Cerrar la ventana debería dejar la VM en ejecución (pendiente de verificar).
- **Acceso desde Terminal**: un panel te guía para activar Sesión remota y autorizar tu clave; **Escribir en la VM** escribe el comando en la app Terminal del sistema invitado (sin pulsar Retorno). Después, `nido ssh` entra con la cuenta indicada al crear la VM. Probado en vivo con macOS 26.6.2 (teclado alemán): el comando usa `"$HOME"` en lugar de `~`, que en algunos teclados solo se escribe con una tecla muerta.
- La suspensión, las instantáneas con la VM detenida, la restauración y la clonación también funcionan con macOS (probadas con un IPSW real); la instantánea con la VM en ejecución desde la app está pendiente de verificar; el clon recibe un identificador nuevo y muestra los pasos que hay que dar una vez en la copia (claves de host SSH y nombre del ordenador).
- Carpetas compartidas (solo lectura por omisión, dentro de `/Volumes/My Shared Files`) y salida de audio, configuradas pero pendientes de verificar en el sistema invitado. Sin portapapeles compartido ni micrófono.
- Las Guest Tools, el monitor, el aprovisionamiento, Ollama, el puente de IA y las plantillas de VM siguen siendo solo para Linux.

### Linux y la app
- Un primer arranque de Linux interrumpido ya no deja la VM sin acceso SSH: las claves de host que faltan se regeneran en cada arranque.
- Si sales de Nido durante el primer minuto del primer arranque, la app te avisa.
- `nido list` muestra la columna SISTEMA.

## [0.3.1] – 2026-10-26

### Chat con los modelos locales
- Los enlaces web de las respuestas se abren en el navegador; las direcciones que ocultan su destino, las que apuntan al propio Mac y cualquier otro tipo de dirección se quedan como texto.
- Cada respuesta indica el modelo que la ha escrito.
- **Borrar chat** pide confirmación antes de perder la conversación.
- Si Ollama está detenido, el chat te dice que lo inicies con **Iniciar**.

### Seguridad y fiabilidad
- El puente de IA se cierra con la VM: al detener o suspender la VM, las solicitudes a Hugging Face en curso se cancelan al momento y no consumen más presupuesto.
- Los errores de Hugging Face llegan a la VM sin datos de tu cuenta: solo el código y una explicación fija.
- La clave SSH de cada VM está ligada a la VM y no a su dirección: si la dirección cambia, Nido exige la misma clave.
- Las conexiones del puente en espera ya no ocupan hilos del Mac.

### Nido Guest Tools 1.3.0
- Los servicios de la VM se ejecutan con restricciones del sistema más estrictas.
- Las actualizaciones eliminan los archivos que la nueva versión ya no usa.
- Ollama detenido sigue detenido incluso tras reiniciar la VM, hasta que lo inicies, lo reinicies, lo reinstales o lo actualices.
- Reinstala las Guest Tools desde los ajustes de la VM para tenerlas en las VM existentes.

## [0.3.0] – 2026-10-26

### Chat con los modelos locales
- Las respuestas muestran el formato Markdown: **negrita**, *cursiva*, `código`, listas, títulos, citas y bloques de código.
- La respuesta llega sin parpadeos y la conversación la sigue; si te desplazas hacia arriba, se queda donde estás y aparece **Ir al final**.
- **Copiar** lleva una respuesta al portapapeles, tal como la ha escrito el modelo.
- Debajo de cada respuesta: cuánto ha tardado y cuántos tokens por segundo ha generado el modelo.
- Mientras el modelo prepara la respuesta, lo ves enseguida; **Detener** (o Esc) la interrumpe.
- El chat se queda en la VM y en la memoria: Nido no lo guarda en el Mac y no se puede acceder a Ollama desde fuera.

### Inteligencia artificial en las VM
- Nuevas VM Debian listas para usar: paquetes esenciales y Nido Guest Tools en el primer arranque.
- Ollama y los modelos que elijas se instalan en la VM con un clic, con versión y suma de control verificadas.
- Monitor de la VM: CPU, memoria, disco y alertas, leídos desde la VM sin red.
- Puente de IA opcional hacia Hugging Face: el token se queda en el Llavero, nunca en la VM; límites de tokens y solicitudes para cada VM y un registro sin contenidos.
- Plantillas de VM: guarda una VM como plantilla y crea otras nuevas a partir de ella.

### Máquinas virtuales
- Instantáneas, suspensión y reanudación con el estado de la memoria.
- Clona una VM detenida.
- Carpetas compartidas: ninguna por omisión, de solo lectura salvo que elijas otra cosa, revocables al momento incluso con la VM en ejecución; los clones y las plantillas no las heredan.
- Rosetta para ejecutar programas x86-64 en las VM Linux.
- Aviso cuando la memoria de las VM en ejecución supera la que puede ofrecer el Mac, y reinicio automático de una VM bloqueada por un pánico del kernel.

### Terminal
- `nido --version`, `nido template` y `nido create --from-template`.

### Correcciones
- Los cambios en la configuración de una VM hechos a la vez desde la app y desde Terminal ya no se anulan entre sí.
- El puente de IA libera las conexiones cuando el Mac cierra su lado (Guest Tools 1.2.1: reinstálalas en las VM existentes).

## [0.2.0] – 2026-10-23

### Primera versión de la app
- Biblioteca de VM con el estado en tiempo real.
- Asistente para crear VM Debian.
- Ventana de la VM con pantalla, consola serie, pausa y reanudación.
- Ajustes de la VM y de Nido.

## [0.1.0] – 2026-10-23

### Comando `nido`
- `nido create`, `list`, `start`, `stop`, `ip`, `ssh` y `delete`.
- Imágenes de Debian descargadas solo de fuentes admitidas y verificadas con SHA-512.
- Acceso a las VM solo con clave SSH.
