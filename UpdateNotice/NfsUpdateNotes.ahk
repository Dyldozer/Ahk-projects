#Requires AutoHotkey v2.0
#SingleInstance Force

; Test call - remove these two lines when pasting the function into your script.
ShowNfsUpdateNotes()
ExitApp

; Shows the "Notes for NFS Update 1.1" pop-up and blocks until the user closes it.
; logoPath: optional path to an image file. If omitted or missing, a text wordmark is shown instead.
ShowNfsUpdateNotes(logoPath := "") {
    contactInfo := "[ADD CONTACT INFO HERE]"

    BLUE       := "0099D8"
    BLUE_HOVER := "0074A6"
    NAVY       := "003057"
    TEXT       := "333333"
    MUTED      := "63738A"
    DIVIDER    := "DDE3EA"
    WHITE      := "FFFFFF"

    W      := 560
    PAD    := 32
    innerW := W - PAD * 2

    closed    := false
    hoverBtn  := false
    hoverX    := false

    g := Gui("-Caption +AlwaysOnTop +Border", "Notes for NFS Update 1.1")
    g.BackColor := WHITE
    g.MarginX := 0, g.MarginY := 0
    g.SetFont("s10 norm c" TEXT, "Segoe UI")

    ; Header
    if (logoPath != "" && FileExist(logoPath)) {
        g.Add("Picture", "x" PAD " y18 h36 w-1 BackgroundTrans", logoPath)
    } else {
        g.SetFont("s20 bold c" NAVY, "Segoe UI")
        g.Add("Text", "x" PAD " y16 h40 +0x200 BackgroundTrans", "Spectrum")
        g.SetFont("s13 norm c" BLUE, "Segoe UI Symbol")
        g.Add("Text", "x+3 yp h40 +0x200 BackgroundTrans", Chr(0x25BA))
    }

    g.SetFont("s18 norm c" MUTED, "Segoe UI")
    closeBtn := g.Add("Text", "x" (W - 50) " y14 w36 h36 Center +0x200 BackgroundTrans", Chr(0x00D7))
    closeBtn.OnEvent("Click", CloseNotes)

    g.Add("Text", "x0 y68 w" W " h4 Background" BLUE)

    ; Title
    g.SetFont("s9 bold c" BLUE, "Segoe UI")
    g.Add("Text", "x" PAD " y96 w" innerW " BackgroundTrans", "WHAT'S NEW")
    g.SetFont("s18 bold c" NAVY)
    g.Add("Text", "x" PAD " y+2 w" innerW " BackgroundTrans", "Notes for NFS Update 1.1")
    g.SetFont("s10 norm c" MUTED)
    g.Add("Text", "x" PAD " y+6 w" innerW " BackgroundTrans"
        , "This is a major update to how NFS works behind the scenes. Here's what's changed:")

    ; Features
    AddFeature("Faster, more reliable lookups"
        , "NFS now uses direct HTTP requests instead of the old Chrome/Edge screen reader. "
        . "It's much faster and far less error prone.")
    AddFeature("VIP code required once a day"
        , "You'll be asked to enter your VIP code the first time you use NFS each day.")
    AddFeature("Management Area description is automatic"
        , "NFS now gathers the Management Area description for you, so there's no need "
        . "to copy it from ACSR anymore.")

    ; Contact
    g.Add("Text", "x" PAD " y+28 w" innerW " h1 Background" DIVIDER)
    g.SetFont("s9 norm c" MUTED)
    g.Add("Text", "x" PAD " y+14 w" innerW " BackgroundTrans", "Questions or issues? Contact " contactInfo)

    ; Button
    g.SetFont("s11 bold c" WHITE)
    gotIt := g.Add("Text", "x" (W - PAD - 150) " y+22 w150 h44 Center +0x200 Background" BLUE, "Got It")
    gotIt.OnEvent("Click", CloseNotes)
    gotIt.GetPos(, &btnY, , &btnH)

    H := btnY + btnH + PAD
    g.Add("Text", "x0 y" (H - 6) " w" W " h6 Background" NAVY)

    g.OnEvent("Escape", CloseNotes)
    g.OnEvent("Close", CloseNotes)

    fnMove   := OnMouseMove
    fnCursor := OnSetCursor
    fnDown   := OnLButtonDown
    OnMessage(0x200, fnMove)    ; WM_MOUSEMOVE
    OnMessage(0x20, fnCursor)   ; WM_SETCURSOR
    OnMessage(0x201, fnDown)    ; WM_LBUTTONDOWN

    ; Rounded corners on Windows 11 (ignored on older versions)
    try DllCall("dwmapi\DwmSetWindowAttribute", "Ptr", g.Hwnd, "UInt", 33, "Int*", 2, "UInt", 4)

    hwnd := g.Hwnd
    g.Show("w" W " h" H " Center")
    WinWaitClose("ahk_id " hwnd)
    return

    AddFeature(title, body) {
        g.SetFont("s11 bold c" NAVY, "Segoe UI")
        t := g.Add("Text", "x" (PAD + 20) " y+22 w" (innerW - 20) " BackgroundTrans", title)
        g.SetFont("s10 norm c" TEXT)
        b := g.Add("Text", "x" (PAD + 20) " y+4 w" (innerW - 20) " BackgroundTrans", body)
        t.GetPos(, &ty)
        b.GetPos(, &by, , &bh)
        g.Add("Text", "x" PAD " y" ty " w4 h" (by + bh - ty) " Background" BLUE)
    }

    OnMouseMove(wParam, lParam, msg, msgHwnd) {
        if closed
            return
        overBtn := (msgHwnd = gotIt.Hwnd)
        if (overBtn != hoverBtn) {
            hoverBtn := overBtn
            gotIt.Opt("Background" (overBtn ? BLUE_HOVER : BLUE))
            gotIt.Redraw()
        }
        overX := (msgHwnd = closeBtn.Hwnd)
        if (overX != hoverX) {
            hoverX := overX
            closeBtn.SetFont("c" (overX ? NAVY : MUTED))
        }
    }

    OnSetCursor(wParam, lParam, msg, msgHwnd) {
        if closed
            return
        if (wParam = gotIt.Hwnd || wParam = closeBtn.Hwnd) {
            DllCall("SetCursor", "Ptr", DllCall("LoadCursor", "Ptr", 0, "Ptr", 32649, "Ptr"))  ; IDC_HAND
            return true
        }
    }

    ; Lets the borderless window be dragged by clicking anywhere on its background.
    OnLButtonDown(wParam, lParam, msg, msgHwnd) {
        if (!closed && msgHwnd = hwnd)
            PostMessage(0xA1, 2, , , "ahk_id " hwnd)  ; WM_NCLBUTTONDOWN, HTCAPTION
    }

    CloseNotes(*) {
        if closed
            return
        closed := true
        OnMessage(0x200, fnMove, 0)
        OnMessage(0x20, fnCursor, 0)
        OnMessage(0x201, fnDown, 0)
        g.Destroy()
    }
}
