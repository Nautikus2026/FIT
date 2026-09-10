# FIT

Werkzeuge rund um die Bordelektronik.

## tools/ais-wlan.ps1

PowerShell-Skript fuer Windows: AIS-WLAN und Internetverbindung gleichzeitig nutzen.

### Problem

Der Access Point eines AIS-Geraets (SSID z. B. `B954_...`) bietet kein Internet,
verteilt per DHCP aber trotzdem ein Default-Gateway. Windows waehlt die Default-Route
nach der niedrigsten Metrik. Gewinnt das AIS-WLAN diese Wahl, laeuft der gesamte
Internetverkehr in den Access Point und verschwindet dort, obwohl parallel eine
funktionierende Verbindung (LAN, USB-Tethering, LTE) vorhanden ist.

### Voraussetzung

Ein zweiter Netzwerkweg muss existieren. Ein einzelner WLAN-Adapter kann sich immer
nur mit einem Netz verbinden. Geeignet sind LAN-Kabel, USB-Tethering vom Smartphone,
ein LTE-Stick oder ein zweiter WLAN-Adapter.

### Verwendung

Zuerst mit dem AIS-WLAN verbinden und den zweiten Internetweg aktivieren, damit das
Skript den tatsaechlichen Problemzustand misst.

Diagnose, veraendert nichts, ohne Administratorrechte:

    Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
    .\ais-wlan.ps1

Beheben, PowerShell als Administrator:

    .\ais-wlan.ps1 -Apply -Static

Zuruecksetzen:

    .\ais-wlan.ps1 -Undo

### Was `-Apply` aendert

| Aenderung | Wirkung |
|---|---|
| Interface-Metrik des Internetadapters auf 10 | wird fuer die Default-Route bevorzugt |
| Interface-Metrik des AIS-WLAN auf 60 | verliert die Wahl der Default-Route |
| Default-Route des AIS-WLAN entfernt | Internetverkehr kann nicht mehr dorthin laufen |
| `-Static` zusaetzlich: feste IP ohne Gateway, DNS zurueckgesetzt | ueberlebt einen Reconnect |

Das Subnetz des AIS bleibt ueber die Interface-Route erreichbar, der NMEA-Stream
laeuft also weiter.

### Bestaetigte Werte an Bord

Gemessen mit Internet ueber USB-Tethering vom Samsung S10 und gleichzeitig
stehender WLAN-Verbindung zum AIS-Geraet:

| Wert | |
|---|---|
| SSID | `B954_...` |
| AIS-Geraet | `192.168.2.1` |
| NMEA ueber TCP | Port `5000` |
| OpenCPN | Verbindung vom Typ Netzwerk, Protokoll TCP, nur Empfang |

Der Standardwert von `-AisPort` steht deshalb auf `5000`.

### Parameter

| Parameter | Standard | Bedeutung |
|---|---|---|
| `-Ssid` | `B954` | Praefix der AIS-SSID zur Adaptererkennung |
| `-WlanAlias` | automatisch | WLAN-Adapter explizit angeben |
| `-NetAlias` | automatisch | Internetadapter explizit angeben |
| `-AisPort` | `5000` | Port fuer den NMEA-Verbindungstest, Alternativen 2000 / 10110 / 39150 |
| `-MetricNet` | `10` | Metrik des Internetadapters |
| `-MetricWlan` | `60` | Metrik des AIS-WLAN |

### Zusaetzliche Pruefung

Das Skript meldet einen Subnetz-Konflikt, wenn AIS-Access-Point und Internetweg im
selben `/24` liegen, etwa beide auf `192.168.1.0/24`. Dieser Fall laesst sich ueber
Metriken nicht loesen und erfordert eine Umstellung des Subnetzes im Webinterface
des AIS-Geraets.

### Status

Auf echter Hardware noch nicht ausgefuehrt. Das Skript verwendet ausschliesslich
Windows-Bordmittel ab Windows 8 (`Get-NetIPInterface`, `Set-NetIPInterface`,
`Get-NetRoute`, `Remove-NetRoute`, `New-NetIPAddress`).

Ein statischer Durchgang hat vier Stellen korrigiert:

- `if`-Statements als Hashtable-Werte durch vorher berechnete Variablen ersetzt,
  weil die Schreibweise je nach PowerShell-Version einen Parserfehler ausloest
- `-InterfaceMetric` wird zusammen mit `-AutomaticMetric Disabled` gesetzt,
  sonst ueberschreibt Windows die Metrik wieder selbst
- bei `-Static` wird DHCP jetzt vor dem Entfernen der Adressen abgeschaltet,
  sonst holt sich der Adapter Adresse und Gateway sofort zurueck
- `Test-NetConnection` laeuft mit `-ErrorAction SilentlyContinue`, damit ein
  fehlgeschlagener Verbindungstest wegen `$ErrorActionPreference = 'Stop'`
  nicht das ganze Skript abbricht
