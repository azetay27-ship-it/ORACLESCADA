#requires -Version 2.0
# Compare Windows identities, not the scheduler's display form of an account name.
# No scheduler, process, application, marker or configuration is changed here.
function Resolve-TaskPrincipalSid([string]$UserId) {
    if ([string]::IsNullOrEmpty($UserId) -or $UserId.Trim().Length -eq 0) {
        throw 'Task principal UserId is empty.'
    }
    if ($UserId -match '^S-') {
        $sid = New-Object System.Security.Principal.SecurityIdentifier -ArgumentList $UserId
        return $sid.Value
    }
    $accountName = $UserId
    if ($accountName.StartsWith('.\')) {
        $accountName = [Environment]::MachineName + '\' + $accountName.Substring(2)
    }
    $account = New-Object System.Security.Principal.NTAccount -ArgumentList $accountName
    return $account.Translate([System.Security.Principal.SecurityIdentifier]).Value
}

function Assert-TaskPrincipal($Principal, [string]$ExpectedSid, [string]$ExpectedName) {
    $rawUserId = [string]$Principal.UserId
    $logonType = [int]$Principal.LogonType
    $resolvedSid = '<unresolved>'
    $resolutionError = ''
    try { $resolvedSid = Resolve-TaskPrincipalSid $rawUserId }
    catch { $resolutionError = $_.Exception.Message }
    if ($logonType -ne 3 -or $resolvedSid -ine $ExpectedSid) {
        $details = 'TaskUserId="' + $rawUserId + '"; TaskSID=' + $resolvedSid +
            '; LogonType=' + $logonType + ' (required 3); CurrentUser="' + $ExpectedName +
            '"; CurrentSID=' + $ExpectedSid
        if ($resolutionError.Length -gt 0) { $details += '; ResolutionError=' + $resolutionError }
        throw ('Task operator verification failed. It was not changed. ' + $details)
    }
}
