; =============================================================================
; Remote Desktop Solution Installer
; NSIS 3.x Unicode installer
; =============================================================================

Unicode True

; ---------------------------------------------------------------------------
; Product metadata
; ---------------------------------------------------------------------------
!define PRODUCT_NAME        "Remote Desktop Solution"
!define PRODUCT_VERSION     "1.0.0"
!define PRODUCT_PUBLISHER   "Remote Desktop Solution"
!define PRODUCT_URL         "https://github.com/your-org/remote-desktop-solution"
!define INSTALL_DIR         "$PROGRAMFILES64\RemoteDesktop"
!define UNINSTALL_REG_KEY   "Software\Microsoft\Windows\CurrentVersion\Uninstall\RemoteDesktopSolution"
!define REG_ROOT            "HKLM"

; ---------------------------------------------------------------------------
; MUI2 configuration
; ---------------------------------------------------------------------------
!include "MUI2.nsh"
!include "LogicLib.nsh"
!include "WinVer.nsh"
!include "x64.nsh"
!include "Sections.nsh"
!include "FileFunc.nsh"

; MUI settings
!define MUI_ABORTWARNING
!define MUI_ICON             "resources\installer.ico"
!define MUI_UNICON           "resources\installer.ico"
!define MUI_WELCOMEFINISHPAGE_BITMAP   "resources\welcome.bmp"
!define MUI_UNWELCOMEFINISHPAGE_BITMAP "resources\welcome.bmp"
!define MUI_HEADERIMAGE
!define MUI_HEADERIMAGE_BITMAP         "resources\header.bmp"
!define MUI_HEADERIMAGE_RIGHT

; Welcome page customisation
!define MUI_WELCOMEPAGE_TITLE   "Welcome to the ${PRODUCT_NAME} Setup Wizard"
!define MUI_WELCOMEPAGE_TEXT    "This wizard will install ${PRODUCT_NAME} ${PRODUCT_VERSION} on your computer.$\r$\n$\r$\nThe suite includes:$\r$\n  • Sunshine game-streaming host$\r$\n  • Moonlight Web client$\r$\n  • Tailscale secure networking$\r$\n$\r$\nClick Next to continue."

; Finish page customisation
!define MUI_FINISHPAGE_TITLE    "Installation Complete"
!define MUI_FINISHPAGE_TEXT     "${PRODUCT_NAME} ${PRODUCT_VERSION} has been successfully installed.$\r$\n$\r$\nYou can connect from any browser by navigating to:$\r$\n  https://localhost:8080"
!define MUI_FINISHPAGE_RUN
!define MUI_FINISHPAGE_RUN_TEXT "Launch first-run configuration wizard"
!define MUI_FINISHPAGE_RUN_FUNCTION LaunchWizard
!define MUI_FINISHPAGE_LINK     "Visit ${PRODUCT_URL}"
!define MUI_FINISHPAGE_LINK_LOCATION "${PRODUCT_URL}"

; ---------------------------------------------------------------------------
; Installer pages
; ---------------------------------------------------------------------------
!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_LICENSE "resources\LICENSE.txt"
!insertmacro MUI_PAGE_COMPONENTS
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH

; Uninstaller pages
!insertmacro MUI_UNPAGE_WELCOME
!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES
!insertmacro MUI_UNPAGE_FINISH

; Language (must come after pages)
!insertmacro MUI_LANGUAGE "English"

; ---------------------------------------------------------------------------
; General installer settings
; ---------------------------------------------------------------------------
Name            "${PRODUCT_NAME} ${PRODUCT_VERSION}"
OutFile         "RemoteDesktop-Host-Setup-${PRODUCT_VERSION}.exe"
InstallDir      "${INSTALL_DIR}"
InstallDirRegKey ${REG_ROOT} "${UNINSTALL_REG_KEY}" "InstallLocation"
RequestExecutionLevel admin
ShowInstDetails  show
ShowUnInstDetails show
SetCompressor    /SOLID lzma
SetCompressorDictSize 32

; ---------------------------------------------------------------------------
; Version information embedded in the exe
; ---------------------------------------------------------------------------
VIProductVersion  "1.0.0.0"
VIAddVersionKey "ProductName"      "${PRODUCT_NAME}"
VIAddVersionKey "ProductVersion"   "${PRODUCT_VERSION}"
VIAddVersionKey "CompanyName"      "${PRODUCT_PUBLISHER}"
VIAddVersionKey "FileDescription"  "${PRODUCT_NAME} Installer"
VIAddVersionKey "FileVersion"      "${PRODUCT_VERSION}"
VIAddVersionKey "LegalCopyright"   "© 2024 ${PRODUCT_PUBLISHER}"

; ---------------------------------------------------------------------------
; Macros
; ---------------------------------------------------------------------------

; Check $ERRORLEVEL from an ExecWait call and abort with a message if non-zero
!macro CheckExecError _msg
    ${If} $0 <> 0
        MessageBox MB_OK|MB_ICONSTOP "$\r$\nError: ${_msg}$\r$\nExit code: $0"
        Abort
    ${EndIf}
!macroend

; Remove a directory tree only if it exists
!macro SafeRMDir _path
    ${If} ${FileExists} "${_path}\*.*"
        RMDir /r "${_path}"
    ${EndIf}
!macroend

; ---------------------------------------------------------------------------
; Registry / detection helpers
; ---------------------------------------------------------------------------
!macro DetectVCRedist _found
    ; Check for VS 2015-2022 x64 VC++ Redist
    ReadRegDWORD $1 HKLM "SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64" "Installed"
    ${If} $1 == 1
        StrCpy ${_found} "1"
    ${Else}
        StrCpy ${_found} "0"
    ${EndIf}
!macroend

!macro DetectWebView2 _found
    ReadRegStr $1 HKLM "SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}" "pv"
    ${If} $1 != ""
        StrCpy ${_found} "1"
    ${Else}
        ; also try 64-bit hive
        ReadRegStr $1 HKLM "SOFTWARE\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}" "pv"
        ${If} $1 != ""
            StrCpy ${_found} "1"
        ${Else}
            StrCpy ${_found} "0"
        ${EndIf}
    ${EndIf}
!macroend

; ---------------------------------------------------------------------------
; Section definitions
; ---------------------------------------------------------------------------

; --- Core: Sunshine (required) ---
Section "Sunshine Streaming Host (required)" SecSunshine
    SectionIn RO          ; cannot be deselected
    SetOutPath "$INSTDIR"

    DetailPrint "Installing Sunshine streaming host..."
    File "resources\sunshine-installer.exe"
    ExecWait '"$INSTDIR\sunshine-installer.exe" /S' $0
    !insertmacro CheckExecError "Sunshine installer failed"
    Delete "$INSTDIR\sunshine-installer.exe"
    DetailPrint "Sunshine installed successfully."
SectionEnd

; --- Core: Moonlight Web (required) ---
Section "Moonlight Web Client (required)" SecMoonlightWeb
    SectionIn RO          ; cannot be deselected

    DetailPrint "Installing Moonlight Web server..."
    SetOutPath "$INSTDIR\moonlight-web"
    File "resources\web-server.exe"

    SetOutPath "$INSTDIR\moonlight-web\static"
    File /r "resources\static\*.*"

    DetailPrint "Moonlight Web installed."
SectionEnd

; --- Core: Tailscale (required) ---
Section "Tailscale Secure Networking (required)" SecTailscale
    SectionIn RO          ; cannot be deselected

    DetailPrint "Installing Tailscale..."
    SetOutPath "$INSTDIR"
    File "resources\tailscale.msi"
    ExecWait 'msiexec.exe /i "$INSTDIR\tailscale.msi" /quiet /norestart' $0
    !insertmacro CheckExecError "Tailscale MSI installation failed"
    Delete "$INSTDIR\tailscale.msi"
    DetailPrint "Tailscale installed successfully."
SectionEnd

; --- Optional: coturn / Docker ---
Section /o "coturn TURN Server (Docker, optional)" SecCoturn
    DetailPrint "Installing coturn via Docker Compose..."
    SetOutPath "$INSTDIR\coturn"
    File /r "resources\coturn\*.*"
    DetailPrint "coturn assets copied. Start manually with: docker compose up -d"
SectionEnd

; --- Optional: Virtual Display Driver ---
Section /o "Virtual Display Driver (optional)" SecVirtualDisplay
    DetailPrint "Installing Virtual Display Driver..."
    SetOutPath "$INSTDIR\vdd"
    File /r "resources\vdd\*.*"
    ; Run the device installer silently
    ExecWait '"$INSTDIR\vdd\devcon.exe" install "$INSTDIR\vdd\usbmmidd.inf" root\usbmmid' $0
    ${If} $0 <> 0
        MessageBox MB_OK|MB_ICONEXCLAMATION "Virtual Display Driver installation returned exit code $0.$\r$\nYou may need to install it manually."
    ${Else}
        DetailPrint "Virtual Display Driver installed."
    ${EndIf}
SectionEnd

; ---------------------------------------------------------------------------
; Section descriptions shown in the components page
; ---------------------------------------------------------------------------
!insertmacro MUI_FUNCTION_DESCRIPTION_BEGIN
    !insertmacro MUI_DESCRIPTION_TEXT ${SecSunshine}       "Sunshine is the open-source game-streaming host. Required for all streaming functionality."
    !insertmacro MUI_DESCRIPTION_TEXT ${SecMoonlightWeb}   "Moonlight Web provides a browser-based client UI served over HTTPS on port 8080."
    !insertmacro MUI_DESCRIPTION_TEXT ${SecTailscale}      "Tailscale creates a secure peer-to-peer VPN so you can access your desktop from anywhere."
    !insertmacro MUI_DESCRIPTION_TEXT ${SecCoturn}         "Installs coturn Docker Compose files for TURN relay when direct connections are unavailable."
    !insertmacro MUI_DESCRIPTION_TEXT ${SecVirtualDisplay} "Installs a virtual display driver so you can stream even when no physical monitor is connected."
!insertmacro MUI_FUNCTION_DESCRIPTION_END

; ---------------------------------------------------------------------------
; Main installation section (runs after component sections)
; ---------------------------------------------------------------------------
Section "-Core Installation" SecCore
    SetOutPath "$INSTDIR"

    ; --- Create directory structure ---
    CreateDirectory "$INSTDIR"
    CreateDirectory "$INSTDIR\config"
    CreateDirectory "$INSTDIR\certs"
    CreateDirectory "$INSTDIR\logs"
    CreateDirectory "$INSTDIR\wizard"
    CreateDirectory "$INSTDIR\scripts"

    ; --- Copy config templates ---
    DetailPrint "Copying configuration templates..."
    SetOutPath "$INSTDIR\config"
    File /r "resources\config\*.*"

    ; --- Copy scripts ---
    SetOutPath "$INSTDIR\scripts"
    File "scripts\install-services.ps1"
    File "scripts\configure-firewall.ps1"
    File "scripts\generate-certs.ps1"
    File "scripts\uninstall-firewall.ps1"
    File "scripts\detect-gpu.ps1"

    ; --- Copy wizard ---
    ${If} ${FileExists} "resources\wizard\wizard.exe"
        SetOutPath "$INSTDIR\wizard"
        File /r "resources\wizard\*.*"
    ${EndIf}

    ; --- Visual C++ Redistributable ---
    DetailPrint "Checking Visual C++ Redistributable..."
    !insertmacro DetectVCRedist $R0
    ${If} $R0 == "0"
        DetailPrint "Installing Visual C++ Redistributable..."
        SetOutPath "$INSTDIR"
        File "resources\vc_redist.x64.exe"
        ExecWait '"$INSTDIR\vc_redist.x64.exe" /install /quiet /norestart' $0
        !insertmacro CheckExecError "Visual C++ Redistributable installation failed"
        Delete "$INSTDIR\vc_redist.x64.exe"
        DetailPrint "Visual C++ Redistributable installed."
    ${Else}
        DetailPrint "Visual C++ Redistributable already present — skipping."
    ${EndIf}

    ; --- WebView2 Runtime ---
    DetailPrint "Checking WebView2 Runtime..."
    !insertmacro DetectWebView2 $R1
    ${If} $R1 == "0"
        DetailPrint "Installing WebView2 Runtime..."
        SetOutPath "$INSTDIR"
        File "resources\MicrosoftEdgeWebview2Setup.exe"
        ExecWait '"$INSTDIR\MicrosoftEdgeWebview2Setup.exe" /silent /install' $0
        !insertmacro CheckExecError "WebView2 Runtime installation failed"
        Delete "$INSTDIR\MicrosoftEdgeWebview2Setup.exe"
        DetailPrint "WebView2 Runtime installed."
    ${Else}
        DetailPrint "WebView2 Runtime already present — skipping."
    ${EndIf}

    ; --- Register services ---
    DetailPrint "Registering Windows services..."
    nsExec::ExecToLog 'powershell.exe -NonInteractive -ExecutionPolicy Bypass -File "$INSTDIR\scripts\install-services.ps1" -InstDir "$INSTDIR"'
    Pop $0
    !insertmacro CheckExecError "Service installation failed"

    ; --- Configure firewall ---
    DetailPrint "Configuring Windows Firewall rules..."
    nsExec::ExecToLog 'powershell.exe -NonInteractive -ExecutionPolicy Bypass -File "$INSTDIR\scripts\configure-firewall.ps1" -InstDir "$INSTDIR"'
    Pop $0
    !insertmacro CheckExecError "Firewall configuration failed"

    ; --- Generate TLS certificates ---
    DetailPrint "Generating self-signed TLS certificates..."
    nsExec::ExecToLog 'powershell.exe -NonInteractive -ExecutionPolicy Bypass -File "$INSTDIR\scripts\generate-certs.ps1" -InstDir "$INSTDIR"'
    Pop $0
    !insertmacro CheckExecError "Certificate generation failed"

    ; --- GPU detection ---
    DetailPrint "Detecting GPU capabilities..."
    nsExec::ExecToLog 'powershell.exe -NonInteractive -ExecutionPolicy Bypass -File "$INSTDIR\scripts\detect-gpu.ps1" -InstDir "$INSTDIR"'
    Pop $0
    ; GPU detection failure is non-fatal — warn but continue
    ${If} $0 <> 0
        DetailPrint "WARNING: GPU detection returned exit code $0. Default encoding settings will be used."
    ${EndIf}

    ; --- Start Menu shortcuts ---
    DetailPrint "Creating shortcuts..."
    CreateDirectory "$SMPROGRAMS\${PRODUCT_NAME}"
    CreateShortcut "$SMPROGRAMS\${PRODUCT_NAME}\${PRODUCT_NAME}.lnk" \
        "$INSTDIR\moonlight-web\web-server.exe" "" \
        "$INSTDIR\moonlight-web\web-server.exe" 0
    CreateShortcut "$SMPROGRAMS\${PRODUCT_NAME}\Uninstall ${PRODUCT_NAME}.lnk" \
        "$INSTDIR\uninstall.exe" "" \
        "$INSTDIR\uninstall.exe" 0
    CreateShortcut "$SMPROGRAMS\${PRODUCT_NAME}\Open Web Client.lnk" \
        "https://localhost:8080" "" "" 0

    ; --- Desktop shortcut ---
    CreateShortcut "$DESKTOP\${PRODUCT_NAME}.lnk" \
        "$INSTDIR\moonlight-web\web-server.exe" "" \
        "$INSTDIR\moonlight-web\web-server.exe" 0

    ; --- Write uninstaller ---
    DetailPrint "Writing uninstaller..."
    WriteUninstaller "$INSTDIR\uninstall.exe"

    ; --- Add/Remove Programs registry ---
    DetailPrint "Writing registry entries..."
    ${GetSize} "$INSTDIR" "/S=0K" $R2 $R3 $R4
    IntFmt $R2 "0x%08X" $R2

    WriteRegStr   ${REG_ROOT} "${UNINSTALL_REG_KEY}" "DisplayName"          "${PRODUCT_NAME}"
    WriteRegStr   ${REG_ROOT} "${UNINSTALL_REG_KEY}" "DisplayVersion"       "${PRODUCT_VERSION}"
    WriteRegStr   ${REG_ROOT} "${UNINSTALL_REG_KEY}" "Publisher"            "${PRODUCT_PUBLISHER}"
    WriteRegStr   ${REG_ROOT} "${UNINSTALL_REG_KEY}" "URLInfoAbout"         "${PRODUCT_URL}"
    WriteRegStr   ${REG_ROOT} "${UNINSTALL_REG_KEY}" "InstallLocation"      "$INSTDIR"
    WriteRegStr   ${REG_ROOT} "${UNINSTALL_REG_KEY}" "UninstallString"      '"$INSTDIR\uninstall.exe"'
    WriteRegStr   ${REG_ROOT} "${UNINSTALL_REG_KEY}" "QuietUninstallString" '"$INSTDIR\uninstall.exe" /S'
    WriteRegStr   ${REG_ROOT} "${UNINSTALL_REG_KEY}" "DisplayIcon"          '"$INSTDIR\moonlight-web\web-server.exe"'
    WriteRegDWORD ${REG_ROOT} "${UNINSTALL_REG_KEY}" "EstimatedSize"        $R2
    WriteRegDWORD ${REG_ROOT} "${UNINSTALL_REG_KEY}" "NoModify"             1
    WriteRegDWORD ${REG_ROOT} "${UNINSTALL_REG_KEY}" "NoRepair"             1

    DetailPrint "Installation complete."
SectionEnd

; ---------------------------------------------------------------------------
; Finish page callback — launch the wizard
; ---------------------------------------------------------------------------
Function LaunchWizard
    ${If} ${FileExists} "$INSTDIR\wizard\wizard.exe"
        Exec '"$INSTDIR\wizard\wizard.exe"'
    ${Else}
        ; Fallback: open the web UI
        ExecShell "open" "https://localhost:8080"
    ${EndIf}
FunctionEnd

; ---------------------------------------------------------------------------
; Installer init — OS / architecture checks
; ---------------------------------------------------------------------------
Function .onInit
    ; Require Windows 10 or later
    ${IfNot} ${AtLeastWin10}
        MessageBox MB_OK|MB_ICONSTOP "This installer requires Windows 10 or later."
        Abort
    ${EndIf}

    ; Require 64-bit Windows
    ${IfNot} ${RunningX64}
        MessageBox MB_OK|MB_ICONSTOP "This installer requires a 64-bit version of Windows."
        Abort
    ${EndIf}

    ; Prevent multiple simultaneous installs
    System::Call 'kernel32::CreateMutex(p 0, i 1, t "RemoteDesktopSolutionSetupMutex") p .r1 ?e'
    Pop $0
    ${If} $0 = 183  ; ERROR_ALREADY_EXISTS
        MessageBox MB_OK|MB_ICONSTOP "The installer is already running."
        Abort
    ${EndIf}
FunctionEnd

; ---------------------------------------------------------------------------
; Uninstall section
; ---------------------------------------------------------------------------
Section "Uninstall"
    ; --- Stop and remove services ---
    DetailPrint "Stopping services..."

    nsExec::ExecToLog 'sc.exe stop MoonlightWebServer'
    Pop $0
    nsExec::ExecToLog 'sc.exe delete MoonlightWebServer'
    Pop $0

    nsExec::ExecToLog 'sc.exe stop SunshineService'
    Pop $0

    ; Remove firewall rules
    DetailPrint "Removing firewall rules..."
    nsExec::ExecToLog 'powershell.exe -NonInteractive -ExecutionPolicy Bypass -File "$INSTDIR\scripts\uninstall-firewall.ps1"'
    Pop $0
    ${If} $0 <> 0
        DetailPrint "WARNING: Firewall rule removal returned exit code $0."
    ${EndIf}

    ; --- Optionally remove Tailscale ---
    MessageBox MB_YESNO|MB_ICONQUESTION "Do you want to uninstall Tailscale as well?" IDNO SkipTailscaleRemoval
        DetailPrint "Uninstalling Tailscale..."
        ; Find Tailscale uninstall key
        ReadRegStr $0 HKLM "SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Tailscale" "UninstallString"
        ${If} $0 != ""
            ExecWait '"$0" /quiet /norestart' $1
            ${If} $1 <> 0
                DetailPrint "WARNING: Tailscale uninstall returned exit code $1."
            ${EndIf}
        ${Else}
            DetailPrint "Tailscale uninstall key not found — skipping."
        ${EndIf}
    SkipTailscaleRemoval:

    ; --- Delete files ---
    DetailPrint "Removing installation directory..."
    RMDir /r "$INSTDIR\moonlight-web"
    RMDir /r "$INSTDIR\config"
    RMDir /r "$INSTDIR\certs"
    RMDir /r "$INSTDIR\logs"
    RMDir /r "$INSTDIR\scripts"
    RMDir /r "$INSTDIR\wizard"
    RMDir /r "$INSTDIR\coturn"
    RMDir /r "$INSTDIR\vdd"
    Delete "$INSTDIR\uninstall.exe"
    RMDir "$INSTDIR"

    ; --- Remove shortcuts ---
    Delete "$SMPROGRAMS\${PRODUCT_NAME}\${PRODUCT_NAME}.lnk"
    Delete "$SMPROGRAMS\${PRODUCT_NAME}\Uninstall ${PRODUCT_NAME}.lnk"
    Delete "$SMPROGRAMS\${PRODUCT_NAME}\Open Web Client.lnk"
    RMDir  "$SMPROGRAMS\${PRODUCT_NAME}"
    Delete "$DESKTOP\${PRODUCT_NAME}.lnk"

    ; --- Remove registry ---
    DetailPrint "Removing registry entries..."
    DeleteRegKey ${REG_ROOT} "${UNINSTALL_REG_KEY}"

    DetailPrint "Uninstallation complete."
SectionEnd

; ---------------------------------------------------------------------------
; Uninstaller init
; ---------------------------------------------------------------------------
Function un.onInit
    MessageBox MB_ICONQUESTION|MB_YESNO|MB_DEFBUTTON2 \
        "Are you sure you want to uninstall ${PRODUCT_NAME}?" \
        IDYES +2
    Abort
FunctionEnd
