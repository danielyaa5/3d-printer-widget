-- Camera UI verification, with explicit switch/configuration actions on request.
-- Run in the same logged-in user session as the installed app. No print-control
-- buttons, credentials, addresses, filenames, or camera frames are read or logged.
-- Usage: osascript scripts/camera-ui.applescript BUNDLE inspect
--        osascript scripts/camera-ui.applescript BUNDLE live-on PRINTER_INDEX
-- Actions: inspect, live-on/off, snapshots-on/off, open-menu, close-menu,
-- open-connection, set-camera-url, save-connection, open-camera-setup,
-- setup-bridge, setup-url, setup-test, setup-save, setup-cancel.
on run args
 if (count args) < 2 then error "Pass a bundle identifier and camera action."
 set bundleID to item 1 of args
 set requestedAction to item 2 of args
 if requestedAction is not in {"inspect", "live-on", "live-off", "snapshots-on", "snapshots-off", "open-menu", "close-menu", "open-connection", "set-camera-url", "save-connection", "open-camera-setup", "setup-bridge", "setup-url", "setup-test", "setup-save", "setup-cancel", "scroll-top", "scroll-bottom", "close-window"} then error "Unsupported action."
 tell application "System Events"
  set matches to application processes whose bundle identifier is bundleID
  if (count matches) is not 1 then error "Expected one running app with the supplied bundle identifier."
  set targetProcess to item 1 of matches
  if requestedAction is "open-menu" then
   tell targetProcess
    if (count menu bars) < 2 then error "App status menu is unavailable."
    if (count menu bar items of menu bar 2) is not 1 then error "Expected one app status item."
    set targetItem to menu bar item 1 of menu bar 2
    if role of targetItem is not "AXMenuBarItem" then error "Expected an app status item."
    set itemPosition to position of targetItem
    set itemSize to size of targetItem
    if item 1 of itemSize < 1 or item 2 of itemSize < 1 then error "Status item is not visible."
    click at {(item 1 of itemPosition) + (item 1 of itemSize) / 2, (item 2 of itemPosition) + (item 2 of itemSize) / 2}
   end tell
   return "menu-open-requested"
  end if
  if requestedAction is "close-menu" then
   tell targetProcess to key code 53
   return "menu-close-requested"
  end if
  if (count windows of targetProcess) < 1 then error "No visible app window."
  set targetWindow to window 1 of targetProcess
  set elements to entire contents of targetWindow
  if requestedAction is in {"scroll-top", "scroll-bottom", "close-window"} then
   repeat with e in elements
    try
     if requestedAction is "close-window" then
      if role of e is "AXButton" and value of attribute "AXSubrole" of e is "AXCloseButton" then
       perform action "AXPress" of e
       return "camera-window-closed"
      end if
     else if role of e is "AXScrollBar" then
      set frontmost of targetProcess to true
      set fraction to 0
      if requestedAction is "scroll-bottom" then set fraction to 1
      set value of e to fraction
      return "camera-window-scroll-requested"
     end if
    end try
   end repeat
   error "Camera window control unavailable."
  end if
  if requestedAction starts with "setup-" then
   if requestedAction is "setup-cancel" then
    tell targetProcess to key code 53
    return "camera-setup-cancel-requested"
   end if
   set desiredID to "camera-setup-" & text 7 thru -1 of requestedAction
   if requestedAction is "setup-url" and (count args) is not 3 then error "Pass a camera URL."
   repeat with e in elements
    try
     if requestedAction is "setup-bridge" and role of e is "AXRadioButton" then
      if value of attribute "AXDescription" of e is "Bridge or custom URL" then
       perform action "AXPress" of e
       return "camera-setup-bridge-selected"
      end if
     end if
     if role of e is not in {"AXButton", "AXTextField"} then error "Skip non-control."
     if value of attribute "AXIdentifier" of e is desiredID then
      if requestedAction is "setup-url" then
       set frontmost of targetProcess to true
       set value of attribute "AXFocused" of e to true
       tell targetProcess
        keystroke "a" using command down
        keystroke (item 3 of args)
        key code 48
       end tell
       return "camera-setup-address-set"
      end if
      if enabled of e is not true then error "Camera setup control is disabled."
      if name of every action of e does not contain "AXPress" then error "Camera setup control is not actionable."
      perform action "AXPress" of e
      return "camera-setup-action-requested"
     end if
    end try
   end repeat
   error "Camera setup control unavailable."
  end if
  if requestedAction is "open-camera-setup" then
   if (count args) is not 3 then error "Pass a printer ordinal."
   set setupControls to {}
   repeat with e in elements
    try
     if role of e is not "AXButton" then error "Skip non-button."
     if (value of attribute "AXIdentifier" of e as text) starts with "camera-setup-" and role of e is "AXButton" then set end of setupControls to contents of e
    end try
   end repeat
   set ordinal to item 3 of args as integer
   if ordinal < 1 or ordinal > (count setupControls) then error "Camera setup unavailable."
   set targetButton to item ordinal of setupControls
   if name of every action of targetButton does not contain "AXPress" then error "Camera setup is not actionable."
   perform action "AXPress" of targetButton
   return "camera-setup-open-requested"
  end if
  set optionControls to {}
  set liveControls to {}
  set snapshotControls to {}
  set liveLabels to 0
  set snapshotLabels to 0
  set unavailableLabels to 0
  repeat with e in elements
   try
    if role of e is not in {"AXButton", "AXMenuButton", "AXCheckBox", "AXSwitch"} then error "Skip non-control."
    set ident to value of attribute "AXIdentifier" of e
    if ident is "ellipsis" then set end of optionControls to contents of e
    if ident starts with "camera-toggle-" then set end of liveControls to contents of e
    if ident starts with "widget-camera-toggle-" then set end of snapshotControls to contents of e
   end try
   if requestedAction is "inspect" then
   try
    if role of e is "AXStaticText" then
     set labelText to value of e as text
     if labelText contains "Live camera" then set liveLabels to liveLabels + 1
     if labelText contains "Snapshot captured" then set snapshotLabels to snapshotLabels + 1
     if labelText contains "No camera found" or labelText contains "Camera disconnected" or labelText contains "Camera unavailable" or labelText contains "Snapshot unavailable" then set unavailableLabels to unavailableLabels + 1
    end if
   end try
   end if
  end repeat
  if requestedAction is "open-connection" then
   if (count args) is not 3 then error "Pass a printer ordinal."
   set ordinal to item 3 of args as integer
   if ordinal < 1 or ordinal > (count optionControls) then error "Connection options unavailable."
   set targetOptions to item ordinal of optionControls
   if name of every action of targetOptions does not contain "AXPress" then error "Options not actionable."
   perform action "AXPress" of targetOptions
   return "connection-menu-opened"
  end if
  if requestedAction is "set-camera-url" then
   if (count args) is not 3 then error "Pass a camera URL."
   set targetFields to {}
   repeat with e in elements
    try
     if value of attribute "AXIdentifier" of e is "camera-stream-address" then set end of targetFields to contents of e
    end try
   end repeat
   if (count targetFields) is not 1 then error "Camera address field unavailable."
   set value of item 1 of targetFields to item 3 of args
   return "camera-address-set"
  end if
  if requestedAction is "save-connection" then
   set connectButtons to {}
   repeat with e in elements
    try
     if value of attribute "AXIdentifier" of e is "connect-printer" then set end of connectButtons to contents of e
    end try
   end repeat
   if (count connectButtons) is not 1 then error "Connection save button unavailable."
   set targetButton to item 1 of connectButtons
   if enabled of targetButton is not true then error "Connection is still checking."
   if name of every action of targetButton does not contain "AXPress" then error "Connection save is not actionable."
   perform action "AXPress" of targetButton
   return "connection-save-requested"
  end if
  if requestedAction is not "inspect" then
   if (count args) is not 3 then error "Pass the printer ordinal from inspect."
   set ordinal to item 3 of args as integer
   if requestedAction starts with "live-" then
    set controls to liveControls
   else
    set controls to snapshotControls
   end if
   if ordinal < 1 or ordinal > (count controls) then error "Printer ordinal is out of range."
   set targetSwitch to item ordinal of controls
   set controlRole to role of targetSwitch
   if controlRole is not in {"AXCheckBox", "AXSwitch"} then error "Expected a camera switch."
   set desired to 0
   if requestedAction ends with "-on" then set desired to 1
   set previous to value of attribute "AXValue" of targetSwitch as integer
   if previous is not desired then
    if name of every action of targetSwitch does not contain "AXPress" then error "Camera switch is not actionable."
    perform action "AXPress" of targetSwitch
   end if
   return "camera-switch-requested,previous=" & previous & ",desired=" & desired
  end if
  set output to "camera-ui,live-labels=" & liveLabels & ",snapshot-labels=" & snapshotLabels & ",unavailable-labels=" & unavailableLabels
  repeat with ordinal from 1 to count liveControls
   set flag to value of attribute "AXValue" of item ordinal of liveControls as integer
   set output to output & ";live," & ordinal & "," & flag
  end repeat
  repeat with ordinal from 1 to count snapshotControls
   set flag to value of attribute "AXValue" of item ordinal of snapshotControls as integer
   set output to output & ";snapshots," & ordinal & "," & flag
  end repeat
  return output
 end tell
end run
