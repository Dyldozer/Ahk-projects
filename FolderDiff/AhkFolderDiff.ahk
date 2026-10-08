#Requires AutoHotkey v2.0
#SingleInstance Force
SetWorkingDir A_ScriptDir

; ==============================================================================
;  AHK Folder Diff
;  Compares two folders (e.g. two variants of the same AutoHotkey project) and
;  shows files that exist on only one side plus a detailed, line-by-line and
;  word-by-word view of every changed file.
; ==============================================================================

global APP_TITLE := "AHK Folder Diff"
global INI_FILE := A_ScriptDir "\AhkFolderDiff.ini"
; Upper bound on line edits per file before the precise alignment is abandoned
; (memory use grows with the square of this number).
global MAX_EDIT_DISTANCE := 3000
global STATUS_LIST := ["Error", "Modified", "Binary", "OnlyA", "OnlyB", "Moved", "Equivalent", "Identical"]
global STATUS_ORDER := Map("Error", 0, "Modified", 1, "Binary", 2, "OnlyA", 3, "OnlyB", 4, "Moved", 5, "Equivalent", 6, "Identical", 7)
global STATUS_LABEL := Map("Error", "Read error", "Modified", "Modified", "Binary", "Binary differs"
    , "OnlyA", "Only in A", "OnlyB", "Only in B", "Moved", "Moved / renamed"
    , "Equivalent", "Equivalent", "Identical", "Identical")

global App := {results: [], dirA: "", dirB: "", opts: "", when: "", current: 0, pendingId: 0
    , viewSeq: 0, viewFile: "", html: "", busy: false}
global UI := {}

BuildGui()
OnExit(Cleanup)

; ==============================================================================
;  GUI
; ==============================================================================

BuildGui() {
    g := Gui("+Resize +MinSize980x560", APP_TITLE)
    UI.g := g
    g.SetFont("s9", "Segoe UI")

    g.Add("Text", "x10 y14 w60", "Folder A:")
    UI.edA := g.Add("Edit", "x75 y10 w600 h23")
    UI.btnA := g.Add("Button", "x680 y9 w80 h25", "Browse...")
    UI.btnSwap := g.Add("Button", "x765 y9 w75 h25", "Swap A/B")

    g.Add("Text", "x10 y43 w60", "Folder B:")
    UI.edB := g.Add("Edit", "x75 y39 w600 h23")
    UI.btnB := g.Add("Button", "x680 y38 w80 h25", "Browse...")

    g.Add("Text", "x10 y72", "Include files:")
    UI.edIncl := g.Add("Edit", "x85 y68 w200 h23")
    g.Add("Text", "x295 y72", "Exclude:")
    UI.edExcl := g.Add("Edit", "x345 y68 w260 h23")
    UI.chkRec := g.Add("CheckBox", "x620 y71", "Include subfolders")

    g.Add("Text", "x10 y101", "Whitespace:")
    UI.ddlWs := g.Add("DropDownList", "x85 y97 w200", ["Compare exactly", "Ignore trailing whitespace"
        , "Ignore changes in amount", "Ignore all whitespace"])
    UI.chkCase := g.Add("CheckBox", "x295 y100", "Ignore case")
    g.Add("Text", "x385 y101", "Context:")
    UI.ddlCtx := g.Add("DropDownList", "x435 y97 w95", ["0 lines", "3 lines", "5 lines", "10 lines", "25 lines", "Whole file"])
    g.Add("Text", "x540 y101", "View:")
    UI.ddlView := g.Add("DropDownList", "x575 y97 w110", ["Side by side", "Unified"])
    UI.chkIdent := g.Add("CheckBox", "x700 y100", "Show identical files")

    UI.btnCompare := g.Add("Button", "x10 y128 w115 h28 Default", "&Compare (F5)")
    UI.btnReport := g.Add("Button", "x130 y128 w145 h28", "&Export HTML report...")
    UI.btnCopy := g.Add("Button", "x280 y128 w140 h28", "Copy &unified diff")
    UI.btnOpen := g.Add("Button", "x425 y128 w150 h28", "Open view in &browser")
    UI.txtSummary := g.Add("Text", "x590 y135 w380", "")

    UI.lv := g.Add("ListView", "x10 y164 w420 h400 -Multi Grid"
        , ["Status", "File", "Changes", "- Lines", "+ Lines", "Size A", "Size B", "ID"])
    for col in [3, 4, 5, 6, 7, 8]
        UI.lv.ModifyCol(col, "Integer")
    UI.lv.ModifyCol(1, 95)
    UI.lv.ModifyCol(2, 230)
    UI.lv.ModifyCol(3, 58)
    UI.lv.ModifyCol(4, 52)
    UI.lv.ModifyCol(5, 52)
    UI.lv.ModifyCol(6, 70)
    UI.lv.ModifyCol(7, 70)
    UI.lv.ModifyCol(8, 0)

    UI.wbCtrl := g.Add("ActiveX", "x435 y164 w500 h400", "Shell.Explorer")
    UI.wb := UI.wbCtrl.Value
    try UI.wb.Silent := true
    UI.sb := g.Add("StatusBar")

    UI.btnA.OnEvent("Click", (*) => BrowseFolder(UI.edA))
    UI.btnB.OnEvent("Click", (*) => BrowseFolder(UI.edB))
    UI.btnSwap.OnEvent("Click", SwapFolders)
    UI.btnCompare.OnEvent("Click", (*) => DoCompare())
    UI.btnReport.OnEvent("Click", (*) => ExportReport())
    UI.btnCopy.OnEvent("Click", (*) => CopyUnified(App.current))
    UI.btnOpen.OnEvent("Click", (*) => OpenViewInBrowser())
    UI.ddlCtx.OnEvent("Change", (*) => RefreshView())
    UI.ddlView.OnEvent("Change", (*) => RefreshView())
    UI.chkIdent.OnEvent("Click", (*) => PopulateList())
    for ctrl in [UI.ddlWs, UI.edIncl, UI.edExcl]
        ctrl.OnEvent("Change", OptionsChanged)
    for ctrl in [UI.chkCase, UI.chkRec]
        ctrl.OnEvent("Click", OptionsChanged)
    UI.lv.OnEvent("ItemSelect", LvSelect)
    UI.lv.OnEvent("ContextMenu", LvContext)
    g.OnEvent("Size", GuiSize)
    g.OnEvent("Close", (*) => ExitApp())
    g.OnEvent("DropFiles", GuiDrop)

    LoadSettings()
    g.Show("w1350 h820")
    ShowHtml(WelcomeHtml())
    SetStatus("Ready. Choose two folders and press Compare (F5).")

    HotIfWinActive("ahk_id " g.Hwnd)
    Hotkey("F5", (*) => DoCompare())
    HotIf()
}

GuiSize(g, minMax, w, h) {
    if (minMax = -1)
        return
    right := w - 10
    swapX := right - 75
    browseX := swapX - 5 - 80
    editW := browseX - 5 - 75
    UI.btnSwap.Move(swapX)
    UI.btnA.Move(browseX)
    UI.btnB.Move(browseX)
    UI.edA.Move(, , editW)
    UI.edB.Move(, , editW)
    UI.txtSummary.Move(, , Max(100, w - 590 - 10))
    top := 164
    listH := h - top - 28
    lvW := Max(330, Round(w * 0.32))
    UI.lv.Move(10, top, lvW, listH)
    UI.wbCtrl.Move(10 + lvW + 5, top, w - lvW - 25, listH)
}

GuiDrop(g, ctrl, files, x, y) {
    dirs := []
    for f in files {
        if DirExist(f)
            dirs.Push(f)
        else {
            SplitPath(f, , &dir)
            dirs.Push(dir)
        }
    }
    if (dirs.Length >= 2) {
        UI.edA.Value := dirs[1]
        UI.edB.Value := dirs[2]
    } else if (ctrl && ctrl.Hwnd = UI.edB.Hwnd) {
        UI.edB.Value := dirs[1]
    } else if (ctrl && ctrl.Hwnd = UI.edA.Hwnd) {
        UI.edA.Value := dirs[1]
    } else if (UI.edA.Value = "") {
        UI.edA.Value := dirs[1]
    } else {
        UI.edB.Value := dirs[1]
    }
}

BrowseFolder(edit) {
    sel := DirSelect("*" edit.Value, 3, "Select a folder")
    if (sel != "")
        edit.Value := sel
}

SwapFolders(*) {
    tmp := UI.edA.Value
    UI.edA.Value := UI.edB.Value
    UI.edB.Value := tmp
    OptionsChanged()
}

OptionsChanged(*) {
    if (App.results.Length)
        SetStatus("Folders or comparison options changed - press Compare (F5) to re-run.")
}

SetStatus(text) {
    UI.sb.SetText("  " text)
}

GetOptions() {
    ctxVals := [0, 3, 5, 10, 25, -1]
    return {ws: UI.ddlWs.Value, wsText: UI.ddlWs.Text, ic: UI.chkCase.Value, ctx: ctxVals[UI.ddlCtx.Value]
        , view: UI.ddlView.Value, rec: UI.chkRec.Value, incl: Trim(UI.edIncl.Value), excl: Trim(UI.edExcl.Value)}
}

OptionsText(o) {
    return "Whitespace: " o.wsText " | Ignore case: " (o.ic ? "yes" : "no")
        . " | Subfolders: " (o.rec ? "yes" : "no")
        . " | Include: " (o.incl = "" ? "*" : o.incl) " | Exclude: " (o.excl = "" ? "(nothing)" : o.excl)
}

LoadSettings() {
    UI.edA.Value := IniRead(INI_FILE, "Settings", "FolderA", "")
    UI.edB.Value := IniRead(INI_FILE, "Settings", "FolderB", "")
    UI.edIncl.Value := IniRead(INI_FILE, "Settings", "Include", "*")
    UI.edExcl.Value := IniRead(INI_FILE, "Settings", "Exclude", ".git;.svn;.vs;node_modules;*.bak;*.tmp")
    ChooseSafe(UI.ddlWs, IniRead(INI_FILE, "Settings", "Whitespace", 1), 1)
    ChooseSafe(UI.ddlCtx, IniRead(INI_FILE, "Settings", "Context", 2), 2)
    ChooseSafe(UI.ddlView, IniRead(INI_FILE, "Settings", "View", 1), 1)
    UI.chkCase.Value := IniRead(INI_FILE, "Settings", "IgnoreCase", 0) = 1
    UI.chkRec.Value := IniRead(INI_FILE, "Settings", "Recursive", 1) = 1
    UI.chkIdent.Value := IniRead(INI_FILE, "Settings", "ShowIdentical", 0) = 1
}

ChooseSafe(ddl, value, default) {
    try
        ddl.Choose(Integer(value))
    catch
        ddl.Choose(default)
}

SaveSettings() {
    try {
        IniWrite(UI.edA.Value, INI_FILE, "Settings", "FolderA")
        IniWrite(UI.edB.Value, INI_FILE, "Settings", "FolderB")
        IniWrite(UI.edIncl.Value, INI_FILE, "Settings", "Include")
        IniWrite(UI.edExcl.Value, INI_FILE, "Settings", "Exclude")
        IniWrite(UI.ddlWs.Value, INI_FILE, "Settings", "Whitespace")
        IniWrite(UI.ddlCtx.Value, INI_FILE, "Settings", "Context")
        IniWrite(UI.ddlView.Value, INI_FILE, "Settings", "View")
        IniWrite(UI.chkCase.Value, INI_FILE, "Settings", "IgnoreCase")
        IniWrite(UI.chkRec.Value, INI_FILE, "Settings", "Recursive")
        IniWrite(UI.chkIdent.Value, INI_FILE, "Settings", "ShowIdentical")
    }
}

Cleanup(*) {
    SaveSettings()
    if (App.viewFile != "")
        try FileDelete(App.viewFile)
}

; ==============================================================================
;  File list
; ==============================================================================

PopulateList() {
    lv := UI.lv
    lv.Opt("-Redraw")
    lv.Delete()
    showIdent := UI.chkIdent.Value
    for r in App.results {
        if (r.status = "Identical" && !showIdent)
            continue
        ch := "", dl := "", il := ""
        if (IsObject(r.stats) && r.status != "Equivalent") {
            ch := r.stats.changes
            dl := r.stats.del
            il := r.stats.ins
        }
        lv.Add(, STATUS_LABEL[r.status], r.rel, ch, dl, il, r.sizeA, r.sizeB, r.id)
    }
    lv.Opt("+Redraw")
}

LvSelect(lv, item, selected) {
    if (!selected || !item)
        return
    App.pendingId := Integer(lv.GetText(item, 8))
    SetTimer(RenderPending, -60)
}

RenderPending() {
    if (App.pendingId)
        ShowResult(App.pendingId)
}

LvContext(lv, item, isRightClick, x, y) {
    if (!item)
        return
    id := Integer(lv.GetText(item, 8))
    r := App.results[id]
    m := Menu()
    m.Add("Open A file", (*) => OpenFile(r.pathA))
    m.Add("Open B file", (*) => OpenFile(r.pathB))
    m.Add()
    m.Add("Show A file in Explorer", (*) => ShowInExplorer(r.pathA))
    m.Add("Show B file in Explorer", (*) => ShowInExplorer(r.pathB))
    m.Add()
    m.Add("Copy unified diff", (*) => CopyUnified(id))
    m.Add("Copy relative path", (*) => (A_Clipboard := r.rel))
    if (r.pathA = "") {
        m.Disable("Open A file")
        m.Disable("Show A file in Explorer")
    }
    if (r.pathB = "") {
        m.Disable("Open B file")
        m.Disable("Show B file in Explorer")
    }
    m.Show()
}

OpenFile(path) {
    try
        Run('*edit "' path '"')
    catch
        Run('notepad.exe "' path '"')
}

ShowInExplorer(path) {
    Run('explorer.exe /select,"' path '"')
}

; ==============================================================================
;  Viewer (embedded browser)
; ==============================================================================

ShowHtml(html) {
    App.html := html
    App.viewSeq++
    path := A_Temp "\AhkFolderDiff_" DllCall("GetCurrentProcessId") "_" App.viewSeq ".html"
    WriteUtf8(path, html)
    UI.wb.Navigate(path)
    if (App.viewFile != "")
        try FileDelete(App.viewFile)
    App.viewFile := path
}

ShowSummary() {
    App.current := 0
    ShowHtml(HtmlPage("Summary", RenderSummary(false)))
}

ShowResult(id) {
    r := App.results[id]
    App.current := id
    SetStatus("Rendering " r.rel " ...")
    try {
        html := HtmlPage(r.rel, RenderFile(r, GetOptions(), "f", false))
    } catch as e {
        html := HtmlPage("Error", '<div class="file"><p>Could not render this file: ' HtmlEsc(e.Message) '</p></div>')
    }
    ShowHtml(html)
    SetStatus(STATUS_LABEL[r.status] ": " r.rel)
}

RefreshView() {
    if (App.current)
        ShowResult(App.current)
    else if (App.results.Length)
        ShowSummary()
}

OpenViewInBrowser() {
    if (App.html = "")
        return
    path := A_Temp "\AhkFolderDiff_view.html"
    WriteUtf8(path, App.html)
    Run(path)
}

WriteUtf8(path, text) {
    f := FileOpen(path, "w", "UTF-8")
    f.Write(text)
    f.Close()
}

; ==============================================================================
;  Comparing folders
; ==============================================================================

DoCompare() {
    if (App.busy)
        return
    dirA := NormDir(UI.edA.Value)
    dirB := NormDir(UI.edB.Value)
    if (dirA = "" || !DirExist(dirA)) {
        MsgBox("Folder A does not exist:`n" dirA, APP_TITLE, "Icon!")
        return
    }
    if (dirB = "" || !DirExist(dirB)) {
        MsgBox("Folder B does not exist:`n" dirB, APP_TITLE, "Icon!")
        return
    }
    if (dirA = dirB) {
        MsgBox("Folder A and Folder B are the same folder.", APP_TITLE, "Icon!")
        return
    }
    opts := GetOptions()
    SaveSettings()
    App.busy := true
    UI.btnCompare.Enabled := false
    try {
        RunComparison(dirA, dirB, opts)
    } catch as e {
        MsgBox("Comparison failed:`n" e.Message "`n`n" e.What " (line " e.Line ")", APP_TITLE, "Iconx")
    } finally {
        UI.btnCompare.Enabled := true
        App.busy := false
    }
}

RunComparison(dirA, dirB, opts) {
    start := A_TickCount
    SetStatus("Scanning folders...")
    inclRx := (opts.incl = "" || opts.incl = "*" || opts.incl = "*.*") ? "" : WildToRegex(opts.incl)
    exclRx := WildToRegex(opts.excl)
    filesA := ScanDir(dirA, inclRx, exclRx, opts.rec)
    filesB := ScanDir(dirB, inclRx, exclRx, opts.rec)

    results := [], onlyA := [], onlyB := []
    total := filesA.Count, i := 0, tick := 0
    for rel, fa in filesA {
        i++
        if (A_TickCount - tick > 150) {
            SetStatus("Comparing " i " / " total ": " rel)
            Sleep(-1)
            tick := A_TickCount
        }
        if filesB.Has(rel) {
            r := NewResult(rel, rel, fa, filesB[rel])
            CompareFiles(r, opts)
            results.Push(r)
        } else {
            onlyA.Push(NewResult(rel, "", fa, ""))
        }
    }
    for rel, fb in filesB {
        if !filesA.Has(rel)
            onlyB.Push(NewResult("", rel, "", fb))
    }
    SetStatus("Looking for moved / renamed files...")
    DetectMoves(onlyA, onlyB, results)
    for r in results {
        if (r.status = "OnlyA" || r.status = "OnlyB")
            try EnsureLoaded(r)
    }

    results := SortResults(results)
    for idx, r in results
        r.id := idx
    App.results := results
    App.dirA := dirA
    App.dirB := dirB
    App.opts := opts
    App.when := FormatTime(, "yyyy-MM-dd HH:mm:ss")

    counts := CountStatuses()
    UI.txtSummary.Value := counts.Get("Modified", 0) " modified, " counts.Get("OnlyA", 0) " only in A, "
        . counts.Get("OnlyB", 0) " only in B, " counts.Get("Moved", 0) " moved, "
        . counts.Get("Identical", 0) + counts.Get("Equivalent", 0) " same"
    PopulateList()
    ShowSummary()
    SetStatus("Compared " filesA.Count " + " filesB.Count " files in " Round((A_TickCount - start) / 1000, 1) " s.")
}

NewResult(relA, relB, fa, fb) {
    return {id: 0, relA: relA, relB: relB, rel: relA != "" ? relA : relB, status: ""
        , pathA: fa ? fa.full : "", pathB: fb ? fb.full : ""
        , sizeA: fa ? fa.size : "", sizeB: fb ? fb.size : ""
        , timeA: fa ? fa.time : "", timeB: fb ? fb.time : ""
        , A: "", B: "", ops: "", blocks: "", stats: "", notes: [], ctxA: "", ctxB: ""
        , loaded: false, truncated: false}
}

NormDir(path) {
    path := Trim(path, " `t`"")
    return RTrim(path, "\/")
}

ScanDir(root, inclRx, exclRx, recurse) {
    files := Map()
    files.CaseSense := "Off"
    Loop Files root "\*", recurse ? "FR" : "F" {
        rel := SubStr(A_LoopFileFullPath, StrLen(root) + 2)
        if IsExcluded(rel, exclRx)
            continue
        if (inclRx != "" && !RegExMatch(A_LoopFileName, inclRx))
            continue
        files[rel] := {full: A_LoopFileFullPath, size: A_LoopFileSize, time: A_LoopFileTimeModified}
    }
    return files
}

IsExcluded(rel, rx) {
    if (rx = "")
        return false
    for seg in StrSplit(rel, "\") {
        if RegExMatch(seg, rx)
            return true
    }
    return false
}

WildToRegex(list) {
    joined := ""
    for p in StrSplit(list, [";", ","]) {
        p := Trim(p)
        if (p = "")
            continue
        rx := RegExReplace(p, "[\\.^$+(){}\[\]|]", "\$0")
        rx := StrReplace(StrReplace(rx, "*", ".*"), "?", ".")
        joined .= (joined = "" ? "" : "|") rx
    }
    return joined = "" ? "" : "i)^(?:" joined ")$"
}

CompareFiles(r, opts) {
    try {
        if (r.sizeA = r.sizeB && (r.sizeA = 0 || RawEqual(r.pathA, r.pathB))) {
            r.status := "Identical"
            return
        }
        ComputeTextDiff(r, opts)
    } catch as e {
        r.status := "Error"
        r.notes.Push("Could not read or compare this file: " e.Message)
    }
}

RawEqual(p1, p2) {
    b1 := FileRead(p1, "RAW")
    b2 := FileRead(p2, "RAW")
    if (b1.Size != b2.Size)
        return false
    if (b1.Size = 0)
        return true
    return DllCall("ntdll\RtlCompareMemory", "Ptr", b1, "Ptr", b2, "UPtr", b1.Size, "UPtr") = b1.Size
}

DetectMoves(onlyA, onlyB, results) {
    usedB := Map()
    for ra in onlyA {
        found := 0
        for ib, rb in onlyB {
            if (usedB.Has(ib) || ra.sizeA != rb.sizeB || ra.sizeA = 0)
                continue
            try {
                if RawEqual(ra.pathA, rb.pathB) {
                    found := ib
                    break
                }
            }
        }
        if (found) {
            rb := onlyB[found]
            usedB[found] := true
            ra.status := "Moved"
            ra.relB := rb.relB
            ra.pathB := rb.pathB
            ra.sizeB := rb.sizeB
            ra.timeB := rb.timeB
            ra.rel := ra.relA " -> " rb.relB
        } else {
            ra.status := "OnlyA"
        }
        results.Push(ra)
    }
    for ib, rb in onlyB {
        if !usedB.Has(ib) {
            rb.status := "OnlyB"
            results.Push(rb)
        }
    }
}

SortResults(arr) {
    if (!arr.Length)
        return arr
    s := ""
    for i, r in arr
        s .= Format("{:02}", STATUS_ORDER[r.status]) "|" r.rel "`t" i "`n"
    s := Sort(RTrim(s, "`n"))
    out := []
    Loop Parse s, "`n" {
        out.Push(arr[Integer(SubStr(A_LoopField, InStr(A_LoopField, "`t", , -1) + 1))])
    }
    return out
}

CountStatuses() {
    counts := Map()
    for r in App.results
        counts[r.status] := counts.Get(r.status, 0) + 1
    return counts
}

; ==============================================================================
;  Reading files
; ==============================================================================

LoadText(path) {
    info := {lines: [], enc: "UTF-8", eol: "none", finalNL: false, binary: false}
    raw := FileRead(path, "RAW")
    size := raw.Size
    enc := "UTF-8"
    b0 := size >= 1 ? NumGet(raw, 0, "UChar") : -1
    b1 := size >= 2 ? NumGet(raw, 1, "UChar") : -1
    b2 := size >= 3 ? NumGet(raw, 2, "UChar") : -1
    if (b0 = 0xEF && b1 = 0xBB && b2 = 0xBF) {
        info.enc := "UTF-8 with BOM"
    } else if (b0 = 0xFF && b1 = 0xFE) {
        info.enc := "UTF-16 LE"
        enc := "UTF-16"
    } else if (b0 = 0xFE && b1 = 0xFF) {
        info.enc := "UTF-16 BE"
        info.binary := true
        return info
    }
    if (enc != "UTF-16" && size > 0) {
        if DllCall("msvcrt\memchr", "Ptr", raw, "Int", 0, "UPtr", Min(size, 8192), "CDecl Ptr") {
            info.binary := true
            return info
        }
        if (info.enc = "UTF-8") {
            if !DllCall("MultiByteToWideChar", "UInt", 65001, "UInt", 8, "Ptr", raw, "Int", size, "Ptr", 0, "Int", 0) {
                info.enc := "ANSI (system code page)"
                enc := "CP0"
            }
        }
    }
    raw := ""
    text := FileRead(path, enc)
    if (SubStr(text, 1, 1) = Chr(0xFEFF))
        text := SubStr(text, 2)

    text := StrReplace(text, "`r`n", "`n", , &crlf)
    text := StrReplace(text, "`r", "`n", , &cr)
    StrReplace(text, "`n", "`n", , &lfTotal)
    lf := lfTotal - crlf - cr
    kinds := []
    if (crlf)
        kinds.Push("CRLF x" crlf)
    if (lf)
        kinds.Push("LF x" lf)
    if (cr)
        kinds.Push("CR x" cr)
    if (kinds.Length = 1)
        info.eol := crlf ? "CRLF (Windows)" : lf ? "LF (Unix)" : "CR (old Mac)"
    else if (kinds.Length > 1)
        info.eol := "Mixed: " JoinList(kinds, ", ")

    if (SubStr(text, -1) = "`n") {
        info.finalNL := true
        text := SubStr(text, 1, -1)
    }
    if (text = "")
        info.lines := info.finalNL ? [""] : []
    else
        info.lines := StrSplit(text, "`n")
    return info
}

LineKey(s, ws, ic) {
    switch ws {
        case 2: s := RTrim(s, " `t")
        case 3: s := RegExReplace(Trim(s, " `t"), "[ \t]+", " ")
        case 4: s := RegExReplace(s, "[ \t]+")
    }
    return ic ? StrLower(s) : s
}

ComputeTextDiff(r, opts) {
    ta := LoadText(r.pathA)
    tb := LoadText(r.pathB)
    r.A := ta
    r.B := tb
    r.loaded := true
    if (ta.binary || tb.binary) {
        r.status := "Binary"
        r.notes.Push("At least one of the files looks binary, so no line-by-line comparison is shown.")
        return
    }
    ids := Map()
    ka := [], kb := []
    ka.Capacity := ta.lines.Length
    kb.Capacity := tb.lines.Length
    for line in ta.lines {
        k := LineKey(line, opts.ws, opts.ic)
        if !ids.Has(k)
            ids[k] := ids.Count + 1
        ka.Push(ids[k])
    }
    for line in tb.lines {
        k := LineKey(line, opts.ws, opts.ic)
        if !ids.Has(k)
            ids[k] := ids.Count + 1
        kb.Push(ids[k])
    }
    truncated := false
    r.ops := MyersDiff(ka, kb, MAX_EDIT_DISTANCE, &truncated)
    r.truncated := truncated
    r.blocks := BuildBlocks(r.ops)
    r.stats := CalcStats(r.blocks)
    AddFormatNotes(r)
    if (r.stats.changes = 0) {
        r.status := "Equivalent"
    } else {
        r.status := "Modified"
        r.ctxA := BuildContext(ta.lines)
        r.ctxB := BuildContext(tb.lines)
    }
}

EnsureLoaded(r) {
    if (r.loaded)
        return
    r.loaded := true
    if (r.status != "OnlyA" && r.status != "OnlyB")
        return
    isA := r.status = "OnlyA"
    t := LoadText(isA ? r.pathA : r.pathB)
    if isA
        r.A := t
    else
        r.B := t
    if (t.binary)
        return
    ctx := BuildContext(t.lines)
    if isA
        r.ctxA := ctx
    else
        r.ctxB := ctx
    n := t.lines.Length
    r.stats := {changes: n ? 1 : 0, del: isA ? n : 0, ins: isA ? 0 : n, mod: 0}
}

AddFormatNotes(r) {
    ta := r.A, tb := r.B
    if (ta.enc != tb.enc)
        r.notes.Push("Encoding differs: A is " ta.enc ", B is " tb.enc ".")
    if (ta.eol != tb.eol)
        r.notes.Push("Line endings differ: A uses " ta.eol ", B uses " tb.eol ".")
    if (ta.finalNL != tb.finalNL)
        r.notes.Push(ta.finalNL ? "A ends with a newline, B does not." : "B ends with a newline, A does not.")
    if (r.truncated)
        r.notes.Push("These files are very different (more than " MAX_EDIT_DISTANCE " line edits), so the "
            . "middle section is shown as one large removed/added block instead of being aligned line by line.")
}

; ==============================================================================
;  Diff engine (Myers O(ND) algorithm)
;  Returns an array of ops: [0, lineA, lineB] = same, [1, lineA, 0] = only in A,
;  [2, 0, lineB] = only in B. Inputs are arrays of integer ids.
; ==============================================================================

MyersDiff(a, b, maxD, &truncated) {
    truncated := false
    n := a.Length, m := b.Length
    pre := 0
    while (pre < n && pre < m && a[pre + 1] = b[pre + 1])
        pre++
    suf := 0
    while (suf < n - pre && suf < m - pre && a[n - suf] = b[m - suf])
        suf++
    ops := []
    ops.Capacity := n + m
    loop pre
        ops.Push([0, A_Index, A_Index])
    midA := n - pre - suf, midB := m - pre - suf
    if (midA = 0) {
        loop midB
            ops.Push([2, 0, pre + A_Index])
    } else if (midB = 0) {
        loop midA
            ops.Push([1, pre + A_Index, 0])
    } else {
        mid := MyersCore(a, b, pre, midA, midB, maxD)
        if !IsObject(mid) {
            truncated := true
            mid := []
            loop midA
                mid.Push([1, pre + A_Index, 0])
            loop midB
                mid.Push([2, 0, pre + A_Index])
        }
        for op in mid
            ops.Push(op)
    }
    loop suf
        ops.Push([0, n - suf + A_Index, m - suf + A_Index])
    return ops
}

MyersCore(a, b, o, lenA, lenB, maxD) {
    maxSteps := lenA + lenB
    if (maxD > 0 && maxD < maxSteps)
        maxSteps := maxD
    off := maxSteps + 1
    V := Buffer((2 * maxSteps + 3) * 4, 0)
    trace := []
    found := false
    d := 0
    while (d <= maxSteps) {
        k := -d
        while (k <= d) {
            if (k = -d || (k != d && NumGet(V, (off + k - 1) * 4, "Int") < NumGet(V, (off + k + 1) * 4, "Int")))
                x := NumGet(V, (off + k + 1) * 4, "Int")
            else
                x := NumGet(V, (off + k - 1) * 4, "Int") + 1
            y := x - k
            while (x < lenA && y < lenB && a[o + x + 1] = b[o + y + 1]) {
                x++
                y++
            }
            NumPut("Int", x, V, (off + k) * 4)
            if (x >= lenA && y >= lenB) {
                found := true
                break
            }
            k += 2
        }
        cnt := 2 * d + 1
        snap := Buffer(cnt * 4)
        DllCall("RtlMoveMemory", "Ptr", snap, "Ptr", V.Ptr + (off - d) * 4, "UPtr", cnt * 4)
        trace.Push(snap)
        if (found)
            break
        d++
    }
    if (!found)
        return ""

    ; trace[d] holds the furthest x per diagonal after step d-1 (diagonals -(d-1)..d-1).
    rev := []
    x := lenA, y := lenB
    while (d > 0) {
        k := x - y
        prev := trace[d]
        base := d - 1
        if (k = -d || (k != d && NumGet(prev, (k - 1 + base) * 4, "Int") < NumGet(prev, (k + 1 + base) * 4, "Int")))
            prevK := k + 1
        else
            prevK := k - 1
        prevX := NumGet(prev, (prevK + base) * 4, "Int")
        prevY := prevX - prevK
        while (x > prevX && y > prevY) {
            rev.Push([0, o + x, o + y])
            x--
            y--
        }
        if (x = prevX)
            rev.Push([2, 0, o + y])
        else
            rev.Push([1, o + x, 0])
        x := prevX, y := prevY
        d--
    }
    while (x > 0 && y > 0) {
        rev.Push([0, o + x, o + y])
        x--
        y--
    }
    ops := []
    ops.Capacity := rev.Length
    i := rev.Length
    while (i >= 1) {
        ops.Push(rev[i])
        i--
    }
    return ops
}

BuildBlocks(ops) {
    blocks := [], cur := 0, lastA := 0, lastB := 0
    for op in ops {
        if (op[1] = 0) {
            if (IsObject(cur) && cur.eq) {
                cur.len++
            } else {
                cur := {eq: true, a1: op[2], b1: op[3], len: 1}
                blocks.Push(cur)
            }
            lastA := op[2]
            lastB := op[3]
        } else {
            if !(IsObject(cur) && !cur.eq) {
                cur := {eq: false, dels: [], ins: [], aPos: lastA, bPos: lastB, n: 0}
                blocks.Push(cur)
            }
            if (op[1] = 1) {
                cur.dels.Push(op[2])
                lastA := op[2]
            } else {
                cur.ins.Push(op[3])
                lastB := op[3]
            }
        }
    }
    return blocks
}

CalcStats(blocks) {
    s := {changes: 0, del: 0, ins: 0, mod: 0}
    for blk in blocks {
        if (blk.eq)
            continue
        s.changes++
        blk.n := s.changes
        s.del += blk.dels.Length
        s.ins += blk.ins.Length
        s.mod += Min(blk.dels.Length, blk.ins.Length)
    }
    return s
}

; Word-level comparison of two lines. Returns [htmlA, htmlB] with the differing
; parts wrapped in highlight spans.
IntraLine(lineA, lineB) {
    if (lineA == lineB)
        return [HtmlEsc(lineA), HtmlEsc(lineB)]
    tokA := Tokenize(lineA), tokB := Tokenize(lineB)
    if (tokA.Length > 2000 || tokB.Length > 2000)
        return [HtmlEsc(lineA), HtmlEsc(lineB)]
    ids := Map(), ia := [], ib := []
    for t in tokA {
        if !ids.Has(t)
            ids[t] := ids.Count + 1
        ia.Push(ids[t])
    }
    for t in tokB {
        if !ids.Has(t)
            ids[t] := ids.Count + 1
        ib.Push(ids[t])
    }
    tr := false
    ops := MyersDiff(ia, ib, 0, &tr)
    same := 0
    for op in ops {
        if (op[1] = 0)
            same += StrLen(tokA[op[2]])
    }
    total := StrLen(lineA) + StrLen(lineB)
    ; Lines that have almost nothing in common are just shown as whole-line changes.
    if (total = 0 || same * 2 / total < 0.25)
        return [HtmlEsc(lineA), HtmlEsc(lineB)]
    outA := "", outB := "", openA := false, openB := false
    for op in ops {
        switch op[1] {
            case 0:
                if (openA) {
                    outA .= "</span>"
                    openA := false
                }
                if (openB) {
                    outB .= "</span>"
                    openB := false
                }
                outA .= HtmlEsc(tokA[op[2]])
                outB .= HtmlEsc(tokB[op[3]])
            case 1:
                if (!openA) {
                    outA .= '<span class="dc">'
                    openA := true
                }
                outA .= HtmlEsc(tokA[op[2]])
            case 2:
                if (!openB) {
                    outB .= '<span class="ic">'
                    openB := true
                }
                outB .= HtmlEsc(tokB[op[3]])
        }
    }
    if (openA)
        outA .= "</span>"
    if (openB)
        outB .= "</span>"
    return [outA, outB]
}

Tokenize(s) {
    toks := []
    pos := 1
    while (pos := RegExMatch(s, "\w+|\s+|[^\w\s]", &m, pos)) {
        toks.Push(m[0])
        pos += StrLen(m[0])
    }
    return toks
}

; ==============================================================================
;  AutoHotkey structure detection (which function / label / hotkey a line is in)
; ==============================================================================

BuildContext(lines) {
    defs := [], idx := []
    n := lines.Length
    idx.Capacity := n
    cur := 0
    loop n {
        name := DetectDef(lines, A_Index, n)
        if (name != "") {
            defs.Push(SubStr(name, 1, 100))
            cur := defs.Length
        }
        idx.Push(cur)
    }
    return {defs: defs, idx: idx}
}

DetectDef(lines, i, n) {
    line := lines[i]
    if !RegExMatch(line, "^\s*[^\s;]")
        return ""
    if RegExMatch(line, "i)^\s*class\s+([\w.]+)", &m)
        return "class " m[1]
    if RegExMatch(line, "i)^\s*#(HotIf|IfWinActive|IfWinNotActive|IfWinExist|IfWinNotExist|If)\b(.*)", &m)
        return "#" m[1] (Trim(m[2]) != "" ? " " Trim(m[2]) : "")
    if RegExMatch(line, "^\s*:[^:]*:(.+?)::", &m)
        return "hotstring ::" m[1] "::"
    if RegExMatch(line, "i)^\s*(?:static\s+)?([A-Za-z_]\w*)\((.*)\)\s*(\{|=>)?", &m) {
        if !RegExMatch(m[1], "i)^(if|while|for|loop|switch|catch|return|until|else|try|throw|and|or|not|in|is)$") {
            if (m[3] != "" || NextCodeLineIsBrace(lines, i, n))
                return m[1] "(" m[2] ")"
        }
    }
    if (p := InStr(line, "::")) {
        key := Trim(SubStr(line, 1, p - 1))
        if (key != "" && !RegExMatch(key, "[`"'(){}=,]") && SubStr(key, 1, 1) != ":")
            return "hotkey " key "::"
    }
    if RegExMatch(line, "^\s*([A-Za-z_]\w*):\s*(?:;.*)?$", &m) && m[1] != "default"
        return "label " m[1] ":"
    return ""
}

NextCodeLineIsBrace(lines, i, n) {
    j := i + 1
    while (j <= n && j <= i + 5) {
        s := Trim(lines[j])
        if (s = "" || SubStr(s, 1, 1) = ";") {
            j++
            continue
        }
        return SubStr(s, 1, 1) = "{"
    }
    return false
}

CtxName(ctx, lineNo) {
    if (!IsObject(ctx) || lineNo < 1 || lineNo > ctx.idx.Length)
        return ""
    i := ctx.idx[lineNo]
    return i ? ctx.defs[i] : "(top of script)"
}

BlockNames(r, blk) {
    if blk.HasOwnProp("names")
        return blk.names
    names := [], seen := Map()
    for ln in blk.dels
        AddUnique(names, seen, CtxName(r.ctxA, ln))
    for ln in blk.ins
        AddUnique(names, seen, CtxName(r.ctxB, ln))
    if (!names.Length)
        AddUnique(names, seen, CtxName(r.ctxA, blk.aPos))
    blk.names := names
    return names
}

FileFuncs(r) {
    names := [], seen := Map()
    if (!IsObject(r.blocks))
        return names
    for blk in r.blocks {
        if (blk.eq)
            continue
        for nm in BlockNames(r, blk)
            AddUnique(names, seen, nm)
    }
    return names
}

AddUnique(arr, seen, v) {
    if (v = "" || seen.Has(v))
        return
    seen[v] := true
    arr.Push(v)
}

; ==============================================================================
;  HTML rendering
; ==============================================================================

RenderFile(r, opts, p, forReport) {
    EnsureLoaded(r)
    h := '<div class="file" id="' p '"><h2><span class="badge b-' r.status '">' STATUS_LABEL[r.status] '</span>'
    h .= HtmlEsc(r.rel)
    if (forReport)
        h .= ' <a class="small" href="#summary">[back to summary]</a>'
    h .= '</h2>' RenderInfo(r)
    if (r.notes.Length) {
        h .= '<ul class="notes">'
        for note in r.notes
            h .= '<li>' HtmlEsc(note) '</li>'
        h .= '</ul>'
    }
    switch r.status {
        case "Identical":
            h .= '<p class="msg">The two files are byte-for-byte identical.</p>'
        case "Binary":
            h .= '<p class="msg">Binary content differs - no line-by-line view is available.</p>'
        case "Error":
            h .= '<p class="msg">This file could not be compared.</p>'
        case "Moved":
            h .= '<p class="msg">The same content (byte-for-byte) exists in both folders, but at different paths:<br>A: <code>'
                . HtmlEsc(r.relA) '</code><br>B: <code>' HtmlEsc(r.relB) '</code></p>'
        case "Equivalent":
            h .= RenderEquivalent(r)
        case "OnlyA", "OnlyB":
            h .= RenderWholeFile(r)
        case "Modified":
            h .= RenderChangeList(r, p)
            h .= opts.view = 2 ? RenderUnified(r, opts.ctx, p) : RenderSideBySide(r, opts.ctx, p)
    }
    return h '</div>'
}

RenderInfo(r) {
    h := '<table class="info"><tr><th></th><th>A</th><th>B</th></tr>'
    h .= InfoRow("Path", r.pathA, r.pathB, false)
    h .= InfoRow("Size", FmtSize(r.sizeA), FmtSize(r.sizeB), true)
    tA := FmtTime(r.timeA), tB := FmtTime(r.timeB)
    if (r.timeA != "" && r.timeB != "") {
        if (r.timeA > r.timeB)
            tA .= "   (newer)"
        else if (r.timeB > r.timeA)
            tB .= "   (newer)"
    }
    h .= InfoRow("Last modified", tA, tB, true)
    okA := IsObject(r.A) && !r.A.binary
    okB := IsObject(r.B) && !r.B.binary
    if (okA || okB) {
        h .= InfoRow("Lines", okA ? r.A.lines.Length : "", okB ? r.B.lines.Length : "", true)
        h .= InfoRow("Encoding", okA ? r.A.enc : "", okB ? r.B.enc : "", true)
        h .= InfoRow("Line endings", okA ? r.A.eol : "", okB ? r.B.eol : "", true)
        h .= InfoRow("Ends with newline", okA ? (r.A.finalNL ? "Yes" : "No") : "", okB ? (r.B.finalNL ? "Yes" : "No") : "", true)
    }
    return h '</table>'
}

InfoRow(label, valA, valB, highlight) {
    cls := (highlight && valA != "" && valB != "" && String(valA) != String(valB)) ? ' class="dv"' : ""
    return '<tr' cls '><th>' label '</th><td>' (valA = "" ? "-" : HtmlEsc(valA)) '</td><td>'
        . (valB = "" ? "-" : HtmlEsc(valB)) '</td></tr>'
}

RenderChangeList(r, p) {
    s := r.stats
    h := '<div class="sum"><b>' s.changes ' change' (s.changes = 1 ? "" : "s") '</b>: '
    h .= '<span class="minus">' s.del ' line' (s.del = 1 ? "" : "s") ' only in A</span>, '
    h .= '<span class="plus">' s.ins ' line' (s.ins = 1 ? "" : "s") ' only in B</span>'
    h .= ' (' s.mod ' of them are modified versions of each other).</div>'
    funcs := FileFuncs(r)
    if (funcs.Length)
        h .= '<div class="funcs"><b>Functions / labels / hotkeys touched:</b> ' CodeList(funcs) '</div>'
    h .= '<table class="chg"><tr><th>#</th><th>Kind</th><th>A</th><th>B</th><th>Where</th></tr>'
    for blk in r.blocks {
        if (blk.eq)
            continue
        h .= '<tr><td><a href="#' p 'c' blk.n '">Change ' blk.n '</a></td><td>' BlockKind(blk) '</td><td>'
            . RangeText(blk.dels, blk.aPos) '</td><td>' RangeText(blk.ins, blk.bPos) '</td><td>'
            . CodeList(BlockNames(r, blk), 4) '</td></tr>'
    }
    return h '</table>'
}

BlockKind(blk) {
    if (blk.dels.Length && blk.ins.Length)
        return '<span class="kmod">Changed</span>'
    return blk.dels.Length ? '<span class="minus">Only in A</span>' : '<span class="plus">Only in B</span>'
}

RangeText(list, pos) {
    if (!list.Length)
        return "(none - after line " pos ")"
    if (list.Length = 1)
        return "line " list[1]
    return "lines " list[1] "-" list[list.Length] " (" list.Length ")"
}

ChangeHeader(r, blk, p) {
    total := r.stats.changes
    h := '<span class="nav">'
    if (blk.n > 1)
        h .= '<a href="#' p 'c' (blk.n - 1) '">&#9650; prev</a>'
    if (blk.n < total)
        h .= '<a href="#' p 'c' (blk.n + 1) '">next &#9660;</a>'
    h .= '<a href="#' p '">top</a></span>'
    h .= '<b>Change ' blk.n ' of ' total '</b> &nbsp;' BlockKind(blk)
    h .= ' &nbsp;&middot;&nbsp; A: ' RangeText(blk.dels, blk.aPos) ' &nbsp;&middot;&nbsp; B: ' RangeText(blk.ins, blk.bPos)
    names := BlockNames(r, blk)
    if (names.Length)
        h .= ' &nbsp;&middot;&nbsp; in ' CodeList(names, 4)
    return h
}

RenderSideBySide(r, ctxN, p) {
    linesA := r.A.lines, linesB := r.B.lines, blocks := r.blocks, nBlocks := blocks.Length
    h := '<table class="d"><colgroup><col class="cn"><col><col class="cn"><col></colgroup>'
    h .= '<tr><th></th><th>A: ' HtmlEsc(r.relA) '</th><th></th><th>B: ' HtmlEsc(r.relB) '</th></tr>'
    for bi, blk in blocks {
        if (blk.eq) {
            h .= RenderEqRows(r, blk, bi = 1, bi = nBlocks, ctxN, 1)
            continue
        }
        h .= '<tr class="hdr" id="' p 'c' blk.n '"><td colspan="4">' ChangeHeader(r, blk, p) '</td></tr>'
        nd := blk.dels.Length, ni := blk.ins.Length
        loop Max(nd, ni) {
            i := A_Index
            if (i <= nd && i <= ni) {
                la := blk.dels[i], lb := blk.ins[i]
                pr := IntraLine(linesA[la], linesB[lb])
                h .= '<tr><td class="n nd">' la '</td><td class="t cd">' pr[1] '</td><td class="n ni nb">' lb
                    . '</td><td class="t ci">' pr[2] '</td></tr>'
            } else if (i <= nd) {
                la := blk.dels[i]
                h .= '<tr><td class="n nd">' la '</td><td class="t cd">' HtmlEsc(linesA[la])
                    . '</td><td class="n e nb"></td><td class="t e"></td></tr>'
            } else {
                lb := blk.ins[i]
                h .= '<tr><td class="n e"></td><td class="t e"></td><td class="n ni nb">' lb
                    . '</td><td class="t ci">' HtmlEsc(linesB[lb]) '</td></tr>'
            }
        }
    }
    return h '</table>'
}

RenderUnified(r, ctxN, p) {
    linesA := r.A.lines, linesB := r.B.lines, blocks := r.blocks, nBlocks := blocks.Length
    h := '<table class="d"><colgroup><col class="cn"><col class="cn"><col class="cm"><col></colgroup>'
    h .= '<tr><th>A</th><th>B</th><th></th><th>' HtmlEsc(r.rel) '</th></tr>'
    for bi, blk in blocks {
        if (blk.eq) {
            h .= RenderEqRows(r, blk, bi = 1, bi = nBlocks, ctxN, 2)
            continue
        }
        h .= '<tr class="hdr" id="' p 'c' blk.n '"><td colspan="4">' ChangeHeader(r, blk, p) '</td></tr>'
        nd := blk.dels.Length, ni := blk.ins.Length, np := Min(nd, ni)
        pairs := []
        loop np
            pairs.Push(IntraLine(linesA[blk.dels[A_Index]], linesB[blk.ins[A_Index]]))
        loop nd {
            la := blk.dels[A_Index]
            txt := A_Index <= np ? pairs[A_Index][1] : HtmlEsc(linesA[la])
            h .= '<tr class="del"><td class="n">' la '</td><td class="n"></td><td class="m">-</td><td class="t">' txt '</td></tr>'
        }
        loop ni {
            lb := blk.ins[A_Index]
            txt := A_Index <= np ? pairs[A_Index][2] : HtmlEsc(linesB[lb])
            h .= '<tr class="ins"><td class="n"></td><td class="n">' lb '</td><td class="m">+</td><td class="t">' txt '</td></tr>'
        }
    }
    return h '</table>'
}

RenderEqRows(r, blk, isFirst, isLast, ctxN, mode) {
    len := blk.len
    head := isFirst ? 0 : ctxN
    tail := isLast ? 0 : ctxN
    if (ctxN < 0 || head + tail >= len)
        return EqRange(r, blk, 0, len - 1, mode)
    h := ""
    if (head)
        h .= EqRange(r, blk, 0, head - 1, mode)
    hidden := len - head - tail
    a1 := blk.a1 + head, b1 := blk.b1 + head
    h .= '<tr class="gap"><td colspan="4">&#8943; ' hidden ' unchanged line' (hidden = 1 ? "" : "s")
        . ' hidden (A ' a1 '-' (a1 + hidden - 1) ', B ' b1 '-' (b1 + hidden - 1) ') &#8943;</td></tr>'
    if (tail)
        h .= EqRange(r, blk, len - tail, len - 1, mode)
    return h
}

EqRange(r, blk, j1, j2, mode) {
    linesA := r.A.lines, linesB := r.B.lines
    h := ""
    j := j1
    while (j <= j2) {
        la := blk.a1 + j, lb := blk.b1 + j
        txtA := linesA[la], txtB := linesB[lb]
        if (txtA == txtB) {
            hA := HtmlEsc(txtA)
            hB := hA
            cls := ""
        } else {
            ; equal only because of the whitespace / case options
            pr := IntraLine(txtA, txtB)
            hA := pr[1]
            hB := pr[2]
            cls := ' class="ws"'
        }
        if (mode = 1)
            h .= '<tr' cls '><td class="n">' la '</td><td class="t">' hA '</td><td class="n nb">' lb '</td><td class="t">' hB '</td></tr>'
        else
            h .= '<tr' cls '><td class="n">' la '</td><td class="n">' lb '</td><td class="m"></td><td class="t">' hB '</td></tr>'
        j++
    }
    return h
}

RenderEquivalent(r) {
    h := '<p class="msg">These files are equivalent under the current comparison options - no line needs to be ported.</p>'
    if (!IsObject(r.ops))
        return h
    linesA := r.A.lines, linesB := r.B.lines
    rows := "", cnt := 0
    for op in r.ops {
        if (op[1] != 0)
            continue
        txtA := linesA[op[2]], txtB := linesB[op[3]]
        if (txtA == txtB)
            continue
        cnt++
        if (cnt <= 2000) {
            pr := IntraLine(txtA, txtB)
            rows .= '<tr class="ws"><td class="n">' op[2] '</td><td class="t">' pr[1] '</td><td class="n nb">' op[3]
                . '</td><td class="t">' pr[2] '</td></tr>'
        }
    }
    if (cnt) {
        h .= '<p>' cnt ' line' (cnt = 1 ? "" : "s") ' differ only in whitespace or letter case (ignored by your options):</p>'
        h .= '<table class="d"><colgroup><col class="cn"><col><col class="cn"><col></colgroup>'
            . '<tr><th></th><th>A</th><th></th><th>B</th></tr>' rows '</table>'
    } else {
        h .= '<p class="msg">Every line is identical - only the encoding, line endings or final newline differ (see the notes above).</p>'
    }
    return h
}

RenderWholeFile(r) {
    isA := r.status = "OnlyA"
    t := isA ? r.A : r.B
    if (!IsObject(t))
        return ""
    if (t.binary)
        return '<p class="msg">Binary file - content not shown.</p>'
    ctx := isA ? r.ctxA : r.ctxB
    h := '<p class="msg">This file exists only in ' (isA ? "A" : "B") '. Its full content (' t.lines.Length ' lines) is shown below.</p>'
    if (IsObject(ctx) && ctx.defs.Length)
        h .= '<div class="funcs"><b>Defines:</b> ' CodeList(ctx.defs) '</div>'
    cls := isA ? "del" : "ins"
    mark := isA ? "-" : "+"
    h .= '<table class="d"><colgroup><col class="cn"><col class="cm"><col></colgroup>'
    for i, line in t.lines
        h .= '<tr class="' cls '"><td class="n">' i '</td><td class="m">' mark '</td><td class="t">' HtmlEsc(line) '</td></tr>'
    return h '</table>'
}

RenderSummary(forReport) {
    counts := CountStatuses()
    h := '<div class="file" id="summary"><h1>Folder comparison</h1><table class="info">'
    h .= '<tr><th>Folder A</th><td>' HtmlEsc(App.dirA) '</td></tr><tr><th>Folder B</th><td>' HtmlEsc(App.dirB) '</td></tr>'
    h .= '<tr><th>Compared</th><td>' App.when '</td></tr><tr><th>Options</th><td>' HtmlEsc(OptionsText(App.opts)) '</td></tr></table>'
    h .= '<div class="counts">'
    for st in STATUS_LIST {
        if (st = "Error" && !counts.Get(st, 0))
            continue
        h .= '<span class="badge b-' st '">' STATUS_LABEL[st] ': ' counts.Get(st, 0) '</span> '
    }
    h .= '</div>'
    rows := "", diffs := 0
    for r in App.results {
        if (r.status = "Identical")
            continue
        diffs++
        name := HtmlEsc(r.rel)
        if (forReport)
            name := '<a href="#f' r.id '">' name '</a>'
        ch := "", ln := "", fn := ""
        if (IsObject(r.stats) && r.status != "Equivalent") {
            ch := r.stats.changes
            ln := '<span class="minus">-' r.stats.del '</span> &nbsp;<span class="plus">+' r.stats.ins '</span>'
        }
        if (r.status = "Modified")
            fn := CodeList(FileFuncs(r), 10)
        rows .= '<tr><td><span class="badge b-' r.status '">' STATUS_LABEL[r.status] '</span></td><td>' name '</td><td>'
            . ch '</td><td>' ln '</td><td>' fn '</td></tr>'
    }
    if (diffs)
        h .= '<table class="chg"><tr><th>Status</th><th>File</th><th>Changes</th><th>Lines</th><th>Functions / labels touched</th></tr>' rows '</table>'
    else
        h .= '<p class="msg">No differences found - every file is identical.</p>'
    if (!forReport)
        h .= '<p class="msg">Click a file in the list on the left to see its detailed differences.</p>'
    return h '</div>'
}

CodeList(arr, maxN := 0) {
    out := ""
    for i, v in arr {
        if (maxN && i > maxN) {
            out .= ' <i>+' (arr.Length - maxN) ' more</i>'
            break
        }
        out .= (out = "" ? "" : ", ") '<code>' HtmlEsc(v) '</code>'
    }
    return out
}

JoinList(arr, sep) {
    out := ""
    for i, v in arr
        out .= (i = 1 ? "" : sep) v
    return out
}

HtmlEsc(s) {
    s := StrReplace(s, "&", "&amp;")
    s := StrReplace(s, "<", "&lt;")
    s := StrReplace(s, ">", "&gt;")
    s := StrReplace(s, '"', "&quot;")
    return StrReplace(s, "`t", "    ")
}

FmtSize(n) {
    if (n = "")
        return ""
    s := AddCommas(n) " bytes"
    if (n >= 1024)
        s .= " (" Round(n / 1024, 1) " KB)"
    return s
}

AddCommas(n) {
    s := String(n), out := ""
    while (StrLen(s) > 3) {
        out := "," SubStr(s, -3) out
        s := SubStr(s, 1, -3)
    }
    return s out
}

FmtTime(t) {
    return t = "" ? "" : FormatTime(t, "yyyy-MM-dd HH:mm:ss")
}

HtmlPage(title, body) {
    return '<!DOCTYPE html><html><head><meta http-equiv="X-UA-Compatible" content="IE=edge"><meta charset="utf-8"><title>'
        . HtmlEsc(title) '</title><style>' PageCss() '</style></head><body>' body '</body></html>'
}

PageCss() {
    return "
    (
body{font-family:'Segoe UI',Arial,sans-serif;font-size:13px;margin:0;padding:12px 14px;background:#f6f8fa;color:#1f2328}
h1{font-size:20px;margin:0 0 10px}
h2{font-size:16px;margin:0 0 8px;word-wrap:break-word}
a{color:#0969da;text-decoration:none}
a:hover{text-decoration:underline}
a.small{font-size:12px;font-weight:normal}
.file{background:#fff;border:1px solid #d0d7de;border-radius:6px;padding:12px;margin:0 0 18px}
table.info{border-collapse:collapse;margin:6px 0 10px;font-size:12px}
table.info th,table.info td{border:1px solid #d8dee4;padding:3px 8px;text-align:left;vertical-align:top;word-wrap:break-word}
table.info th{background:#f0f3f6}
table.info tr.dv td{background:#fff8c5}
.badge{display:inline-block;padding:1px 8px;border-radius:10px;font-size:12px;color:#fff;background:#6e7781;margin-right:6px;vertical-align:middle}
.b-Modified{background:#bf8700}
.b-Binary{background:#8250df}
.b-OnlyA{background:#cf222e}
.b-OnlyB{background:#1a7f37}
.b-Moved{background:#0969da}
.b-Equivalent{background:#57606a}
.b-Identical{background:#8c959f}
.b-Error{background:#000}
.counts{margin:6px 0 12px}
.counts .badge{font-size:13px;padding:3px 10px}
ul.notes{margin:4px 0 10px;padding-left:20px;color:#9a6700}
.msg{color:#57606a;font-style:italic}
.sum{margin:8px 0}
.minus{color:#cf222e;font-weight:bold}
.plus{color:#1a7f37;font-weight:bold}
.kmod{color:#9a6700;font-weight:bold}
.funcs{margin:6px 0 10px;line-height:1.9}
code{font-family:Consolas,'Courier New',monospace;background:#eff1f3;padding:1px 4px;border-radius:3px;font-size:12px}
table.chg{border-collapse:collapse;margin:4px 0 14px;font-size:12px}
table.chg th,table.chg td{border:1px solid #d8dee4;padding:3px 8px;text-align:left;vertical-align:top}
table.chg th{background:#f0f3f6}
table.d{border-collapse:collapse;width:100%;table-layout:fixed;font-family:Consolas,'Courier New',monospace;font-size:12px;border:1px solid #d0d7de;background:#fff}
table.d col.cn{width:52px}
table.d col.cm{width:18px}
table.d th{font-family:'Segoe UI',Arial,sans-serif;font-size:12px;text-align:left;background:#f0f3f6;padding:4px 6px;border-bottom:1px solid #d0d7de;word-wrap:break-word}
table.d td{padding:0 6px;vertical-align:top;white-space:pre-wrap;word-wrap:break-word;line-height:17px;height:17px}
td.n{text-align:right;color:#8c959f;background:#f6f8fa;border-right:1px solid #e1e4e8}
td.nb{border-left:2px solid #d0d7de}
td.m{text-align:center;font-weight:bold}
td.cd,tr.del td.t{background:#ffebe9}
td.ci,tr.ins td.t{background:#dafbe1}
td.nd,tr.del td.n,tr.del td.m{background:#ffcecb;color:#82071e}
td.ni,tr.ins td.n,tr.ins td.m{background:#aceebb;color:#116329}
td.e{background:#eceff2}
tr.ws td.t{background:#fff8c5}
span.dc{background:#ff9e9a;border-radius:2px}
span.ic{background:#6fdd8b;border-radius:2px}
tr.gap td{background:#ddf4ff;color:#57606a;text-align:center;font-family:'Segoe UI',Arial,sans-serif;font-style:italic;height:22px;line-height:22px}
tr.hdr td{background:#eaeef2;color:#1f2328;font-family:'Segoe UI',Arial,sans-serif;font-size:12px;padding:5px 8px;border-top:2px solid #afb8c1;white-space:normal;height:auto}
.nav{float:right}
.nav a{margin-left:12px}
.legend td{padding:3px 8px}
    )"
}

WelcomeHtml() {
    body := '<div class="file"><h1>AHK Folder Diff</h1>'
        . '<ol><li>Choose <b>Folder A</b> and <b>Folder B</b> (Browse, paste a path, or drag folders onto the window).</li>'
        . '<li>Press <b>Compare</b> (or F5).</li>'
        . '<li>Click a file in the list on the left to see a detailed line-by-line and word-by-word comparison.</li>'
        . '<li>Use <b>Export HTML report</b> to save every difference into one file you can keep or share.</li></ol>'
        . '<h2>File status</h2><table class="info legend">'
        . '<tr><td><span class="badge b-Modified">Modified</span></td><td>Exists in both folders, content differs.</td></tr>'
        . '<tr><td><span class="badge b-OnlyA">Only in A</span></td><td>File exists only in Folder A.</td></tr>'
        . '<tr><td><span class="badge b-OnlyB">Only in B</span></td><td>File exists only in Folder B.</td></tr>'
        . '<tr><td><span class="badge b-Moved">Moved / renamed</span></td><td>Same content, different path or name.</td></tr>'
        . '<tr><td><span class="badge b-Equivalent">Equivalent</span></td><td>Only differs in things your options ignore (whitespace, case, line endings, encoding).</td></tr>'
        . '<tr><td><span class="badge b-Binary">Binary differs</span></td><td>Non-text file with different content.</td></tr>'
        . '<tr><td><span class="badge b-Identical">Identical</span></td><td>Byte-for-byte the same (hidden unless "Show identical files" is ticked).</td></tr></table>'
        . '<h2>Colors in the diff</h2><table class="d" style="width:auto"><colgroup><col class="cn"><col style="width:520px"></colgroup>'
        . '<tr><td class="n nd">12</td><td class="t cd">Line that is only in A (or the A version of a changed line)</td></tr>'
        . '<tr><td class="n ni">12</td><td class="t ci">Line that is only in B (or the B version of a changed line)</td></tr>'
        . '<tr><td class="n nd">40</td><td class="t cd">MsgBox <span class="dc">"Group 1"</span></td></tr>'
        . '<tr><td class="n ni">40</td><td class="t ci">MsgBox <span class="ic">"Group 2"</span>   (strong color = the exact words that changed)</td></tr>'
        . '<tr class="ws"><td class="n">7</td><td class="t">Yellow = differs only in whitespace or case (ignored by your options)</td></tr>'
        . '<tr class="gap"><td colspan="2">&#8943; unchanged lines hidden - pick a bigger Context to see more &#8943;</td></tr></table>'
        . '<p>Every change shows which <b>function, class, label, hotkey or hotstring</b> it is in, so you can quickly decide '
        . 'whether it needs to be copied to the other version. Right-click a file in the list to open either version in your editor.</p></div>'
    return HtmlPage(APP_TITLE, body)
}

; ==============================================================================
;  Export / clipboard
; ==============================================================================

ExportReport() {
    if (!App.results.Length) {
        MsgBox("Run a comparison first.", APP_TITLE, "Icon!")
        return
    }
    path := FileSelect("S16", A_Desktop "\FolderDiff_" FormatTime(, "yyyyMMdd_HHmm") ".html", "Save HTML report", "HTML files (*.html)")
    if (path = "")
        return
    if !RegExMatch(path, "i)\.html?$")
        path .= ".html"
    opts := GetOptions()
    body := RenderSummary(true)
    identical := []
    n := 0
    for r in App.results {
        if (r.status = "Identical") {
            identical.Push(r.rel)
            continue
        }
        n++
        SetStatus("Building report: " n " - " r.rel)
        body .= RenderFile(r, opts, "f" r.id, true)
    }
    if (identical.Length) {
        body .= '<div class="file"><h2>Identical files (' identical.Length ')</h2><p>'
        for rel in identical
            body .= HtmlEsc(rel) '<br>'
        body .= '</p></div>'
    }
    WriteUtf8(path, HtmlPage("Folder comparison report", body))
    SetStatus("Report saved: " path)
    Run(path)
}

CopyUnified(id) {
    if (!id) {
        MsgBox("Select a file in the list first.", APP_TITLE, "Icon!")
        return
    }
    r := App.results[id]
    EnsureLoaded(r)
    if (r.status != "Modified" && r.status != "OnlyA" && r.status != "OnlyB") {
        MsgBox("This file has no line differences to copy.", APP_TITLE, "Iconi")
        return
    }
    if ((r.status = "OnlyA" && r.A.binary) || (r.status = "OnlyB" && r.B.binary)) {
        MsgBox("Binary file - nothing to copy.", APP_TITLE, "Iconi")
        return
    }
    A_Clipboard := UnifiedText(r, 3)
    SetStatus("Unified diff of " r.rel " copied to the clipboard.")
}

UnifiedText(r, ctxN) {
    linesA := IsObject(r.A) ? r.A.lines : []
    linesB := IsObject(r.B) ? r.B.lines : []
    blocks := r.blocks
    if (r.status = "OnlyA")
        blocks := [{eq: false, dels: Range(linesA.Length), ins: [], aPos: 0, bPos: 0}]
    else if (r.status = "OnlyB")
        blocks := [{eq: false, dels: [], ins: Range(linesB.Length), aPos: 0, bPos: 0}]

    ; flatten into [type, lineA, lineB, linesOfABefore, linesOfBBefore]
    items := [], pa := 0, pb := 0
    for blk in blocks {
        if (blk.eq) {
            loop blk.len {
                items.Push([0, blk.a1 + A_Index - 1, blk.b1 + A_Index - 1, pa, pb])
                pa++
                pb++
            }
        } else {
            for la in blk.dels {
                items.Push([1, la, 0, pa, pb])
                pa++
            }
            for lb in blk.ins {
                items.Push([2, 0, lb, pa, pb])
                pb++
            }
        }
    }
    n := items.Length
    keep := []
    keep.Capacity := n
    loop n
        keep.Push(false)
    for i, it in items {
        if (it[1] = 0)
            continue
        j := Max(1, i - ctxN)
        while (j <= Min(n, i + ctxN)) {
            keep[j] := true
            j++
        }
    }
    out := "--- " (r.relA = "" ? "/dev/null" : "a/" StrReplace(r.relA, "\", "/")) "`n"
    out .= "+++ " (r.relB = "" ? "/dev/null" : "b/" StrReplace(r.relB, "\", "/")) "`n"
    i := 1
    while (i <= n) {
        if (!keep[i]) {
            i++
            continue
        }
        j := i
        while (j <= n && keep[j])
            j++
        cntA := 0, cntB := 0, body := ""
        k := i
        while (k < j) {
            it := items[k]
            switch it[1] {
                case 0:
                    cntA++
                    cntB++
                    body .= " " linesA[it[2]] "`n"
                case 1:
                    cntA++
                    body .= "-" linesA[it[2]] "`n"
                case 2:
                    cntB++
                    body .= "+" linesB[it[3]] "`n"
            }
            k++
        }
        first := items[i]
        startA := cntA ? first[4] + 1 : first[4]
        startB := cntB ? first[5] + 1 : first[5]
        where := CtxName(r.ctxA, first[4] + 1)
        if (where = "")
            where := CtxName(r.ctxB, first[5] + 1)
        out .= "@@ -" startA "," cntA " +" startB "," cntB " @@" (where != "" ? " " where : "") "`n" body
        i := j
    }
    return StrReplace(out, "`n", "`r`n")
}

Range(n) {
    arr := []
    loop n
        arr.Push(A_Index)
    return arr
}
