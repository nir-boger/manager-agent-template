#requires -Version 5.1
# Reusable HTML renderer for "investigation"-style emails (Clawpilot palette).
#
# Single source of truth for the look used by the email-investigation skill -
# any other skill that wants to send investigation-flavored mail dot-sources
# this file and calls Build-InvestigationEmailHtml with a structured spec.
#
# Pure: returns an HTML string. No Outlook, no I/O, no signature.
# The CALLER is responsible for:
#   1. Appending the Nirvana signature (via _shared/signature.ps1)
#   2. Sending via Outlook COM (same recipe as the email-team skill)
#   3. Logging to reports/email/YYYY-MM-DD.md
#
# This file is ASCII-only (PS 5.1 .ps1 source-file constraint). All non-ASCII
# glyphs (mdash, middot, arrows, smart quotes, etc.) must go through HTML
# entities (&mdash; &middot; &rarr; &ldquo; &rsquo; etc.) so the source stays
# ASCII while the rendered email still looks good.
#
# Usage:
#   . '<repo>\.copilot\skills\_shared\investigation-email.ps1'
#   $html = Build-InvestigationEmailHtml -Spec $spec
#
# Spec shape (hashtable; all optional unless marked):
#   Title           [string, REQUIRED]  Hero h1
#   Subtitle        [string]            Hero lede (HTML allowed)
#   Eyebrow         [string]            Small caps line above title; default 'Investigation'
#   Chips           [array]             Hero chips: @{ Label; Tone in neutral|good|bad|warn }
#   Tldr            [string]            HTML for the TL;DR card (omit to skip)
#   Stats           [array]             1-4 stat cards: @{ Label; Value; Sublabel; Tone }
#   Sections        [array]             Narrative cards:
#                                         @{ Title; SubtitleHtml?; BodyHtml; Callout? = @{ Tone; Html } }
#   Recommendations [array]             Numbered recommendation cards:
#                                         @{ Priority; Tone; Title; BodyHtml }
#   Joke            [string]            One-liner italicized just before the signature spot
#
# Tone palette: 'neutral' | 'good' | 'bad' | 'warn' | 'accent' | 'muted'

# ---- Palette tokens (Clawpilot-ish, light scheme) ------------------------

$script:InvEmailPalette = @{
    BgPage    = 'transparent'
    Card      = '#ffffff'
    Border    = '#e2e1ec'
    Ink       = '#1f2328'
    Muted     = '#57606a'
    Accent    = '#6e40c9'
    AccentBg  = '#efe7fb'
    Danger    = '#b42318'
    DangerBg  = '#fef0ee'
    Ok        = '#0f7a3c'
    OkBg      = '#e7f6ee'
    Warn      = '#8a5a00'
    WarnBg    = '#fdf3d8'
    # Hero is a plain text header - no background panel and no box at all per Nir's standing preference.
    HeroBg    = 'transparent'
    HeroFg    = '#1f2328'
    HeroLede  = '#57606a'
    HeroLavnd = '#6e40c9'
    FontSans  = "'Segoe UI', Arial, sans-serif"
    FontMono  = "'Cascadia Mono', Consolas, 'Courier New', monospace"
}

# Tone -> (fg, bg) pair for inline elements (chips in light areas, recommendation badges, callouts).
$script:InvEmailToneMap = @{
    neutral = @{ fg = '#57606a'; bg = '#eef1f4' }
    good    = @{ fg = '#0f7a3c'; bg = '#e7f6ee' }
    bad     = @{ fg = '#b42318'; bg = '#fef0ee' }
    warn    = @{ fg = '#8a5a00'; bg = '#fdf3d8' }
    accent  = @{ fg = '#6e40c9'; bg = '#efe7fb' }
    muted   = @{ fg = '#57606a'; bg = '#eef1f4' }
}

# Tone -> (fg, bg) pair for chips inside the dark hero banner.
$script:InvEmailHeroChipMap = @{
    neutral = @{ fg = '#dcd2ff'; bg = '#3a2864' }
    good    = @{ fg = '#b8e6c5'; bg = '#1e3b25' }
    bad     = @{ fg = '#ffd0c5'; bg = '#5c1e1e' }
    warn    = @{ fg = '#ffe6a8'; bg = '#5a4310' }
}

function Get-InvEmailTone {
    [CmdletBinding()]
    param([string] $Tone, [hashtable] $Map = $script:InvEmailToneMap)
    if (-not $Tone) { return $Map['neutral'] }
    $key = $Tone.ToLowerInvariant()
    if ($Map.ContainsKey($key)) { return $Map[$key] }
    return $Map['neutral']
}

function Get-InvEmailPalette { return $script:InvEmailPalette }

# ---- Block builders (each returns an HTML fragment) ----------------------

function Build-InvEmailHero {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [hashtable] $Spec)
    $p = $script:InvEmailPalette
    if (-not $Spec.Title) { throw "Build-InvestigationEmailHtml: Spec.Title is required." }
    $eyebrow = if ($Spec.Eyebrow) { $Spec.Eyebrow } else { 'Investigation' }
    $title   = $Spec.Title
    $sub     = if ($Spec.Subtitle) { $Spec.Subtitle } else { '' }

    $chipsHtml = ''
    if ($Spec.Chips) {
        $parts = @()
        foreach ($c in $Spec.Chips) {
            $tone = Get-InvEmailTone -Tone $c.Tone
            $parts += "<span style=`"display:inline-block;background:$($tone.bg);color:$($tone.fg);font-size:11px;font-weight:600;letter-spacing:0.4px;padding:4px 10px;margin:0 6px 4px 0;`">$($c.Label)</span>"
        }
        $chipsHtml = "<div style=`"margin-top:14px;`">" + ($parts -join '') + "</div>"
    }

    $subHtml = if ($sub) {
        "<div style=`"font-size:14px;color:$($p.HeroLede);line-height:1.55;max-width:720px;`">$sub</div>"
    } else { '' }

    @"
<table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%" style="background:$($p.HeroBg);border-collapse:separate;margin:0 0 16px 0;">
  <tr><td style="padding:2px 0 18px 0;font-family:$($p.FontSans);color:$($p.HeroFg);">
    <div style="font-size:11px;font-weight:600;letter-spacing:2px;text-transform:uppercase;color:$($p.HeroLavnd);margin-bottom:6px;">$eyebrow &middot; Nirvana</div>
    <div style="font-size:22px;font-weight:700;line-height:1.3;color:$($p.HeroFg);margin-bottom:10px;">$title</div>
    $subHtml
    $chipsHtml
  </td></tr>
</table>
"@
}

function Build-InvEmailCardOpen {
    [CmdletBinding()] param([string] $Padding = '20px 22px')
    $p = $script:InvEmailPalette
    @"
<table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%" style="background:$($p.Card);border:1px solid $($p.Border);border-collapse:separate;margin:0 0 16px 0;">
  <tr><td style="padding:$Padding;font-family:$($p.FontSans);color:$($p.Ink);font-size:14px;line-height:1.55;">
"@
}

function Build-InvEmailCardClose { return '</td></tr></table>' }

function Build-InvEmailEyebrow {
    [CmdletBinding()] param([Parameter(Mandatory)] [string] $Text)
    $p = $script:InvEmailPalette
    "<div style=`"font-size:11px;font-weight:700;letter-spacing:1.5px;text-transform:uppercase;color:$($p.Accent);margin-bottom:8px;`">$Text</div>"
}

function Build-InvEmailTldr {
    [CmdletBinding()] param([Parameter(Mandatory)] [string] $Html)
    (Build-InvEmailCardOpen) + (Build-InvEmailEyebrow -Text 'TL;DR') + "<div style=`"font-size:15px;line-height:1.6;`">$Html</div>" + (Build-InvEmailCardClose)
}

function Build-InvEmailStats {
    [CmdletBinding()] param([Parameter(Mandatory)] [array] $Stats)
    if (-not $Stats -or $Stats.Count -eq 0) { return '' }
    $p = $script:InvEmailPalette
    $n = [Math]::Min(4, $Stats.Count)
    $cols = $Stats[0..($n-1)]
    $widthPct = [int](100 / $n)

    $cells = @()
    for ($i = 0; $i -lt $cols.Count; $i++) {
        $card = $cols[$i]
        $tone = Get-InvEmailTone -Tone $card.Tone
        $padLeft  = if ($i -eq 0)          { '0 8px 0 0' } else { '0 8px' }
        $padRight = if ($i -eq $cols.Count - 1) { '0 0 0 8px' } else { '0 8px' }
        $pad      = if ($i -eq 0) { $padLeft } elseif ($i -eq $cols.Count - 1) { $padRight } else { '0 8px' }
        $cells += @"
    <td width="$widthPct%" style="padding:$pad;" valign="top">
      <table cellpadding="0" cellspacing="0" border="0" width="100%" style="background:$($p.Card);border:1px solid $($p.Border);"><tr><td style="padding:16px;font-family:$($p.FontSans);text-align:center;">
        <div style="font-size:11px;color:$($p.Muted);text-transform:uppercase;letter-spacing:1px;margin-bottom:6px;">$($card.Label)</div>
        <div style="font-size:28px;font-weight:700;color:$($tone.fg);">$($card.Value)</div>
        <div style="font-size:12px;color:$($p.Muted);margin-top:4px;">$($card.Sublabel)</div>
      </td></tr></table>
    </td>
"@
    }

    @"
<table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%" style="border-collapse:separate;margin:0 0 16px 0;">
  <tr>
$($cells -join "")
  </tr>
</table>
"@
}

function Build-InvEmailCallout {
    [CmdletBinding()] param(
        [Parameter(Mandatory)] [string] $Html,
        [string] $Tone = 'accent'
    )
    $tone = Get-InvEmailTone -Tone $Tone
    "<div style=`"margin-top:14px;padding:12px 14px;background:$($tone.bg);border-left:3px solid $($tone.fg);font-size:13px;line-height:1.55;`">$Html</div>"
}

function Build-InvEmailSection {
    [CmdletBinding()] param([Parameter(Mandatory)] [hashtable] $Section)
    $p = $script:InvEmailPalette
    if (-not $Section.Title)    { throw "investigation-email: section is missing Title" }
    if (-not $Section.BodyHtml) { throw "investigation-email: section '$($Section.Title)' is missing BodyHtml" }

    $sub = if ($Section.SubtitleHtml) { "<div style=`"font-size:13px;color:$($p.Muted);margin-bottom:14px;`">$($Section.SubtitleHtml)</div>" } else { '' }
    $callout = if ($Section.Callout -and $Section.Callout.Html) { Build-InvEmailCallout -Html $Section.Callout.Html -Tone $Section.Callout.Tone } else { '' }

    (Build-InvEmailCardOpen) `
        + (Build-InvEmailEyebrow -Text $Section.Title) `
        + $sub `
        + "<div>$($Section.BodyHtml)</div>" `
        + $callout `
        + (Build-InvEmailCardClose)
}

function Build-InvEmailRecCard {
    [CmdletBinding()] param(
        [Parameter(Mandatory)] [string] $Number,
        [Parameter(Mandatory)] [hashtable] $Rec
    )
    $p = $script:InvEmailPalette
    if (-not $Rec.Title)    { throw "investigation-email: recommendation is missing Title" }
    if (-not $Rec.BodyHtml) { throw "investigation-email: recommendation '$($Rec.Title)' is missing BodyHtml" }
    $priority = if ($Rec.Priority) { $Rec.Priority } else { '' }
    $tone = Get-InvEmailTone -Tone $Rec.Tone
    $badge = if ($priority) {
        "<span style=`"display:inline-block;background:$($tone.bg);color:$($tone.fg);font-size:10px;font-weight:700;letter-spacing:1px;text-transform:uppercase;padding:3px 8px;margin-right:8px;`">$priority</span>"
    } else { '' }

    @"
<table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%" style="background:$($p.Card);border:1px solid $($p.Border);border-collapse:separate;margin:0 0 10px 0;">
  <tr>
    <td width="56" valign="top" style="padding:18px 0 18px 18px;font-family:$($p.FontSans);">
      <div style="width:40px;height:40px;background:$($p.AccentBg);color:$($p.Accent);font-size:18px;font-weight:700;text-align:center;line-height:40px;font-family:$($p.FontMono);">$Number</div>
    </td>
    <td valign="top" style="padding:16px 20px 16px 14px;font-family:$($p.FontSans);color:$($p.Ink);font-size:13px;line-height:1.6;">
      <div style="margin-bottom:6px;">$badge<strong style="font-size:14px;color:$($p.Ink);">$($Rec.Title)</strong></div>
      <div style="color:$($p.Ink);">$($Rec.BodyHtml)</div>
    </td>
  </tr>
</table>
"@
}

function Build-InvEmailRecommendations {
    [CmdletBinding()] param([Parameter(Mandatory)] [array] $Recs)
    if (-not $Recs -or $Recs.Count -eq 0) { return '' }
    $cards = @()
    for ($i = 0; $i -lt $Recs.Count; $i++) {
        $cards += Build-InvEmailRecCard -Number ($i + 1).ToString() -Rec $Recs[$i]
    }
    (Build-InvEmailCardOpen) `
        + (Build-InvEmailEyebrow -Text 'Recommendations') `
        + ($cards -join '') `
        + (Build-InvEmailCardClose)
}

function Build-InvEmailJoke {
    [CmdletBinding()] param([Parameter(Mandatory)] [string] $Joke)
    $p = $script:InvEmailPalette
    "<p style=`"font-family:$($p.FontSans);font-size:13px;color:$($p.Muted);font-style:italic;margin:18px 4px 6px 4px;`">$Joke</p>"
}

# ---- Top-level entry -----------------------------------------------------

function Build-InvestigationEmailHtml {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [hashtable] $Spec)
    $p = $script:InvEmailPalette

    if (-not $Spec.Title) { throw "Build-InvestigationEmailHtml: Spec.Title is required." }

    $hero  = Build-InvEmailHero -Spec $Spec
    $tldr  = if ($Spec.Tldr)            { Build-InvEmailTldr -Html $Spec.Tldr }              else { '' }
    $stats = if ($Spec.Stats)           { Build-InvEmailStats -Stats $Spec.Stats }           else { '' }

    $sections = ''
    if ($Spec.Sections) {
        foreach ($s in $Spec.Sections) { $sections += Build-InvEmailSection -Section $s }
    }

    $recs = if ($Spec.Recommendations) { Build-InvEmailRecommendations -Recs $Spec.Recommendations } else { '' }
    $joke = if ($Spec.Joke)            { Build-InvEmailJoke -Joke $Spec.Joke }                       else { '' }

    @"
<html><body style="margin:0;padding:0;background:$($p.BgPage);font-family:$($p.FontSans);color:$($p.Ink);">
<table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%" style="background:$($p.BgPage);border-collapse:separate;">
  <tr><td align="center" style="padding:24px 16px;">
    <table role="presentation" cellpadding="0" cellspacing="0" border="0" width="780" style="max-width:780px;border-collapse:separate;">
      <tr><td>
        $hero
        $tldr
        $stats
        $sections
        $recs
        $joke
      </td></tr>
    </table>
  </td></tr>
</table>
</body></html>
"@
}

