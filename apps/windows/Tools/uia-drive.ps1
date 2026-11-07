# The in-session driver for the find, tabs, All and Explore stages: it starts the production app with a private
# library, drives it through UI Automation (a scheduled task is the only context that can hold the foreground), and
# writes one result object. The stage script outside asserts on that object; this file never decides a pass.
#
# **Targeted FindFirst only.** WinUI's provider wedges its bulk FindAll and its sibling walker once a list repaints
# (E_UNEXPECTED / timeout), so every lookup names the one element it wants: a ListItem, a TabItem by header, a control
# by AutomationId. The stages name results whose rows are unique, so one targeted element is enough evidence.
[CmdletBinding()]
param([Parameter(Mandatory)][string]$ConfigPath)

$ErrorActionPreference = 'Stop'
$log = Join-Path (Split-Path -Parent $ConfigPath) 'driver.log'
'start' | Add-Content -LiteralPath $log
$config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
$env:XDICT_LIBRARY = $config.library
$mode = $config.mode
$launchId = 'uia-drive-' + [Guid]::NewGuid().ToString('N')
$quit = Join-Path $env:LOCALAPPDATA ('XDict\launch\' + $launchId + '.quit')
$app = $null
$result = [ordered]@{ mode = $mode; window = $false; error = '' }

try {
    'launching' | Add-Content -LiteralPath $log
    $app = Start-Process -FilePath $config.exe -ArgumentList ('--launch-id ' + $launchId) -PassThru
    ('launched ' + $app.Id) | Add-Content -LiteralPath $log

    Add-Type -AssemblyName UIAutomationClient
    Add-Type -AssemblyName UIAutomationTypes
    Add-Type -AssemblyName System.Windows.Forms
    . (Join-Path $PSScriptRoot 'uia-common.ps1')

    $root = [System.Windows.Automation.AutomationElement]::RootElement
    $byId = {
        param($parent, $id)
        if ($null -eq $parent) { return $null }
        $condition = New-Object System.Windows.Automation.PropertyCondition(
            [System.Windows.Automation.AutomationElement]::AutomationIdProperty, $id)
        # A provider exception is not an absence: returning $null made "the Find bar closed" true whenever the tree
        # stopped answering. Retried, then thrown, so a broken lookup fails the stage instead of passing it.
        for ($attempt = 0; $attempt -lt 6; $attempt++) {
            try { return $parent.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $condition) }
            catch {
                ('findfirst retry (byId ' + $id + '): ' + $_.Exception.Message) | Add-Content -LiteralPath $log
                Start-Sleep -Milliseconds 500
            }
        }
        throw ('the UIA lookup for ' + $id + ' failed')
    }
    # SendKeys goes to whatever holds the foreground: after a focus attempt, the focused element's process is checked
    # before any key is sent, so a keystroke can never reach another application.
    $holdsFocus = {
        param($processId)
        try {
            $focused = [System.Windows.Automation.AutomationElement]::FocusedElement
            return $null -ne $focused -and $focused.Current.ProcessId -eq $processId
        }
        catch { return $false }
    }
    $findOne = {
        param($parent, $scope, $condition)
        for ($attempt = 0; $attempt -lt 6; $attempt++) {
            try {
                $found = $parent.FindFirst($scope, $condition)
                if ($null -ne $found) { return $found }
            }
            catch {
                ('findfirst retry: ' + $_.Exception.Message) | Add-Content -LiteralPath $log
            }
            Start-Sleep -Milliseconds 500
        }
        return $null
    }
    $setValue = {
        param($element, $text)
        if ($null -eq $element) { throw ('no element to set to ' + $text) }
        $element.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).SetValue($text)
    }
    $search = {
        param($window, $text)
        $box = & $byId $window 'SearchBox'
        if ($null -eq $box) { throw 'the search box is not in the tree' }
        $editCondition = New-Object System.Windows.Automation.PropertyCondition(
            [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
            [System.Windows.Automation.ControlType]::Edit)
        $edit = $box.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $editCondition)
        $target = $box
        if ($edit) { $target = $edit }
        & $setValue $target $text
        try { $target.SetFocus() } catch { }
        Start-Sleep -Milliseconds 300
        if (-not (& $holdsFocus $app.Id)) { throw 'the search box did not take the foreground; no key was sent' }
        [System.Windows.Forms.SendKeys]::SendWait('{ENTER}')
        Start-Sleep -Seconds 4
    }
    $listItem = {
        param($list)
        $condition = New-Object System.Windows.Automation.PropertyCondition(
            [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
            [System.Windows.Automation.ControlType]::ListItem)
        $item = & $findOne $list ([System.Windows.Automation.TreeScope]::Children) $condition
        if ($null -eq $item) {
            $item = & $findOne $list ([System.Windows.Automation.TreeScope]::Children) `
                ([System.Windows.Automation.Condition]::TrueCondition)
        }
        return $item
    }
    $openFirst = {
        param($window, $list)
        if ($null -eq $list) { $list = & $byId $window 'Results' }
        if ($null -eq $list) { throw 'the result list is not in the tree' }
        $chosen = & $listItem $list
        if ($null -eq $chosen) { throw 'the search painted no row' }
        $chosen.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select()
        try { $list.SetFocus() } catch { }
        Start-Sleep -Milliseconds 250
        if (-not (& $holdsFocus $app.Id)) { throw 'the result list did not take the foreground; no key was sent' }
        [System.Windows.Forms.SendKeys]::SendWait('{ENTER}')
        Start-Sleep -Seconds 4
    }
    $tabNamed = {
        param($window, $name)
        $tabs = & $byId $window 'Tabs'
        if ($null -eq $tabs) { return $null }
        $idCondition = New-Object System.Windows.Automation.PropertyCondition(
            [System.Windows.Automation.AutomationElement]::AutomationIdProperty, ('Tab_' + $name))
        $found = & $findOne $tabs ([System.Windows.Automation.TreeScope]::Descendants) $idCondition
        if ($null -ne $found) { return $found }
        $nameCondition = New-Object System.Windows.Automation.AndCondition(
            (New-Object System.Windows.Automation.PropertyCondition(
                [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
                [System.Windows.Automation.ControlType]::TabItem)),
            (New-Object System.Windows.Automation.PropertyCondition(
                [System.Windows.Automation.AutomationElement]::NameProperty, $name)))
        return & $findOne $tabs ([System.Windows.Automation.TreeScope]::Descendants) $nameCondition
    }

    $window = Find-XDictWindow -Root $root -Seconds 60 -ProcessId $app.Id
    $result.window = ($null -ne $window)
    $result.tabsFound = ($null -ne (& $byId $window 'Tabs'))
    if (-not $window) { throw 'the XDict window was not found through UIA' }
    Start-Sleep -Seconds 2
    $list = & $byId $window 'Results'
    $documentCondition = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
        [System.Windows.Automation.ControlType]::Document)
    # **The entry page is a top-level UIA element, not a descendant of the XAML tab.** WebView2 composes its content
    # in its own window, which UI Automation exposes by the page's URL (the probe of 2026-11-07 found a document
    # titled after another app's page when the search started from the tab). The visible page is the `xdict://`
    # element whose rectangle lies inside the main window and is on screen.
    $number = {
        param($value)
        # A UIA rectangle is infinities when the element has none; formatting one as an int throws.
        if ([double]::IsInfinity($value) -or [double]::IsNaN($value)) { return 'inf' }
        return [string][int]$value
    }
    $pageInventory = {
        @($root.FindAll([System.Windows.Automation.TreeScope]::Children,
                [System.Windows.Automation.Condition]::TrueCondition) |
            Where-Object { $_.Current.Name -like 'xdict://*' } |
            ForEach-Object {
                $r = $_.Current.BoundingRectangle
                $_.Current.Name + '|' + (& $number $r.X) + ',' + (& $number $r.Y) + ',' + (& $number $r.Width) + ',' +
                    (& $number $r.Height) + '|off=' + $_.Current.IsOffscreen + '|pid=' + $_.Current.ProcessId
            })
    }
    $visiblePage = {
        param($window)
        # **Only the selected tab's page is in the tree.** WebView2 exposes its page as a top-level element named by
        # the page's URL; the hidden tab's pane is not enumerated at all (measured 2026-11-07), and the element's
        # rectangle is empty (`inf`), so neither its position nor `IsOffscreen` can choose between tabs — the
        # enumeration itself already has, and the URL names the entry drawn.
        $pages = @($root.FindAll([System.Windows.Automation.TreeScope]::Children,
            [System.Windows.Automation.Condition]::TrueCondition) |
            Where-Object { $_.Current.Name -like 'xdict://*' })
        if ($pages.Count -eq 0) { return $null }
        return $pages[0]
    }
    $pageText = {
        param($page)
        if ($null -eq $page) { return '' }
        $document = & $findOne $page ([System.Windows.Automation.TreeScope]::Descendants) $documentCondition
        if ($null -eq $document) { return '' }
        try {
            return $document.GetCurrentPattern([System.Windows.Automation.TextPattern]::Pattern).DocumentRange.GetText(400)
        }
        catch { return '' }
    }

    switch ($mode) {
        'find' {
            & $search $window 'colour'
            & $openFirst $window $list
            $result.tabColor = ($null -ne (& $tabNamed $window 'color'))
            $tabs = & $byId $window 'Tabs'
            if ($tabs) {
                $itemCondition = New-Object System.Windows.Automation.PropertyCondition(
                    [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
                    [System.Windows.Automation.ControlType]::TabItem)
                $any = & $findOne $tabs ([System.Windows.Automation.TreeScope]::Descendants) $itemCondition
                $result.anyTab = ($null -ne $any)
                if ($any) {
                    $result.tabItemName = $any.Current.Name
                    $result.tabItemId = $any.Current.AutomationId
                }
                try {
                    $selection = $tabs.GetCurrentPattern([System.Windows.Automation.SelectionPattern]::Pattern).GetSelection()
                    if ($selection.Count -gt 0) { $result.selectedTab = $selection[0].Current.Name }
                }
                catch { $result.selectedTab = '' }
            }
            $page = & $visiblePage $window
            $result.findPage = if ($page) { $page.Current.Name } else { '' }
            $result.pages = & $pageInventory
            $result.document = ($null -ne $page)
            $status = & $byId $window 'StatusText'
            $result.entryStatus = $(if ($status) { $status.Current.Name } else { '' })
            try { $window.SetFocus() } catch { }
            Start-Sleep -Milliseconds 300
            if (-not (& $holdsFocus $app.Id)) { throw 'the window did not take the foreground; no key was sent' }
            [System.Windows.Forms.SendKeys]::SendWait('^f')
            Start-Sleep -Milliseconds 700
            $box = & $byId $window 'FindBox'
            $result.findVisible = ($null -ne $box -and -not $box.Current.IsOffscreen)
            if ($box) {
                & $setValue $box 'color'
                try { $box.SetFocus() } catch { }
                if (-not (& $holdsFocus $app.Id)) { throw 'the find box did not take the foreground; no key was sent' }
                [System.Windows.Forms.SendKeys]::SendWait('{ENTER}')
                Start-Sleep -Milliseconds 500
                $value = $box.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
                $result.findValue = $value.Current.Value
                # The field holding the typed text proves nothing about the search. The page's own selection is the
                # evidence: it must hold the term, follow a second one, and ignore one the entry does not hold.
                $document = if ($page) { & $findOne $page ([System.Windows.Automation.TreeScope]::Descendants) $documentCondition } else { $null }
                $result.findSelection = ''
                if ($document) {
                    try {
                        # The page's selection is reported only while the page itself holds focus: the find bar does
                        # after the key, so the document is focused before it is read (it keeps the selection).
                        try { $document.SetFocus() } catch { }
                        Start-Sleep -Milliseconds 250
                        $textPattern = $document.GetCurrentPattern([System.Windows.Automation.TextPattern]::Pattern)
                        $selection = $textPattern.GetSelection()
                        if ($selection.Count -gt 0) {
                            $result.findSelection = $selection[0].GetText(-1)
                            $result.findSelectionRects = @($selection[0].GetBoundingRectangles()) -join ';'
                        }
                        # A second, different term the page holds: the page's own selection follows it. Chromium
                        # reports no bounding rectangles for a selection, so "the next match moved" is read as the
                        # selection changing to the other term — and a term the page does not hold changes nothing.
                        & $setValue $box 'hue'
                        Start-Sleep -Milliseconds 500
                        try { $document.SetFocus() } catch { }
                        Start-Sleep -Milliseconds 250
                        $second = $textPattern.GetSelection()
                        $result.findSecond = if ($second.Count -gt 0) { $second[0].GetText(-1) } else { '' }
                        $result.findFollows = ($result.findSelection -ne '' -and $result.findSecond -ne '' -and
                            $result.findSelection -ne $result.findSecond)
                        & $setValue $box 'zzzz'
                        Start-Sleep -Milliseconds 500
                        try { $document.SetFocus() } catch { }
                        Start-Sleep -Milliseconds 250
                        $third = $textPattern.GetSelection()
                        $result.findAbsent = if ($third.Count -gt 0) { $third[0].GetText(-1) } else { '' }
                    }
                    catch { $result.findSelection = 'unavailable: ' + $_.Exception.Message }
                }
            }
            # Escape is the find bar's own key: the box takes the focus back from the page before it is sent.
            try { $box.SetFocus() } catch { }
            Start-Sleep -Milliseconds 250
            if (-not (& $holdsFocus $app.Id)) { throw 'the find bar lost the foreground; Escape was not sent' }
            [System.Windows.Forms.SendKeys]::SendWait('{ESC}')
            Start-Sleep -Milliseconds 600
            $box = & $byId $window 'FindBox'
            $result.findClosed = ($null -eq $box -or $box.Current.IsOffscreen)
        }
        'tabs' {
            & $search $window 'colour'
            & $openFirst $window $list
            $result.tabColor = ($null -ne (& $tabNamed $window 'color'))
            & $search $window 'hue'
            & $openFirst $window $list
            $result.tabHue = ($null -ne (& $tabNamed $window 'hue'))
            $first = & $tabNamed $window 'color'
            $second = & $tabNamed $window 'hue'
            if ($first) {
                $first.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select()
                Start-Sleep -Milliseconds 700
                $result.firstSelected = $first.GetCurrentPattern(
                    [System.Windows.Automation.SelectionItemPattern]::Pattern).Current.IsSelected
                # The visible entry page, by its own URL and its own words: the tab's document cannot be reached
                # from the tab element, and the header alone says nothing about what the pane drew.
                $colourPage = & $visiblePage $window
                $result.colorPage = if ($colourPage) { $colourPage.Current.Name } else { '' }
                $result.colorText = (& $pageText $colourPage) -replace '\s+', ' '
            }
            if ($second -and $first) {
                $second.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select()
                Start-Sleep -Milliseconds 700
                $huePage = & $visiblePage $window
                $result.huePage = if ($huePage) { $huePage.Current.Name } else { '' }
                # Both tabs are open here: the inventory records that the hidden one's page is not enumerated at
                # all, which is the measurement that makes the visible page the tab's own evidence.
                $result.pages = & $pageInventory
                $result.hueText = (& $pageText $huePage) -replace '\s+', ' '
                $result.switchedPanes = ($result.colorPage -ne '' -and $result.huePage -ne '' -and
                    $result.colorPage -ne $result.huePage)
                # Back to the first: the same page it had, not a blank tab.
                $first.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select()
                Start-Sleep -Milliseconds 700
                $backPage = & $visiblePage $window
                $result.colorPageAfterSwitch = if ($backPage) { $backPage.Current.Name } else { '' }
                $result.colorTextAfterSwitch = (& $pageText $backPage) -replace '\s+', ' '
                $result.stateKept = ($result.colorPage -ne '' -and
                    $result.colorPage -eq $result.colorPageAfterSwitch)
            }
            if ($second) {
                $closeCondition = New-Object System.Windows.Automation.AndCondition(
                    (New-Object System.Windows.Automation.PropertyCondition(
                        [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
                        [System.Windows.Automation.ControlType]::Button)),
                    (New-Object System.Windows.Automation.PropertyCondition(
                        [System.Windows.Automation.AutomationElement]::AutomationIdProperty, 'CloseButton')))
                $close = $second.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $closeCondition)
                if ($close) {
                    $close.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
                    Start-Sleep -Seconds 1
                    $result.closed = $true
                }
                else { $result.closed = $false }
            }
            $result.colorAfterClose = ($null -ne (& $tabNamed $window 'color'))
            $result.hueAfterClose = ($null -ne (& $tabNamed $window 'hue'))
            $closingPage = & $visiblePage $window
            $result.colorPageAfterClose = if ($closingPage) { $closingPage.Current.Name } else { '' }
        }
        'all' {
            & $search $window 'word'
            & $openFirst $window $list
            $result.tabWord = ($null -ne (& $tabNamed $window 'word'))
            $idProperty = [System.Windows.Automation.AutomationElement]::AutomationIdProperty
            $scroll = & $byId $window 'AllScroll'
            if ($scroll) {
                try {
                    $pattern = $scroll.GetCurrentPattern([System.Windows.Automation.ScrollPattern]::Pattern)
                    $pattern.SetScrollPercent([System.Windows.Automation.ScrollPattern]::NoScroll, 100)
                }
                catch { ('scroll failed: ' + $_.Exception.Message) | Add-Content -LiteralPath $log }
            }
            $deadline = (Get-Date).AddSeconds(30)
            $twinA = $null
            $twinB = $null
            while ((Get-Date) -lt $deadline -and ($null -eq $twinA -or $null -eq $twinB)) {
                if ($null -eq $twinA) {
                    $condition = New-Object System.Windows.Automation.PropertyCondition($idProperty, 'Section_Twin A')
                    $twinA = & $findOne $window ([System.Windows.Automation.TreeScope]::Descendants) $condition
                }
                if ($null -eq $twinB) {
                    $condition = New-Object System.Windows.Automation.PropertyCondition($idProperty, 'Section_Twin B')
                    $twinB = & $findOne $window ([System.Windows.Automation.TreeScope]::Descendants) $condition
                }
                if ($null -eq $twinA -or $null -eq $twinB) { Start-Sleep -Seconds 1 }
            }
            $result.twinA = ($null -ne $twinA)
            $result.twinB = ($null -ne $twinB)
            $status = & $byId $window 'StatusText'
            $result.status = $(if ($status) { $status.Current.Name } else { '' })
        }
        'explore' {
            $button = & $byId $window 'ExploreButton'
            if ($null -eq $button) { throw 'the Explore button is not in the tree' }
            $button.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
            # The window's title is localized; its title control's id is not. Find the top-level window holding it.
            $explore = $null
            $deadline = (Get-Date).AddSeconds(30)
            while ($null -eq $explore -and (Get-Date) -lt $deadline) {
                try {
                    $children = $root.FindAll([System.Windows.Automation.TreeScope]::Children,
                        [System.Windows.Automation.Condition]::TrueCondition)
                    foreach ($candidate in $children) {
                        if ($candidate.Current.ProcessId -ne $app.Id) { continue }
                        if (& $byId $candidate 'ExploreTitle') { $explore = $candidate; break }
                    }
                }
                catch { }
                if ($null -eq $explore) { Start-Sleep -Milliseconds 500 }
            }
            $result.exploreWindow = ($null -ne $explore)
            if (-not $explore) { throw 'the Explore window was not found' }
            Start-Sleep -Seconds 1
            $query = & $byId $explore 'ExploreQuery'
            if ($null -eq $query) { throw 'the Explore query is not in the tree' }
            & $setValue $query 'olour'
            $run = & $byId $explore 'ExploreRun'
            if ($null -eq $run) { throw 'the Explore button is not in the tree' }
            $run.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
            Start-Sleep -Seconds 4
            $rows = & $byId $explore 'ExploreResults'
            $first = $null
            if ($rows) { $first = & $listItem $rows }
            $result.rows = @()
            if ($first) { $result.rows = @($first.Current.Name) }
            if ($first) {
                $first.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select()
                Start-Sleep -Milliseconds 400
                $open = & $byId $explore 'ExploreOpen'
                if ($open) { $open.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke() }
                Start-Sleep -Seconds 4
            }
            $result.tabColour = ($null -ne (& $tabNamed $window 'colour'))
            try { $explore.GetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern).Close() } catch { }
        }
        default { throw ('unknown UIA mode ' + $mode) }
    }
}
catch {
    $result.error = $_.Exception.Message
    try { ('ERROR: ' + ($_ | Out-String)) | Add-Content -LiteralPath $log } catch { }
}
finally {
    'finishing' | Add-Content -LiteralPath $log
    $result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $config.result -Encoding UTF8
    Set-Content -LiteralPath $quit -Value '' -Encoding Ascii
    Start-Sleep -Seconds 2
    if ($null -ne $app -and -not $app.HasExited) { Stop-Process -Id $app.Id -Force }
}
