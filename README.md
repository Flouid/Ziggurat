# Ziggurat
A blazingly fast GUI-based text editor written in Zig. Meant to do everything that notepad does, but better.

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

## Features and Usage

- Smoothly opens, edits, and saves multi-GB files
- Supports all standard mouse + keyboard navigation
- If launched with no command-line args, it opens an empty unsavable scratch document
- If launched via CLI with `Ziggurat.exe <file_path>` it will open that text file for editing or create one
- Save with `ctrl-s` and exit with `ctrl-d`

## Limitations

Each of these is being addressed on the way to v1. 

- No undo/redo
- No file renaming
- No scaling or font support
- No text wrapping
- ASCII only, for now

![alt text](image.png)