# isolate-host.ps1 - Wazuh Active Response : isolation reseau d'un hote Windows
#
# - Les IP de $AllowedIPs (wazuh-manager) restent joignables, tout le reste est bloque.
# - Isoler          : commande AR "add" (cas normal d'un appel API avec "!isolate-host.cmd")
# - Lever isolation : commande AR "delete"  OU  argument "release" dans "arguments" de l'API
# - Tout est journalise dans active-responses.log pour pouvoir diagnostiquer.
#
# Pourquoi pas "block any" + "allow manager" ? Dans le pare-feu Windows, une regle BLOCK
# l'emporte TOUJOURS sur une regle ALLOW. On bloque donc "tout SAUF le manager" en une seule
# regle, en calculant les plages d'adresses complementaires.

# ----------------------------- A ADAPTER -----------------------------
$AllowedIPs = @('192.168.30.10')   # wazuh-manager ; ajouter ici d'autres IP a garder joignables
$LogFile    = 'C:\Program Files (x86)\ossec-agent\active-response\active-responses.log'
# ---------------------------------------------------------------------

$RuleIn  = 'WazuhIsolation_In'
$RuleOut = 'WazuhIsolation_Out'
# anciens noms (version precedente du script) nettoyes aussi
$AllRuleNames = @($RuleIn, $RuleOut, 'WazuhIsolation_Allow_Manager_In', 'WazuhIsolation_Allow_Manager_Out')

function Write-Log([string]$msg) {
    $ts = Get-Date -Format 'yyyy/MM/dd HH:mm:ss'
    try { Add-Content -Path $LogFile -Value "$ts isolate-host: $msg" } catch { }
}

function ConvertTo-UInt([string]$ip) {
    $b = [System.Net.IPAddress]::Parse($ip).GetAddressBytes()
    [Array]::Reverse($b)
    return [BitConverter]::ToUInt32($b, 0)
}

function ConvertTo-Ip([uint64]$n) {
    $b = [BitConverter]::GetBytes([uint32]$n)
    [Array]::Reverse($b)
    return ([System.Net.IPAddress]::new([byte[]]$b)).ToString()
}

# Retourne "0.0.0.0-a.b.c.(d-1),a.b.c.(d+1)-255.255.255.255" : tout sauf les IP donnees
function Get-ExcludedRanges([string[]]$ips) {
    $nums = @($ips | ForEach-Object { [uint64](ConvertTo-UInt $_) } | Sort-Object -Unique)
    $ranges = @()
    [uint64]$start = 0
    foreach ($n in $nums) {
        if ($n -gt $start) {
            $ranges += ('{0}-{1}' -f (ConvertTo-Ip $start), (ConvertTo-Ip ($n - 1)))
        }
        $start = $n + 1
    }
    if ($start -le 4294967295) {
        $ranges += ('{0}-255.255.255.255' -f (ConvertTo-Ip $start))
    }
    return ($ranges -join ',')
}

function Remove-IsolationRules {
    foreach ($r in $AllRuleNames) {
        $out = & netsh advfirewall firewall delete rule "name=$r" 2>&1
        Write-Log "delete rule $r -> exit=$LASTEXITCODE"
    }
}

function Enable-Isolation {
    Remove-IsolationRules
    $ranges = Get-ExcludedRanges $AllowedIPs
    Write-Log "plages bloquees (tout sauf $($AllowedIPs -join ',')) : $ranges"

    # s'assurer que le pare-feu est actif sur tous les profils
    $out = & netsh advfirewall set allprofiles state on 2>&1
    Write-Log "firewall state on -> exit=$LASTEXITCODE $out"

    foreach ($d in @('in', 'out')) {
        $name = if ($d -eq 'in') { $RuleIn } else { $RuleOut }
        $out = & netsh advfirewall firewall add rule "name=$name" "dir=$d" "action=block" "remoteip=$ranges" "profile=any" "enable=yes" 2>&1
        Write-Log "add rule $name (dir=$d) -> exit=$LASTEXITCODE $out"
    }
    Write-Log "ISOLATION ACTIVE"
}

function Disable-Isolation {
    Remove-IsolationRules
    Write-Log "ISOLATION LEVEE"
}

# ------------------------------- main --------------------------------
Write-Log "Starting"

# IMPORTANT : on lit UNE seule ligne (le JSON de Wazuh tient sur une ligne), comme les
# scripts officiels Wazuh. ReadToEnd() attend la fermeture de stdin et peut bloquer.
$raw = [Console]::In.ReadLine()
Write-Log "stdin recu : $raw"

$data = $null
try { $data = $raw | ConvertFrom-Json } catch { Write-Log "ERREUR JSON : $_" }

$cmd   = $null
$extra = @()
if ($data) {
    $cmd = $data.command
    if ($data.parameters -and $data.parameters.extra_args) { $extra = @($data.parameters.extra_args) }
}
Write-Log "command='$cmd' extra_args='$($extra -join ' ')'"

try {
    if ($cmd -eq 'delete' -or $extra -contains 'release') {
        Disable-Isolation
    }
    elseif ($cmd -eq 'add') {
        Enable-Isolation
    }
    else {
        Write-Log "commande inconnue ou stdin vide : rien n'a ete fait"
    }
}
catch {
    Write-Log "EXCEPTION : $_"
}

Write-Log "Ended"
exit 0
