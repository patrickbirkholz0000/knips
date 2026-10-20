; Knips: Ergaenzungen zum NSIS-Installer von Tauri (tauri.conf.json -> bundle.windows.nsis.installerHooks).
; (Nur ASCII in dieser Datei: NSIS liest .nsh ohne BOM in der Codepage des Systems.)
;
; Deinstallieren (nicht beim Aktualisieren, /UPDATE):
; - Druck-Taste immer an Windows zurueckgeben, wenn Knips sie uebernommen hat. Knips vermerkt das in
;   HKCU\Software\Knips (PrintScreenKeyTaken = 1, PrintScreenKeyOriginal = Wert davor; fehlt er, gab
;   es keinen) - siehe set_snipping_key in crates/platform/src/win/hotkeys.rs.
; - Mit "App-Daten loeschen" zusaetzlich zu dem, was Tauri entfernt ($APPDATA\de.birkgroup.knips und
;   $LOCALAPPDATA\de.birkgroup.knips: Originale, Einstellungen, WebView2, Logs): die Ablageorte bis
;   Version 1.0.0 ($LOCALAPPDATA\Knips\items, $APPDATA\Knips) und die Zwischendateien in $TEMP\Knips.
;   Die Bilder im Ablageordner (Bilder\Knips) bleiben - sie gehoeren dem Nutzer.
;
; Still deinstallieren kennt kein Haekchen: "uninstall.exe /S /DELETEAPPDATA" setzt es.

!macro NSIS_HOOK_PREUNINSTALL
  ClearErrors
  ${GetOptions} $CMDLINE "/DELETEAPPDATA" $R9
  ${IfNot} ${Errors}
    StrCpy $DeleteAppDataCheckboxState 1
  ${EndIf}
  ClearErrors
!macroend

!macro NSIS_HOOK_POSTUNINSTALL
  ${If} $UpdateMode <> 1
    ClearErrors
    ReadRegDWORD $R0 HKCU "Software\Knips" "PrintScreenKeyTaken"
    ${IfNot} ${Errors}
    ${AndIf} $R0 = 1
      ClearErrors
      ReadRegDWORD $R1 HKCU "Software\Knips" "PrintScreenKeyOriginal"
      ${If} ${Errors}
        DeleteRegValue HKCU "Control Panel\Keyboard" "PrintScreenKeyForSnippingEnabled"
      ${Else}
        WriteRegDWORD HKCU "Control Panel\Keyboard" "PrintScreenKeyForSnippingEnabled" $R1
      ${EndIf}
      ; WM_SETTINGCHANGE an alle Fenster: Der Explorer liest die Einstellung neu.
      SendMessage 0xFFFF 0x001A 0 "STR:Control Panel\Keyboard" /TIMEOUT=1000
    ${EndIf}
    ClearErrors
    DeleteRegKey HKCU "Software\Knips"
  ${EndIf}

  ${If} $DeleteAppDataCheckboxState = 1
  ${AndIf} $UpdateMode <> 1
    SetShellVarContext current
    RMDir /r "$LOCALAPPDATA\Knips\items"
    RMDir "$LOCALAPPDATA\Knips"
    RMDir /r "$APPDATA\Knips"
    RMDir /r "$TEMP\Knips"
  ${EndIf}
!macroend
