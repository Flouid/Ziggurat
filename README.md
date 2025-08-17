# Ziggurat
A GUI-based text editor written in zig. Mainly intended as a learning project and ideally skills demo.

The name isn't that meaningful, just a play on zig and the idea of building functionality in solid discrete layers. The hope is that most components are well built and self-sufficient enough to be viable as standalone imports to other projects. 

## Layer 1: Text Buffer

This is more or less complete. In release mode, it will perform 100,000 mixed random operations of varying lengths on large files in ~15-20ms. It can materialize full documents in the 10MB range in 5ms. It's highly portable, with no dependencies other than zig itself. You could deploy this on a microcontroller, though I probably wouldn't recommend it since it relies heavily on the heap. 

### Limitations

1. Maximum file size is limited to half of your system's virtual address space. That's 2GB on 32bit systems, irrelevant on 64bit systems. 

### Features

1. Line-aware: Newlines are meticulously and performantly tracked. It exposes methods for translating back and forth between document index and line number.
2. Arbitrary views: Given an index and a length, get a read-only view into the document as an iterable over slices of text.
3. Lightning fast insertion and deletion operations anywhere in the document. 
4. Generic writer interface for any view or the entire document. 
5. Standalone: If you don't care about line/column abstractions use this on it's own.

## Testing Harness and Fixture Generation

The build script will output an executable CLI called `test-engine`. Running this with no args will produce some example usage to help get you started. This tool has two uses:

1. Generating test fixtures.
2. Benchmarking the text engine. 

These functions are accessed via different sets of CLI arguments, and there's a shortcut for running all existing test fixtures as benchmarks in succession. Very handy for profiling different workloads. 

## Roadmap

1. Start writing a GUI! --- exact feature set TBD.
2. More advanced text editor features like undo/redo, copy/paste etc.
3. Maybe more? I don't really have a set end goal for this project. 