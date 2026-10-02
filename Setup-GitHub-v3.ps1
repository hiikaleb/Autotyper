#Requires -Version 5.1
<#
  SETUP GITHUB v3 - Windows 10/11

  Publica pastas no GitHub, ativa GitHub Pages / dominio proprio e traz
  ferramentas de dia a dia (status, historico, branches, tags, backup...).

  Uso:
    .\Setup-GitHub-v3.ps1                      -> menu principal
    .\Setup-GitHub-v3.ps1 -Mode publish -ProjectPath "D:\meu-site"
    Modos: menu | publish | new | update | host | all | status | clone | doctor | engines
#>
param(
    [string]$ProjectPath = "",
    [ValidateSet("menu","publish","new","update","engines","host","all","status","clone","doctor")]
    [string]$Mode = "menu"
)

# Permite arrastar uma pasta sobre o .bat (o .bat entrega o caminho por variavel de ambiente)
if ([string]::IsNullOrWhiteSpace($ProjectPath) -and $env:SETUPGH_PATH) {
    $ProjectPath = $env:SETUPGH_PATH
    if ($Mode -eq "menu") { $Mode = "publish" }
}

$ErrorActionPreference = "Stop"
$ProgressPreference    = "SilentlyContinue"
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

# ----------------------------------------------------------------------------
# Estado global e constantes
# ----------------------------------------------------------------------------
$script:Version          = "3.0"
$script:ScriptDir        = if ($PSCommandPath) { Split-Path -Parent $PSCommandPath } else { (Get-Location).ProviderPath }
$script:AppDir           = Join-Path $env:APPDATA "SetupGitHub"
$script:LogDir           = Join-Path $script:AppDir "logs"
$script:RecentFile       = Join-Path $script:AppDir "recent.txt"
$script:ActiveProject    = $null
$script:LastOutput       = ""
$script:LogFile          = ""
$script:TranscriptOn     = $false
$script:HadError         = $false
$script:LargeWarnBytes   = 50MB
$script:LargeBlockBytes  = 100MB

$script:TextExtensions = @(".html",".htm",".css",".js",".mjs",".cjs",".ts",".tsx",".jsx",".json",".md",".txt",
                           ".yml",".yaml",".toml",".ini",".cfg",".config",".py",".ps1",".sh",".bat",".cmd",
                           ".xml",".php",".env")

$script:SecretNameRegexes = @(
    '(^|/)\.env(\.[^/]+)?$',
    '\.(pem|key|pfx|p12|jks|keystore)$',
    '(^|/)id_(rsa|dsa|ecdsa|ed25519)$',
    '(^|/)\.(npmrc|netrc)$',
    'firebase-adminsdk[^/]*\.json$',
    'service[-_]?account[^/]*\.json$',
    '(^|/)(credentials|secrets?)(\.[^/]+)?$'
)
$script:SecretSafeSuffix = '\.(example|sample|template|dist)$'

$script:SecretContentPatterns = @(
    @{ Name = "chave privada";         Regex = '-----BEGIN (RSA |EC |DSA |OPENSSH |PGP )?PRIVATE KEY' },
    @{ Name = "AWS access key";        Regex = '\bAKIA[0-9A-Z]{16}\b' },
    @{ Name = "token do GitHub";       Regex = '\b(ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{36,}\b|\bgithub_pat_[A-Za-z0-9_]{50,}\b' },
    @{ Name = "token do Slack";        Regex = '\bxox[baprs]-[A-Za-z0-9-]{10,}' },
    @{ Name = "chave secreta Stripe";  Regex = '\bsk_live_[A-Za-z0-9]{20,}' },
    @{ Name = "chave de API (sk-...)"; Regex = '\bsk-(ant-)?[A-Za-z0-9_-]{32,}' }
)

# ----------------------------------------------------------------------------
# Saida no console
# ----------------------------------------------------------------------------
function Write-Ok($msg)   { Write-Host "[OK] $msg" -ForegroundColor Green }
function Write-Info($msg) { Write-Host "[*] $msg"  -ForegroundColor Cyan }
function Write-Warn($msg) { Write-Host "[!] $msg"  -ForegroundColor Yellow }
function Write-Fail($msg) { Write-Host "[X] $msg"  -ForegroundColor Red }

function Write-Header([string]$Title, [string]$Color = "Cyan") {
    $line = "=" * 60
    Write-Host ""
    Write-Host $line -ForegroundColor $Color
    Write-Host ("  " + $Title) -ForegroundColor $Color
    Write-Host $line -ForegroundColor $Color
    Write-Host ""
}

function Pause-Script {
    Write-Host ""
    [void](Read-Host "Pressione Enter para continuar")
}

function Stop-Operation([string]$Message = "Operacao cancelada.") {
    throw (New-Object System.OperationCanceledException $Message)
}

function Read-YesNo([string]$Prompt, [bool]$Default = $false) {
    $suffix = if ($Default) { "[S/n]" } else { "[s/N]" }
    $answer = (Read-Host "$Prompt $suffix").Trim().ToLower()
    if ($answer -eq "") { return $Default }
    return ($answer -in @("s","sim","y","yes"))
}

function Read-Choice([string]$Prompt, [string[]]$Valid) {
    while ($true) {
        $value = (Read-Host $Prompt).Trim().ToLower()
        if ($Valid -contains $value) { return $value }
        Write-Warn "Opcao invalida."
    }
}

# ----------------------------------------------------------------------------
# Execucao de comandos nativos (sem erros falsos por causa do stderr)
# ----------------------------------------------------------------------------
function Test-Command([string]$Name) {
    return $null -ne (Get-Command $Name -ErrorAction SilentlyContinue)
}

# Converte uma linha de saida nativa (string ou ErrorRecord do stderr) em texto limpo.
function Format-NativeLine($Item) {
    if ($Item -is [System.Management.Automation.ErrorRecord]) { $t = $Item.Exception.Message } else { $t = "$Item" }
    $parts = @($t -split "`r" | Where-Object { $_ -ne "" })
    if ($parts.Count -eq 0) { return "" }
    return ($parts[-1] -replace '\x1b\[[0-9;]*[A-Za-z]', '')
}

# Executa em silencio e devolve ExitCode + Output (stdout+stderr).
function Invoke-Native {
    param([string]$File, [string[]]$Arguments = @(), [switch]$StdoutOnly)
    if (-not (Test-Command $File)) {
        return [pscustomobject]@{ ExitCode = 127; Output = "Comando nao encontrado: $File" }
    }
    $old = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        if ($StdoutOnly) { $lines = @(& $File @Arguments 2>$null) }
        else             { $lines = @(& $File @Arguments 2>&1 | ForEach-Object { Format-NativeLine $_ }) }
        $code = $LASTEXITCODE
    } finally { $ErrorActionPreference = $old }
    $text = (($lines | ForEach-Object { "$_" }) -join "`n").Trim()
    return [pscustomobject]@{ ExitCode = [int]$code; Output = $text }
}

# Executa mostrando a saida (cinza) e guarda em $script:LastOutput. Retorna o codigo de saida.
function Invoke-Live {
    param([string]$File, [string[]]$Arguments = @())
    $script:LastOutput = ""
    if (-not (Test-Command $File)) {
        $script:LastOutput = "Comando nao encontrado: $File"
        Write-Fail $script:LastOutput
        return 127
    }
    $buffer = New-Object System.Collections.Generic.List[string]
    $old = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        & $File @Arguments 2>&1 | ForEach-Object {
            $line = Format-NativeLine $_
            $buffer.Add($line)
            if ($line -ne "") { Write-Host "    $line" -ForegroundColor DarkGray }
        }
        $code = $LASTEXITCODE
    } finally { $ErrorActionPreference = $old }
    $script:LastOutput = ($buffer -join "`n")
    return [int]$code
}

# Executa com o console real (winget, login do gh). Retorna o codigo de saida.
function Invoke-Console {
    param([string]$File, [string[]]$Arguments)
    if (-not (Test-Command $File)) { throw "Comando nao encontrado: $File" }
    $quoted = @($Arguments | ForEach-Object {
        if ($_ -match '[\s"]') { '"' + ($_ -replace '"','\"') + '"' } else { $_ }
    })
    $p = Start-Process -FilePath $File -ArgumentList $quoted -NoNewWindow -Wait -PassThru
    return [int]$p.ExitCode
}

function Update-SessionPath {
    $machine = [Environment]::GetEnvironmentVariable("Path", "Machine")
    $user    = [Environment]::GetEnvironmentVariable("Path", "User")
    $env:Path = (@($machine, $user) | Where-Object { $_ }) -join ";"
}

# ----------------------------------------------------------------------------
# Arquivos de texto (UTF-8 SEM BOM - o BOM quebrava .gitignore e CNAME)
# ----------------------------------------------------------------------------
function Get-FullPath([string]$Path) {
    if ([System.IO.Path]::IsPathRooted($Path)) { return $Path }
    return (Join-Path (Get-Location).ProviderPath $Path)
}

function Write-TextFile([string]$Path, [string]$Content) {
    [System.IO.File]::WriteAllText((Get-FullPath $Path), $Content, (New-Object System.Text.UTF8Encoding($false)))
}

function Repair-Utf8Bom([string]$Path) {
    $full = Get-FullPath $Path
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { return }
    $bytes = [System.IO.File]::ReadAllBytes($full)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        $rest = New-Object byte[] ($bytes.Length - 3)
        [Array]::Copy($bytes, 3, $rest, 0, $rest.Length)
        [System.IO.File]::WriteAllBytes($full, $rest)
        Write-Info "BOM removido de $Path (o BOM quebra a primeira linha desse arquivo)."
    }
}

# ----------------------------------------------------------------------------
# Log e pastas recentes
# ----------------------------------------------------------------------------
function Start-Log {
    try {
        if (-not (Test-Path -LiteralPath $script:LogDir)) { New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null }
        Get-ChildItem -LiteralPath $script:LogDir -Filter "*.log" -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-30) } |
            Remove-Item -Force -ErrorAction SilentlyContinue
        $script:LogFile = Join-Path $script:LogDir ("setup-{0}.log" -f (Get-Date -Format "yyyyMMdd-HHmmss"))
        Start-Transcript -Path $script:LogFile | Out-Null
        $script:TranscriptOn = $true
    } catch { }
}

function Stop-Log {
    if ($script:TranscriptOn) { try { Stop-Transcript | Out-Null } catch { } }
}

function Get-RecentProjects {
    if (-not (Test-Path -LiteralPath $script:RecentFile)) { return @() }
    return @(Get-Content -LiteralPath $script:RecentFile -Encoding UTF8 |
             Where-Object { $_ -and (Test-Path -LiteralPath $_) })
}

function Add-RecentProject([string]$Path) {
    try {
        if (-not (Test-Path -LiteralPath $script:AppDir)) { New-Item -ItemType Directory -Path $script:AppDir -Force | Out-Null }
        $list = @($Path) + @(Get-RecentProjects | Where-Object { $_ -ne $Path })
        Set-Content -LiteralPath $script:RecentFile -Value ($list | Select-Object -First 8) -Encoding UTF8
    } catch { }
}

# ----------------------------------------------------------------------------
# Selecao e validacao de pastas
# ----------------------------------------------------------------------------
function Select-Folder([string]$Description = "Selecione a pasta do projeto") {
    try {
        Add-Type -AssemblyName System.Windows.Forms
        $owner  = New-Object System.Windows.Forms.Form
        $owner.TopMost = $true
        $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
        $dialog.Description = $Description
        $dialog.ShowNewFolderButton = $true
        $result = $dialog.ShowDialog($owner)
        $owner.Dispose()
        if ($result -eq [System.Windows.Forms.DialogResult]::OK) { return $dialog.SelectedPath }
        return $null
    } catch {
        Write-Warn "Nao foi possivel abrir a janela de selecao."
        $manual = (Read-Host "Digite o caminho completo da pasta (Enter = cancelar)").Trim().Trim('"')
        if ($manual) { return $manual }
        return $null
    }
}

function Select-Project([string]$Description = "Selecione a pasta do projeto") {
    $recent = @(Get-RecentProjects)
    if ($recent.Count -eq 0) { return (Select-Folder $Description) }

    Write-Host "  Pastas recentes:"
    for ($i = 0; $i -lt $recent.Count; $i++) { Write-Host ("    [{0}] {1}" -f ($i + 1), $recent[$i]) }
    Write-Host "    [B] Procurar pasta..."
    Write-Host "    [D] Digitar caminho"
    Write-Host "    [Enter] Cancelar"
    $c = (Read-Host "Escolha").Trim().ToLower()
    if ($c -eq "") { return $null }
    if ($c -eq "b") { return (Select-Folder $Description) }
    if ($c -eq "d") {
        $typed = (Read-Host "Caminho da pasta").Trim().Trim('"')
        if ($typed) { return $typed }
        return $null
    }
    if ($c -match '^\d+$') {
        $idx = [int]$c - 1
        if ($idx -ge 0 -and $idx -lt $recent.Count) { return $recent[$idx] }
    }
    Write-Warn "Opcao invalida."
    return $null
}

function Resolve-ProjectPath([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { throw "Nenhuma pasta selecionada." }
    $Path = $Path.Trim().Trim('"')
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { throw "Pasta nao encontrada: $Path" }
    $full  = (Resolve-Path -LiteralPath $Path).ProviderPath
    $clean = $full.TrimEnd('\')

    if ($clean -match '^[A-Za-z]:$') { throw "Nao publique a raiz de um disco inteiro ($full). Escolha a pasta do projeto." }

    $blocked = @($env:SystemRoot, $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramData, $env:USERPROFILE) | Where-Object { $_ }
    if ($env:USERPROFILE) {
        $blocked += @((Join-Path $env:USERPROFILE "Desktop"), (Join-Path $env:USERPROFILE "Documents"), (Join-Path $env:USERPROFILE "Downloads"))
    }
    foreach ($b in $blocked) {
        if ($clean -ieq $b.TrimEnd('\')) { throw "Pasta protegida ($full). Escolha uma subpasta especifica do projeto." }
    }
    if ($env:SystemRoot -and $clean -like ($env:SystemRoot.TrimEnd('\') + '\*')) { throw "Nao use pastas do Windows ($full)." }
    return $full
}

function Use-Project([string]$Path) {
    $full = Resolve-ProjectPath $Path
    Set-Location -LiteralPath $full
    $script:ActiveProject = $full
    Add-RecentProject $full
    return $full
}

function Get-ActiveProject {
    if ($script:ActiveProject -and (Test-Path -LiteralPath $script:ActiveProject)) {
        Set-Location -LiteralPath $script:ActiveProject
        return $script:ActiveProject
    }
    $p = Select-Project "Selecione o projeto"
    if (-not $p) { Stop-Operation "Nenhuma pasta selecionada." }
    return (Use-Project $p)
}

# ----------------------------------------------------------------------------
# Instalacao de ferramentas
# ----------------------------------------------------------------------------
function Ensure-Winget {
    if (-not (Test-Command "winget")) {
        throw "WinGet nao foi encontrado. Instale o 'App Installer' pela Microsoft Store e tente de novo."
    }
}

function Ensure-Tool([string]$Command, [string]$WingetId, [string]$Label) {
    if (Test-Command $Command) { return }
    Ensure-Winget
    Write-Info "Instalando $Label pelo WinGet..."
    $code = Invoke-Console "winget" @("install","--id",$WingetId,"-e","--source","winget","--accept-package-agreements","--accept-source-agreements")
    Update-SessionPath
    if (-not (Test-Command $Command)) {
        throw "$Label foi instalado (codigo $code), mas '$Command' ainda nao foi encontrado. Feche e abra este programa novamente."
    }
    Write-Ok "$Label instalado."
}

function Ensure-Git       { Ensure-Tool "git"  "Git.Git"           "Git" }
function Ensure-GitHubCli { Ensure-Tool "gh"   "GitHub.cli"        "GitHub CLI" }
function Ensure-Node      { Ensure-Tool "node" "OpenJS.NodeJS.LTS" "Node.js LTS" }

function Test-PythonWorks {
    if (-not (Test-Command "python")) { return $false }
    return ((Invoke-Native "python" @("--version")).ExitCode -eq 0)
}

function Ensure-Python {
    if (Test-PythonWorks) { return }
    Ensure-Winget
    Write-Info "Instalando Python pelo WinGet..."
    [void](Invoke-Console "winget" @("install","--id","Python.Python.3.13","-e","--source","winget","--accept-package-agreements","--accept-source-agreements"))
    Update-SessionPath
    if (-not (Test-PythonWorks)) { throw "Python instalado, mas nao encontrado. Feche e abra este programa novamente." }
}

function Install-ProjectDependencies {
    if (Test-Path -LiteralPath "package.json") {
        Ensure-Node
        Write-Info "Instalando dependencias npm..."
        if (Test-Path -LiteralPath "package-lock.json") { $c = Invoke-Live "npm" @("ci") } else { $c = Invoke-Live "npm" @("install") }
        if ($c -ne 0) { Write-Warn "npm terminou com erro (codigo $c)." }
    }
    if ((Test-Path -LiteralPath "requirements.txt") -or (Test-Path -LiteralPath "pyproject.toml")) {
        Ensure-Python
        if (-not (Test-Path -LiteralPath ".venv")) { [void](Invoke-Live "python" @("-m","venv",".venv")) }
        if (Test-Path -LiteralPath "requirements.txt") {
            $py = Join-Path (Get-Location).ProviderPath ".venv\Scripts\python.exe"
            $c = Invoke-Live $py @("-m","pip","install","-r","requirements.txt")
            if ($c -ne 0) { Write-Warn "pip terminou com erro (codigo $c)." }
        }
    }
    Write-Ok "Dependencias verificadas."
}

function Ensure-GitConfig {
    function Get-Cfg([string]$Key) {
        $r = Invoke-Native "git" @("config","--global",$Key)
        if ($r.ExitCode -eq 0) { return $r.Output.Trim() }
        return ""
    }
    $name  = Get-Cfg "user.name"
    $email = Get-Cfg "user.email"
    if (-not $name) {
        do { $name = (Read-Host "Nome para os commits do Git").Trim() } until ($name)
        [void](Invoke-Native "git" @("config","--global","user.name",$name))
    }
    if (-not $email) {
        do { $email = (Read-Host "Email para os commits do Git").Trim() } until ($email -match '^[^@\s]+@[^@\s]+$')
        [void](Invoke-Native "git" @("config","--global","user.email",$email))
    }
    if (-not (Get-Cfg "init.defaultBranch")) {
        [void](Invoke-Native "git" @("config","--global","init.defaultBranch","main"))
    }
}

function Ensure-GitHubAuth {
    $r = Invoke-Native "gh" @("auth","status")
    if ($r.ExitCode -ne 0) {
        Write-Info "Login no GitHub necessario. O navegador sera aberto - siga as instrucoes."
        $code = Invoke-Console "gh" @("auth","login","--web","--git-protocol","https","--hostname","github.com")
        if ($code -ne 0) { throw "Login no GitHub nao foi concluido." }
    }
    [void](Invoke-Native "gh" @("auth","setup-git"))
}

# ----------------------------------------------------------------------------
# Arquivos padrao: .gitignore, README, LICENSE, .nojekyll
# ----------------------------------------------------------------------------
function Get-GitIgnoreLines {
    $common = @'
# Sistema
.DS_Store
Thumbs.db
desktop.ini

# Segredos e ambiente
.env
.env.*
!.env.example
*.pem
*.key
*.pfx
*.p12
firebase-adminsdk*.json
*service-account*.json

# Logs e temporarios
*.log
*.tmp
*.bak

# Editores
.vscode/
.idea/
'@
    $node = @'
# Node
node_modules/
dist/
build/
.next/
.cache/
coverage/
'@
    $python = @'
# Python
.venv/
venv/
__pycache__/
*.pyc
'@
    $parts = @($common)
    if (Test-Path -LiteralPath "package.json") { $parts += $node }
    if ((Test-Path -LiteralPath "requirements.txt") -or (Test-Path -LiteralPath "pyproject.toml")) { $parts += $python }
    return (($parts -join "`n`n") -split "`r?`n")
}

function New-GitIgnore {
    if (Test-Path -LiteralPath ".gitignore") { return }
    Write-TextFile ".gitignore" ((Get-GitIgnoreLines) -join "`n")
    Write-Ok ".gitignore criado."
}

function Add-ToGitIgnore([string[]]$Entries) {
    $existing = @()
    if (Test-Path -LiteralPath ".gitignore") { $existing = @(Get-Content -LiteralPath ".gitignore" -Encoding UTF8) }
    $new = @($Entries | Where-Object { $_ -and ($existing -notcontains $_) })
    if ($new.Count -eq 0) { return }
    Write-TextFile ".gitignore" ((($existing + $new) -join "`n") + "`n")
}

function New-Readme {
    if (Test-Path -LiteralPath "README.md") { return }
    $folder = Split-Path -Leaf (Get-Location).ProviderPath
    Write-TextFile "README.md" ("# $folder`n")
    Write-Ok "README.md criado."
}

function New-LicenseFile {
    if (Test-Path -LiteralPath "LICENSE") { Write-Info "LICENSE ja existe."; return }
    Write-Warn "A licenca MIT permite que QUALQUER pessoa reutilize o conteudo do repositorio."
    Write-Warn "Para trabalhos autorais (videos, imagens, layouts) prefira NAO adicionar licenca."
    if (-not (Read-YesNo "Adicionar licenca MIT mesmo assim?" $false)) { return }
    $author = (Invoke-Native "git" @("config","--global","user.name")).Output.Trim()
    if (-not $author) { $author = (Read-Host "Nome do autor").Trim() }
    $year = (Get-Date).Year
    $text = @'
MIT License

Copyright (c) __YEAR__ __AUTHOR__

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
'@
    $text = $text.Replace("__YEAR__", "$year").Replace("__AUTHOR__", $author)
    Write-TextFile "LICENSE" ($text + "`n")
    Write-Ok "LICENSE (MIT) criada."
}

function New-StarterSite([string]$Title) {
    $safe = [System.Net.WebUtility]::HtmlEncode($Title)
    New-Item -ItemType Directory -Path "css","js" -Force | Out-Null
    $html = @'
<!DOCTYPE html>
<html lang="pt-BR">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>__TITLE__</title>
  <link rel="stylesheet" href="css/style.css">
</head>
<body>
  <main>
    <h1>__TITLE__</h1>
    <p>Site publicado com GitHub Pages.</p>
  </main>
  <script src="js/main.js"></script>
</body>
</html>
'@
    $css = @'
* { box-sizing: border-box; }
body { margin: 0; font-family: system-ui, sans-serif; line-height: 1.6; }
main { max-width: 720px; margin: 10vh auto; padding: 0 1rem; }
'@
    $js = "// Seu JavaScript aqui`n"
    Write-TextFile "index.html"    ($html.Replace("__TITLE__", $safe) + "`n")
    Write-TextFile "css\style.css" ($css + "`n")
    Write-TextFile "js\main.js"     $js
    Write-Ok "Arquivos iniciais do site criados (index.html, css/, js/)."
}

# ----------------------------------------------------------------------------
# Git: utilitarios
# ----------------------------------------------------------------------------
function Test-HasCommits { return ((Invoke-Native "git" @("rev-parse","--verify","--quiet","HEAD")).ExitCode -eq 0) }

function Get-Remotes {
    $r = Invoke-Native "git" @("remote")
    if ($r.ExitCode -ne 0 -or -not $r.Output) { return @() }
    return @($r.Output -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

function Test-HasOrigin { return ((Get-Remotes) -contains "origin") }

function Get-CurrentBranch {
    $r = Invoke-Native "git" @("branch","--show-current")
    if ($r.ExitCode -eq 0 -and $r.Output.Trim()) { return $r.Output.Trim() }
    return "main"
}

function Initialize-Repository {
    if (Test-Path -LiteralPath ".git") { return }
    $r = Invoke-Native "git" @("rev-parse","--show-toplevel")
    if ($r.ExitCode -eq 0 -and $r.Output.Trim()) {
        Write-Warn "Esta pasta esta dentro de outro repositorio Git: $($r.Output.Trim())"
        if (-not (Read-YesNo "Criar um repositorio separado apenas para esta pasta?" $true)) { Stop-Operation }
    }
    if ((Invoke-Live "git" @("init")) -ne 0) { throw "git init falhou." }
    [void](Invoke-Native "git" @("symbolic-ref","HEAD","refs/heads/main"))
    Write-Ok "Repositorio Git local inicializado (branch main)."
}

function Get-NestedRepos {
    $root = (Get-Location).ProviderPath.TrimEnd('\')
    $skip = @("node_modules",".venv","venv","__pycache__",".git")
    $found = New-Object System.Collections.Generic.List[string]
    $stack = New-Object System.Collections.Generic.Stack[string]
    $stack.Push($root)
    while ($stack.Count -gt 0) {
        $dir = $stack.Pop()
        if ($dir -ne $root -and (Test-Path -LiteralPath (Join-Path $dir ".git"))) { $found.Add($dir); continue }
        try { $subs = [System.IO.Directory]::GetDirectories($dir) } catch { continue }
        foreach ($s in $subs) {
            $leaf = [System.IO.Path]::GetFileName($s)
            if ($skip -contains $leaf) { continue }
            try {
                if (([System.IO.File]::GetAttributes($s) -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
            } catch { continue }
            $stack.Push($s)
        }
    }
    return @($found)
}

function Remove-GitlinkFromIndex([string]$RelPath) {
    $r = Invoke-Native "git" @("ls-files","-s","--",$RelPath)
    if ($r.Output -match '^160000') {
        [void](Invoke-Native "git" @("rm","--cached","-q","-f","--",$RelPath))
    }
}

# Repositorios dentro do projeto viram "pastas vazias" no GitHub. Aqui o usuario decide.
function Resolve-NestedRepos {
    $root   = (Get-Location).ProviderPath.TrimEnd('\')
    $nested = @(Get-NestedRepos)
    if ($nested.Count -eq 0) { return }

    Write-Warn "Ha repositorios Git dentro do projeto (no GitHub eles apareceriam como pastas vazias):"
    foreach ($n in $nested) { Write-Host "    - $($n.Substring($root.Length + 1))" }
    Write-Host ""
    Write-Host "  1 - Incorporar ao projeto (move o .git de cada um para um backup seguro; nada e apagado)"
    Write-Host "  2 - Ignorar essas pastas (nao enviar ao GitHub)"
    Write-Host "  0 - Cancelar"
    $c = Read-Choice "Escolha [1/2/0]" @("1","2","0")
    if ($c -eq "0") { Stop-Operation }

    foreach ($n in $nested) {
        $rel    = $n.Substring($root.Length + 1)
        $relGit = $rel -replace '\\','/'
        if ($c -eq "1") {
            $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
            $dest  = Join-Path (Join-Path $script:AppDir "nested-git-backups") ("{0}-{1}" -f ($rel -replace '[\\/:]','_'), $stamp)
            New-Item -ItemType Directory -Path $dest -Force | Out-Null
            Move-Item -LiteralPath (Join-Path $n ".git") -Destination (Join-Path $dest ".git") -Force
            Remove-GitlinkFromIndex $relGit
            Write-Ok "Incorporado: $rel  (historico antigo guardado em $dest)"
        } else {
            Add-ToGitIgnore @("/$relGit/")
            [void](Invoke-Native "git" @("rm","-r","--cached","-q","--ignore-unmatch","--",$relGit))
            Write-Ok "Ignorado: $rel"
        }
    }
}

# ----------------------------------------------------------------------------
# Verificacoes antes do commit: arquivos grandes e segredos
# ----------------------------------------------------------------------------
function Get-StagedFiles {
    $r = Invoke-Native "git" @("-c","core.quotepath=off","diff","--cached","--name-only","--diff-filter=AMR")
    if ($r.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($r.Output)) { return @() }
    return @($r.Output -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

function Remove-FromIndex([string[]]$Paths) {
    foreach ($p in $Paths) {
        [void](Invoke-Native "git" @("rm","--cached","-q","-f","--ignore-unmatch","--",$p))
    }
}

function Test-StagedFiles {
    $root   = (Get-Location).ProviderPath
    $staged = @(Get-StagedFiles)
    if ($staged.Count -eq 0) { return }

    $findings = New-Object System.Collections.ArrayList
    foreach ($rel in $staged) {
        $full = Join-Path $root $rel
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { continue }
        $fi = Get-Item -LiteralPath $full -Force

        if ($fi.Length -ge $script:LargeWarnBytes) {
            [void]$findings.Add([pscustomobject]@{
                Path = $rel; Kind = "large"; Blocking = ($fi.Length -ge $script:LargeBlockBytes)
                Detail = ("arquivo grande ({0:N1} MB)" -f ($fi.Length / 1MB)) })
        }

        $isSecret = $false
        if ($rel -notmatch $script:SecretSafeSuffix) {
            foreach ($rx in $script:SecretNameRegexes) {
                if ($rel -match $rx) {
                    [void]$findings.Add([pscustomobject]@{ Path = $rel; Kind = "secret"; Blocking = $false; Detail = "nome parece conter segredo/credencial" })
                    $isSecret = $true
                    break
                }
            }
        }

        if (-not $isSecret -and $fi.Length -le 1MB -and ($script:TextExtensions -contains $fi.Extension.ToLower())) {
            try {
                $content = [System.IO.File]::ReadAllText($full)
                foreach ($pat in $script:SecretContentPatterns) {
                    if ($content -cmatch $pat.Regex) {
                        [void]$findings.Add([pscustomobject]@{ Path = $rel; Kind = "secret"; Blocking = $false; Detail = ("possivel " + $pat.Name + " dentro do arquivo") })
                        break
                    }
                }
            } catch { }
        }
    }
    if ($findings.Count -eq 0) { return }

    Write-Host ""
    Write-Warn "Itens que merecem atencao antes do commit:"
    foreach ($f in @($findings | Select-Object -First 20)) {
        Write-Host ("    - {0}  [{1}]" -f $f.Path, $f.Detail) -ForegroundColor Yellow
    }
    if ($findings.Count -gt 20) { Write-Host "    ... e mais $($findings.Count - 20) item(ns)" -ForegroundColor Yellow }

    $large      = @($findings | Where-Object { $_.Kind -eq "large" })
    $hasSecret  = @($findings | Where-Object { $_.Kind -eq "secret" }).Count -gt 0
    $hasBlock   = @($large | Where-Object { $_.Blocking }).Count -gt 0
    if ($large.Count -gt 0) {
        Write-Host ""
        Write-Host "  Dica: o GitHub recusa arquivos acima de 100 MB. Para videos, o ideal e hospedar no" -ForegroundColor DarkGray
        Write-Host "  YouTube/Vimeo e incorporar no site. O GitHub Pages nao serve arquivos do Git LFS." -ForegroundColor DarkGray
    }
    if ($hasSecret) {
        Write-Host "  Se algum segredo ja foi enviado ao GitHub antes, considere-o comprometido e gere outro." -ForegroundColor DarkGray
    }
    Write-Host ""
    Write-Host "  1 - Tirar esses arquivos do commit e adicionar ao .gitignore (recomendado)"
    $valid = @("1","0")
    if (-not $hasBlock) { Write-Host "  2 - Continuar mesmo assim"; $valid += "2" }
    if ($large.Count -gt 0) { Write-Host "  3 - Enviar os arquivos grandes via Git LFS (segredos continuam de fora)"; $valid += "3" }
    Write-Host "  0 - Cancelar"
    $c = Read-Choice "Escolha" $valid

    switch ($c) {
        "0" { [void](Invoke-Native "git" @("reset","-q")); Stop-Operation }
        "2" { return }
        "1" {
            Remove-FromIndex @($findings | ForEach-Object { $_.Path })
            Add-ToGitIgnore @($findings | ForEach-Object { "/" + $_.Path } | Select-Object -Unique)
            Write-Ok "Arquivos removidos do commit e adicionados ao .gitignore."
        }
        "3" {
            if ((Invoke-Native "git" @("lfs","version")).ExitCode -ne 0) {
                throw "Git LFS nao encontrado. Reinstale o Git for Windows (ele inclui o LFS) ou escolha outra opcao."
            }
            [void](Invoke-Native "git" @("lfs","install","--local"))
            $secrets = @($findings | Where-Object { $_.Kind -eq "secret" })
            if ($secrets.Count -gt 0) {
                Remove-FromIndex @($secrets | ForEach-Object { $_.Path })
                Add-ToGitIgnore @($secrets | ForEach-Object { "/" + $_.Path } | Select-Object -Unique)
            }
            $exts = @($large | ForEach-Object { [System.IO.Path]::GetExtension($_.Path).ToLower() } | Where-Object { $_ } | Select-Object -Unique)
            foreach ($e in $exts) { [void](Invoke-Native "git" @("lfs","track","*$e")) }
            foreach ($f in $large) {
                [void](Invoke-Native "git" @("rm","--cached","-q","-f","--ignore-unmatch","--",$f.Path))
                [void](Invoke-Native "git" @("add","--",$f.Path))
            }
            [void](Invoke-Native "git" @("add",".gitattributes"))
            Write-Ok "Arquivos grandes configurados no Git LFS ($($exts -join ', '))."
        }
    }
}

# ----------------------------------------------------------------------------
# Commit e push
# ----------------------------------------------------------------------------
function Commit-Project {
    $r = Invoke-Native "git" @("add","-A")
    if ($r.ExitCode -ne 0) { throw "git add falhou: $($r.Output)" }

    # Se a verificacao falhar ou for cancelada, nada pode ficar preparado no indice
    # (senao um commit posterior levaria junto segredos/arquivos grandes).
    try { Test-StagedFiles } catch { [void](Invoke-Native "git" @("reset","-q")); throw }
    [void](Invoke-Native "git" @("add","-A"))

    $st = Invoke-Native "git" @("status","--porcelain")
    if ([string]::IsNullOrWhiteSpace($st.Output)) {
        Write-Info "Nenhuma alteracao nova para commit."
        return $false
    }

    $lines = @($st.Output -split "`n")
    Write-Info "Alteracoes que serao enviadas ($($lines.Count) arquivo(s)):"
    $lines | Select-Object -First 15 | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
    if ($lines.Count -gt 15) { Write-Host "    ... e mais $($lines.Count - 15) arquivo(s)" -ForegroundColor DarkGray }

    $default = if (Test-HasCommits) { "Atualizacao " + (Get-Date -Format "yyyy-MM-dd HH:mm") } else { "Initial commit" }
    $message = (Read-Host "Mensagem do commit [Enter = $default]").Trim()
    if (-not $message) { $message = $default }
    $message = $message -replace '"',"'"

    if ((Invoke-Live "git" @("commit","-m",$message)) -ne 0) { throw "git commit falhou." }
    Write-Ok "Commit criado: $message"
    return $true
}

function Commit-Files([string[]]$Files, [string]$Message) {
    [void](Invoke-Native "git" (@("add","--") + $Files))
    $d = Invoke-Native "git" (@("diff","--cached","--quiet","--") + $Files)
    if ($d.ExitCode -eq 0) { return $false }
    # "-- arquivos": commita SOMENTE esses caminhos, mesmo que haja outras coisas no indice
    if ((Invoke-Live "git" (@("commit","-m",$Message,"--") + $Files)) -ne 0) { throw "git commit falhou." }
    return $true
}

function ConvertTo-RepoName([string]$Name) {
    $clean = ($Name.Trim() -replace '[^A-Za-z0-9._-]','-').Trim('-')
    if (-not $clean) { throw "Nome de repositorio invalido." }
    return $clean
}

function Get-MyRepos {
    $r = Invoke-Native "gh" @("repo","list","--limit","50","--json","name,isPrivate,nameWithOwner") -StdoutOnly
    if ($r.ExitCode -eq 0 -and $r.Output) {
        try { return @($r.Output | ConvertFrom-Json) } catch { }
    }
    return @()
}

function Select-OrCreateGitHubRepo {
    $repos   = @(Get-MyRepos)
    $default = ConvertTo-RepoName (Split-Path -Leaf (Get-Location).ProviderPath)

    while ($true) {
        Write-Header "SELECAO DE REPOSITORIO"
        Write-Host "  [0] Criar NOVO repositorio com o nome da pasta ($default)"
        Write-Host "  [N] Criar NOVO repositorio com outro nome"
        for ($i = 0; $i -lt $repos.Count; $i++) {
            $tag = if ($repos[$i].isPrivate) { " (privado)" } else { "" }
            Write-Host ("  [{0}] {1}{2}" -f ($i + 1), $repos[$i].name, $tag)
        }
        Write-Host ""
        $choice = (Read-Host "Escolha [Enter = criar '$default']").Trim()

        if ($choice -eq "" -or $choice -eq "0") { return [pscustomobject]@{ Name = $default; IsNew = $true } }
        if ($choice -ieq "n") {
            $n = ConvertTo-RepoName (Read-Host "Nome do novo repositorio")
            return [pscustomobject]@{ Name = $n; IsNew = -not (@($repos | Where-Object { $_.name -ieq $n }).Count -gt 0) }
        }
        if ($choice -match '^\d+$') {
            $idx = [int]$choice - 1
            if ($idx -ge 0 -and $idx -lt $repos.Count) { return [pscustomobject]@{ Name = $repos[$idx].name; IsNew = $false } }
            Write-Warn "Numero fora da lista."
            continue
        }
        $typed = ConvertTo-RepoName $choice
        return [pscustomobject]@{ Name = $typed; IsNew = -not (@($repos | Where-Object { $_.name -ieq $typed }).Count -gt 0) }
    }
}

function Connect-GitHubRemote($Selection) {
    if (-not (Test-HasCommits)) { throw "Nao ha commits para enviar. A pasta esta vazia?" }
    if ($Selection.IsNew) {
        Write-Host "Visibilidade do repositorio:"
        Write-Host "  1 - Publico (necessario para GitHub Pages gratuito)"
        Write-Host "  2 - Privado"
        $vis  = Read-Choice "Escolha [1/2]" @("1","2")
        $flag = if ($vis -eq "1") { "--public" } else { "--private" }
        $desc = (Read-Host "Descricao curta do repositorio (opcional)").Trim()
        $ghArgs = @("repo","create",$Selection.Name,$flag,"--source=.","--remote=origin")
        if ($desc) { $ghArgs += @("--description",$desc) }
        if ((Invoke-Live "gh" $ghArgs) -ne 0) { throw "Nao foi possivel criar o repositorio '$($Selection.Name)'." }
    } else {
        $user = (Invoke-Native "gh" @("api","user","--jq",".login") -StdoutOnly).Output.Trim()
        if (-not $user) { throw "Nao foi possivel descobrir seu usuario do GitHub. Verifique o login (gh auth status)." }
        [void](Invoke-Native "git" @("remote","add","origin","https://github.com/$user/$($Selection.Name).git"))
        Write-Ok "Conectado a https://github.com/$user/$($Selection.Name)"
    }
}

function Push-Project {
    $branch = Get-CurrentBranch
    $code = Invoke-Live "git" @("push","-u","origin",$branch)
    if ($code -eq 0) { return }
    $out = $script:LastOutput

    if ($out -match "GH001|larger than 100|exceeds GitHub") {
        throw "O GitHub recusou arquivo(s) acima de 100 MB que ja estao no historico. Remova-os do historico (git filter-repo/BFG) ou recrie o repositorio sem eles."
    }
    if ($out -match "Authentication failed|could not read Username|Permission to .* denied|returned error: 403") {
        throw "Falha de autenticacao/permissao. Rode o diagnostico (menu) ou 'gh auth login' e tente novamente."
    }

    Write-Info "Push recusado. Verificando o repositorio remoto..."
    [void](Invoke-Native "git" @("fetch","origin"))
    $ref = "refs/remotes/origin/$branch"
    if ((Invoke-Native "git" @("rev-parse","--verify","--quiet",$ref)).ExitCode -ne 0) {
        throw "O push falhou e o branch '$branch' nao existe no remoto. Detalhes:`n$out"
    }

    $base    = Invoke-Native "git" @("merge-base","HEAD",$ref)
    $related = ($base.ExitCode -eq 0 -and $base.Output.Trim())

    if ($related) {
        Write-Info "O GitHub tem commits que voce ainda nao tem. Integrando (pull --rebase)..."
        if ((Invoke-Live "git" @("pull","--rebase","origin",$branch)) -ne 0) {
            [void](Invoke-Native "git" @("rebase","--abort"))
            throw "Conflito ao integrar com o GitHub. Nada foi perdido; resolva manualmente (git pull --rebase) ou abra o repositorio no VS Code."
        }
    } else {
        Write-Warn "O repositorio no GitHub ja tem conteudo com historico DIFERENTE deste projeto."
        Write-Host "  1 - Tentar mesclar os dois historicos"
        Write-Host "  2 - SOBRESCREVER o GitHub com esta pasta (apaga o historico remoto)"
        Write-Host "  0 - Cancelar"
        $c = Read-Choice "Escolha [1/2/0]" @("1","2","0")
        if ($c -eq "0") { Stop-Operation }
        if ($c -eq "1") {
            if ((Invoke-Live "git" @("pull","--no-rebase","--allow-unrelated-histories","--no-edit","origin",$branch)) -ne 0) {
                [void](Invoke-Native "git" @("merge","--abort"))
                throw "Nao foi possivel mesclar automaticamente (arquivos conflitantes). Nada foi alterado."
            }
        } else {
            $confirm = Read-Host "Digite SOBRESCREVER (em maiusculas) para confirmar"
            if ($confirm -cne "SOBRESCREVER") { Stop-Operation }
            if ((Invoke-Live "git" @("push","--force-with-lease","-u","origin",$branch)) -ne 0) { throw "Push forcado falhou." }
            Write-Ok "Enviado para o GitHub (remoto sobrescrito)."
            return
        }
    }

    if ((Invoke-Live "git" @("push","-u","origin",$branch)) -ne 0) { throw "Nao foi possivel enviar para o GitHub. Detalhes:`n$($script:LastOutput)" }
    Write-Ok "Enviado para o GitHub com sucesso."
}

function Sync-Remote {
    if (-not (Test-HasOrigin)) {
        $selected = Select-OrCreateGitHubRepo
        Connect-GitHubRemote $selected
    }
    Push-Project
}

function Get-RepoInfo {
    $r = Invoke-Native "gh" @("repo","view","--json","name,isPrivate,owner,url") -StdoutOnly
    if ($r.ExitCode -ne 0 -or -not $r.Output) { throw "Este projeto ainda nao esta associado a um repositorio no GitHub." }
    $j = $r.Output | ConvertFrom-Json
    return [pscustomobject]@{ Owner = $j.owner.login; Name = $j.name; IsPrivate = [bool]$j.isPrivate; Url = $j.url }
}

# ----------------------------------------------------------------------------
# Fluxos principais: publicar / atualizar / novo projeto
# ----------------------------------------------------------------------------
function Publish-Project([string]$Path) {
    $null = Use-Project $Path
    Write-Header "PUBLICAR: $((Get-Location).ProviderPath)"

    Ensure-Git
    Ensure-GitHubCli
    Ensure-GitConfig
    Ensure-GitHubAuth

    $hasDeps = (Test-Path -LiteralPath "package.json") -or (Test-Path -LiteralPath "requirements.txt") -or (Test-Path -LiteralPath "pyproject.toml")
    if ($hasDeps -and (Read-YesNo "Instalar as dependencias do projeto (npm/pip) agora? (nao e necessario para publicar)" $false)) {
        Install-ProjectDependencies
    }

    Repair-Utf8Bom ".gitignore"
    Repair-Utf8Bom "CNAME"
    New-GitIgnore
    New-Readme
    Initialize-Repository
    Resolve-NestedRepos

    $null = Commit-Project
    if (-not (Test-HasCommits)) { throw "Nada para publicar: a pasta parece vazia." }
    Sync-Remote

    $url = (Invoke-Native "gh" @("repo","view","--json","url","--jq",".url") -StdoutOnly).Output.Trim()
    Write-Ok "Publicacao concluida!"
    if ($url) { Write-Info "Repositorio: $url" }
}

function Update-Project([string]$Path) {
    $null = Use-Project $Path
    Write-Header "ATUALIZAR: $((Get-Location).ProviderPath)"
    if (-not (Test-Path -LiteralPath ".git")) { throw "Esta pasta ainda nao e um repositorio Git. Use 'Publicar' primeiro." }

    Ensure-Git
    Ensure-GitHubCli
    Ensure-GitConfig
    Ensure-GitHubAuth
    Repair-Utf8Bom ".gitignore"
    Resolve-NestedRepos
    $null = Commit-Project
    if (-not (Test-HasCommits)) { throw "Este repositorio ainda nao tem commits." }
    Sync-Remote
    Write-Ok "Atualizacao enviada!"
}

function New-ProjectFlow {
    $parent = Select-Folder "Onde criar o novo projeto?"
    if (-not $parent) { Stop-Operation }
    $name = (Read-Host "Nome do novo projeto").Trim()
    if (-not $name) { Stop-Operation "Nome vazio." }
    if ($name.IndexOfAny([System.IO.Path]::GetInvalidFileNameChars()) -ge 0) { throw "O nome contem caracteres invalidos." }
    $newPath = Join-Path $parent $name
    if (Test-Path -LiteralPath $newPath) { throw "Ja existe uma pasta com esse nome: $newPath" }
    New-Item -ItemType Directory -Path $newPath | Out-Null
    Set-Location -LiteralPath $newPath

    Write-Host ""
    Write-Host "Conteudo inicial:"
    Write-Host "  1 - Site estatico basico (index.html, css/, js/)"
    Write-Host "  2 - Apenas README"
    Write-Host "  3 - Pasta vazia (voce copia os arquivos depois)"
    $t = Read-Choice "Escolha [1/2/3]" @("1","2","3")
    if ($t -eq "1") { New-StarterSite $name }
    if ($t -eq "3") {
        Write-Info "Pasta criada: $newPath"
        Write-Info "Copie seus arquivos para la e depois use 'Atualizar projeto' ou 'Publicar'."
        $null = Use-Project $newPath
        return
    }
    Publish-Project $newPath
}

# ----------------------------------------------------------------------------
# GitHub Pages e dominio
# ----------------------------------------------------------------------------
function Get-PagesInfo([string]$Owner, [string]$Repo) {
    $r = Invoke-Native "gh" @("api","repos/$Owner/$Repo/pages") -StdoutOnly
    if ($r.ExitCode -ne 0 -or -not $r.Output) { return $null }
    try { return ($r.Output | ConvertFrom-Json) } catch { return $null }
}

function Set-PagesSource([string]$Owner, [string]$Repo, [string]$Branch, [string]$Path) {
    $existing = Get-PagesInfo $Owner $Repo
    $method   = if ($existing) { "PUT" } else { "POST" }
    $r = Invoke-Native "gh" @("api","-X",$method,"repos/$Owner/$Repo/pages","-f","source[branch]=$Branch","-f","source[path]=$Path")
    if ($r.ExitCode -ne 0) { throw "Nao foi possivel configurar o GitHub Pages: $($r.Output)" }
    if ($existing) { Write-Ok "GitHub Pages atualizado (branch $Branch, pasta $Path)." }
    else           { Write-Ok "GitHub Pages ativado (branch $Branch, pasta $Path)." }
}

function Wait-PagesBuild([string]$Owner, [string]$Repo) {
    Write-Info "Aguardando o GitHub publicar o site (pode levar 1-2 minutos)..."
    for ($i = 0; $i -lt 18; $i++) {
        Start-Sleep -Seconds 10
        $r = Invoke-Native "gh" @("api","repos/$Owner/$Repo/pages/builds/latest") -StdoutOnly
        if ($r.ExitCode -eq 0 -and $r.Output) {
            try { $b = $r.Output | ConvertFrom-Json } catch { $b = $null }
            if ($b -and $b.status -eq "built")   { Write-Ok "Site publicado!"; return $true }
            if ($b -and $b.status -eq "errored") { Write-Fail "O build do Pages falhou: $($b.error.message)"; return $false }
        }
        Write-Host ("    ... aguardando ({0}s)" -f (($i + 1) * 10)) -ForegroundColor DarkGray
    }
    Write-Warn "O build ainda esta em andamento. Veja o status depois no menu de Pages."
    return $false
}

function Set-PagesHttps([string]$Owner, [string]$Repo) {
    $r = Invoke-Native "gh" @("api","-X","PUT","repos/$Owner/$Repo/pages","-F","https_enforced=true")
    if ($r.ExitCode -eq 0) { Write-Ok "HTTPS obrigatorio ativado."; return $true }
    Write-Warn "Ainda nao foi possivel exigir HTTPS: o certificado so e emitido depois que o DNS propaga."
    Write-Warn "Tente novamente mais tarde em: Pages > Forcar HTTPS."
    if ($r.Output) { Write-Host "    Detalhe: $($r.Output)" -ForegroundColor DarkGray }
    return $false
}

function Set-CustomDomain([string]$Owner, [string]$Repo, [string]$SrcDir = ".") {
    $domain = (Read-Host "Dominio (ex: www.seusite.com) [Enter = remover dominio atual]").Trim().ToLower()
    $domain = ($domain -replace '^https?://','') -replace '/.*$',''
    $cnameFile = if ($SrcDir -eq ".") { "CNAME" } else { Join-Path $SrcDir "CNAME" }

    if (-not $domain) {
        if (-not (Read-YesNo "Remover o dominio personalizado deste site?" $false)) { return }
        [void](Invoke-Native "git" @("rm","-q","--ignore-unmatch","--",($cnameFile -replace '\\','/')))
        if ((Invoke-Native "git" @("diff","--cached","--quiet")).ExitCode -ne 0) {
            [void](Invoke-Live "git" @("commit","-m","Remove dominio personalizado"))
            Push-Project
        }
        [void](Invoke-Native "gh" @("api","-X","PUT","repos/$Owner/$Repo/pages","-F","cname=null"))
        Write-Ok "Dominio personalizado removido."
        return
    }

    if ($domain -notmatch '^(?=.{4,253}$)([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,}$') {
        throw "Dominio invalido: $domain"
    }

    if ($SrcDir -ne "." -and -not (Test-Path -LiteralPath $SrcDir)) { New-Item -ItemType Directory -Path $SrcDir -Force | Out-Null }
    Write-TextFile $cnameFile ($domain + "`n")
    if (Commit-Files @(($cnameFile -replace '\\','/')) "Configura dominio personalizado") { Push-Project }
    Write-Ok "Arquivo CNAME configurado: $domain"

    $r = Invoke-Native "gh" @("api","-X","PUT","repos/$Owner/$Repo/pages","-f","cname=$domain")
    if ($r.ExitCode -ne 0) { Write-Warn "O GitHub nao aceitou o dominio agora: $($r.Output)" }

    Write-Host ""
    Write-Host "  Agora configure o DNS no painel do seu provedor de dominio:" -ForegroundColor Cyan
    Write-Host "    - Dominio raiz (ex: seusite.com): 4 registros A"
    Write-Host "        185.199.108.153   185.199.109.153   185.199.110.153   185.199.111.153"
    Write-Host "    - Subdominio (ex: www): registro CNAME apontando para  $Owner.github.io"
    Write-Host "  A propagacao pode levar de minutos a 24 horas." -ForegroundColor DarkGray
    Write-Host ""
    if (Read-YesNo "Tentar exigir HTTPS agora?" $false) { [void](Set-PagesHttps $Owner $Repo) }
}

function Enable-PagesFlow {
    Ensure-Git
    Ensure-GitHubCli
    Ensure-GitConfig
    Ensure-GitHubAuth

    if (-not (Test-Path -LiteralPath ".git") -or -not (Test-HasOrigin) -or -not (Test-HasCommits)) {
        Write-Info "Este projeto ainda nao esta no GitHub. Publicando primeiro..."
        Publish-Project (Get-Location).ProviderPath
    }

    $info = Get-RepoInfo
    if ($info.IsPrivate) {
        Write-Warn "O repositorio e PRIVADO e o GitHub Pages gratuito exige repositorio publico."
        Write-Warn "Ao torna-lo publico, todo o codigo e o historico ficam visiveis para qualquer pessoa."
        if (-not (Read-YesNo "Tornar '$($info.Name)' publico agora?" $false)) { Stop-Operation "Pages nao ativado (repositorio privado)." }
        $c = Invoke-Live "gh" @("repo","edit","$($info.Owner)/$($info.Name)","--visibility","public","--accept-visibility-change-consequences")
        if ($c -ne 0) { throw "Nao foi possivel tornar o repositorio publico." }
    }

    $branch  = Get-CurrentBranch
    $path    = "/"
    $srcDir  = "."
    $rootIdx = (Test-Path -LiteralPath "index.html") -or (Test-Path -LiteralPath "index.md")
    if (-not $rootIdx -and (Test-Path -LiteralPath "docs\index.html")) {
        $path = "/docs"; $srcDir = "docs"
        Write-Info "Encontrei docs\index.html - o site sera servido a partir de /docs."
    } elseif (-not $rootIdx) {
        Write-Warn "Nao encontrei index.html na raiz do projeto. O site pode ficar em branco (erro 404)."
    }

    $nojekyll = Join-Path $srcDir ".nojekyll"
    if (-not (Test-Path -LiteralPath $nojekyll) -and (Read-YesNo "Criar .nojekyll (evita que o GitHub processe o site com Jekyll)?" $true)) {
        Write-TextFile $nojekyll ""
        if (Commit-Files @(($nojekyll -replace '\\','/')) "Adiciona .nojekyll") { Push-Project }
    }

    Set-PagesSource $info.Owner $info.Name $branch $path

    if (Read-YesNo "Configurar um dominio proprio (ex: www.seusite.com)?" $false) {
        Set-CustomDomain $info.Owner $info.Name $srcDir
    }

    $null = Wait-PagesBuild $info.Owner $info.Name
    $pages = Get-PagesInfo $info.Owner $info.Name
    $url = if ($pages -and $pages.html_url) { $pages.html_url } else { "https://$($info.Owner).github.io/$($info.Name)/" }
    Write-Info "Seu site: $url"
    if (Read-YesNo "Abrir o site no navegador?" $true) { Start-Process $url }
}

function Show-PagesStatus([string]$Owner, [string]$Repo) {
    $pages = Get-PagesInfo $Owner $Repo
    if (-not $pages) { Write-Warn "GitHub Pages nao esta ativo neste repositorio."; return }
    Write-Host "  URL:         $($pages.html_url)"
    Write-Host "  Status:      $($pages.status)"
    if ($pages.source) { Write-Host "  Origem:      branch $($pages.source.branch), pasta $($pages.source.path)" }
    $cname = if ($pages.cname) { $pages.cname } else { "(nenhum)" }
    Write-Host "  Dominio:     $cname"
    Write-Host "  HTTPS forcado: $($pages.https_enforced)"
    $b = Invoke-Native "gh" @("api","repos/$Owner/$Repo/pages/builds/latest") -StdoutOnly
    if ($b.ExitCode -eq 0 -and $b.Output) {
        try {
            $j = $b.Output | ConvertFrom-Json
            Write-Host "  Ultimo build: $($j.status) ($($j.updated_at))"
            if ($j.error -and $j.error.message) { Write-Host "  Erro:         $($j.error.message)" -ForegroundColor Red }
        } catch { }
    }
}

function Show-PagesMenu {
    $null = Get-ActiveProject
    Ensure-Git; Ensure-GitHubCli; Ensure-GitHubAuth
    if (-not (Test-Path -LiteralPath ".git") -or -not (Test-HasOrigin)) {
        if (Read-YesNo "Este projeto ainda nao esta no GitHub. Publicar agora?" $true) { Publish-Project (Get-Location).ProviderPath }
        else { Stop-Operation }
    }
    while ($true) {
        $info  = Get-RepoInfo
        $pages = Get-PagesInfo $info.Owner $info.Name
        Write-Header "GITHUB PAGES - $($info.Owner)/$($info.Name)"
        if ($pages) { Write-Host "  Site ativo: $($pages.html_url)" -ForegroundColor Green } else { Write-Host "  Pages ainda nao ativado." -ForegroundColor Yellow }
        Write-Host ""
        Write-Host "  1 - Ativar / atualizar o Pages (assistente completo)"
        Write-Host "  2 - Ver status do site e do ultimo build"
        Write-Host "  3 - Configurar dominio proprio (CNAME + instrucoes de DNS)"
        Write-Host "  4 - Exigir HTTPS"
        Write-Host "  5 - Desativar o Pages"
        Write-Host "  0 - Voltar"
        $c = Read-Choice "Escolha" @("0","1","2","3","4","5")
        switch ($c) {
            "0" { return }
            "1" { Invoke-Safe { Enable-PagesFlow } }
            "2" { Invoke-Safe { Show-PagesStatus $info.Owner $info.Name } }
            "3" {
                Invoke-Safe {
                    $src = if ($pages -and $pages.source -and $pages.source.path -eq "/docs") { "docs" } else { "." }
                    if (-not $pages) { throw "Ative o Pages primeiro (opcao 1)." }
                    Set-CustomDomain $info.Owner $info.Name $src
                }
            }
            "4" { Invoke-Safe { [void](Set-PagesHttps $info.Owner $info.Name) } }
            "5" {
                Invoke-Safe {
                    if (Read-YesNo "Desativar o GitHub Pages? O site sai do ar." $false) {
                        $r = Invoke-Native "gh" @("api","-X","DELETE","repos/$($info.Owner)/$($info.Name)/pages")
                        if ($r.ExitCode -eq 0) { Write-Ok "Pages desativado." } else { throw "Falha ao desativar: $($r.Output)" }
                    }
                }
            }
        }
        Pause-Script
    }
}

function Invoke-CompletePanel {
    Write-Header "PAINEL COMPLETO: PUBLICAR + HOSPEDAR + DOMINIO"
    $p = if ($ProjectPath) { $ProjectPath } else { Select-Project "Selecione a pasta do projeto/site" }
    if (-not $p) { Stop-Operation }
    Publish-Project $p
    Enable-PagesFlow
}

# ----------------------------------------------------------------------------
# Ferramentas do projeto: status, historico, branches, tags, backup, clonar, abrir
# ----------------------------------------------------------------------------
function Show-RepoStatus {
    $null = Get-ActiveProject
    Write-Header "STATUS DO REPOSITORIO"
    Write-Host "  Pasta:      $((Get-Location).ProviderPath)"
    if (-not (Test-Path -LiteralPath ".git")) { Write-Warn "Esta pasta ainda nao e um repositorio Git (use 'Publicar')."; return }

    $branch = Get-CurrentBranch
    Write-Host "  Branch:     $branch"

    $origin = Invoke-Native "git" @("remote","get-url","origin")
    if ($origin.ExitCode -eq 0) {
        Write-Host "  Remoto:     $($origin.Output)"
        [void](Invoke-Native "git" @("fetch","origin","--quiet"))
        if ((Invoke-Native "git" @("rev-parse","--verify","--quiet","refs/remotes/origin/$branch")).ExitCode -eq 0) {
            $lr = Invoke-Native "git" @("rev-list","--left-right","--count","HEAD...origin/$branch")
            $p  = @($lr.Output -split '\s+')
            if ($p.Count -ge 2) { Write-Host "  Sincronia:  $($p[0]) commit(s) para enviar, $($p[1]) para receber" }
        } else {
            Write-Host "  Sincronia:  branch ainda nao existe no GitHub"
        }
    } else {
        Write-Host "  Remoto:     (nenhum - ainda nao publicado)" -ForegroundColor Yellow
    }

    $st = Invoke-Native "git" @("status","--porcelain")
    $n  = if ($st.Output) { @($st.Output -split "`n").Count } else { 0 }
    Write-Host "  Alteracoes: $n arquivo(s) nao commitado(s)"
    if (Test-HasCommits) {
        $last = Invoke-Native "git" @("log","-1","--format=%h %s (%cr)")
        Write-Host "  Ultimo commit: $($last.Output)"
    }
    if ($origin.ExitCode -eq 0 -and (Test-Command "gh")) {
        try {
            $info = Get-RepoInfo
            $vis  = if ($info.IsPrivate) { "privado" } else { "publico" }
            Write-Host "  GitHub:     $($info.Url) ($vis)"
            $pg = Get-PagesInfo $info.Owner $info.Name
            if ($pg) { Write-Host "  Site:       $($pg.html_url) [$($pg.status)]" }
        } catch { }
    }
    if ($n -gt 0) {
        Write-Host ""
        $lines = @($st.Output -split "`n")
        $lines | Select-Object -First 15 | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
        if ($lines.Count -gt 15) { Write-Host "    ... e mais $($lines.Count - 15)" -ForegroundColor DarkGray }
    }
}

function Backup-Project {
    $root   = (Get-Location).ProviderPath.TrimEnd('\')
    $parent = Split-Path -Parent $root
    if (-not $parent) { throw "Nao foi possivel definir onde salvar o backup." }
    $name = Split-Path -Leaf $root
    $zip  = Join-Path $parent ("{0}-backup-{1}.zip" -f $name, (Get-Date -Format "yyyyMMdd-HHmmss"))
    $skip = @("node_modules",".venv","venv","__pycache__")

    Write-Info "Criando backup (sem node_modules/.venv)..."
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem

    $files = New-Object System.Collections.Generic.List[string]
    $stack = New-Object System.Collections.Generic.Stack[string]
    $stack.Push($root)
    while ($stack.Count -gt 0) {
        $dir = $stack.Pop()
        try { foreach ($f in [System.IO.Directory]::GetFiles($dir)) { $files.Add($f) } } catch { }
        try { $subs = [System.IO.Directory]::GetDirectories($dir) } catch { continue }
        foreach ($s in $subs) {
            if ($skip -contains [System.IO.Path]::GetFileName($s)) { continue }
            try { if (([System.IO.File]::GetAttributes($s) -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { continue } } catch { continue }
            $stack.Push($s)
        }
    }
    if ($files.Count -eq 0) { Write-Warn "Pasta vazia - nada para salvar."; return $null }

    $skipped = 0
    $fs = [System.IO.File]::Open($zip, [System.IO.FileMode]::Create)
    $archive = New-Object System.IO.Compression.ZipArchive($fs, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($f in $files) {
            $entry = $f.Substring($root.Length + 1) -replace '\\','/'
            try {
                [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $f, $entry, [System.IO.Compression.CompressionLevel]::Optimal)
            } catch { $skipped++ }
        }
    } finally { $archive.Dispose(); $fs.Dispose() }

    $mb = (Get-Item -LiteralPath $zip).Length / 1MB
    Write-Ok ("Backup criado: {0} ({1:N1} MB)" -f $zip, $mb)
    if ($skipped -gt 0) { Write-Warn "$skipped arquivo(s) estavam em uso e ficaram de fora." }
    return $zip
}

function Show-HistoryMenu {
    $null = Get-ActiveProject
    if (-not (Test-Path -LiteralPath ".git")) { throw "Esta pasta ainda nao e um repositorio Git." }
    while ($true) {
        Write-Header "HISTORICO E DESFAZER"
        Write-Host "  1 - Ver os ultimos 15 commits"
        Write-Host "  2 - Desfazer o ultimo commit (mantem os arquivos)  [so se ainda nao foi enviado]"
        Write-Host "  3 - Reverter o ultimo commit (cria um commit inverso - seguro mesmo se ja foi enviado)"
        Write-Host "  4 - Descartar alteracoes nao commitadas (PERIGOSO)"
        Write-Host "  0 - Voltar"
        $c = Read-Choice "Escolha" @("0","1","2","3","4")
        if ($c -eq "0") { return }
        Invoke-Safe {
            if (-not (Test-HasCommits)) { throw "Este repositorio ainda nao tem commits." }
            switch ($c) {
                "1" { [void](Invoke-Live "git" @("log","--oneline","--decorate","-n","15")) }
                "2" {
                    if ((Invoke-Native "git" @("rev-parse","--verify","--quiet","HEAD~1")).ExitCode -ne 0) { throw "Este e o primeiro commit; nao ha o que desfazer." }
                    $pushed = Invoke-Native "git" @("branch","-r","--contains","HEAD")
                    if ($pushed.Output) { throw "O ultimo commit ja esta no GitHub. Use a opcao 3 (reverter), que e segura." }
                    [void](Invoke-Live "git" @("log","--oneline","-n","1"))
                    if (Read-YesNo "Desfazer este commit (os arquivos permanecem)?" $false) {
                        if ((Invoke-Live "git" @("reset","--soft","HEAD~1")) -eq 0) { Write-Ok "Commit desfeito. Seus arquivos continuam intactos." }
                    }
                }
                "3" {
                    [void](Invoke-Live "git" @("log","--oneline","-n","1"))
                    if (Read-YesNo "Criar um commit que desfaz o ultimo?" $false) {
                        if ((Invoke-Live "git" @("revert","HEAD","--no-edit")) -eq 0) { Write-Ok "Commit revertido (envie com 'Atualizar projeto')." }
                        else { [void](Invoke-Native "git" @("revert","--abort")); throw "Nao foi possivel reverter automaticamente." }
                    }
                }
                "4" {
                    $st = Invoke-Native "git" @("status","--short")
                    if (-not $st.Output) { Write-Info "Nao ha alteracoes para descartar."; return }
                    Write-Warn "Estas alteracoes serao PERDIDAS (arquivos novos/nao rastreados nao sao apagados):"
                    ($st.Output -split "`n") | Select-Object -First 20 | ForEach-Object { Write-Host "    $_" }
                    if (Read-YesNo "Fazer um backup ZIP antes?" $true) { $null = Backup-Project }
                    $confirm = Read-Host "Digite DESCARTAR (em maiusculas) para confirmar"
                    if ($confirm -cne "DESCARTAR") { Stop-Operation }
                    if ((Invoke-Live "git" @("restore","--source=HEAD","--staged","--worktree","--",".")) -eq 0) { Write-Ok "Alteracoes descartadas." }
                }
            }
        }
        Pause-Script
    }
}

function Show-BranchMenu {
    $null = Get-ActiveProject
    if (-not (Test-Path -LiteralPath ".git")) { throw "Esta pasta ainda nao e um repositorio Git." }
    while ($true) {
        Write-Header "BRANCHES E PULL REQUEST  (atual: $(Get-CurrentBranch))"
        Write-Host "  1 - Listar branches"
        Write-Host "  2 - Criar novo branch e trocar para ele"
        Write-Host "  3 - Trocar de branch"
        Write-Host "  4 - Enviar o branch atual para o GitHub"
        Write-Host "  5 - Abrir Pull Request no navegador"
        Write-Host "  0 - Voltar"
        $c = Read-Choice "Escolha" @("0","1","2","3","4","5")
        if ($c -eq "0") { return }
        Invoke-Safe {
            switch ($c) {
                "1" { [void](Invoke-Live "git" @("branch","-a","-vv")) }
                "2" {
                    $n = (Read-Host "Nome do novo branch (ex: novo-layout)").Trim()
                    if (-not $n) { Stop-Operation }
                    if ((Invoke-Native "git" @("check-ref-format","--branch",$n)).ExitCode -ne 0) { throw "Nome de branch invalido." }
                    if ((Invoke-Live "git" @("switch","-c",$n)) -eq 0) { Write-Ok "Agora voce esta no branch '$n'." }
                }
                "3" {
                    [void](Invoke-Live "git" @("branch"))
                    $n = (Read-Host "Nome do branch").Trim()
                    if (-not $n) { Stop-Operation }
                    if ((Invoke-Live "git" @("switch",$n)) -eq 0) { Write-Ok "Agora voce esta no branch '$n'." }
                }
                "4" { Ensure-GitHubAuth; Push-Project }
                "5" {
                    Ensure-GitHubCli; Ensure-GitHubAuth
                    if ((Invoke-Live "gh" @("pr","create","--web","--fill")) -ne 0) { Write-Warn "Envie o branch primeiro (opcao 4) e tente de novo." }
                }
            }
        }
        Pause-Script
    }
}

function Show-TagMenu {
    $null = Get-ActiveProject
    if (-not (Test-Path -LiteralPath ".git")) { throw "Esta pasta ainda nao e um repositorio Git." }
    if (-not (Test-HasCommits)) { throw "Este repositorio ainda nao tem commits." }
    Write-Header "TAGS E RELEASES"
    Write-Host "  Tags existentes (mais recentes primeiro):"
    $t = Invoke-Native "git" @("tag","--sort=-creatordate")
    if ($t.Output) { ($t.Output -split "`n") | Select-Object -First 8 | ForEach-Object { Write-Host "    $_" } } else { Write-Host "    (nenhuma)" }
    Write-Host ""
    $st = Invoke-Native "git" @("status","--porcelain")
    if ($st.Output) { Write-Warn "Ha alteracoes nao commitadas - a tag apontara para o ultimo commit, sem elas." }

    $name = (Read-Host "Nome da nova tag (ex: v1.0.0) [Enter = cancelar]").Trim()
    if (-not $name) { return }
    if ((Invoke-Native "git" @("check-ref-format","refs/tags/$name")).ExitCode -ne 0) { throw "Nome de tag invalido." }
    $msg = (Read-Host "Mensagem da tag [Enter = $name]").Trim()
    if (-not $msg) { $msg = $name }
    $msg = $msg -replace '"',"'"

    if ((Invoke-Live "git" @("tag","-a",$name,"-m",$msg)) -ne 0) { throw "Nao foi possivel criar a tag." }
    Ensure-GitHubAuth
    if ((Invoke-Live "git" @("push","origin",$name)) -ne 0) { throw "Nao foi possivel enviar a tag." }
    Write-Ok "Tag $name enviada."
    if (Read-YesNo "Criar tambem uma Release no GitHub com notas automaticas?" $true) {
        if ((Invoke-Live "gh" @("release","create",$name,"--title",$name,"--generate-notes")) -eq 0) { Write-Ok "Release criada." }
    }
}

function Show-DefaultFilesMenu {
    $null = Get-ActiveProject
    Write-Header "ARQUIVOS PADRAO DO PROJETO"
    Write-Host "  1 - Criar/complementar .gitignore (detecta Node/Python/site estatico)"
    Write-Host "  2 - Criar README.md (se nao existir)"
    Write-Host "  3 - Adicionar LICENSE (MIT)"
    Write-Host "  4 - Criar .nojekyll (para GitHub Pages)"
    Write-Host "  5 - Corrigir BOM em .gitignore e CNAME"
    Write-Host "  0 - Voltar"
    $c = Read-Choice "Escolha" @("0","1","2","3","4","5")
    $changed = @()
    switch ($c) {
        "0" { return }
        "1" {
            if (Test-Path -LiteralPath ".gitignore") { Add-ToGitIgnore (Get-GitIgnoreLines | Where-Object { $_ -and -not $_.StartsWith("#") }); Write-Ok ".gitignore complementado." }
            else { New-GitIgnore }
            $changed = @(".gitignore")
        }
        "2" { New-Readme; $changed = @("README.md") }
        "3" { New-LicenseFile; $changed = @("LICENSE") }
        "4" { Write-TextFile ".nojekyll" ""; Write-Ok ".nojekyll criado."; $changed = @(".nojekyll") }
        "5" { Repair-Utf8Bom ".gitignore"; Repair-Utf8Bom "CNAME"; $changed = @(".gitignore","CNAME") }
    }
    $changed = @($changed | Where-Object { Test-Path -LiteralPath $_ })
    if ($changed.Count -gt 0 -and (Test-Path -LiteralPath ".git") -and (Read-YesNo "Commitar e enviar para o GitHub agora?" $false)) {
        Ensure-GitConfig; Ensure-GitHubAuth
        if (Commit-Files $changed "Atualiza arquivos padrao do projeto") { Sync-Remote }
        else { Write-Info "Nada mudou no Git." }
    }
}

function Clone-Repository {
    Ensure-Git; Ensure-GitHubCli; Ensure-GitHubAuth
    $repos = @(Get-MyRepos)
    Write-Header "CLONAR REPOSITORIO DO GITHUB"
    for ($i = 0; $i -lt $repos.Count; $i++) {
        $tag = if ($repos[$i].isPrivate) { " (privado)" } else { "" }
        Write-Host ("  [{0}] {1}{2}" -f ($i + 1), $repos[$i].nameWithOwner, $tag)
    }
    Write-Host "  Ou digite usuario/repositorio ou a URL."
    $choice = (Read-Host "Escolha [Enter = cancelar]").Trim()
    if (-not $choice) { Stop-Operation }
    $full = $choice
    if ($choice -match '^\d+$') {
        $idx = [int]$choice - 1
        if ($idx -lt 0 -or $idx -ge $repos.Count) { throw "Numero fora da lista." }
        $full = $repos[$idx].nameWithOwner
    }
    $leaf = (($full.TrimEnd('/') -split '[/\\]')[-1]) -replace '\.git$',''
    if (-not $leaf) { throw "Repositorio invalido." }

    $parent = Select-Folder "Onde salvar a copia?"
    if (-not $parent) { Stop-Operation }
    $dest = Join-Path $parent $leaf
    if (Test-Path -LiteralPath $dest) { throw "Ja existe uma pasta em $dest" }
    if ((Invoke-Live "gh" @("repo","clone",$full,$dest)) -ne 0) { throw "Falha ao clonar '$full'." }
    $null = Use-Project $dest
    Write-Ok "Clonado em $dest (agora e o projeto ativo)."
}

function Show-OpenMenu {
    $null = Get-ActiveProject
    $here = (Get-Location).ProviderPath
    Write-Header "ABRIR"
    Write-Host "  1 - Repositorio no navegador"
    Write-Host "  2 - Site publicado (GitHub Pages)"
    Write-Host "  3 - Pasta no Explorer"
    Write-Host "  4 - Pasta no VS Code"
    Write-Host "  0 - Voltar"
    $c = Read-Choice "Escolha" @("0","1","2","3","4")
    switch ($c) {
        "1" { Ensure-GitHubCli; [void](Invoke-Live "gh" @("repo","view","--web")) }
        "2" {
            $info  = Get-RepoInfo
            $pages = Get-PagesInfo $info.Owner $info.Name
            if (-not $pages) { throw "GitHub Pages nao esta ativo neste repositorio." }
            Start-Process $pages.html_url
        }
        "3" { Start-Process "explorer.exe" -ArgumentList ('"' + $here + '"') }
        "4" {
            if (Test-Command "code") { Start-Process "cmd.exe" -ArgumentList ('/c code "' + $here + '"') -WindowStyle Hidden }
            else { Write-Warn "VS Code nao encontrado no PATH (comando 'code')." }
        }
    }
}

# ----------------------------------------------------------------------------
# Sistema: diagnostico e atualizacao
# ----------------------------------------------------------------------------
function Get-ToolVersion([string]$Command, [string[]]$Arguments) {
    if (-not (Test-Command $Command)) { return $null }
    $r = Invoke-Native $Command $Arguments
    if ($r.ExitCode -ne 0) { return $null }
    return (($r.Output -split "`n")[0]).Trim()
}

function Show-Doctor {
    Write-Header "DIAGNOSTICO DO AMBIENTE"
    Write-Host "  Setup GitHub v$($script:Version) | PowerShell $($PSVersionTable.PSVersion) | Windows $([Environment]::OSVersion.Version)"
    Write-Host ""
    $tools = @(
        @("WinGet",     "winget", @("--version")),
        @("Git",        "git",    @("--version")),
        @("Git LFS",    "git",    @("lfs","version")),
        @("GitHub CLI", "gh",     @("--version")),
        @("Node.js",    "node",   @("--version")),
        @("npm",        "npm",    @("--version")),
        @("Python",     "python", @("--version"))
    )
    foreach ($t in $tools) {
        $v = Get-ToolVersion $t[1] $t[2]
        if ($v) { Write-Host ("  [OK] {0,-11} {1}" -f $t[0], $v) -ForegroundColor Green }
        else    { Write-Host ("  [--] {0,-11} nao instalado" -f $t[0]) -ForegroundColor Yellow }
    }
    Write-Host ""
    if (Test-Command "git") {
        $n = (Invoke-Native "git" @("config","--global","user.name")).Output
        $e = (Invoke-Native "git" @("config","--global","user.email")).Output
        Write-Host "  Git user.name : $(if ($n) { $n } else { '(nao configurado)' })"
        Write-Host "  Git user.email: $(if ($e) { $e } else { '(nao configurado)' })"
    }
    if (Test-Command "gh") {
        $u = Invoke-Native "gh" @("api","user","--jq",".login") -StdoutOnly
        if ($u.ExitCode -eq 0 -and $u.Output) { Write-Host "  GitHub login  : $($u.Output.Trim())" -ForegroundColor Green }
        else { Write-Host "  GitHub login  : nao autenticado (sera pedido ao publicar)" -ForegroundColor Yellow }
    }
    Write-Host ""
    Write-Host "  Pasta de dados: $($script:AppDir)"
    Write-Host "  Log desta sessao: $(if ($script:LogFile) { $script:LogFile } else { '(desativado)' })"
}

function Update-SystemEngines {
    Ensure-Winget
    $targets = @(
        @("git",  "Git.Git",           "Git"),
        @("gh",   "GitHub.cli",        "GitHub CLI"),
        @("node", "OpenJS.NodeJS.LTS", "Node.js LTS")
    )
    foreach ($t in $targets) {
        if (-not (Test-Command $t[0])) { Write-Info "$($t[2]) nao esta instalado - ignorando."; continue }
        Write-Info "Verificando atualizacao: $($t[2])..."
        $code = Invoke-Console "winget" @("upgrade","--id",$t[1],"-e","--accept-source-agreements","--accept-package-agreements")
        if ($code -eq -1978335189) { Write-Ok "$($t[2]) ja esta na versao mais recente." }
        elseif ($code -ne 0)       { Write-Warn "winget retornou codigo $code para $($t[2])." }
    }
    Update-SessionPath
    Write-Ok "Verificacao de ferramentas concluida."
}

# ----------------------------------------------------------------------------
# Menu e execucao segura
# ----------------------------------------------------------------------------
function Invoke-Safe([scriptblock]$Action) {
    try { & $Action }
    catch [System.OperationCanceledException] { Write-Warn $_.Exception.Message }
    catch {
        $script:HadError = $true
        Write-Host ""
        Write-Fail $_.Exception.Message
        Write-Warn "O processo foi interrompido com seguranca."
        if ($script:LogFile) { Write-Host "    Detalhes no log: $($script:LogFile)" -ForegroundColor DarkGray }
    }
}

function Show-Menu {
    while ($true) {
        Set-Location -LiteralPath $script:ScriptDir
        Clear-Host
        Write-Host "============================================================" -ForegroundColor Green
        Write-Host "        SETUP GITHUB v$($script:Version) - PAINEL PRINCIPAL" -ForegroundColor Green
        Write-Host "============================================================" -ForegroundColor Green
        $active = if ($script:ActiveProject) { $script:ActiveProject } else { "(nenhum - sera pedido quando necessario)" }
        Write-Host "  Projeto ativo: $active" -ForegroundColor DarkGray
        Write-Host ""
        Write-Host " PUBLICAR" -ForegroundColor Cyan
        Write-Host "   1  - Publicar a pasta onde este script esta"
        Write-Host "   2  - Selecionar outra pasta e publicar"
        Write-Host "   3  - Criar novo projeto e publicar"
        Write-Host "   4  - Atualizar projeto existente (commit + push)"
        Write-Host " HOSPEDAGEM" -ForegroundColor Cyan
        Write-Host "   5  - GitHub Pages / dominio proprio / HTTPS"
        Write-Host "   6  - Painel completo (publicar + hospedar + dominio)"
        Write-Host " PROJETO" -ForegroundColor Cyan
        Write-Host "   7  - Status do repositorio"
        Write-Host "   8  - Historico e desfazer"
        Write-Host "   9  - Branches e Pull Request"
        Write-Host "   10 - Tags e releases"
        Write-Host "   11 - Arquivos padrao (.gitignore, README, LICENSE...)"
        Write-Host "   12 - Backup ZIP do projeto"
        Write-Host "   13 - Clonar repositorio do GitHub"
        Write-Host "   14 - Abrir (navegador, site, Explorer, VS Code)"
        Write-Host " SISTEMA" -ForegroundColor Cyan
        Write-Host "   15 - Diagnostico do ambiente"
        Write-Host "   16 - Atualizar ferramentas (WinGet)"
        Write-Host "   P  - Trocar projeto ativo"
        Write-Host "   0  - Sair"
        Write-Host ""

        $choice = (Read-Host "Escolha uma opcao").Trim().ToLower()
        $validChoices = @("0","1","2","3","4","5","6","7","8","9","10","11","12","13","14","15","16","p")
        if ($validChoices -notcontains $choice) { Write-Warn "Opcao invalida."; Start-Sleep -Milliseconds 700; continue }
        $pause = $true
        switch ($choice) {
            "1" {
                Invoke-Safe {
                    Write-Info "Pasta do script: $($script:ScriptDir)"
                    if (Read-YesNo "Publicar esta pasta?" $true) { Publish-Project $script:ScriptDir }
                }
            }
            "2" {
                Invoke-Safe {
                    $p = Select-Project "Selecione a pasta a publicar"
                    if (-not $p) { Stop-Operation }
                    Publish-Project $p
                }
            }
            "3"  { Invoke-Safe { New-ProjectFlow } }
            "4" {
                Invoke-Safe {
                    $p = Select-Project "Selecione o projeto para atualizar"
                    if (-not $p) { Stop-Operation }
                    Update-Project $p
                }
            }
            "5"  { Invoke-Safe { Show-PagesMenu }; $pause = $false }
            "6"  { Invoke-Safe { Invoke-CompletePanel } }
            "7"  { Invoke-Safe { Show-RepoStatus } }
            "8"  { Invoke-Safe { Show-HistoryMenu }; $pause = $false }
            "9"  { Invoke-Safe { Show-BranchMenu }; $pause = $false }
            "10" { Invoke-Safe { Show-TagMenu } }
            "11" { Invoke-Safe { Show-DefaultFilesMenu } }
            "12" { Invoke-Safe { $null = Get-ActiveProject; $null = Backup-Project } }
            "13" { Invoke-Safe { Clone-Repository } }
            "14" { Invoke-Safe { Show-OpenMenu } }
            "15" { Invoke-Safe { Show-Doctor } }
            "16" { Invoke-Safe { Update-SystemEngines } }
            "p" {
                Invoke-Safe {
                    $p = Select-Project "Selecione o projeto ativo"
                    if (-not $p) { Stop-Operation }
                    $null = Use-Project $p
                    Write-Ok "Projeto ativo: $($script:ActiveProject)"
                }
            }
            "0" { Write-Host "Saindo..." -ForegroundColor Yellow; return }
        }
        if ($pause) { Pause-Script }
    }
}

function Invoke-Mode {
    switch ($Mode) {
        "menu"    { Show-Menu }
        "publish" {
            Invoke-Safe {
                $p = if ($ProjectPath) { $ProjectPath } else { Select-Project "Selecione a pasta a publicar" }
                if (-not $p) { Stop-Operation }
                Publish-Project $p
            }
        }
        "new"     { Invoke-Safe { New-ProjectFlow } }
        "update"  {
            Invoke-Safe {
                $p = if ($ProjectPath) { $ProjectPath } else { Select-Project "Selecione o projeto para atualizar" }
                if (-not $p) { Stop-Operation }
                Update-Project $p
            }
        }
        "host"    {
            Invoke-Safe {
                $p = if ($ProjectPath) { $ProjectPath } else { Select-Project "Selecione a pasta do site" }
                if (-not $p) { Stop-Operation }
                $null = Use-Project $p
                Enable-PagesFlow
            }
        }
        "all"     { Invoke-Safe { Invoke-CompletePanel } }
        "status"  {
            Invoke-Safe {
                if ($ProjectPath) { $null = Use-Project $ProjectPath }
                Show-RepoStatus
            }
        }
        "clone"   { Invoke-Safe { Clone-Repository } }
        "doctor"  { Invoke-Safe { Show-Doctor } }
        "engines" { Invoke-Safe { Update-SystemEngines } }
    }
}

# ----------------------------------------------------------------------------
# Ponto de entrada (nao executa se o arquivo for carregado com ". .\arquivo.ps1")
# ----------------------------------------------------------------------------
if ($MyInvocation.InvocationName -ne ".") {
    $exitCode = 0
    try {
        Start-Log
        Invoke-Mode
        if ($Mode -ne "menu" -and $script:HadError) { $exitCode = 1 }
    } finally {
        Stop-Log
    }
    exit $exitCode
}
