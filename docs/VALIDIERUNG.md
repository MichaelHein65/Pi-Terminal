# Prüfstand der Version 1.0.0

Stand: 18.11.2026.

## Auf dem echten iPhone

Der Nutzer hat vor der Veröffentlichung alle sechs Verbindungen bestätigt:

| Gerät | Lokal | Tailscale |
|---|---|---|
| Pi Zero | bestätigt | bestätigt |
| Pi 5 | bestätigt | bestätigt |
| Pi 4 | bestätigt | bestätigt |

Die persönliche Installation nutzt einen auf dem iPhone erzeugten, biometrisch geschützten SSH-Schlüssel. Dessen öffentliche Seite wurde auf den Zielgeräten hinterlegt. Eine erfolgreiche iPhone-Schlüsselanmeldung wurde außerdem im SSH-Serverprotokoll bestätigt. Geräteadressen, Schlüssel und Protokolle werden nicht mit veröffentlicht.

## Automatische Prüfung der öffentlichen Fassung

Die öffentliche Fassung wurde mit Xcode 26.1 im iPhone-17-Pro-Simulator gebaut und getestet: **sechs Tests, keine Fehler**. Auch der Build für ein echtes iPhone (`generic/platform=iOS`, ohne Signierung) war erfolgreich. Das Schema `Documentation` prüft:

1. Migration leerer Adressfelder unter Erhalt der Profil-ID und eigener Konfiguration.
2. Schlüsselbund: Speichern, Lesen, Ersetzen und Löschen optionaler Passwörter.
3. Markdown-Codeblock und mehrzeiliger Skripttext einschließlich Here-Document.
4. Ablehnung versteckter Terminal-Steuerzeichen beim Editorversand.
5. Echte SSH-Sitzung zum lokalen Testserver: Server-Pinning, Passwort, Ed25519-Signatur, `none`-Authentifizierung, Banner, UTF-8, Editorversand, dauerhafte Shell, Terminalgröße und Wiederverbinden.
6. Rendern der bebilderten Dokumentation aus nativen App-Ansichten mit Demo-Daten.

Die Simulator-Tests verwenden einen separaten, öffentlich dokumentierten Testschlüssel. Sie prüfen keine reale biometrische Freigabe und ersetzen keine Prüfung des Tailscale-VPNs oder einer Kontofreigabe. Dafür ist der oben dokumentierte manuelle Gerätestand maßgeblich.
