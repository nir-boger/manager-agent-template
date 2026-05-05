# teams-meeting.ps1 - shared helpers for Nirvana-created meeting invites.
#
# Saved Nir preference (2026-05-05): EVERY meeting invite Nirvana sends
# (any skill, any flow) MUST include a Teams join link.
#
# --- WORKING RECIPE (verified 2026-05-05 by real send to Zvi Schneider) ---
# Outlook 16.x exposes AppointmentItem.OnlineMeetingProvider /
# IsOnlineMeeting / ConferenceLink as READ-ONLY over COM, and the
# `AddOnlineMeetingForAllMeetings` profile registry toggle does NOT
# attach a Teams link for COM-created invites (proven empirically
# 2026-05-05 - even after Outlook restart, .Save() and .Send() leave
# IsOnlineMeeting=False, OnlineMeetingProvider=5, ConferenceLink="").
#
# What DOES work: call $appt.GetInspector.Display($false). The
# `TeamsAddin.FastConnect` COM add-in registers an inspector hook that
# fires on Display, calls the Teams backend to provision a real meeting,
# and APPENDS the boilerplate (separator + "Microsoft Teams meeting" +
# joinUrl + Meeting ID + Passcode + "Need help?" link + system reference
# deeplink) to whatever Body you already set. Your existing intro / joke
# / signature stays at the top of the body untouched.
# Location is set to "Microsoft Teams Meeting" by the add-in. The
# structured props (IsOnlineMeeting / OnlineMeetingProvider / ConferenceLink)
# STAY at their default False / 5 / "" values - those flip only when the
# user clicks the Teams Meeting toggle in the UI directly. Detection
# MUST read the body for the URL pattern, NOT IsOnlineMeeting.
#
# Public API:
#   - Add-TeamsLinkToAppointment -Appointment $apt [-TimeoutSeconds 30]
#       Wakes up the Teams add-in via Display+poll. Returns $true on
#       success, $false on timeout. Caller MUST set Body BEFORE calling
#       (the add-in appends to it). Caller MUST NOT pre-set Location;
#       the add-in writes "Microsoft Teams Meeting".
#   - Test-AppointmentHasTeamsLink -Appointment $apt
#       Returns $true if Body contains a Teams join URL pattern.
#   - Get-TeamsLinkFromAppointment -Appointment $apt
#       Returns the matched Teams URL (or $null).
#
# Deprecated (kept as no-ops so old callers don't crash):
#   - Test-OutlookAlwaysAddOnlineMeeting  -> always $true (lies; not used)
#   - Enable-OutlookAlwaysAddOnlineMeeting -> warns, no-op
#   - Assert-OutlookAlwaysAddOnlineMeeting -> warns, no-op

$script:TeamsLinkRegex = 'https://teams\.microsoft\.com/(?:l/meetup-join|meet)/[^\s"<>]+'

function Test-AppointmentHasTeamsLink {
    [CmdletBinding()] param([Parameter(Mandatory)] $Appointment)
    try {
        $body = [string]$Appointment.Body
        if ([string]::IsNullOrEmpty($body)) { return $false }
        return ($body -match $script:TeamsLinkRegex)
    } catch {
        return $false
    }
}

function Get-TeamsLinkFromAppointment {
    [CmdletBinding()] param([Parameter(Mandatory)] $Appointment)
    try {
        $body = [string]$Appointment.Body
        if ([string]::IsNullOrEmpty($body)) { return $null }
        if ($body -match $script:TeamsLinkRegex) { return $matches[0] }
    } catch {}
    return $null
}

# Wakes up TeamsAddin.FastConnect by displaying the inspector, then polls
# the body until the Teams join URL appears. Closes the inspector before
# returning. Returns $true on success, $false on timeout.
#
# Caller must populate Subject / Start / Duration / Body / Recipients
# before calling. Do NOT set Location -- the add-in sets it to
# "Microsoft Teams Meeting". A pre-set Location may be overwritten.
#
# Typical timing: URL appears in ~2s. Default timeout 30s.
function Add-TeamsLinkToAppointment {
    [CmdletBinding()] param(
        [Parameter(Mandatory)] $Appointment,
        [int] $TimeoutSeconds = 30,
        [int] $PollIntervalSeconds = 2
    )

    if ($null -eq $Appointment) { throw "Appointment is null" }

    $insp = $null
    try {
        $insp = $Appointment.GetInspector
        if ($null -eq $insp) { throw "GetInspector returned null" }
        # $false = non-modal so we can poll the underlying item
        $insp.Display($false)
    } catch {
        Write-Warning ("Add-TeamsLinkToAppointment: Display failed: {0}" -f $_.Exception.Message)
        return $false
    }

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $found = $false
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds $PollIntervalSeconds
        try { $Appointment.Save() | Out-Null } catch {}
        if (Test-AppointmentHasTeamsLink -Appointment $Appointment) {
            $found = $true
            break
        }
    }

    # Close the inspector so we leave a clean UI. .Send() would also close
    # it, but the caller may want to inspect/modify before sending.
    try { $insp.Close(1) } catch {}   # 1 = olDiscard (we already saved)

    return $found
}

# --- Deprecated shims (registry path no longer used) ---

function Test-OutlookAlwaysAddOnlineMeeting {
    [CmdletBinding()] param()
    Write-Verbose "Test-OutlookAlwaysAddOnlineMeeting is deprecated; the Outlook profile toggle does not affect COM-created invites. Use Add-TeamsLinkToAppointment."
    return $true
}

function Enable-OutlookAlwaysAddOnlineMeeting {
    [CmdletBinding()] param()
    Write-Warning "Enable-OutlookAlwaysAddOnlineMeeting is deprecated and does nothing. The registry toggle does not attach Teams links to COM-created invites (verified 2026-05-05). Use Add-TeamsLinkToAppointment from your skill instead."
}

function Assert-OutlookAlwaysAddOnlineMeeting {
    [CmdletBinding()] param()
    Write-Verbose "Assert-OutlookAlwaysAddOnlineMeeting is deprecated; no-op."
}
