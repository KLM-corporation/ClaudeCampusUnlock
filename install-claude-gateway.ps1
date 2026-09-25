#requires -Version 5.1
<##
.SYNOPSIS
    Installe une passerelle web privee avec un navigateur Firefox isole par ami.

.DESCRIPTION
    Le script prepare Docker Compose avec :
      - un conteneur jlesage/firefox par ami ;
      - un profil Firefox persistant et separe pour chaque ami ;
      - Caddy comme reverse proxy HTTPS ;
      - une authentification propre a chaque conteneur.

    Le routeur n'est pas configure automatiquement, car la procedure depend
    de sa marque et de son modele. Les ports 80 et 443 doivent etre rediriges
    vers le PC Windows qui execute Docker Desktop.

    Le script ne demande ni ne stocke de mot de passe Claude. Chaque ami se
    connecte a son propre compte Claude dans son propre navigateur distant.

.EXAMPLE
    Set-ExecutionPolicy -Scope Process Bypass
    .\install-claude-gateway.ps1 -InstallDocker

.EXAMPLE
    .\install-claude-gateway.ps1
#>

[CmdletBinding()]
param(
    [string]$InstallDir = (Join-Path $env:USERPROFILE "claude-gateway"),
    [switch]$InstallDocker
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Write-Info {
    param([string]$Message)
    Write-Host "[INFO] $Message" -ForegroundColor Cyan
}

function Write-WarningMessage {
    param([string]$Message)
    Write-Host "[ATTENTION] $Message" -ForegroundColor Yellow
}

function Test-CommandExists {
    param([Parameter(Mandatory)][string]$Name)
    return $null -ne (Get-Command $Name -ErrorAction SilentlyContinue)
}

function Test-IsAdmin {
    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

function New-RandomPassword {
    param([int]$Length = 24)

    # Alphabet volontairement limite aux lettres et chiffres pour eviter les
    # problemes de guillemets ou de caracteres speciaux dans .env.
    $alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789"
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $bytes = New-Object byte[] $Length
        $rng.GetBytes($bytes)
    }
    finally {
        $rng.Dispose()
    }

    $characters = foreach ($byte in $bytes) {
        $alphabet[$byte % $alphabet.Length]
    }
    return (-join $characters)
}

function Normalize-Id {
    param([string]$Value)

    $result = $Value.Trim().ToLowerInvariant()
    $result = $result -replace "[^a-z0-9-]", "-"
    $result = $result.Trim("-")

    if ([string]::IsNullOrWhiteSpace($result)) {
        throw "L'identifiant ne peut pas etre vide."
    }

    if ($result[0] -match "[0-9]") {
        $result = "ami-$result"
    }

    return $result
}

function Normalize-Hostname {
    param([string]$Value)

    $result = $Value.Trim().ToLowerInvariant()
    $result = $result -replace "^https?://", ""
    $result = $result.TrimEnd("/")

    if ($result.Contains("/") -or $result.Contains(":")) {
        throw "Entre uniquement un nom DNS, sans https://, chemin ou port."
    }

    # Nom DNS public classique, par exemple ami1.exemple.duckdns.org.
    $dnsPattern = "^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)+$"
    if ($result -notmatch $dnsPattern) {
        throw "Nom DNS invalide : $result"
    }

    return $result
}

function Protect-SecretFile {
    param([Parameter(Mandatory)][string]$Path)

    try {
        $currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
        $acl = Get-Acl -LiteralPath $Path
        $acl.SetAccessRuleProtection($true, $false)
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            $currentUser,
            "FullControl",
            "Allow"
        )
        $acl.SetAccessRule($rule)
        Set-Acl -LiteralPath $Path -AclObject $acl
        attrib +h $Path 2>$null | Out-Null
    }
    catch {
        Write-WarningMessage "Impossible de restreindre automatiquement les droits de $Path. Garde ce fichier prive."
    }
}

function Ensure-Docker {
    if (-not (Test-CommandExists "docker")) {
        if (-not $InstallDocker) {
            throw "Docker Desktop n'est pas installe. Relance avec -InstallDocker, ou installe Docker Desktop manuellement puis relance le script."
        }

        if (-not (Test-IsAdmin)) {
            throw "L'installation de Docker Desktop via -InstallDocker necessite d'executer PowerShell en tant qu'administrateur."
        }

        if (-not (Test-CommandExists "winget")) {
            throw "winget est introuvable. Installe Docker Desktop manuellement depuis https://www.docker.com/products/docker-desktop/"
        }

        Write-Info "Installation de Docker Desktop via winget..."
        winget install --id Docker.DockerDesktop --exact --accept-source-agreements --accept-package-agreements
        if ($LASTEXITCODE -ne 0) {
            throw "L'installation de Docker Desktop a echoue."
        }

        throw "Docker Desktop vient d'etre installe. Redemarre Windows si necessaire, demarre Docker Desktop, puis relance ce script sans -InstallDocker."
    }

    if (-not (Test-CommandExists "docker")) {
        throw "La commande docker est introuvable."
    }

    docker compose version *> $null
    if ($LASTEXITCODE -ne 0) {
        throw "Docker Compose est indisponible. Mets a jour Docker Desktop."
    }

    docker info *> $null
    if ($LASTEXITCODE -ne 0) {
        throw "Le moteur Docker ne repond pas. Demarre Docker Desktop, attends qu'il soit pret, puis relance le script."
    }
}

Write-Host ""
Write-Host "=== Passerelle Claude privee - Windows / Docker ===" -ForegroundColor Green
Write-Host ""
Write-WarningMessage "Cette passerelle donnera a tes amis un acces Internet sortant par ta connexion maison. Ne la partage qu'avec des personnes de confiance."
Write-WarningMessage "Le script ne configure pas le routeur et ne demande jamais de mot de passe Claude."
Write-Host ""

Ensure-Docker

do {
    $rawHost = Read-Host "Nom DNS public general (exemple : mon-relais.duckdns.org)"
    try {
        $publicHost = Normalize-Hostname $rawHost
    }
    catch {
        Write-WarningMessage $_.Exception.Message
        $publicHost = $null
    }
} while ([string]::IsNullOrWhiteSpace($publicHost))

$countText = Read-Host "Combien d'amis veux-tu configurer (1 a 20) ?"
[int]$friendCount = 0
if (-not [int]::TryParse($countText, [ref]$friendCount) -or $friendCount -lt 1 -or $friendCount -gt 20) {
    throw "Le nombre d'amis doit etre compris entre 1 et 20."
}

$friends = @()
$usedIds = @{}

for ($index = 1; $index -le $friendCount; $index++) {
    Write-Host ""
    Write-Host "--- Ami $index / $friendCount ---" -ForegroundColor Green

    do {
        $rawId = Read-Host "Identifiant court (exemple : gabi)"
        try {
            $id = Normalize-Id $rawId
        }
        catch {
            Write-WarningMessage $_.Exception.Message
            $id = $null
        }

        if ($id -and $usedIds.ContainsKey($id)) {
            Write-WarningMessage "Cet identifiant est deja utilise."
            $id = $null
        }
    } while ([string]::IsNullOrWhiteSpace($id))

    $rawPass = Read-Host "Mot de passe pour $id (Entree pour generer aleatoirement)"
    if ([string]::IsNullOrWhiteSpace($rawPass)) {
        $password = New-RandomPassword -Length 24
        Write-Info "Mot de passe genere automatiquement pour $id : $password"
    } else {
        $password = $rawPass.Trim()
    }

    Write-Info "Generation du hash securise pour $id..."
    $hashOutput = docker run --rm caddy:2 caddy hash-password --plaintext "$password"
    $bcryptHash = $hashOutput.Trim()
    if ([string]::IsNullOrWhiteSpace($bcryptHash) -or -not $bcryptHash.StartsWith("`$2")) {
        throw "La generation du hash de mot de passe a echoue."
    }

    $container = "$id-firefox"
    $envName = (($id.ToUpperInvariant() -replace "[^A-Z0-9]", "_") + "_PASSWORD")
    $usedIds[$id] = $true

    $friends += [PSCustomObject]@{
        Id         = $id
        Username   = $id
        Password   = $password
        BcryptHash = $bcryptHash
        Container  = $container
        EnvName    = $envName
    }
}

New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $InstallDir "data") -Force | Out-Null

$serviceBlocks = New-Object System.Collections.Generic.List[string]
$basicAuthLines = New-Object System.Collections.Generic.List[string]
$routingBlocks = New-Object System.Collections.Generic.List[string]
$envLines = New-Object System.Collections.Generic.List[string]

$envLines.Add("# Configuration de la passerelle ClaudeCampusUnlock")
$envLines.Add("# URL publique unique : https://$publicHost")
$envLines.Add("")

foreach ($friend in $friends) {
    $serviceBlocks.Add(@"
  $($friend.Container):
    image: jlesage/firefox:latest
    container_name: $($friend.Container)
    restart: unless-stopped
    environment:
      SECURE_CONNECTION: "1"
      WEB_AUTHENTICATION: "0"
      FF_OPEN_URL: "https://claude.ai"
      WEB_FILE_MANAGER: "0"
      WEB_TERMINAL: "0"
      WEB_HOST_CLIPBOARD_SYNC: "0"
      TZ: "Europe/Paris"
    volumes:
      - "./data/$($friend.Id):/config"
    expose:
      - "5800"
    shm_size: "1gb"
"@)

    $basicAuthLines.Add("        $($friend.Username) $($friend.BcryptHash)")
    $envLines.Add("# Ami : $($friend.Id) | Identifiant : $($friend.Username) | Mot de passe : $($friend.Password)")
    $envLines.Add("$($friend.EnvName)=$($friend.Password)")
}

if ($friends.Count -eq 1) {
    $singleFriend = $friends[0]
    $routingBlocks.Add(@"
    reverse_proxy https://$($singleFriend.Container):5800 {
        transport http {
            tls_insecure_skip_verify
        }
    }
"@)
} else {
    foreach ($friend in $friends) {
        $routingBlocks.Add(@"
    @is_$($friend.Id) expression {http.auth.user.id} == '$($friend.Username)'
    handle @is_$($friend.Id) {
        reverse_proxy https://$($friend.Container):5800 {
            transport http {
                tls_insecure_skip_verify
            }
        }
    }
"@)
    }
}

$caddyContent = @"
# Caddy obtient automatiquement le certificat HTTPS pour $publicHost.
# Tous les amis utilisent la meme URL unique : https://$publicHost
# Caddy authentifie chaque ami et l'aiguille vers son propre conteneur Firefox.

$publicHost {
    basic_auth {
$($basicAuthLines -join "`n")
    }

$($routingBlocks -join "`n")
}
"@

$envContent = @"
# Fichier sensible : mots de passe d'acces aux navigateurs distants.
# Ne le partage pas et ne le publie jamais.
$($envLines -join "`n")
"@

$composePath = Join-Path $InstallDir "compose.yml"
$caddyPath = Join-Path $InstallDir "Caddyfile"
$envPath = Join-Path $InstallDir ".env"
$gitignorePath = Join-Path $InstallDir ".gitignore"
$routerGuidePath = Join-Path $InstallDir "CONFIGURATION-ROUTEUR.txt"

Set-Content -LiteralPath $composePath -Value $composeContent -Encoding UTF8 -Force
Set-Content -LiteralPath $caddyPath -Value $caddyContent -Encoding UTF8 -Force
Set-Content -LiteralPath $envPath -Value $envContent -Encoding UTF8 -Force
Set-Content -LiteralPath $gitignorePath -Value ".env`ndata/`n" -Encoding UTF8 -Force

Protect-SecretFile -Path $envPath

$routerGuide = @"
CONFIGURATION A FAIRE SUR LE ROUTEUR
====================================

1. Reserve une adresse IP locale fixe pour ce PC Windows.
2. Redirige uniquement :
      TCP 80  -> IP_LOCALE_DU_PC:80
      TCP 443 -> IP_LOCALE_DU_PC:443
3. Ne redirige pas les ports 5800, 5900 ou 3389.
4. Verifie que le nom DNS ($publicHost) resout vers ton adresse IP publique actuelle.
5. Si ton operateur utilise un CGNAT, la redirection de ports ne fonctionnera
   probablement pas. Il faudra alors utiliser un tunnel sortant (Termux / Cloudflare).

ACCES CLIENT (URL UNIQUE)
=========================
Tous les amis ouvrent exactement la MEME adresse web :
    https://$publicHost

Lors de l'invite de connexion, chacun entre son propre identifiant et son mot de passe.
Caddy authentifie la personne et l'aiguille automatiquement vers son navigateur Firefox personnel !

TEST LOCAL
==========
Depuis ce PC, lance :
    docker compose ps
    docker compose logs -f caddy

Une fois le routeur et le DNS configures, teste l'URL depuis un reseau
exterieur a ta maison (ex: en 4G), pas uniquement depuis le Wi-Fi domestique.

MAINTENANCE
===========
Mise a jour des images :
    docker compose pull
    docker compose up -d

Arret :
    docker compose down
"@
Set-Content -LiteralPath $routerGuidePath -Value $routerGuide -Encoding UTF8 -Force

Push-Location $InstallDir
try {
    Write-Info "Telechargement des images Docker..."
    docker compose pull
    if ($LASTEXITCODE -ne 0) {
        throw "Le telechargement des images Docker a echoue."
    }

    Write-Info "Demarrage des conteneurs..."
    docker compose up -d
    if ($LASTEXITCODE -ne 0) {
        throw "Le demarrage des conteneurs a echoue."
    }
}
finally {
    Pop-Location
}

Write-Host ""
Write-Host "=== Installation locale terminee ===" -ForegroundColor Green
Write-Host "Fichiers crees dans : $InstallDir"
Write-Host ""
Write-WarningMessage "L'URL ne fonctionnera depuis l'exterieur qu'apres la configuration du routeur et du DNS."
Write-WarningMessage "Ne partage pas le fichier .env. Il contient les mots de passe des passerelles."
Write-Host ""
Write-Host "Acces a transmettre aux amis :" -ForegroundColor Green
Write-Host "  URL unique pour tout le monde : https://$publicHost" -ForegroundColor Cyan
Write-Host ""
foreach ($friend in $friends) {
    Write-Host "  --- Ami : $($friend.Id) ---"
    Write-Host "  Identifiant : $($friend.Username)"
    Write-Host "  Mot de passe : $($friend.Password)"
    Write-Host ""
}

Write-Host "Commandes utiles :" -ForegroundColor Green
Write-Host "  cd `"$InstallDir`""
Write-Host "  docker compose ps"
Write-Host "  docker compose logs -f caddy"
Write-Host "  docker compose down"
Write-Host ""
Write-Host "Chaque ami doit ensuite se connecter avec son propre compte Claude dans son Firefox distant." -ForegroundColor Cyan
