# Entwickeln und prüfen

## Voraussetzungen

- macOS mit Xcode 26.1 oder neuer und einem iOS-Simulator.
- Für die Installation auf einem iPhone: eigenes Entwicklerteam und eingerichtete Signierung.
- Für den optionalen lokalen SSH-Testserver: Python 3 und Paramiko in einer virtuellen Umgebung.

Das Xcode-Projekt bindet die lokale Citadel-Fassung aus `Vendor/Citadel` und SwiftTerm über Swift Package Manager ein. `swift-log` ist für Xcode 26.1 auf 1.6.4 begrenzt. Die aufgelösten Abhängigkeiten stehen in `SSHClient.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`.

## Build

```sh
xcodebuild -project SSHClient.xcodeproj -scheme SSHClient \
  -destination 'generic/platform=iOS' \
  -skipPackagePluginValidation CODE_SIGNING_ALLOWED=NO build
```

Der Parameter zur Plugin-Prüfung ist für den automatisierten Build vorgesehen. Das SwiftTerm-Plugin erzeugt Versionsinformationen. In Xcode kann das Plugin nach Prüfung einmal freigegeben werden.

Für die Installation auf einem echten iPhone die Signierung in Xcode konfigurieren und **Run** verwenden. Die öffentliche Projektdatei enthält kein persönliches Entwicklerteam. Die Face-ID-Beschreibung ist bereits in `Config/Info.plist` enthalten.

## Tests

Das Standardschema **SSHClient** führt die Unit-Tests aus und überspringt den SSH-Integrationstest sowie die Dokumentationsbilder. Der Integrationstest wird mit dem Schema **SSHIntegration** aktiviert.

Lokalen Testserver starten:

```sh
python3 -m venv /tmp/pi-terminal-test
/tmp/pi-terminal-test/bin/pip install paramiko
/tmp/pi-terminal-test/bin/python Scripts/ssh_fixture.py
```

In einem zweiten Terminal:

```sh
xcodebuild -project SSHClient.xcodeproj -scheme SSHIntegration \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -skipPackagePluginValidation CODE_SIGN_IDENTITY=- test
```

Bei Bedarf den Simulatornamen durch ein installiertes Gerät ersetzen. Die Ad-hoc-Signierung ist für den Schlüsselbund im Simulator erforderlich.

Der Testserver lauscht ausschließlich auf `127.0.0.1:22222`. Benutzer `fixture`, Passwort `simulator-only` und der deterministische Testschlüssel sind ausschließlich öffentliche Testdaten. Sie gehören nicht auf echte Geräte. Ein zweiter Testbenutzer simuliert die SSH-Authentifizierung `none`; dies prüft den Protokollpfad, nicht den Tailscale-VPN-Dienst oder eine reale SSO-Freigabe.

Der Integrationstest prüft Server-Pinning und Schlüsseländerungen, Passwort- und Schlüsselanmeldung, Banner, `none`-Authentifizierung, dauerhafte Shell, UTF-8, Here-Documents, den tatsächlichen Editorversand, Terminalgröße und Wiederverbinden. Die Testdaten und die vorübergehenden Host-Pins werden nach dem Test zurückgesetzt.

## Dokumentationsbilder neu erzeugen

Mit laufendem Testserver:

```sh
xcodebuild -project SSHClient.xcodeproj -scheme Documentation \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -skipPackagePluginValidation CODE_SIGN_IDENTITY=- test
```

Das Schema aktiviert zusätzlich `DocumentationScreenshots`. Die Bilder werden aus den echten SwiftUI-/UIKit-Ansichten gerendert. Die Geräteübersicht nutzt synthetische Hostnamen; die Terminalansicht nutzt den Loopback-Testserver. Es werden weder persönliche Profile noch biometrische Schlüssel verwendet.

Die erzeugten PNGs aus dem Simulator-App-Container übernehmen:

```sh
PI_TERMINAL_CONTAINER=$(xcrun simctl get_app_container booted de.michaelhein.SSHClient data)
cp "$PI_TERMINAL_CONTAINER/Documents/documentation-screenshots/devices.png" docs/images/
cp "$PI_TERMINAL_CONTAINER/Documents/documentation-screenshots/terminal.png" docs/images/
```

## Struktur

| Datei | Aufgabe |
|---|---|
| `Models.swift` | Geräteprofile, lokale Speicherung, optionales Passwort im Schlüsselbund, Textaufbereitung |
| `PhoneIdentity.swift` | Biometrisch geschützter iPhone-Schlüssel, SSH-Authentifizierung und Banner |
| `SSHSession.swift` | Verbindungslebensdauer, Host-Key-Pinning, Eingabe-/Ausgabestrom und Verlauf |
| `TerminalBridge.swift` | SwiftTerm-Einbettung und Weiterleitung von Einfügen in den Editor |
| `ContentView.swift` | Geräteübersicht, Einrichtung, Terminal und Editor |
| `NetworkAddresses.swift` | Lokaler IPv4-Export zur manuellen Servereinrichtung |
| `Vendor/Citadel/LOCAL_CHANGES.md` | Begründung der kleinen lokalen Bibliotheksanpassungen |

## Optionale Einrichtungsskripte

Die iPhone-App richtet keine Server eigenständig ein. Die Skripte benötigen einen bereits funktionierenden SSH-Zugang des Macs.

### Öffentlichen Schlüssel autorisieren

```sh
python3 Scripts/authorize_iphone.py /pfad/zum/iphone-ssh.pub pi@pi5.local pi@pizero.local
```

Es wird nur ein öffentlicher Ed25519-Schlüssel übernommen. Das Skript ergänzt ihn idempotent in `~/.ssh/authorized_keys`, erhält vorhandene Einträge und legt vor der ersten Ergänzung eine Sicherung an. SSH-Ziele müssen explizit angegeben werden; persönliche Adressen sind nicht voreingestellt.

### Bestehende Quelladressbeschränkung ergänzen

Die App schreibt beim Start auf dem echten iPhone ihre WLAN-/VPN-IPv4-Adressen in `Documents/iphone-network.json` im geschützten App-Container. Eine exportierte Kopie kann zur gezielten Ergänzung einer bereits vorhandenen SSH-Quelladressliste verwendet werden:

```sh
python3 Scripts/allow_iphone_sources.py /pfad/zum/iphone-network.json pi@pi5.local pi
```

Das Skript benötigt passwortloses `sudo` für die ausdrücklich gewählte SSH-Verbindung. Es ergänzt nur die privaten WLAN-/Tailscale-Quelladressen aus dem Export in einer eigenen Datei unter `sshd_config.d`, prüft mit `sshd -t` und lädt den Dienst neu. Bei Fehlern wird die vorherige Datei wiederhergestellt. Es verändert weder Tailscale-Regeln noch die vorhandenen SSH-Zulassungsdateien. Nach DHCP-Änderungen kann eine erneute Ergänzung nötig sein.

## Version veröffentlichen

Version 1.0.0 entspricht dem ersten öffentlichen Stand. Persönliche Konfigurationen, Geräteexporte, Schlüssel und Signierungsdateien bleiben außerhalb von Git. Das öffentliche Projekt verwendet leere Geräteprofile. Vor einem neuen Tag Build, Tests und Dokumentationsbilder mit dem zu veröffentlichenden Quellstand prüfen.
