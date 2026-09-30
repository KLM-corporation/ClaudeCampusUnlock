#requires -Version 5.1
<#
.SYNOPSIS
    Installe (ou met a jour) une passerelle web privee avec un navigateur Firefox isole par ami.

.DESCRIPTION
    Le script prepare Docker Compose avec :
      - un portail d'authentification (auth_portal.py), mots de passe hashes PBKDF2 ;
      - un conteneur jlesage/firefox par ami, chacun sur son propre reseau Docker ;
      - un profil Firefox persistant et separe pour chaque ami ;
      - Caddy comme reverse proxy HTTPS.

    Relance le script pour AJOUTER des amis : les amis existants sont conserves (leurs
    mots de passe ne changent pas) et les anciens fichiers sont sauvegardes dans un
    dossier backup-AAAAMMJJ-HHMMSS.

    Le routeur n'est pas configure automatiquement, car la procedure depend
    de sa marque et de son modele. Les ports 80 et 443 doivent etre rediriges
    vers le PC Windows qui execute Docker Desktop.

    Le script ne demande ni ne stocke de mot de passe Claude. Chaque ami se
    connecte a son propre compte Claude dans son propre navigateur distant.

.PARAMETER InstallDir
    Dossier d'installation (defaut : %USERPROFILE%\claude-gateway).

.PARAMETER InstallDocker
    Installe Docker Desktop avec winget s'il est absent (PowerShell administrateur requis).

.PARAMETER FirefoxMemoryLimit
    Limite de memoire par navigateur (defaut : 3g). Evite qu'un ami sature le PC.

.PARAMETER GenerateOnly
    Genere les fichiers sans telecharger d'images ni demarrer Docker.

.EXAMPLE
    Set-ExecutionPolicy -Scope Process Bypass
    .\install-claude-gateway.ps1 -InstallDocker

.EXAMPLE
    .\install-claude-gateway.ps1
#>

[CmdletBinding()]
param(
    [string]$InstallDir = (Join-Path $env:USERPROFILE "claude-gateway"),
    [switch]$InstallDocker,
    [ValidatePattern('^[1-9][0-9]*[mg]$')]
    [string]$FirefoxMemoryLimit = "3g",
    [switch]$GenerateOnly
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$MinPasswordLength = 12
$MaxFriends = 20

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

function Invoke-NativeQuiet {
    # Lance une commande native sans afficher sa sortie et renvoie son code de sortie.
    # Sous ErrorActionPreference=Stop, Windows PowerShell 5.1 leve NativeCommandError des que
    # la commande ecrit sur stderr, meme redirigee : on repasse donc en Continue le temps de l'appel.
    param([Parameter(Mandatory)][scriptblock]$Command)
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $global:LASTEXITCODE = 0
    try { & $Command *> $null } finally { $ErrorActionPreference = $previous }
    return $LASTEXITCODE
}

function Invoke-NativeVisible {
    # Comme Invoke-NativeQuiet, mais la sortie reste affichee (docker compose pull / up).
    param([Parameter(Mandatory)][scriptblock]$Command)
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $global:LASTEXITCODE = 0
    try { & $Command } finally { $ErrorActionPreference = $previous }
    return $LASTEXITCODE
}

function New-RandomPassword {
    param([int]$Length = 24)

    # Alphabet volontairement limite aux lettres et chiffres (pas de caracteres ambigus ni speciaux).
    # Echantillonnage par rejet : chaque caractere a exactement la meme probabilite.
    $alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789"
    $limit = 256 - (256 % $alphabet.Length)
    $characters = New-Object System.Collections.Generic.List[char]
    $buffer = New-Object byte[] ($Length * 2)
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        while ($characters.Count -lt $Length) {
            $rng.GetBytes($buffer)
            foreach ($byte in $buffer) {
                if ($byte -lt $limit -and $characters.Count -lt $Length) {
                    $characters.Add($alphabet[$byte % $alphabet.Length])
                }
            }
        }
    }
    finally {
        $rng.Dispose()
    }
    return (-join $characters)
}

function ConvertFrom-SecureStringPlain {
    param([Parameter(Mandatory)][System.Security.SecureString]$Secure)
    $pointer = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
    try { return [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer) }
    finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer) }
}

function Read-FriendPassword {
    # Saisie masquee. Entree vide = mot de passe aleatoire (affiche une seule fois, a la fin).
    param([Parameter(Mandatory)][string]$Id)

    while ($true) {
        $first = ConvertFrom-SecureStringPlain (Read-Host -Prompt "Mot de passe pour $Id ($MinPasswordLength caracteres minimum, Entree pour en generer un)" -AsSecureString)
        if ([string]::IsNullOrEmpty($first)) {
            return (New-RandomPassword -Length 24)
        }
        if ($first.Length -lt $MinPasswordLength) {
            Write-WarningMessage "Mot de passe trop court : $MinPasswordLength caracteres minimum."
            continue
        }
        $second = ConvertFrom-SecureStringPlain (Read-Host -Prompt "Confirme le mot de passe pour $Id" -AsSecureString)
        if ($first -cne $second) {
            Write-WarningMessage "Les deux saisies sont differentes."
            continue
        }
        return $first
    }
}

function New-Pbkdf2Hash {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Password,
        [int]$Iterations = 600000
    )

    $salt = New-Object byte[] 16
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($salt) } finally { $rng.Dispose() }

    $pbkdf2 = New-Object System.Security.Cryptography.Rfc2898DeriveBytes($Password, $salt, $Iterations, [System.Security.Cryptography.HashAlgorithmName]::SHA256)
    try { $hashBytes = $pbkdf2.GetBytes(32) } finally { $pbkdf2.Dispose() }

    $saltHex = [BitConverter]::ToString($salt).Replace("-", "").ToLowerInvariant()
    $hashHex = [BitConverter]::ToString($hashBytes).Replace("-", "").ToLowerInvariant()

    return [PSCustomObject]@{
        salt       = $saltHex
        hash       = $hashHex
        iterations = $Iterations
    }
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

    # Une adresse IP n'obtient pas de certificat Let's Encrypt : il faut un vrai nom.
    if ($result -match "^[0-9.]+$") {
        throw "Entre un nom DNS (par exemple mon-relais.duckdns.org), pas une adresse IP."
    }

    return $result
}

function Protect-SecretFile {
    # Restreint les droits du fichier a l'utilisateur courant. (Pas d'attribut "cache" : il
    # empechait de reecrire le fichier a la 2e execution, et n'apporte aucune securite.)
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
    }
    catch {
        Write-WarningMessage "Impossible de restreindre automatiquement les droits de $Path. Garde ce fichier prive."
    }
}

function Write-TextFile {
    # Ecrit en UTF-8 sans BOM avec des fins de ligne LF (fichiers lus par des conteneurs Linux).
    # Retire d'abord les attributs Cache / Lecture seule laisses par d'anciennes versions du script.
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Content
    )
    if (Test-Path -LiteralPath $Path) {
        [System.IO.File]::SetAttributes($Path, [System.IO.FileAttributes]::Normal)
    }
    $text = $Content -replace "`r`n", "`n"
    if (-not $text.EndsWith("`n")) { $text += "`n" }
    [System.IO.File]::WriteAllText($Path, $text, (New-Object System.Text.UTF8Encoding($false)))
}

function Backup-ExistingFiles {
    # Sauvegarde la configuration existante avant de l'ecraser. Retourne le dossier, ou $null.
    param([Parameter(Mandatory)][string]$InstallDir)

    $names = @('users.json', 'compose.yml', 'Caddyfile', 'auth_portal.py', 'CONFIGURATION-ROUTEUR.txt')
    $present = @($names | Where-Object { Test-Path -LiteralPath (Join-Path $InstallDir $_) })
    if ($present.Count -eq 0) { return $null }

    $backupDir = Join-Path $InstallDir ("backup-" + (Get-Date -Format "yyyyMMdd-HHmmss"))
    New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
    foreach ($name in $present) {
        Copy-Item -LiteralPath (Join-Path $InstallDir $name) -Destination (Join-Path $backupDir $name) -Force
    }
    $backupUsers = Join-Path $backupDir 'users.json'
    if (Test-Path -LiteralPath $backupUsers) { Protect-SecretFile -Path $backupUsers }
    return $backupDir
}

function Get-ExistingFriends {
    # Lit users.json d'une installation precedente. Retourne un tableau (vide s'il n'y en a pas).
    param([Parameter(Mandatory)][string]$UsersJsonPath)

    if (-not (Test-Path -LiteralPath $UsersJsonPath)) { return @() }
    try {
        $data = Get-Content -LiteralPath $UsersJsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    catch {
        throw "users.json existe mais n'est pas un JSON valide : $($_.Exception.Message)"
    }
    if ($null -eq $data) { return @() }

    $result = @()
    foreach ($property in $data.PSObject.Properties) {
        $id = $property.Name
        $record = $property.Value
        if ((Normalize-Id $id) -ne $id) {
            throw "L'identifiant '$id' de users.json n'est pas standard (minuscules, chiffres et tirets uniquement, sans commencer par un chiffre). Corrige users.json, ou reponds 'n' pour repartir de zero."
        }
        $fields = @($record.PSObject.Properties | ForEach-Object { $_.Name })
        if (($fields -notcontains 'salt') -or ($fields -notcontains 'hash')) {
            throw "L'entree '$id' de users.json n'a pas de champs salt/hash."
        }
        $iterations = 600000
        if ($fields -contains 'iterations') { $iterations = [int]$record.iterations }
        $result += [PSCustomObject]@{
            Id         = $id
            Username   = $id
            Password   = $null
            Salt       = $record.salt
            Hash       = $record.hash
            Iterations = $iterations
            Container  = "$id-firefox"
            IsNew      = $false
        }
    }
    return $result
}

function Get-ExistingHostname {
    # Nom DNS deja configure dans le Caddyfile d'une installation precedente, ou $null.
    param([Parameter(Mandatory)][string]$CaddyfilePath)

    if (-not (Test-Path -LiteralPath $CaddyfilePath)) { return $null }
    $text = Get-Content -LiteralPath $CaddyfilePath -Raw
    if ($text -match '(?m)^([A-Za-z0-9][A-Za-z0-9.-]*\.[A-Za-z]{2,})\s*\{\s*$') { return $Matches[1].ToLowerInvariant() }
    return $null
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

    if ((Invoke-NativeQuiet { docker compose version }) -ne 0) {
        throw "Docker Compose est indisponible. Mets a jour Docker Desktop."
    }

    if ((Invoke-NativeQuiet { docker info }) -ne 0) {
        throw "Le moteur Docker ne repond pas. Demarre Docker Desktop, attends qu'il soit pret, puis relance le script."
    }
}

function New-ComposeContent {
    param(
        [Parameter(Mandatory)][object[]]$Friends,
        [string]$MemoryLimit = "3g"
    )

    $serviceBlocks = New-Object System.Collections.Generic.List[string]
    foreach ($friend in $Friends) {
        $serviceBlocks.Add(@"
  $($friend.Container):
    image: jlesage/firefox:latest
    container_name: $($friend.Container)
    restart: unless-stopped
    environment:
      SECURE_CONNECTION: "1"
      WEB_AUTHENTICATION: "0"
      FF_OPEN_URL: "https://claude.ai"
      WEB_FILE_MANAGER: "1"
      WEB_FILE_MANAGER_ALLOWED_PATHS: "/config/downloads"
      WEB_TERMINAL: "0"
      WEB_HOST_CLIPBOARD_SYNC: "1"
      TZ: "Europe/Paris"
      FF_PREF_1: "browser.download.dir=/config/downloads"
      FF_PREF_2: "browser.download.folderList=2"
      FF_PREF_3: "browser.download.useDownloadDir=true"
    volumes:
      - "./data/$($friend.Id):/config"
    expose:
      - "5800"
    shm_size: "1gb"
    mem_limit: $MemoryLimit
    pids_limit: 2048
    security_opt:
      - no-new-privileges:true
    networks:
      - net-$($friend.Id)
    logging: *default-logging
"@)
    }

    $dependsOn = (@('auth-portal') + @($Friends | ForEach-Object { $_.Container }) | ForEach-Object { "      - $_" }) -join "`n"
    $caddyNetworks = (@('portal') + @($Friends | ForEach-Object { "net-$($_.Id)" }) | ForEach-Object { "      - $_" }) -join "`n"
    $networkDefinitions = (@($Friends | ForEach-Object { "  net-$($_.Id):" }) -join "`n")

    return @"
# Chaque ami a son propre reseau Docker : les navigateurs ne peuvent ni se joindre entre eux
# ni joindre le portail d'authentification. Seul Caddy est rattache a tous les reseaux.
# C'est CETTE separation qui protege chaque navigateur (WEB_AUTHENTICATION=0 : l'authentification
# est faite par le portail). Les navigateurs peuvent en revanche toujours atteindre l'hote Docker
# (host.docker.internal) et le reseau local : c'est inherent a un navigateur distant.
x-logging: &default-logging
  driver: json-file
  options:
    max-size: "10m"
    max-file: "3"

services:
  auth-portal:
    image: python:3-alpine
    container_name: claude-gateway-auth
    restart: unless-stopped
    user: "65534:65534"
    read_only: true
    tmpfs:
      - /tmp
    cap_drop:
      - ALL
    security_opt:
      - no-new-privileges:true
    mem_limit: 128m
    pids_limit: 128
    volumes:
      - "./auth_portal.py:/app/auth_portal.py:ro"
      - "./users.json:/app/users.json:ro"
    command: ["python", "-u", "/app/auth_portal.py"]
    expose:
      - "8080"
    networks:
      - portal
    logging: *default-logging
$($serviceBlocks -join "`n")
  caddy:
    image: caddy:2
    container_name: claude-gateway-caddy
    restart: unless-stopped
    cap_drop:
      - ALL
    cap_add:
      - NET_BIND_SERVICE
    security_opt:
      - no-new-privileges:true
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - "./Caddyfile:/etc/caddy/Caddyfile:ro"
      - "caddy_data:/data"
      - "caddy_config:/config"
    depends_on:
$dependsOn
    networks:
$caddyNetworks
    logging: *default-logging

networks:
  portal:
$networkDefinitions

volumes:
  caddy_data:
  caddy_config:
"@
}

function New-CaddyfileContent {
    param(
        [Parameter(Mandatory)][string]$PublicHost,
        [Parameter(Mandatory)][object[]]$Friends
    )

    $routes = New-Object System.Collections.Generic.List[string]
    foreach ($friend in $Friends) {
        $routes.Add(@"
            @is_$($friend.Id) header X-Auth-User $($friend.Username)
            handle @is_$($friend.Id) {
                reverse_proxy https://$($friend.Container):5800 {
                    header_up -Cookie
                    transport http {
                        tls_insecure_skip_verify
                    }
                }
            }
"@)
    }

    return @"
# Caddy obtient automatiquement le certificat HTTPS pour $PublicHost.
# Tous les amis utilisent la meme URL unique : https://$PublicHost
# Caddy verifie les sessions via le portail d'authentification, puis aiguille chaque
# personne vers SON conteneur Firefox d'apres l'en-tete X-Auth-User (fourni par le portail).

$PublicHost {
    # Le service n'est servi qu'en HTTPS.
    header Strict-Transport-Security "max-age=31536000"

    # 1. Routes publiques sans authentification
    @no_auth path /login /login/* /logout
    handle @no_auth {
        reverse_proxy http://auth-portal:8080
    }

    # 2. Toutes les autres routes requierent une session active
    handle {
        forward_auth http://auth-portal:8080 {
            uri /verify
            copy_headers X-Auth-User
        }

        # Page portail (interface d'accueil avec top bar et bouton deconnexion)
        @is_portal path / /portal /portal/*
        handle @is_portal {
            reverse_proxy http://auth-portal:8080
        }

        # Flux Firefox distant (noVNC) : le cookie de session du portail n'est jamais
        # transmis aux conteneurs Firefox (header_up -Cookie).
        handle_path /stream/* {
            header >X-Frame-Options "SAMEORIGIN"
            header >X-Content-Type-Options "nosniff"

$($routes -join "`n")

            # Utilisateur connu du portail mais sans conteneur : erreur explicite, pas une page blanche.
            handle {
                respond "Aucun navigateur n'est configure pour ce compte." 403
            }
        }
    }
}
"@
}

function New-RouterGuide {
    param([Parameter(Mandatory)][string]$PublicHost)

    return @"
CONFIGURATION A FAIRE SUR LE ROUTEUR
====================================

1. Reserve une adresse IP locale fixe pour ce PC Windows.
2. Redirige uniquement :
      TCP 80  -> IP_LOCALE_DU_PC:80
      TCP 443 -> IP_LOCALE_DU_PC:443
3. Ne redirige pas les ports 5800, 5900 ou 3389.
4. Verifie que le nom DNS ($PublicHost) resout vers ton adresse IP publique actuelle.
   Si ton adresse IP change (abonnement sans IP fixe), utilise un client DDNS pour
   mettre a jour le nom automatiquement, sinon l'acces tombe en panne sans message.
5. Si ton operateur utilise un CGNAT, la redirection de ports ne fonctionnera
   probablement pas. Il faudra alors utiliser un tunnel sortant (Termux / Cloudflare).

ACCES CLIENT (URL UNIQUE)
=========================
Tous les amis ouvrent exactement la MEME adresse web :
    https://$PublicHost

Lors de l'invite de connexion, chacun entre son propre identifiant et son mot de passe.
Le portail authentifie la personne et Caddy l'aiguille automatiquement vers son navigateur
Firefox personnel.

TEST LOCAL
==========
Depuis ce PC, lance :
    docker compose ps
    docker compose logs -f caddy
    docker compose logs -f auth-portal     (journal des connexions, reussies ou non)

Une fois le routeur et le DNS configures, teste l'URL depuis un reseau
exterieur a ta maison (ex: en 4G), pas uniquement depuis le Wi-Fi domestique.

AJOUTER UN AMI
==============
Relance install-claude-gateway.ps1 : reponds O pour conserver les amis existants
(leurs mots de passe ne changent pas), puis indique combien d'amis ajouter.
Les anciens fichiers sont sauvegardes dans un dossier backup-AAAAMMJJ-HHMMSS.

MAINTENANCE
===========
Mise a jour des images :
    docker compose pull
    docker compose up -d

Arret :
    docker compose down
"@
}

# Permet de charger les fonctions sans lancer l'installation (tests) :  . .\install-claude-gateway.ps1
if ($MyInvocation.InvocationName -eq '.') { return }

Write-Host ""
Write-Host "=== Passerelle Claude privee - Windows / Docker ===" -ForegroundColor Green
Write-Host ""
Write-WarningMessage "Cette passerelle donnera a tes amis un acces Internet sortant par ta connexion maison. Ne la partage qu'avec des personnes de confiance."
Write-WarningMessage "Leurs navigateurs peuvent aussi atteindre les services de ce PC et de ton reseau local : c'est inherent a un navigateur distant."
Write-WarningMessage "Le script ne configure pas le routeur et ne demande jamais de mot de passe Claude."
Write-Host ""

# Fichier source verifie AVANT de poser la moindre question (le .ps1 seul ne suffit pas).
$scriptBase = if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) { $PSScriptRoot } else { $PWD.Path }
$sourceAuthScript = [System.IO.Path]::Combine($scriptBase, "auth-portal", "auth_portal.py")
if (-not (Test-Path -LiteralPath $sourceAuthScript)) {
    $sourceAuthScript = [System.IO.Path]::Combine($PWD.Path, "auth-portal", "auth_portal.py")
}
if (-not (Test-Path -LiteralPath $sourceAuthScript)) {
    throw "Le fichier auth-portal\auth_portal.py est introuvable a cote du script. Telecharge le depot COMPLET (git clone, ou l'archive ZIP de GitHub) et lance le script depuis son dossier : le .ps1 seul ne suffit pas."
}

if (-not $GenerateOnly) { Ensure-Docker }

$composePath = Join-Path $InstallDir "compose.yml"
$caddyPath = Join-Path $InstallDir "Caddyfile"
$usersJsonPath = Join-Path $InstallDir "users.json"
$authPortalPath = Join-Path $InstallDir "auth_portal.py"
$gitignorePath = Join-Path $InstallDir ".gitignore"
$routerGuidePath = Join-Path $InstallDir "CONFIGURATION-ROUTEUR.txt"
$legacyEnvPath = Join-Path $InstallDir ".env"

$friends = @()
$usedIds = @{}

# Installation existante : on peut conserver les amis et en ajouter.
$existingFriends = @(Get-ExistingFriends -UsersJsonPath $usersJsonPath)
$keepExisting = $false
if ($existingFriends.Count -gt 0) {
    $names = ($existingFriends | ForEach-Object { $_.Id }) -join ", "
    Write-Info "Installation existante detectee ($($existingFriends.Count) ami(s) : $names)."
    $answer = Read-Host "Conserver ces amis (mots de passe inchanges) et en ajouter de nouveaux ? (O/n)"
    if ($answer -notmatch '^\s*(n|non|no)\s*$') {
        $keepExisting = $true
        foreach ($existing in $existingFriends) {
            $friends += $existing
            $usedIds[$existing.Id] = $true
            if (-not (Test-Path -LiteralPath (Join-Path (Join-Path $InstallDir "data") $existing.Id))) {
                Write-WarningMessage "Aucun profil Firefox existant pour '$($existing.Id)' (data\$($existing.Id) absent) : un navigateur vierge sera cree. Si cet identifiant est un alias de l'ami d'un autre profil (routage ajoute a la main dans le Caddyfile), reponds 'n' et corrige users.json d'abord."
            }
        }
        Write-WarningMessage "Les conteneurs vont etre recrees : les sessions ouvertes sur le portail seront perdues (les amis devront se reconnecter ; leurs profils Firefox sont conserves)."
    }
    else {
        Write-WarningMessage "Les amis existants seront remplaces (les anciens fichiers sont sauvegardes)."
    }
}

$defaultHost = Get-ExistingHostname -CaddyfilePath $caddyPath
do {
    $hostPrompt = "Nom DNS public general (exemple : mon-relais.duckdns.org)"
    if ($defaultHost) { $hostPrompt += " [$defaultHost]" }
    $rawHost = Read-Host $hostPrompt
    if ([string]::IsNullOrWhiteSpace($rawHost) -and $defaultHost) { $rawHost = $defaultHost }
    try {
        $publicHost = Normalize-Hostname $rawHost
    }
    catch {
        Write-WarningMessage $_.Exception.Message
        $publicHost = $null
    }
} while ([string]::IsNullOrWhiteSpace($publicHost))

$maxNew = $MaxFriends - $friends.Count
$minNew = if ($keepExisting) { 0 } else { 1 }
if ($maxNew -lt $minNew) { throw "Il y a deja $MaxFriends amis : impossible d'en ajouter." }
if ($keepExisting) { $countPrompt = "Combien d'amis veux-tu AJOUTER ($minNew a $maxNew) ?" } else { $countPrompt = "Combien d'amis veux-tu configurer ($minNew a $maxNew) ?" }
$countText = Read-Host $countPrompt
[int]$newCount = 0
if (-not [int]::TryParse($countText, [ref]$newCount) -or $newCount -lt $minNew -or $newCount -gt $maxNew) {
    throw "Le nombre d'amis doit etre compris entre $minNew et $maxNew."
}

for ($index = 1; $index -le $newCount; $index++) {
    Write-Host ""
    Write-Host "--- Nouvel ami $index / $newCount ---" -ForegroundColor Green

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

    $password = Read-FriendPassword -Id $id

    Write-Info "Generation du hash securise (PBKDF2-SHA256) pour $id..."
    $crypto = New-Pbkdf2Hash -Password $password
    $usedIds[$id] = $true

    $friends += [PSCustomObject]@{
        Id         = $id
        Username   = $id
        Password   = $password
        Salt       = $crypto.salt
        Hash       = $crypto.hash
        Iterations = $crypto.iterations
        Container  = "$id-firefox"
        IsNew      = $true
    }
}

if ($friends.Count -eq 0) { throw "Aucun ami a configurer." }

$composeContent = New-ComposeContent -Friends $friends -MemoryLimit $FirefoxMemoryLimit
$caddyContent = New-CaddyfileContent -PublicHost $publicHost -Friends $friends
$routerGuide = New-RouterGuide -PublicHost $publicHost

# users.json : uniquement des hashs PBKDF2 sales, jamais de mot de passe.
$usersDict = [ordered]@{}
foreach ($friend in $friends) {
    $usersDict[$friend.Username] = [ordered]@{
        salt       = $friend.Salt
        hash       = $friend.Hash
        iterations = $friend.Iterations
    }
}
$usersJsonContent = $usersDict | ConvertTo-Json -Depth 5

New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $InstallDir "data") -Force | Out-Null

$backupDir = Backup-ExistingFiles -InstallDir $InstallDir
if ($backupDir) { Write-Info "Anciens fichiers sauvegardes dans : $backupDir" }

# users.json en premier : si quelque chose echoue, compose.yml et le Caddyfile ne sont pas touches.
Write-TextFile -Path $usersJsonPath -Content $usersJsonContent
Protect-SecretFile -Path $usersJsonPath
Write-TextFile -Path $composePath -Content $composeContent
Write-TextFile -Path $caddyPath -Content $caddyContent
Copy-Item -LiteralPath $sourceAuthScript -Destination $authPortalPath -Force
Write-TextFile -Path $gitignorePath -Content ".env`nusers.json`ndata/`nbackup-*/`n"
Write-TextFile -Path $routerGuidePath -Content $routerGuide

if ((Test-Path -LiteralPath $legacyEnvPath) -and ((Get-Content -LiteralPath $legacyEnvPath -Raw) -match '_PASSWORD=')) {
    Write-WarningMessage "Un ancien fichier .env contient des mots de passe EN CLAIR : $legacyEnvPath"
    Write-WarningMessage "Il n'est plus utilise (les mots de passe ne sont stockes que sous forme de hash dans users.json). Supprime-le."
}

if ($GenerateOnly) {
    Write-Info "Mode -GenerateOnly : fichiers generes dans $InstallDir, Docker n'a pas ete lance."
}
else {
    Push-Location $InstallDir
    try {
        Write-Info "Telechargement des images Docker..."
        if ((Invoke-NativeVisible { docker compose pull }) -ne 0) {
            throw "Le telechargement des images Docker a echoue."
        }

        Write-Info "Demarrage des conteneurs..."
        if ((Invoke-NativeVisible { docker compose up -d --remove-orphans }) -ne 0) {
            throw "Le demarrage des conteneurs a echoue."
        }
    }
    finally {
        Pop-Location
    }
}

Write-Host ""
Write-Host "=== Installation locale terminee ===" -ForegroundColor Green
Write-Host "Fichiers crees dans : $InstallDir"
Write-Host ""
Write-WarningMessage "L'URL ne fonctionnera depuis l'exterieur qu'apres la configuration du routeur et du DNS."
Write-WarningMessage "Les mots de passe ne sont affiches qu'ici : transmets-les maintenant, ils ne sont stockes nulle part en clair."
Write-Host ""
Write-Host "Acces a transmettre aux amis :" -ForegroundColor Green
Write-Host "  URL unique pour tout le monde : https://$publicHost" -ForegroundColor Cyan
Write-Host ""
foreach ($friend in @($friends | Where-Object { $_.IsNew })) {
    Write-Host "  --- Ami : $($friend.Id) ---"
    Write-Host "  Identifiant : $($friend.Username)"
    Write-Host "  Mot de passe : $($friend.Password)"
    Write-Host ""
}
$keptNames = @($friends | Where-Object { -not $_.IsNew } | ForEach-Object { $_.Id })
if ($keptNames.Count -gt 0) {
    Write-Host "Amis conserves (identifiants inchanges) : $($keptNames -join ', ')"
    Write-Host ""
}

Write-Host "Commandes utiles :" -ForegroundColor Green
Write-Host "  cd `"$InstallDir`""
Write-Host "  docker compose ps"
Write-Host "  docker compose logs -f caddy"
Write-Host "  docker compose logs -f auth-portal"
Write-Host "  docker compose down"
Write-Host ""
Write-Host "Chaque ami doit ensuite se connecter avec son propre compte Claude dans son Firefox distant." -ForegroundColor Cyan
