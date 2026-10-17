# VB6 → Free Pascal / Lazarus cheat sheet

For porting a Visual Basic 6 project to Free Pascal with Lazarus. Work leaf unit by leaf unit, keep each one compiling, and let the compiler judge.
Start from UTF-8 copies of the sources (the originals are Windows-1252, or Windows-1255 for Hebrew), never from the originals.

## Types

| VB6 | Free Pascal | Watch |
|-----|-------------|-------|
| `Integer` (16-bit) | `SmallInt` (`Integer` in FPC's default mode is 16-bit, in `{$mode objfpc}`/`delphi` it is 32-bit: use `SmallInt` to be explicit) | overflow behaves differently: VB6 raises an error |
| `Long` | `LongInt` | |
| `Single`, `Double` | `Single`, `Double` | |
| `Currency` | `Currency` | both are 64-bit fixed point with 4 decimals: a true match |
| `Byte` | `Byte` | |
| `Boolean` | `Boolean` (True = 1) | **VB6 True = -1**: `CInt(True)` is -1, `Not True` works bitwise. Use `LongBool` when the value goes to the Windows API or is stored |
| `String` | `String` (UTF-8 in Lazarus) or `AnsiString` | VB6 strings are UTF-16 internally and **1-based**; in Lazarus `String` indexes are 1-based too, but Hebrew text is multi-byte: use `LazUTF8` (`UTF8Length`, `UTF8Copy`, `UTF8Pos`) |
| `Date` | `TDateTime` | same epoch (30 Dec 1899) and a Double: a true match |
| `Variant` | `Variant` | `Empty`/`Null` → `Unassigned`/`Null`; avoid it in the port where the real type is known |
| `Object` | `TObject` / `IDispatch` (for COM, `Variant` + `CreateOleObject`, Windows only) | |

## Operators and expressions

- `\` integer division → `div`; `Mod` → `mod`; `^` → `Power` (unit `Math`); `&` concatenation → `+`.
- `And`, `Or`, `Not`, `Xor` are **bitwise on integers** in both languages, but VB6 does **not short-circuit**: `If a And b` evaluates both. Pascal short-circuits by default (`{$B-}`). Check conditions with side effects.
- `Like` → no operator: `MatchesMask` (unit `Masks`) for `*`/`?`, or a regular expression (`RegExpr`).
- `Is Nothing` → `= nil`. `TypeOf x Is T` → `x is T`.
- Rounding: VB6 `Round` and FPC `Round` are both banker's rounding (half to even); `Format()` and `CInt` differ: check.
- Integer overflow: VB6 raises error 6; FPC wraps silently unless `{$Q+}` (overflow checks) is on.

## Control flow

- `If … Then … ElseIf … Else … End If` → `if … then … else if …`. `Select Case x` → `case x of` (ranges `1 To 5` → `1..5`; `Is > 5` has no equivalent, use `if`; strings are allowed in FPC `case`).
- `For i = a To b Step s` → `for i := a to b do` (step 1 only; other steps → `while`). `Exit For` → `Break`; `Exit Do` → `Break`; `Exit Sub/Function` → `Exit`.
- `Do While … Loop` → `while … do`; `Do … Loop Until c` → `repeat … until c`.
- `With obj … End With` → `with obj do begin … end`.
- `GoTo label` → `label`/`goto` (avoid: restructure). `GoSub` → turn the subroutine into a procedure.

## Errors

- `On Error Resume Next` → wrap the statements in `try … except end;` (a bare `except` swallows) and **check each place**: the VB6 code continues after *every* failing line.
- `On Error GoTo Handler` → `try … except on E: Exception do begin … end; end;`. `Err.Number` / `Err.Description` → `E.ClassName` / `E.Message`. `Err.Raise` → `raise Exception.Create(...)`.
- `Resume` / `Resume Next` inside a handler have no equivalent: restructure.

## Strings (1-based, like Pascal)

| VB6 | Pascal |
|-----|--------|
| `Len(s)` | `Length(s)` (`UTF8Length` for Hebrew) |
| `Left(s, n)` / `Right(s, n)` | `Copy(s, 1, n)` / `Copy(s, Length(s) - n + 1, n)` |
| `Mid(s, p, n)` | `Copy(s, p, n)`; the `Mid(s, p, n) = x` **statement** → `Delete` + `Insert` |
| `InStr(s, t)` (returns 0 if absent) | `Pos(t, s)` — **arguments are reversed** |
| `UCase` / `LCase` | `UpperCase` / `LowerCase` (`UTF8UpperCase` for non-ASCII) |
| `Trim` / `LTrim` / `RTrim` | `Trim` / `TrimLeft` / `TrimRight` |
| `Replace(s, a, b)` | `StringReplace(s, a, b, [rfReplaceAll])` |
| `Split(s, ",")` / `Join` | `TStringList` with `Delimiter`, `StrictDelimiter`, `DelimitedText` |
| `Chr(n)` / `Asc(c)` | `Chr(n)` / `Ord(c)` (ANSI codes: for code page 1255 text use `UTF8ToCP1255` / `ConvertEncoding`) |
| `Space(n)` / `String(n, c)` | `StringOfChar(c, n)` |
| `Format(x, "0.00")` | `FormatFloat('0.00', x)`; dates: `FormatDateTime('yyyy-mm-dd', d)` |
| `CStr`, `CInt`, `CLng`, `CDbl`, `Val` | `IntToStr`/`FloatToStr`, `StrToInt`, `StrToFloat`, `StrToFloatDef` (VB6 `Val` never raises: use the `Def` forms) |

## Arrays

- `Dim a(10) As Integer` has **11 elements** (0 to 10); Pascal `array[0..10]` too, but `array[10]` is not valid. `Option Base 1` → `array[1..N]`.
- `ReDim a(n)` → `SetLength(a, n + 1)`; `ReDim Preserve` → the same (`SetLength` keeps the contents). `LBound`/`UBound` → `Low`/`High`.
- Control arrays on forms (`Text1(0)`, `Text1(1)`) have no direct equivalent: create the controls in code and keep them in a `TList`/array.

## Files

| VB6 | Pascal |
|-----|--------|
| `Open f For Input As #1` / `Line Input #1, s` / `Close #1` | `AssignFile(F, f); Reset(F); ReadLn(F, s); CloseFile(F)` |
| `Open f For Output` / `Print #1, s` | `Rewrite(F)` / `WriteLn(F, s)` |
| `Open f For Append` | `Append(F)` |
| `Open f For Binary` / `Get` / `Put` | `TFileStream` |
| `EOF(1)` / `FreeFile` | `Eof(F)` / use a variable per file |
| `Dir`, `Kill`, `MkDir`, `FileCopy` | `FindFirst`, `DeleteFile`, `CreateDir`, `CopyFile` (`FileUtil`) |
| `App.Path` | `ExtractFilePath(ParamStr(0))`; `\` → `PathDelim` |
| `GetSetting` / `SaveSetting`, the registry | `TIniFile` (cross-platform) or `TRegistry` (Windows only) |

## Forms and controls

| VB6 | Lazarus |
|-----|---------|
| `Form_Load` | `FormCreate` / `FormShow`; `Form_Unload` → `FormClose`; `Me` → `Self`; `Unload Me` → `Close` |
| `TextBox` / `Label` / `CommandButton` | `TEdit` (`TMemo` if multi-line) / `TLabel` / `TButton` |
| `ListBox` / `ComboBox` | `TListBox` / `TComboBox` (`.List` → `.Items`, `.ListIndex` → `.ItemIndex`, `.AddItem` → `.Items.Add`) |
| `CheckBox` / `OptionButton` / `Frame` | `TCheckBox` (`.Value` → `.Checked`) / `TRadioButton` / `TGroupBox` |
| `Timer` | `TTimer` (`Interval`, `Enabled`; `OnTimer`) |
| `PictureBox` / `Image` | `TPaintBox` or `TImage` |
| `MSFlexGrid` / `DataGrid` | `TStringGrid` / `TDBGrid` |
| `MsgBox` / `InputBox` | `MessageDlg` or `ShowMessage` / `InputBox` |
| `CommonDialog` | `TOpenDialog`, `TSaveDialog`, `TColorDialog`, `TFontDialog` |
| Events `_Click`, `_Change`, `_KeyPress`, `_KeyDown`, `_MouseDown`, `_Resize` | `OnClick`, `OnChange`, `OnKeyPress`, `OnKeyDown`, `OnMouseDown`, `OnResize` |
| `.frm` + `.frx` | `.lfm` + `.pas` (the `.frx` holds pictures and long strings: extract them to files) |
| `Left`, `Top`, `Width`, `Height` in **twips** (1440 per inch) | pixels: divide by 15 at 96 dpi, or lay out with anchors and `Align` |
| `Caption` on a form / button | `Caption` (same) |
| Right-to-left forms (`RightToLeft = True`, font `Charset 177`) | `BiDiMode := bdRightToLeft`, UTF-8 text, a font with Hebrew glyphs |

## Database and the rest

- `ADODB.Connection` / `Recordset`, `DAO` → `SQLdb` (`TSQLConnection`, `TSQLQuery`, `TSQLTransaction`) with a driver for the database (SQLite, Firebird, MySQL, ODBC). Parameter syntax changes (`?` → `:name`).
- `CreateObject("Scripting.FileSystemObject")` → `SysUtils`/`FileUtil`; `CreateObject("Excel.Application")` → Windows-only OLE automation (`comobj`, `Variant`) or LibreOffice; `Scripting.Dictionary` → `TFPGMap` / `TDictionary`.
- `Shell` → `TProcess` (unit `Process`) or `ExecuteProcess`; `SendKeys` has no portable equivalent.
- `DoEvents` → `Application.ProcessMessages`.
- `Declare Function … Lib "user32"` → `function Name(…): …; stdcall; external 'user32.dll';` in a Windows-only unit (`{$IFDEF WINDOWS}`), or replace with the LCL/RTL call.
- Third-party OCX controls: no drop-in. Find a Lazarus component, or write the behaviour.
- Classes: `Class_Initialize` / `Class_Terminate` → `constructor Create` / `destructor Destroy`; `Property Get/Let/Set` → `property X: T read GetX write SetX`; `Implements` → `interface`; `Public Event` / `RaiseEvent` → a method pointer property (`property OnX: TNotifyEvent`).
- `Set obj = New Class` → `obj := TClass.Create` (**and free it**: Pascal has no reference counting for classes).

## Checking the port

1. After each unit: build with the Lazarus tool; read the errors; fix; repeat.
2. Compare behaviour on a few inputs with the VB6 program, especially numbers (rounding, overflow), dates, and Hebrew text (length, sorting, case).
3. Keep a list of the places listed under "things to watch" in the inventory and tick them off.
