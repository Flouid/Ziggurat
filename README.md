# Ziggurat
A GUI-based text editor written in zig. Mainly intended as a learning project and ideally skills demo.

The name isn't that meaningful, just a play on zig and the idea of building functionality in solid discrete layers. The hope is that most components are well built and self-sufficient enough to be viable as standalone imports to other projects. 

Currently, it's in a bare-minimum viable v0 form. However, the core functionality it present.

## Build Process

By default, the build script produces 4 binaries:

Two targets:
- Whatever system you build on
- x86_64 Windows

Don't ask me what happens if your system *is* x86_64 windows, I don't know.

Two programs:
- `Ziggurat`: the actual text editor
- `test-engine`: a CLI for testing and benchmarking the underlying text buffer

## Features

- Supports keyboard navigation with arrow keys + home/end
- Supports generic typing + backspace
- If launched with no command-line args, it opens an empty scratch document
- If launched via CLI with `Ziggurat.exe <file_path>` it will open that text file for editing or create one
- When working on a named file, `ctrl-s` saves and overwrites the opened file
- `ctrl-d` exits
- Dynamic resizing
- Cursor clamping, cursor will always remain visible

## Limitations

- No mouse support
- No selection/highlight
- No undo/redo
- No file renaming
- No scaling or font support
- No text wrapping

![alt text](image.png)