<#
.SYNOPSIS
    Diagnose und Fix: AIS-WLAN (kein Internet) parallel zu einer Internetverbindung nutzen.

.BESCHREIBUNG
    Windows routet standardmaessig ueber die Schnittstelle mit der niedrigsten Metrik.
    Ein AIS-Access-Point verteilt per DHCP ein Default-Gateway, das ins Leere fuehrt.
    Gewinnt dieses WLAN die Metrik-Wahl, geht der gesamte Internetverkehr ins AIS.

    Dieses Skript
      - zeigt alle aktiven Adapter mit Metrik, IP, Gateway und Konnektivitaet,
      - benennt die Default-Routen und welche gerade gewinnt,
      - setzt auf Wunsch die Metriken korrekt und entfernt die Default-Route des AIS-WLAN,
      - kann alles wieder zuruecksetzen.

.BEISPIELE
    .\ais-wlan.ps1
        Nur Diagnose, aendert nichts. Kein Adminrecht noetig.

    .\ais-wlan.ps1 -Apply
        Metriken setzen und Default-Route des AIS-WLAN entfernen. Als Admin ausfuehren.

    .\ais-wlan.ps1 -Apply -Static
        Zusaetzlich das WLAN dauerhaft auf feste IP ohne Gateway stellen,
        damit die Route nach einem Reconnect nicht zurueckkommt.

    .\ais-wlan.ps1 -Undo
        Alles zuruecksetzen: automatische Metrik und DHCP.
#>

[CmdletBinding()]
param(
    [string]$Ssid       = 'B954',
    [string]$WlanAlias  = '',
    [string]$NetAlias   = '',
    [int]   $AisPort    = 2000,
    [int]   $MetricNet  = 10,
    [int]   $MetricWlan = 60,
    [switch]$Apply,
    [switch]$Static,
    [switch]$Undo
)

$ErrorActionPreference = 'Stop'

function Write-Head($t) {
    Write-Host ''
    Write-Host ('=' * 68) -ForegroundColor DarkCyan
    Write-Host "  $t" -ForegroundColor Cyan
    Write-Host ('=' * 68) -ForegroundColor DarkCyan
}
function Write-Ok($t)   { Write-Host "  [ok]   $t" -ForegroundColor Green }
function Write-Warn($t) { Write-Host "  [!]    $t" -ForegroundColor Yellow }
function Write-Bad($t)  { Write-Host "  [FEHLER] $t" -ForegroundColor Red }
function Write-Info($t) { Write-Host "  $t" }

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-ProfileName([int]$ifIndex) {
    $p = Get-NetConnectionProfile -InterfaceIndex $ifIndex -ErrorAction SilentlyContinue
    if ($p) { return $p.Name } else { return '' }
}

function Get-Ipv4([int]$ifIndex) {
    Get-NetIPAddress -InterfaceIndex $ifIndex -AddressFamily IPv4 `
        -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -notlike '169.254.*' } |
        Select-Object -First 1
}

function Get-Gateway([int]$ifIndex) {
    $r = Get-NetRoute -InterfaceIndex $ifIndex -DestinationPrefix '0.0.0.0/0' `
            -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($r) { return $r.NextHop } else { return '' }
}

# ---------------------------------------------------------------- Bestandsaufnahme
Write-Head 'Aktive Netzwerkadapter'

$up = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' } | Sort-Object ifIndex
if (-not $up) { Write-Bad 'Kein aktiver Netzwerkadapter gefunden.'; return }

$rows = foreach ($a in $up) {
    $ip   = Get-Ipv4 $a.ifIndex
    $ifc  = Get-NetIPInterface -InterfaceIndex $a.ifIndex -AddressFamily IPv4 `
                -ErrorAction SilentlyContinue
    $prof = Get-NetConnectionProfile -InterfaceIndex $a.ifIndex -ErrorAction SilentlyContinue

    $sIp   = '-'
    if ($ip) { $sIp = "$($ip.IPAddress)/$($ip.PrefixLength)" }

    $sGw = Get-Gateway $a.ifIndex
    if (-not $sGw) { $sGw = '-' }

    $sMetric = '?'; $sAuto = '?'; $sDhcp = '?'
    if ($ifc) {
        $sMetric = $ifc.InterfaceMetric
        $sAuto   = $ifc.AutomaticMetric
        $sDhcp   = $ifc.Dhcp
    }

    $sProfile = '-'; $sConn = '-'
    if ($prof) {
        $sProfile = $prof.Name
        $sConn    = $prof.IPv4Connectivity
    }

    [pscustomobject]@{
        ifIndex   = $a.ifIndex
        Alias     = $a.InterfaceAlias
        Typ       = $a.InterfaceType
        IPv4      = $sIp
        Gateway   = $sGw
        Metrik    = $sMetric
        AutoMetr  = $sAuto
        DHCP      = $sDhcp
        Profil    = $sProfile
        Internet  = $sConn
    }
}
$rows | Format-Table -AutoSize | Out-String | Write-Host

# ---------------------------------------------------------------- Adapter zuordnen
Write-Head 'Zuordnung'

if ($WlanAlias) {
    $wlan = $up | Where-Object { $_.InterfaceAlias -eq $WlanAlias } | Select-Object -First 1
} else {
    # 71 = IEEE 802.11. Falls der Treiber das nicht meldet, ueber das Profil (SSID) suchen.
    $wlan = $up | Where-Object {
        $_.InterfaceType -eq 71 -and (Get-ProfileName $_.ifIndex) -like "$Ssid*"
    } | Select-Object -First 1

    if (-not $wlan) {
        $wlan = $up | Where-Object { (Get-ProfileName $_.ifIndex) -like "$Ssid*" } |
                Select-Object -First 1
    }
}

if (-not $wlan) {
    Write-Bad "Kein aktiver Adapter mit SSID '$Ssid*' gefunden."
    Write-Info "Verbinde dich zuerst mit dem AIS-WLAN, oder gib den Adapter direkt an:"
    Write-Info "    .\ais-wlan.ps1 -WlanAlias 'WLAN'"
    return
}
Write-Ok "AIS-WLAN : [$($wlan.ifIndex)] $($wlan.InterfaceAlias)  (SSID: $(Get-ProfileName $wlan.ifIndex))"

if ($NetAlias) {
    $net = $up | Where-Object { $_.InterfaceAlias -eq $NetAlias } | Select-Object -First 1
} else {
    $net = $up | Where-Object {
        $_.ifIndex -ne $wlan.ifIndex -and (Get-Gateway $_.ifIndex)
    } | Select-Object -First 1
}

if (-not $net) {
    Write-Warn 'Keine zweite Schnittstelle mit Gateway gefunden (LAN / USB-Tethering / LTE-Stick).'
    Write-Info 'Ohne zweiten Internetweg kann es kein "gleichzeitig" geben.'
    Write-Info 'Handy per USB anschliessen und USB-Tethering aktivieren, dann erneut ausfuehren.'
} else {
    Write-Ok "Internet  : [$($net.ifIndex)] $($net.InterfaceAlias)  (Gateway: $(Get-Gateway $net.ifIndex))"
}

# ---------------------------------------------------------------- Default-Routen
Write-Head 'Default-Routen (0.0.0.0/0) - niedrigste Summe gewinnt'

$def = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
       ForEach-Object {
           $ifc = Get-NetIPInterface -InterfaceIndex $_.InterfaceIndex `
                     -AddressFamily IPv4 -ErrorAction SilentlyContinue
           $ifMetric = 0
           if ($ifc) { $ifMetric = $ifc.InterfaceMetric }

           [pscustomobject]@{
               ifIndex     = $_.InterfaceIndex
               Alias       = $_.InterfaceAlias
               NextHop     = $_.NextHop
               RouteMetrik = $_.RouteMetric
               IfMetrik    = $ifMetric
               Summe       = $_.RouteMetric + $ifMetric
           }
       } | Sort-Object Summe

$def | Format-Table -AutoSize | Out-String | Write-Host

$winner = $def | Select-Object -First 1
if ($winner) {
    if ($winner.ifIndex -eq $wlan.ifIndex) {
        Write-Bad "Das AIS-WLAN haelt aktuell die Default-Route (Summe $($winner.Summe))."
        Write-Info 'Genau das ist die Ursache: Internetverkehr laeuft ins AIS und verschwindet.'
    } else {
        Write-Ok "Default-Route laeuft ueber '$($winner.Alias)' - das ist richtig."
    }
}

$wlanDefault = Get-NetRoute -InterfaceIndex $wlan.ifIndex -DestinationPrefix '0.0.0.0/0' `
                  -ErrorAction SilentlyContinue
if ($wlanDefault) {
    Write-Warn 'Das AIS-WLAN hat ueberhaupt eine Default-Route. Die gehoert dort nicht hin.'
}

# ---------------------------------------------------------------- Subnetz-Konflikt
$wIp = Get-Ipv4 $wlan.ifIndex
if ($net) {
    $nIp = Get-Ipv4 $net.ifIndex
    if ($wIp -and $nIp -and $wIp.PrefixLength -eq $nIp.PrefixLength) {
        $wNet = ($wIp.IPAddress -split '\.')[0..2] -join '.'
        $nNet = ($nIp.IPAddress -split '\.')[0..2] -join '.'
        if ($wNet -eq $nNet) {
            Write-Bad "Subnetz-Konflikt: AIS und Internetweg liegen beide in $wNet.0/24."
            Write-Info 'Das laesst sich per Metrik nicht loesen - im AIS-Webinterface auf'
            Write-Info 'ein anderes Subnetz umstellen, z. B. 192.168.44.0/24.'
        }
    }
}

# ---------------------------------------------------------------- Undo
if ($Undo) {
    Write-Head 'Zuruecksetzen'
    if (-not (Test-Admin)) { Write-Bad 'Bitte PowerShell als Administrator starten.'; return }

    Set-NetIPInterface -InterfaceIndex $wlan.ifIndex -AddressFamily IPv4 -AutomaticMetric Enabled
    Write-Ok "Automatische Metrik fuer '$($wlan.InterfaceAlias)' wieder aktiviert."

    if ($net) {
        Set-NetIPInterface -InterfaceIndex $net.ifIndex -AddressFamily IPv4 -AutomaticMetric Enabled
        Write-Ok "Automatische Metrik fuer '$($net.InterfaceAlias)' wieder aktiviert."
    }

    $ifc = Get-NetIPInterface -InterfaceIndex $wlan.ifIndex -AddressFamily IPv4
    if ($ifc.Dhcp -eq 'Disabled') {
        Get-NetIPAddress -InterfaceIndex $wlan.ifIndex -AddressFamily IPv4 `
            -ErrorAction SilentlyContinue |
            Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
        Set-NetIPInterface -InterfaceIndex $wlan.ifIndex -AddressFamily IPv4 -Dhcp Enabled
        Set-DnsClientServerAddress -InterfaceIndex $wlan.ifIndex -ResetServerAddresses
        Write-Ok 'WLAN wieder auf DHCP gestellt.'
    }
    Write-Info 'WLAN einmal trennen und neu verbinden.'
    return
}

# ---------------------------------------------------------------- Apply
if (-not $Apply) {
    Write-Head 'Naechster Schritt'
    Write-Info 'Diagnose beendet - es wurde nichts geaendert.'
    Write-Info ''
    Write-Info 'Zum Beheben PowerShell als Administrator oeffnen und ausfuehren:'
    Write-Info '    .\ais-wlan.ps1 -Apply'
    Write-Info ''
    Write-Info 'Damit die Aenderung auch nach einem Reconnect haelt:'
    Write-Info '    .\ais-wlan.ps1 -Apply -Static'
    return
}

Write-Head 'Aenderungen werden angewendet'
if (-not (Test-Admin)) {
    Write-Bad 'Bitte PowerShell als Administrator starten (Rechtsklick > Als Administrator).'
    return
}

Set-NetIPInterface -InterfaceIndex $wlan.ifIndex -AddressFamily IPv4 `
    -AutomaticMetric Disabled -InterfaceMetric $MetricWlan
Write-Ok "Metrik '$($wlan.InterfaceAlias)' = $MetricWlan (unattraktiv fuers Internet)."

if ($net) {
    Set-NetIPInterface -InterfaceIndex $net.ifIndex -AddressFamily IPv4 `
        -AutomaticMetric Disabled -InterfaceMetric $MetricNet
    Write-Ok "Metrik '$($net.InterfaceAlias)' = $MetricNet (bevorzugt fuers Internet)."
}

$removed = Get-NetRoute -InterfaceIndex $wlan.ifIndex -DestinationPrefix '0.0.0.0/0' `
              -ErrorAction SilentlyContinue
if ($removed) {
    $removed | Remove-NetRoute -Confirm:$false
    Write-Ok 'Default-Route des AIS-WLAN entfernt.'
} else {
    Write-Info 'Das AIS-WLAN hatte keine Default-Route - nichts zu entfernen.'
}

if ($Static) {
    if (-not $wIp) {
        Write-Warn 'Keine gueltige IPv4 am WLAN - feste IP wird uebersprungen.'
    } else {
        $addr   = $wIp.IPAddress
        $prefix = $wIp.PrefixLength
        Write-Info "Setze feste IP $addr/$prefix ohne Gateway ..."

        # Reihenfolge ist wichtig: solange DHCP aktiv ist, holt sich der Adapter
        # eine entfernte Adresse samt Gateway sofort wieder.
        Set-NetIPInterface -InterfaceIndex $wlan.ifIndex -AddressFamily IPv4 -Dhcp Disabled

        Get-NetIPAddress -InterfaceIndex $wlan.ifIndex -AddressFamily IPv4 `
            -ErrorAction SilentlyContinue |
            Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
        Get-NetRoute -InterfaceIndex $wlan.ifIndex -DestinationPrefix '0.0.0.0/0' `
            -ErrorAction SilentlyContinue |
            Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue

        New-NetIPAddress -InterfaceIndex $wlan.ifIndex -AddressFamily IPv4 `
            -IPAddress $addr -PrefixLength $prefix | Out-Null
        Set-DnsClientServerAddress -InterfaceIndex $wlan.ifIndex -ResetServerAddresses

        Write-Ok "WLAN fest auf $addr/$prefix, kein Gateway, kein eigener DNS."
        Write-Info 'Rueckgaengig jederzeit mit:  .\ais-wlan.ps1 -Undo'
    }
}

# ---------------------------------------------------------------- Verifikation
Write-Head 'Verifikation'

Write-Info 'Warte kurz auf die neue Routing-Tabelle ...'
Start-Sleep -Seconds 3

$defNow = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
          ForEach-Object {
              $ifc = Get-NetIPInterface -InterfaceIndex $_.InterfaceIndex `
                        -AddressFamily IPv4 -ErrorAction SilentlyContinue
              $ifMetric = 0
              if ($ifc) { $ifMetric = $ifc.InterfaceMetric }

              [pscustomobject]@{
                  ifIndex = $_.InterfaceIndex
                  Alias   = $_.InterfaceAlias
                  Summe   = $_.RouteMetric + $ifMetric
              }
          } | Sort-Object Summe | Select-Object -First 1

if ($defNow) {
    if ($defNow.ifIndex -eq $wlan.ifIndex) {
        Write-Bad "Default-Route liegt weiterhin auf dem AIS-WLAN."
    } else {
        Write-Ok "Default-Route laeuft jetzt ueber '$($defNow.Alias)'."
    }
}

Write-Info ''
Write-Info 'Test 1 - Internet (DNS-Port auf 1.1.1.1):'
$t1 = Test-NetConnection -ComputerName '1.1.1.1' -Port 53 `
          -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
if ($t1.TcpTestSucceeded) {
    Write-Ok "erreichbar ueber '$($t1.InterfaceAlias)'"
} else {
    Write-Bad 'nicht erreichbar'
}

$aisIp = ''
if ($wIp) {
    $aisIp = (($wIp.IPAddress -split '\.')[0..2] -join '.') + '.1'
}
if ($aisIp) {
    Write-Info ''
    Write-Info "Test 2 - AIS-Geraet ($aisIp Port $AisPort):"
    $t2 = Test-NetConnection -ComputerName $aisIp -Port $AisPort `
              -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
    if ($t2.TcpTestSucceeded) {
        Write-Ok "NMEA-Stream erreichbar ueber '$($t2.InterfaceAlias)'"
    } else {
        Write-Warn "Port $AisPort auf $aisIp nicht offen."
        Write-Info 'Moeglich: andere Geraete-IP, anderer Port (10110 / 39150), oder UDP statt TCP.'
        Write-Info "Anderen Port pruefen:  .\ais-wlan.ps1 -AisPort 10110"
    }
}

Write-Head 'Fertig'
Write-Info 'In der Navi-Software als Datenquelle eintragen:'
if ($aisIp) { Write-Info "    TCP-Client  ->  $aisIp : $AisPort" }
Write-Info 'Rueckgaengig machen:  .\ais-wlan.ps1 -Undo'
