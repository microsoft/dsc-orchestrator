# Copyright (c) Microsoft Corporation.
# Licensed under the MIT license.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-OrchestratorJsonMember {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowNull()][object]$Object,
        [Parameter(Mandatory)][string]$Name
    )

    if ($null -eq $Object) {
        return [pscustomobject]@{ Found = $false; Value = $null }
    }

    if ($Object -is [System.Collections.IDictionary]) {
        foreach ($key in $Object.Keys) {
            if ([string]::Equals([string]$key, $Name, [System.StringComparison]::Ordinal)) {
                return [pscustomobject]@{ Found = $true; Value = $Object[$key] }
            }
        }
    }
    elseif ($Object -is [pscustomobject]) {
        foreach ($property in $Object.PSObject.Properties) {
            if ([string]::Equals($property.Name, $Name, [System.StringComparison]::Ordinal)) {
                return [pscustomobject]@{ Found = $true; Value = $property.Value }
            }
        }
    }

    [pscustomobject]@{ Found = $false; Value = $null }
}

function Get-OrchestratorJsonMemberNames {
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Returns every member name for additionalProperties validation.')]
    param([Parameter(Mandatory)][object]$Object)

    if ($Object -is [System.Collections.IDictionary]) {
        return @($Object.Keys | ForEach-Object { [string]$_ })
    }
    if ($Object -is [pscustomobject]) {
        return @($Object.PSObject.Properties | ForEach-Object { $_.Name })
    }
    return @()
}

function Test-OrchestratorJsonNumber {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowNull()][object]$Value)

    if ($null -eq $Value -or $Value -is [bool]) { return $false }
    return $Value -is [byte] -or $Value -is [sbyte] -or
        $Value -is [int16] -or $Value -is [uint16] -or
        $Value -is [int32] -or $Value -is [uint32] -or
        $Value -is [int64] -or $Value -is [uint64] -or
        $Value -is [single] -or $Value -is [double] -or $Value -is [decimal]
}

function Test-OrchestratorJsonType {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowNull()][object]$Value,
        [Parameter(Mandatory)][ValidateSet('object','array','string','boolean','integer','number','null')][string]$Type
    )

    switch ($Type) {
        'null'    { return $null -eq $Value }
        'object'  { return $null -ne $Value -and ($Value -is [System.Collections.IDictionary] -or $Value -is [pscustomobject]) }
        'array'   { return $null -ne $Value -and $Value -is [System.Collections.IList] -and $Value -isnot [string] }
        'string'  { return $Value -is [string] -or $Value -is [datetime] -or $Value -is [datetimeoffset] }
        'boolean' { return $Value -is [bool] }
        'integer' {
            if (-not (Test-OrchestratorJsonNumber -Value $Value)) { return $false }
            return [decimal]$Value -eq [decimal]::Truncate([decimal]$Value)
        }
        'number'  { return Test-OrchestratorJsonNumber -Value $Value }
    }
    return $false
}

function Get-OrchestratorJsonTypeName {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowNull()][object]$Value)

    if ($null -eq $Value) { return 'null' }
    if ($Value -is [pscustomobject] -or $Value -is [System.Collections.IDictionary]) { return 'object' }
    if ($Value -is [System.Collections.IList] -and $Value -isnot [string]) { return 'array' }
    if ($Value -is [datetime] -or $Value -is [datetimeoffset]) { return 'string' }
    if ($Value -is [string]) { return 'string' }
    if ($Value -is [bool]) { return 'boolean' }
    if (Test-OrchestratorJsonNumber -Value $Value) {
        if (Test-OrchestratorJsonType -Value $Value -Type 'integer') { return 'integer' }
        return 'number'
    }
    return $Value.GetType().Name
}

function Test-OrchestratorJsonScalarEqual {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowNull()][object]$Left,
        [Parameter(Mandatory)][AllowNull()][object]$Right
    )

    if ($null -eq $Left -or $null -eq $Right) { return $null -eq $Left -and $null -eq $Right }
    if ($Left -is [string] -or $Right -is [string]) {
        return $Left -is [string] -and $Right -is [string] -and
            [string]::Equals($Left, $Right, [System.StringComparison]::Ordinal)
    }
    if ($Left -is [bool] -or $Right -is [bool]) {
        return $Left -is [bool] -and $Right -is [bool] -and $Left -eq $Right
    }
    if ((Test-OrchestratorJsonNumber -Value $Left) -and (Test-OrchestratorJsonNumber -Value $Right)) {
        return [decimal]$Left -eq [decimal]$Right
    }
    return $false
}

function Invoke-OrchestratorJsonSchemaNode {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Schema,
        [Parameter(Mandatory)][AllowNull()][object]$Value,
        [Parameter(Mandatory)][string]$InstancePath,
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[string]]$Errors
    )

    $oneOf = Get-OrchestratorJsonMember -Object $Schema -Name 'oneOf'
    if ($oneOf.Found) {
        $matchingSchemaCount = 0
        foreach ($candidate in @($oneOf.Value)) {
            $candidateErrors = [System.Collections.Generic.List[string]]::new()
            Invoke-OrchestratorJsonSchemaNode -Schema $candidate -Value $Value `
                -InstancePath $InstancePath -Errors $candidateErrors
            if ($candidateErrors.Count -eq 0) { $matchingSchemaCount++ }
        }
        if ($matchingSchemaCount -ne 1) {
            [void]$Errors.Add("$InstancePath must match exactly one schema alternative; matched $matchingSchemaCount.")
        }
        return
    }

    $typeMember = Get-OrchestratorJsonMember -Object $Schema -Name 'type'
    if ($typeMember.Found) {
        $typeMatches = $false
        foreach ($typeName in @($typeMember.Value)) {
            if (Test-OrchestratorJsonType -Value $Value -Type ([string]$typeName)) {
                $typeMatches = $true
                break
            }
        }
        if (-not $typeMatches) {
            $expected = (@($typeMember.Value) -join ' or ')
            $actual = Get-OrchestratorJsonTypeName -Value $Value
            [void]$Errors.Add("$InstancePath must be $expected; found $actual.")
            return
        }
    }

    $constMember = Get-OrchestratorJsonMember -Object $Schema -Name 'const'
    if ($constMember.Found -and -not (Test-OrchestratorJsonScalarEqual -Left $Value -Right $constMember.Value)) {
        [void]$Errors.Add("$InstancePath must equal '$($constMember.Value)'.")
    }

    $enumMember = Get-OrchestratorJsonMember -Object $Schema -Name 'enum'
    if ($enumMember.Found) {
        $enumMatch = $false
        foreach ($allowedValue in @($enumMember.Value)) {
            if (Test-OrchestratorJsonScalarEqual -Left $Value -Right $allowedValue) {
                $enumMatch = $true
                break
            }
        }
        if (-not $enumMatch) {
            [void]$Errors.Add("$InstancePath must be one of: $(@($enumMember.Value) -join ', ').")
        }
    }

    if ($Value -is [string] -or $Value -is [datetime] -or $Value -is [datetimeoffset]) {
        $stringValue = [string]$Value
        if ($Value -is [datetime]) {
            $stringValue = $Value.ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)
        }
        elseif ($Value -is [datetimeoffset]) {
            $stringValue = $Value.ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)
        }
        $patternMember = Get-OrchestratorJsonMember -Object $Schema -Name 'pattern'
        if ($patternMember.Found -and -not [regex]::IsMatch($stringValue, [string]$patternMember.Value, [System.Text.RegularExpressions.RegexOptions]::CultureInvariant)) {
            [void]$Errors.Add("$InstancePath does not match the required pattern '$($patternMember.Value)'.")
        }

        $minLength = Get-OrchestratorJsonMember -Object $Schema -Name 'minLength'
        if ($minLength.Found -and $stringValue.Length -lt [int]$minLength.Value) {
            [void]$Errors.Add("$InstancePath must contain at least $($minLength.Value) character(s).")
        }
        $maxLength = Get-OrchestratorJsonMember -Object $Schema -Name 'maxLength'
        if ($maxLength.Found -and $stringValue.Length -gt [int]$maxLength.Value) {
            [void]$Errors.Add("$InstancePath must contain no more than $($maxLength.Value) character(s).")
        }

        $formatMember = Get-OrchestratorJsonMember -Object $Schema -Name 'format'
        if ($formatMember.Found -and [string]$formatMember.Value -eq 'date-time') {
            $parsed = [DateTimeOffset]::MinValue
            $validDateTime = [DateTimeOffset]::TryParse(
                $stringValue,
                [System.Globalization.CultureInfo]::InvariantCulture,
                [System.Globalization.DateTimeStyles]::RoundtripKind,
                [ref]$parsed
            )
            if (-not $validDateTime) {
                [void]$Errors.Add("$InstancePath must be an ISO 8601 date-time.")
            }
        }
    }

    if (Test-OrchestratorJsonType -Value $Value -Type 'number') {
        $minimum = Get-OrchestratorJsonMember -Object $Schema -Name 'minimum'
        if ($minimum.Found -and [decimal]$Value -lt [decimal]$minimum.Value) {
            [void]$Errors.Add("$InstancePath must be at least $($minimum.Value).")
        }
        $maximum = Get-OrchestratorJsonMember -Object $Schema -Name 'maximum'
        if ($maximum.Found -and [decimal]$Value -gt [decimal]$maximum.Value) {
            [void]$Errors.Add("$InstancePath must be no greater than $($maximum.Value).")
        }
    }

    if (Test-OrchestratorJsonType -Value $Value -Type 'object') {
        $properties = Get-OrchestratorJsonMember -Object $Schema -Name 'properties'
        $required = Get-OrchestratorJsonMember -Object $Schema -Name 'required'
        $actualNames = @(Get-OrchestratorJsonMemberNames -Object $Value)

        if ($required.Found) {
            foreach ($requiredName in @($required.Value)) {
                $requiredMember = Get-OrchestratorJsonMember -Object $Value -Name ([string]$requiredName)
                if (-not $requiredMember.Found) {
                    [void]$Errors.Add("$InstancePath.$requiredName is required.")
                }
            }
        }

        $additionalProperties = Get-OrchestratorJsonMember -Object $Schema -Name 'additionalProperties'
        foreach ($propertyName in $actualNames) {
            $propertySchema = if ($properties.Found) {
                Get-OrchestratorJsonMember -Object $properties.Value -Name $propertyName
            }
            else {
                [pscustomobject]@{ Found = $false; Value = $null }
            }

            if ($propertySchema.Found) {
                $propertyValue = Get-OrchestratorJsonMember -Object $Value -Name $propertyName
                Invoke-OrchestratorJsonSchemaNode -Schema $propertySchema.Value -Value $propertyValue.Value `
                    -InstancePath "$InstancePath.$propertyName" -Errors $Errors
            }
            elseif ($additionalProperties.Found -and $additionalProperties.Value -is [bool] -and -not $additionalProperties.Value) {
                [void]$Errors.Add("$InstancePath has unexpected property '$propertyName'.")
            }
            elseif ($additionalProperties.Found -and
                ($additionalProperties.Value -is [pscustomobject] -or $additionalProperties.Value -is [System.Collections.IDictionary])) {
                $propertyValue = Get-OrchestratorJsonMember -Object $Value -Name $propertyName
                Invoke-OrchestratorJsonSchemaNode -Schema $additionalProperties.Value -Value $propertyValue.Value `
                    -InstancePath "$InstancePath.$propertyName" -Errors $Errors
            }
        }
    }
    elseif (Test-OrchestratorJsonType -Value $Value -Type 'array') {
        $minimumItems = Get-OrchestratorJsonMember -Object $Schema -Name 'minItems'
        if ($minimumItems.Found -and $Value.Count -lt [int]$minimumItems.Value) {
            [void]$Errors.Add("$InstancePath must contain at least $($minimumItems.Value) item(s).")
        }
        $maximumItems = Get-OrchestratorJsonMember -Object $Schema -Name 'maxItems'
        if ($maximumItems.Found -and $Value.Count -gt [int]$maximumItems.Value) {
            [void]$Errors.Add("$InstancePath must contain no more than $($maximumItems.Value) item(s).")
        }

        $items = Get-OrchestratorJsonMember -Object $Schema -Name 'items'
        if ($items.Found) {
            for ($index = 0; $index -lt $Value.Count; $index++) {
                Invoke-OrchestratorJsonSchemaNode -Schema $items.Value -Value $Value[$index] `
                    -InstancePath "$InstancePath[$index]" -Errors $Errors
            }
        }
    }
}

function Test-OrchestratorJsonSchema {
    <#
    .SYNOPSIS
        Validates a JSON value against the contract-schema keywords used by this repository.
    .DESCRIPTION
        Uses ConvertFrom-Json-compatible PowerShell types, so contract validation works in
        Windows PowerShell 5.1 without the PowerShell 6.2 Test-Json cmdlet. Schemas use only
        type, required, properties, additionalProperties, items, oneOf, const, enum, pattern,
        length/item bounds, numeric bounds, and date-time format.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][AllowNull()][object]$Value,
        [Parameter(Mandatory)]
        [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
        [string]$SchemaPath,
        [Parameter()][ValidateNotNullOrEmpty()][string]$InstancePath = '$'
    )

    $fullSchemaPath = [System.IO.Path]::GetFullPath($SchemaPath)
    try {
        $schema = Get-Content -LiteralPath $fullSchemaPath -Raw -ErrorAction Stop |
            ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw "Failed to read JSON Schema '$fullSchemaPath': $($_.Exception.Message)"
    }
    if ($schema -isnot [pscustomobject]) {
        throw "JSON Schema '$fullSchemaPath' must contain an object."
    }

    $errors = [System.Collections.Generic.List[string]]::new()
    Invoke-OrchestratorJsonSchemaNode -Schema $schema -Value $Value -InstancePath $InstancePath -Errors $errors
    return $errors.ToArray()
}

function Assert-OrchestratorJsonSchema {
    <#
    .SYNOPSIS
        Throws with a readable field path when a value violates a repository contract schema.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowNull()][object]$Value,
        [Parameter(Mandatory)]
        [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
        [string]$SchemaPath,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Subject
    )

    $errors = @(Test-OrchestratorJsonSchema -Value $Value -SchemaPath $SchemaPath)
    if ($errors.Count -gt 0) {
        $details = @($errors | ForEach-Object { "  - $_" }) -join [Environment]::NewLine
        throw "$Subject does not conform to JSON Schema '$SchemaPath':$([Environment]::NewLine)$details"
    }
}

Export-ModuleMember -Function Test-OrchestratorJsonSchema, Assert-OrchestratorJsonSchema
