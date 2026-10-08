# AHK Folder Diff

An AutoHotkey v2 tool that compares two folders, typically two variants of the same
AutoHotkey project for different user groups, and shows exactly what differs between them.

## Running it

1. Install [AutoHotkey v2](https://www.autohotkey.com/).
2. Double-click `AhkFolderDiff.ahk`.
3. Pick **Folder A** and **Folder B**. You can browse, paste a path, or drag folders onto the window.
4. Press **Compare** (or F5).
5. Click a file in the list to see its differences on the right.

The folders, filters and options you last used are saved to `AhkFolderDiff.ini` next to the script.

## What it shows

**File list**: every file is given one of these statuses:

| Status | Meaning |
| --- | --- |
| Modified | In both folders, content differs |
| Only in A / Only in B | Added or removed files (their full content is shown) |
| Moved / renamed | Byte-identical file found at a different path |
| Equivalent | Only differs in things you chose to ignore (whitespace, case), or in line endings / encoding |
| Binary differs | Non-text file with different content |
| Identical | Byte-for-byte the same (hidden unless "Show identical files" is ticked) |

**Per-file view**:

- File info for A and B side by side: size, last-modified date (with the newer one marked),
  line count, encoding (UTF-8, UTF-8 BOM, UTF-16, ANSI), line endings (CRLF/LF/mixed) and
  whether the file ends with a newline. Values that differ are highlighted.
- A list of all **functions, classes, labels, hotkeys, hotstrings and `#HotIf` sections** that
  were touched.
- A table of every change with its line ranges in A and B and where in the script it is.
- Side-by-side (or unified) diff with line numbers. Changed lines are paired up and the exact
  **words / characters that changed are highlighted**. Each change has prev / next links.
- Lines that differ only in whitespace or case (when you ignore those) are shown in yellow, so
  nothing is hidden from you.

**Options**

- *Include files* / *Exclude*: `;`-separated wildcards, e.g. `*.ahk;*.ini` and `.git;*.bak`.
  Exclude patterns match file names and folder names.
- *Whitespace*: compare exactly, ignore trailing whitespace, ignore changes in amount of
  whitespace, or ignore all whitespace. *Ignore case* is also available.
- *Context*: how many unchanged lines to show around each change (0, 3, 5, 10, 25 or the whole file).
- *View*: side by side or unified.

**Extras**

- **Export HTML report**: one HTML file with a summary table plus the full detail of every
  differing file (linked from the summary). It opens in your normal browser.
- **Open view in browser**: opens the currently displayed file diff in your normal browser.
- **Copy unified diff**: copies a standard `diff -u` / patch-style text of the selected file.
- Right-click a file: open the A or B version in your editor, show it in Explorer, copy a
  diff or copy its path.
