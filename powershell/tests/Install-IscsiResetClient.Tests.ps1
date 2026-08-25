BeforeAll {
    $script:InstallerPath = Join-Path `
        (Split-Path $PSScriptRoot -Parent) `
        "Install-IscsiResetClient.ps1"
    . $script:InstallerPath -CaCertificatePath "unused-for-dot-source"
}

Describe "iSCSI reset client installer inputs" {
    It "does not evaluate PSScriptRoot from a parameter default" {
        $powerShellRoot = Split-Path $script:InstallerPath -Parent
        $paths = @(
            $script:InstallerPath,
            (Join-Path $powerShellRoot "Install-IscsiReleasePublisher.ps1"),
            (Join-Path $powerShellRoot "Reset-And-Connect.ps1"),
            (Join-Path $powerShellRoot "Publish-IscsiRelease.ps1")
        )

        foreach ($path in $paths) {
            $parseErrors = $null
            $tokens = $null
            $ast = [Management.Automation.Language.Parser]::ParseFile(
                $path,
                [ref]$tokens,
                [ref]$parseErrors
            )
            $parseErrors.Count | Should -Be 0
            $parameters = @($ast.FindAll({
                param($node)
                $node -is [Management.Automation.Language.ParameterAst]
            }, $true))
            foreach ($parameter in $parameters) {
                if ($null -ne $parameter.DefaultValue) {
                    $parameter.DefaultValue.Extent.Text | Should -Not -Match '\$PSScriptRoot'
                }
            }
        }
    }

    It "does not accept a raw token or full API URL as parameters" {
        $parseErrors = $null
        $tokens = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile(
            $script:InstallerPath,
            [ref]$tokens,
            [ref]$parseErrors
        )
        $parseErrors.Count | Should -Be 0
        $parameterNames = @($ast.ParamBlock.Parameters | ForEach-Object {
            $_.Name.VariablePath.UserPath
        })

        $parameterNames | Should -Contain "ResetApiIp"
        $parameterNames | Should -Contain "EpicGamesManifestSync"
        $parameterNames | Should -Contain "MajesticLauncherSettingsSync"
        $parameterNames | Should -Not -Contain "Token"
        $parameterNames | Should -Not -Contain "ApiBaseUrl"
    }

    It "uses the documented IPv4 when the prompt is left empty" {
        Mock Read-Host { return "" }

        $api = Resolve-ResetApiAddress -Address ""

        $api.Ip | Should -Be "10.20.40.10"
        $api.BaseUrl | Should -Be "https://10.20.40.10:8443"
    }

    It "accepts a canonical IPv4 without prompting" {
        Mock Read-Host { throw "prompt must not be called" }

        $api = Resolve-ResetApiAddress -Address "192.168.40.15"

        $api.Ip | Should -Be "192.168.40.15"
        $api.BaseUrl | Should -Be "https://192.168.40.15:8443"
        Should -Invoke Read-Host -Times 0 -Exactly
    }

    It "rejects hostnames, IPv6, and non-canonical IPv4 forms" -ForEach @(
        @{ Address = "truenas.local" }
        @{ Address = "2001:db8::10" }
        @{ Address = "127.1" }
        @{ Address = "10.20.40.999" }
    ) {
        { Resolve-ResetApiAddress -Address $Address } | Should -Throw
    }

    It "reads the client token as a SecureString" {
        $secure = ConvertTo-SecureString "one-time-client-token" -AsPlainText -Force
        Mock Read-Host { return $secure } -ParameterFilter { $AsSecureString }

        $result = Read-ClientToken
        try {
            $result.PlainText | Should -Be "one-time-client-token"
            $result.SecureString.GetType().FullName | Should -Be "System.Security.SecureString"
            Should -Invoke Read-Host -Times 1 -Exactly -ParameterFilter { $AsSecureString }
        }
        finally {
            $result.PlainText = $null
            $result.SecureString.Dispose()
        }
    }

    It "rejects an empty protected token" {
        $secure = New-Object Security.SecureString
        Mock Read-Host { return $secure } -ParameterFilter { $AsSecureString }

        { Read-ClientToken } | Should -Throw "*must not be empty*"
    }

    It "uses the token only in the initial Authorization header" {
        $headers = New-ClientRequestHeaders -ClientToken "one-time-client-token"

        $headers.Authorization | Should -Be "Bearer one-time-client-token"
        $headers["X-Request-ID"] | Should -Match `
            '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    }

    It "builds scheduled-task arguments from paths and API URL only" {
        $arguments = New-ResetScheduledTaskArguments `
            -ScriptPath 'C:\ProgramData\IscsiReset\Reset-And-Connect.ps1' `
            -BaseUrl 'https://10.20.40.10:8443' `
            -ClientTokenPath 'C:\ProgramData\IscsiReset\client.token'

        $arguments | Should -Match '-ApiBaseUrl "https://10\.20\.40\.10:8443"'
        $arguments | Should -Match '-TokenPath "C:\\ProgramData\\IscsiReset\\client\.token"'
        $arguments | Should -Not -Match 'one-time-client-token|Authorization|Bearer'
    }

    It "accepts an existing non-SYSTEM Majestic user profile" {
        $profile = Join-Path $TestDrive "game-user"
        New-Item -ItemType Directory -Path $profile | Out-Null
        Set-Content -LiteralPath (Join-Path $profile "NTUSER.DAT") -Value "hive"

        $resolved = Get-MajesticSyncUserProfile `
            -Sid "S-1-5-21-100-200-300-1001" -ProfilePath $profile

        $resolved.Sid | Should -Be "S-1-5-21-100-200-300-1001"
        $resolved.ProfilePath | Should -Be (Get-Item $profile).FullName
    }

    It "rejects SYSTEM and a Majestic user profile without NTUSER.DAT" {
        $profile = Join-Path $TestDrive "missing-hive"
        New-Item -ItemType Directory -Path $profile | Out-Null

        {
            Get-MajesticSyncUserProfile -Sid "S-1-5-18" -ProfilePath $profile
        } | Should -Throw "*not SYSTEM*"
        {
            Get-MajesticSyncUserProfile `
                -Sid "S-1-5-21-100-200-300-1001" -ProfilePath $profile
        } | Should -Throw "*NTUSER.DAT*"
    }
}

Describe "Installer secret and ACL regression" {
    It "uses language-independent well-known SIDs" {
        $clientSource = Get-Content -LiteralPath $script:InstallerPath -Raw
        $publisherPath = Join-Path `
            (Split-Path $PSScriptRoot -Parent) `
            "Install-IscsiReleasePublisher.ps1"
        $publisherSource = Get-Content -LiteralPath $publisherPath -Raw

        foreach ($source in @($clientSource, $publisherSource)) {
            $source | Should -Match "S-1-5-18"
            $source | Should -Match "S-1-5-32-544"
            $source | Should -Not -Match 'NT AUTHORITY\\SYSTEM|BUILTIN\\Administrators|"Administrators:'
        }
    }

    It "protects the install directory before writing the token" {
        $source = Get-Content -LiteralPath $script:InstallerPath -Raw
        $directoryAcl = $source.IndexOf(
            'Set-Acl -LiteralPath $InstallRoot -AclObject (New-RestrictedFileSystemAcl -Directory)'
        )
        $tokenWrite = $source.IndexOf('[System.IO.File]::WriteAllText(')

        $directoryAcl | Should -BeGreaterThan -1
        $tokenWrite | Should -BeGreaterThan $directoryAcl
    }

    It "uses idempotent overwrite operations for repeat installation" {
        $source = Get-Content -LiteralPath $script:InstallerPath -Raw
        $publisherSource = Get-Content -LiteralPath (Join-Path `
            (Split-Path $script:InstallerPath -Parent) `
            "Install-IscsiReleasePublisher.ps1") -Raw

        $source | Should -Match 'New-Item -ItemType Directory -Path \$InstallRoot -Force'
        $source | Should -Match 'Copy-Item .* -Destination \$installedScript -Force'
        $source | Should -Match 'Register-ScheduledTask .*\n\s*-Trigger .* -Force'
        $source | Should -Match 'schema_version = 2'
        $source | Should -Match 'mode = \$EpicGamesManifestSync\.ToLowerInvariant\(\)'
        $source | Should -Match 'ValidateSet\("Enabled", "Disabled", "Aggressive"\)'
        $source | Should -Match '\$taskLimitMinutes = if \(\$EpicGamesManifestSync -eq "Aggressive"\)'
        $source | Should -Match 'New-TimeSpan -Minutes \$taskLimitMinutes'
        foreach ($installerSource in @($source, $publisherSource)) {
            $installerSource | Should -Match 'schema_version = 2'
            $installerSource | Should -Match `
                'mode = \$EpicGamesManifestSync\.ToLowerInvariant\(\)'
            $installerSource | Should -Match `
                'ValidateSet\("Enabled", "Disabled", "Aggressive"\)'
            $installerSource | Should -Match `
                'MajesticLauncherSettingsSync = "Disabled"'
            $installerSource | Should -Match 'schema_version = 1'
            $installerSource | Should -Match `
                'mode = \$MajesticLauncherSettingsSync\.ToLowerInvariant\(\)'
            $installerSource | Should -Match 'user_sid'
            $installerSource | Should -Match 'profile_path'
            $installerSource | Should -Match `
                '\$majesticProfile = Get-MajesticSyncUserProfile'
            $installerSource | Should -Match 'user_sid = \$majesticProfile\.Sid'
            $installerSource | Should -Match 'profile_path = \$majesticProfile\.ProfilePath'
        }
    }

    It "does not place the raw token in scheduled-task arguments or output" {
        $source = Get-Content -LiteralPath $script:InstallerPath -Raw

        $source | Should -Match 'Read-Host "Client token" -AsSecureString'
        $source | Should -Match 'ZeroFreeBSTR'
        $source | Should -Not -Match '(?m)^\s*Write-(Host|Output).*\$token'
        $source | Should -Not -Match '\$arguments\s*=.*\$token'
        $source | Should -Not -Match '-Token\s+`?"?\$token'
    }

    It "creates ACL entries directly from SIDs on Windows" {
        if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
            Set-ItResult -Skipped -Because "Windows ACL implementation is required"
            return
        }

        $acl = New-RestrictedFileSystemAcl -Directory
        $identitySids = @($acl.Access | ForEach-Object {
            $_.IdentityReference.Translate(
                [System.Security.Principal.SecurityIdentifier]
            ).Value
        })
        $identitySids | Should -Contain "S-1-5-18"
        $identitySids | Should -Contain "S-1-5-32-544"
    }
}
