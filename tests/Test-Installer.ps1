# Tests de install-claude-gateway.ps1 (valides sous Windows PowerShell 5.1). Aucun conteneur n'est demarre.
# Lancer depuis n'importe ou :  powershell -NoProfile -ExecutionPolicy Bypass -File tests\Test-Installer.ps1
[CmdletBinding()]
param(
    [string]$WorkDir = (Join-Path ([System.IO.Path]::GetTempPath()) ("ccu-tests-" + [guid]::NewGuid().ToString('N').Substring(0, 8)))
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$installerPath = Join-Path $repoRoot 'install-claude-gateway.ps1'
$portalPath = Join-Path $repoRoot 'auth-portal\auth_portal.py'
$script:failures = 0
$script:passed = 0

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if ($Condition) { $script:passed++; Write-Output "ok   $Message" }
    else { $script:failures++; Write-Output "FAIL $Message" }
}

function Get-Bytes { param([string]$Path) return , [System.IO.File]::ReadAllBytes($Path) }

function Invoke-Capture {
    # Lance une commande native en capturant sortie + code de retour, sans NativeCommandError.
    param([scriptblock]$Command)
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $global:LASTEXITCODE = 0
    try { $lines = & $Command 2>&1 | ForEach-Object { "$_" } } finally { $ErrorActionPreference = $previous }
    return [PSCustomObject]@{ Output = ($lines -join "`n"); ExitCode = $LASTEXITCODE }
}

New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null
Write-Output "Dossier de travail : $WorkDir"

# ---------------------------------------------------------------------------------------------
Write-Output "`n== 1. Analyse statique"
$tokens = $null; $errors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($installerPath, [ref]$tokens, [ref]$errors)
Assert-True ($errors.Count -eq 0) "le script est syntaxiquement valide"
$installerBytes = Get-Bytes $installerPath
Assert-True (-not ($installerBytes | Where-Object { $_ -gt 127 } | Select-Object -First 1)) "le script est en ASCII pur (Windows PowerShell 5.1 lit l'UTF-8 sans BOM comme de l'ANSI)"

# ---------------------------------------------------------------------------------------------
Write-Output "`n== 2. Fonctions (chargees par dot-sourcing, sans lancer l'installation)"
. $installerPath
Assert-True ((Get-Command New-ComposeContent -ErrorAction SilentlyContinue) -and (Get-Command Normalize-Id -ErrorAction SilentlyContinue)) "le dot-sourcing charge les fonctions sans executer l'installation"

Assert-True ((Normalize-Id 'Gabi') -eq 'gabi') "Normalize-Id met en minuscules"
Assert-True ((Normalize-Id '123abc') -eq 'ami-123abc') "Normalize-Id prefixe un identifiant qui commence par un chiffre"
Assert-True ((Normalize-Id 'x;rm -rf') -eq 'x-rm--rf') "Normalize-Id neutralise les caracteres dangereux"
foreach ($bad in '---', '   ') {
    $threw = $false; try { [void](Normalize-Id $bad) } catch { $threw = $true }
    Assert-True $threw "Normalize-Id refuse '$bad'"
}
Assert-True ((Normalize-Hostname 'https://Mon-Relais.DuckDNS.org/') -eq 'mon-relais.duckdns.org') "Normalize-Hostname nettoie l'URL"
foreach ($bad in 'foo', 'foo.bar:8443', 'a..b.org', '-a.org', 'foo.bar.org }', '192.168.1.10') {
    $threw = $false; try { [void](Normalize-Hostname $bad) } catch { $threw = $true }
    Assert-True $threw "Normalize-Hostname refuse '$bad'"
}

$generated = 1..50 | ForEach-Object { New-RandomPassword -Length 24 }
Assert-True (@($generated | Where-Object { $_.Length -ne 24 }).Count -eq 0) "New-RandomPassword renvoie 24 caracteres"
Assert-True (@($generated | Select-Object -Unique).Count -eq 50) "New-RandomPassword ne repete pas de valeur"
Assert-True (-not ($generated | Where-Object { $_ -notmatch '^[ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789]+$' } | Select-Object -First 1)) "New-RandomPassword n'utilise que l'alphabet prevu"

$unicodePassword = [string]::Concat('p', [char]0x00E4, 'ssw', [char]0x00F6, 'rd-', [char]0x20AC, [char]0x65E5)
$hashA = New-Pbkdf2Hash -Password $unicodePassword
$hashB = New-Pbkdf2Hash -Password $unicodePassword
Assert-True (($hashA.iterations -eq 600000) -and ($hashA.salt.Length -eq 32) -and ($hashA.hash.Length -eq 64)) "New-Pbkdf2Hash : 600000 iterations, sel 16 octets, hash 32 octets"
Assert-True ($hashA.salt -ne $hashB.salt) "New-Pbkdf2Hash : un sel different a chaque appel"

$python = Get-Command python -ErrorAction SilentlyContinue
if ($python) {
    $pyCode = "import importlib.util,json,sys; s=importlib.util.spec_from_file_location('ap', sys.argv[1]); ap=importlib.util.module_from_spec(s); s.loader.exec_module(ap); r=json.loads(sys.argv[2]); print(ap.verify_password(r, sys.argv[3]))"
    $recordJson = (@{ salt = $hashA.salt; hash = $hashA.hash; iterations = $hashA.iterations } | ConvertTo-Json -Compress).Replace('"', '\"')
    $res = Invoke-Capture { & python -c $pyCode $portalPath $recordJson $unicodePassword }
    Assert-True ($res.Output.Trim() -eq 'True') "le hash PowerShell est accepte par auth_portal.py (mot de passe avec accents)"
}
else { Write-Output "skip Python absent : verification croisee PBKDF2 ignoree" }

$fileProbe = Join-Path $WorkDir 'probe.txt'
[System.IO.File]::WriteAllText($fileProbe, 'x')
Protect-SecretFile -Path $fileProbe
$acl = Get-Acl -LiteralPath $fileProbe
Assert-True (($acl.AreAccessRulesProtected) -and (@($acl.Access).Count -eq 1)) "Protect-SecretFile : droits limites a un seul compte, heritage coupe"
$warningSeen = $false
$warningSeen = (Protect-SecretFile -Path $fileProbe 6>&1 | Out-String) -match "Impossible de restreindre"
Assert-True (-not $warningSeen) "Protect-SecretFile : idempotent (2e appel sur un fichier deja protege, sans avertissement)"
Assert-True (-not ((Get-Item -LiteralPath $fileProbe -Force).Attributes -band [System.IO.FileAttributes]::Hidden)) "Protect-SecretFile ne cache plus le fichier"
[System.IO.File]::SetAttributes($fileProbe, [System.IO.FileAttributes]::Hidden)
$threw = $false; try { Write-TextFile -Path $fileProbe -Content "nouveau`r`ncontenu" } catch { $threw = $true }
Assert-True ((-not $threw) -and ([System.IO.File]::ReadAllText($fileProbe) -eq "nouveau`ncontenu`n")) "Write-TextFile ecrase un fichier cache (bug de la 2e execution) et normalise en LF"

$previousEap = $ErrorActionPreference
$ErrorActionPreference = 'Stop'
$threw = $false
try { $code = Invoke-NativeQuiet { cmd /c "echo boom 1>&2 & exit 3" } } catch { $threw = $true }
$ErrorActionPreference = $previousEap
Assert-True ((-not $threw) -and ($code -eq 3)) "Invoke-NativeQuiet : pas de NativeCommandError, code de sortie conserve"

# ---------------------------------------------------------------------------------------------
Write-Output "`n== 3. Ensure-Docker : messages lisibles quand Docker ne repond pas"
function docker { if ($args[0] -eq 'info') { cmd /c "echo moteur arrete 1>&2 & exit 1" } else { cmd /c "exit 0" } }
$message = 'aucune erreur'
try { Ensure-Docker } catch { $message = $_.Exception.Message }
Assert-True ($message -like '*moteur Docker ne repond pas*') "moteur arrete -> message prevu (et non NativeCommandError) : $message"
function docker { cmd /c "echo plugin absent 1>&2 & exit 1" }
$message = 'aucune erreur'
try { Ensure-Docker } catch { $message = $_.Exception.Message }
Assert-True ($message -like '*Compose est indisponible*') "compose absent -> message prevu : $message"
Remove-Item function:docker

# ---------------------------------------------------------------------------------------------
Write-Output "`n== 4. Contenu genere (compose.yml / Caddyfile)"
$twoFriends = @(
    [PSCustomObject]@{ Id = 'gabi'; Username = 'gabi'; Container = 'gabi-firefox' },
    [PSCustomObject]@{ Id = 'maxim'; Username = 'maxim'; Container = 'maxim-firefox' }
)
$composeText = New-ComposeContent -Friends $twoFriends -MemoryLimit '2g'
$caddyText = New-CaddyfileContent -PublicHost 'relais.example.org' -Friends $twoFriends
Assert-True ($composeText -match 'net-gabi' -and $composeText -match 'net-maxim') "un reseau Docker par ami"
Assert-True ($composeText -notmatch 'VNC_LOCALHOST_ONLY') "pas de VNC_LOCALHOST_ONLY (sans effet avec SECURE_CONNECTION=1, verifie sur l'image reelle) : l'isolation vient des reseaux"
Assert-True ($composeText -match 'mem_limit: 2g') "limite memoire appliquee aux navigateurs"
Assert-True (-not ($composeText -match '(?m)^\s*-\s*"?(5800|5900|8080):')) "aucun port interne n'est publie sur l'hote"
Assert-True ($caddyText -match 'header_up -Cookie') "le cookie du portail n'est pas transmis aux navigateurs"
Assert-True ($caddyText -match '(?s)handle \{\s*respond "[^"]+" 403') "un utilisateur sans conteneur recoit un 403 explicite"
Assert-True (-not ($caddyText -match 'novnc_root')) "plus de bloc de routage racine superflu"

# alias : un compte qui partage le navigateur d'un autre ami
$withAlias = @($twoFriends[0]) + @([PSCustomObject]@{ Id = 'gsmario'; Username = 'gsmario'; Container = 'gabi-firefox'; AliasOf = 'gabi' }) + @($twoFriends[1])
$aliasCompose = New-ComposeContent -Friends $withAlias
$aliasCaddy = New-CaddyfileContent -PublicHost 'relais.example.org' -Friends $withAlias
Assert-True (($aliasCompose -notmatch 'gsmario') -and ($aliasCompose -match 'gabi-firefox:') -and ($aliasCompose -match 'maxim-firefox:')) "alias : pas de conteneur ni de reseau pour l'alias"
Assert-True ($aliasCaddy -match '@is_gabi header_regexp X-Auth-User \^\(gabi\|gsmario\)\$') "alias : l'alias est route vers le navigateur de gabi"
Assert-True ($aliasCaddy -match '@is_maxim header X-Auth-User maxim') "alias : les comptes sans alias gardent une correspondance exacte"

$composeFile = Join-Path $WorkDir 'compose-check\compose.yml'
New-Item -ItemType Directory -Path (Split-Path $composeFile) -Force | Out-Null
Write-TextFile -Path $composeFile -Content $composeText
if (Get-Command docker -ErrorAction SilentlyContinue) {
    $res = Invoke-Capture { docker compose -f $composeFile config --format json }
    if ($res.ExitCode -eq 0) {
        $cfg = $res.Output | ConvertFrom-Json
        $netsOf = { param($name) @($cfg.services.$name.networks.PSObject.Properties.Name) }
        Assert-True ((@(& $netsOf 'auth-portal') -join ',') -eq 'portal') "auth-portal n'est que sur le reseau 'portal'"
        Assert-True ((@(& $netsOf 'gabi-firefox') -join ',') -eq 'net-gabi') "gabi-firefox n'est que sur net-gabi"
        Assert-True ((@(& $netsOf 'maxim-firefox') -join ',') -eq 'net-maxim') "maxim-firefox n'est que sur net-maxim"
        Assert-True ((@(& $netsOf 'caddy') | Sort-Object) -join ',' -eq 'net-gabi,net-maxim,portal') "caddy est rattache a tous les reseaux"
        Assert-True ($cfg.services.'gabi-firefox'.mem_limit -eq 2147483648) "mem_limit 2g = 2147483648 octets"
        Assert-True ($cfg.services.'auth-portal'.read_only -eq $true -and $cfg.services.'auth-portal'.user -eq '65534:65534') "auth-portal : lecture seule, utilisateur non privilegie"
    }
    else { Write-Output "skip docker compose config --format json indisponible : $($res.Output.Split("`n")[0])" }
    $hasCaddyImage = (Invoke-Capture { docker image inspect caddy:2 }).ExitCode -eq 0
    if ($hasCaddyImage) {
        $caddyFile = Join-Path $WorkDir 'compose-check\Caddyfile'
        Write-TextFile -Path $caddyFile -Content $caddyText
        $res = Invoke-Capture { docker run --rm --network none -v "${caddyFile}:/etc/caddy/Caddyfile:ro" caddy:2 caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile }
        Assert-True ($res.Output -match 'Valid configuration') "caddy validate accepte le Caddyfile genere"
        $aliasCaddyFile = Join-Path $WorkDir 'compose-check\Caddyfile.alias'
        Write-TextFile -Path $aliasCaddyFile -Content $aliasCaddy
        $res = Invoke-Capture { docker run --rm --network none -v "${aliasCaddyFile}:/etc/caddy/Caddyfile:ro" caddy:2 caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile }
        Assert-True ($res.Output -match 'Valid configuration') "caddy validate accepte le Caddyfile avec alias"
    }
    else { Write-Output "skip image caddy:2 absente : validation du Caddyfile ignoree (aucun telechargement)" }
}
else { Write-Output "skip Docker absent : compose config / caddy validate ignores" }

# ---------------------------------------------------------------------------------------------
Write-Output "`n== 5. Installation complete simulee (vrai script, -GenerateOnly, saisies simulees)"
$global:__answers = New-Object System.Collections.Queue
$global:__prompts = New-Object System.Collections.Generic.List[string]
function Read-Host {
    param([string]$Prompt, [switch]$AsSecureString)
    $global:__prompts.Add($Prompt)
    if ($global:__answers.Count -eq 0) { throw "Read-Host inattendu : $Prompt" }
    $value = [string]$global:__answers.Dequeue()
    if ($AsSecureString) {
        $secure = New-Object System.Security.SecureString
        foreach ($c in $value.ToCharArray()) { $secure.AppendChar($c) }
        $secure.MakeReadOnly()
        return $secure
    }
    return $value
}
function Invoke-Installer {
    param([string[]]$Answers, [string]$Dir, [string]$Script = $installerPath, [hashtable]$AliasMap = @{})
    $global:__answers.Clear(); $global:__prompts.Clear()
    foreach ($a in $Answers) { $global:__answers.Enqueue($a) }
    $log = Join-Path $WorkDir 'installer.log'
    & $Script -InstallDir $Dir -GenerateOnly -Alias $AliasMap *> $log
    return (Get-Content -LiteralPath $log -Raw)
}
function Read-Users { param([string]$Dir) return (Get-Content -LiteralPath (Join-Path $Dir 'users.json') -Raw | ConvertFrom-Json) }

$installDirA = Join-Path $WorkDir 'install'
$typedPassword = 'Un-mot-de-passe-solide-1'

# 5a. premiere installation : deux amis (un mot de passe saisi, un genere)
$log = Invoke-Installer -Dir $installDirA -Answers @('relais.example.org', '2', 'Gabi', $typedPassword, $typedPassword, 'maxim', '')
$users = Read-Users $installDirA
Assert-True ((@($users.PSObject.Properties.Name) -join ',') -eq 'gabi,maxim') "5a users.json contient gabi et maxim"
$usersRaw = Get-Content -LiteralPath (Join-Path $installDirA 'users.json') -Raw
Assert-True (-not $usersRaw.Contains($typedPassword)) "5a users.json ne contient aucun mot de passe en clair"
Assert-True (-not (Test-Path -LiteralPath (Join-Path $installDirA '.env'))) "5a aucun fichier .env (il contenait les mots de passe en clair)"
Assert-True (-not ((Get-Item -LiteralPath (Join-Path $installDirA 'users.json') -Force).Attributes -band [System.IO.FileAttributes]::Hidden)) "5a users.json n'est pas cache"
$badFiles = @('users.json', 'compose.yml', 'Caddyfile', 'CONFIGURATION-ROUTEUR.txt') | Where-Object {
    $b = Get-Bytes (Join-Path $installDirA $_)
    ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) -or ($b -contains 13)
}
Assert-True (-not $badFiles) "5a fichiers generes en UTF-8 sans BOM et fins de ligne LF"
Assert-True (@(Get-ChildItem -LiteralPath $installDirA -Directory -Filter 'backup-*').Count -eq 0) "5a pas de sauvegarde a la premiere installation"
Assert-True ($log -match 'Identifiant : gabi' -and $log -match 'Identifiant : maxim' -and $log.Contains($typedPassword)) "5a les identifiants sont affiches a la fin"
Assert-True ($log -notmatch 'mot de passe genere automatiquement') "5a le mot de passe genere n'est pas affiche en cours de route"
Assert-True ((Get-Content -LiteralPath (Join-Path $installDirA 'auth_portal.py') -Raw) -match 'def authenticate') "5a auth_portal.py recopie (version durcie)"
$gabiBefore = $users.gabi

# 5b. relance sur une installation heritee de l'ancien script : users.json cache + .env en clair -> ajout d'un ami
[System.IO.File]::SetAttributes((Join-Path $installDirA 'users.json'), [System.IO.FileAttributes]::Hidden)
[System.IO.File]::WriteAllText((Join-Path $installDirA '.env'), "GABI_PASSWORD=ancien`n")
New-Item -ItemType Directory -Path (Join-Path $installDirA 'data\gabi') -Force | Out-Null   # gabi a deja un profil, maxim non
$log = Invoke-Installer -Dir $installDirA -Answers @('O', '', '1', 'jojo', $typedPassword, $typedPassword)
Assert-True (($log -match "Aucun profil Firefox existant pour 'maxim'") -and ($log -notmatch "Aucun profil Firefox existant pour 'gabi'")) "5b relance : avertit quand un ami conserve n'a pas de profil (alias possible), pas pour celui qui en a un"
Assert-True ($log -match 'sessions ouvertes sur le portail seront perdues') "5b relance : previent que les sessions du portail seront perdues"
$users = Read-Users $installDirA
Assert-True ((@($users.PSObject.Properties.Name) -join ',') -eq 'gabi,maxim,jojo') "5b relance : les amis existants sont conserves, jojo ajoute (plus d'erreur 'acces refuse')"
Assert-True (($users.gabi.salt -eq $gabiBefore.salt) -and ($users.gabi.hash -eq $gabiBefore.hash)) "5b relance : le mot de passe de gabi est inchange"
Assert-True ($log -match 'relais\.example\.org') "5b relance : le nom DNS est repris du Caddyfile existant"
$backups = @(Get-ChildItem -LiteralPath $installDirA -Directory -Filter 'backup-*')
Assert-True (($backups.Count -eq 1) -and (Test-Path -LiteralPath (Join-Path $backups[0].FullName 'users.json')) -and (Test-Path -LiteralPath (Join-Path $backups[0].FullName 'compose.yml'))) "5b relance : anciens fichiers sauvegardes"
Assert-True ($log -match 'ancien fichier \.env contient des mots de passe EN CLAIR') "5b relance : avertissement sur l'ancien .env en clair"
Assert-True ($log -match 'Amis conserves \(identifiants inchanges\) : gabi, maxim') "5b relance : resume des amis conserves"
$composeNow = Get-Content -LiteralPath (Join-Path $installDirA 'compose.yml') -Raw
Assert-True (($composeNow -match 'net-jojo') -and ($composeNow -match 'jojo-firefox')) "5b relance : compose.yml contient le nouvel ami"

# 5c. relance en repartant de zero
$log = Invoke-Installer -Dir $installDirA -Answers @('n', 'relais.example.org', '1', 'solo', '')
$users = Read-Users $installDirA
Assert-True ((@($users.PSObject.Properties.Name) -join ',') -eq 'solo') "5c 'n' remplace les amis existants"
Assert-True (@(Get-ChildItem -LiteralPath $installDirA -Directory -Filter 'backup-*').Count -ge 1) "5c l'ancienne configuration reste sauvegardee"

# 5d. validations de saisie
$installDirD = Join-Path $WorkDir 'install-d'
$null = Invoke-Installer -Dir $installDirD -Answers @('relais.example.org', '1', 'ami', 'court', $typedPassword, 'different-12345678', $typedPassword, $typedPassword)
Assert-True ((Read-Users $installDirD).PSObject.Properties.Name -contains 'ami') "5d mot de passe trop court, puis confirmation differente : redemandes avant d'accepter"
$threw = $false; try { $null = Invoke-Installer -Dir (Join-Path $WorkDir 'install-e') -Answers @('relais.example.org', '99') } catch { $threw = $true }
Assert-True $threw "5d nombre d'amis hors limites refuse"
$threw = $false; $null = Invoke-Installer -Dir (Join-Path $WorkDir 'install-f') -Answers @('192.168.1.10', 'relais.example.org', '1', 'ami', '') 2>$null
Assert-True ((Read-Users (Join-Path $WorkDir 'install-f')).PSObject.Properties.Name -contains 'ami') "5d une adresse IP comme nom DNS est redemandee"

# 5f. alias : gsmario partage le navigateur de gabi (cas d'une installation reelle retouchee a la main)
$installDirG = Join-Path $WorkDir 'install-g'
$null = Invoke-Installer -Dir $installDirG -Answers @('relais.example.org', '2', 'gabi', $typedPassword, $typedPassword, 'gsmario', $typedPassword, $typedPassword)
New-Item -ItemType Directory -Path (Join-Path $installDirG 'data\gabi') -Force | Out-Null
$gsmarioBefore = (Read-Users $installDirG).gsmario
$log = Invoke-Installer -Dir $installDirG -Answers @('O', '', '0') -AliasMap @{ gsmario = 'gabi' }
$users = Read-Users $installDirG
Assert-True (($users.gsmario.alias_of -eq 'gabi') -and ($users.gsmario.hash -eq $gsmarioBefore.hash) -and ($users.gsmario.salt -eq $gsmarioBefore.salt)) "5f -Alias : alias_of enregistre, mot de passe inchange"
$composeG = Get-Content -LiteralPath (Join-Path $installDirG 'compose.yml') -Raw
Assert-True (($composeG -match 'gabi-firefox:') -and ($composeG -notmatch 'gsmario')) "5f l'alias n'a pas de conteneur"
Assert-True ((Get-Content -LiteralPath (Join-Path $installDirG 'Caddyfile') -Raw) -match '\^\(gabi\|gsmario\)\$') "5f le Caddyfile route gsmario vers gabi"
Assert-True (($log -match "Alias : 'gsmario' utilise le navigateur de 'gabi'") -and ($log -notmatch 'Aucun profil Firefox existant')) "5f pas d'avertissement 'profil absent' pour un alias"
$null = Invoke-Installer -Dir $installDirG -Answers @('O', '', '0')
$users = Read-Users $installDirG
Assert-True ($users.gsmario.alias_of -eq 'gabi') "5f l'alias est conserve aux relances suivantes (sans -Alias)"
$message = 'aucune erreur'; try { $null = Invoke-Installer -Dir $installDirG -Answers @('O', '', '0') -AliasMap @{ inconnu = 'gabi' } } catch { $message = $_.Exception.Message }
Assert-True ($message -like "*'inconnu' n'existe pas*") "5f -Alias refuse un compte inexistant"
$message = 'aucune erreur'; try { $null = Invoke-Installer -Dir $installDirG -Answers @('O', '', '0') -AliasMap @{ gsmario = 'personne' } } catch { $message = $_.Exception.Message }
Assert-True ($message -like "*'personne' n'est pas un ami*") "5f -Alias refuse une cible inexistante"
$message = 'aucune erreur'; try { $null = Invoke-Installer -Dir $installDirG -Answers @('n', 'relais.example.org', '1', 'solo', '') -AliasMap @{ gsmario = 'gabi' } } catch { $message = $_.Exception.Message }
Assert-True ($message -like '*ne s''applique qu''a une installation existante*') "5f -Alias refuse de s'appliquer quand on repart de zero"
$raw = (Get-Content -LiteralPath (Join-Path $installDirG 'users.json') -Raw).Replace('"alias_of":  "gabi"', '"alias_of":  "fantome"')
[System.IO.File]::WriteAllText((Join-Path $installDirG 'users.json'), $raw)
$message = 'aucune erreur'; try { $null = Invoke-Installer -Dir $installDirG -Answers @('O', '', '0') } catch { $message = $_.Exception.Message }
Assert-True ($message -like "*alias de 'fantome'*") "5f un alias_of vers un ami inexistant dans users.json est refuse avec un message clair"

# 5e. le .ps1 seul (sans auth-portal\) echoue AVANT la premiere question
$aloneDir = Join-Path $WorkDir 'alone'
New-Item -ItemType Directory -Path $aloneDir -Force | Out-Null
Copy-Item -LiteralPath $installerPath -Destination (Join-Path $aloneDir 'install-claude-gateway.ps1')
$message = 'aucune erreur'
Push-Location $aloneDir
try { $null = Invoke-Installer -Dir (Join-Path $aloneDir 'out') -Answers @('relais.example.org', '1', 'ami', '') -Script (Join-Path $aloneDir 'install-claude-gateway.ps1') } catch { $message = $_.Exception.Message } finally { Pop-Location }
Assert-True (($message -like '*auth_portal.py*') -and ($global:__prompts.Count -eq 0)) "5e le .ps1 seul echoue immediatement avec un message clair, sans poser de question"

# ---------------------------------------------------------------------------------------------
Remove-Item function:Read-Host
Get-ChildItem -LiteralPath $WorkDir -Recurse -Force -File | ForEach-Object { [System.IO.File]::SetAttributes($_.FullName, [System.IO.FileAttributes]::Normal) }
Remove-Item -LiteralPath $WorkDir -Recurse -Force -ErrorAction SilentlyContinue

Write-Output "`n$script:passed ok, $script:failures echec(s)"
if ($script:failures -gt 0) { exit 1 }
