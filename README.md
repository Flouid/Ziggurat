# Ziggurat
A GUI-based text editor written in zig. Mainly intended as a learning project and ideally skills demo.

The name isn't that meaningful, just a play on zig and the idea of building functionality in solid discrete layers. The hope is that most components are well built and self-sufficient enough to be viable as standalone imports to other projects. 

# Layer 1: Text Engine

This is mostly complete at this point, pending correctness tests. It's a single module called PieceTable which implements an optimized data structure for storing text documents in memory.

## Limitations

1. At the moment it supports whatever file size your system is capable of. There are plans to restrict this to 32bit (4 GB) max to further optimize performance.
2. Not thoroughly tested, but it makes some assumptions about UTF-8 encoding. There is no guarantee it will work with multi-character bytes. In fact it probably wont.

## Implementation

Built in layers. 

1. The top layer is a [piece table](https://dev.to/_darrenburns/the-piece-table---the-unsung-hero-of-your-text-editor-al8/comments) --- a fantastic scheme for storing edits as a collection of "pieces." A naive implementation for the pieces is an array or list, but random edits become O(n) in the number of pieces --- prohibitively slow for large numbers of writes. A version of the core engine built with this simple scheme exists at `src/core/piece_table_old.zig` for correctness verification.
2. The next layer is a [rope](https://en.wikipedia.org/wiki/Rope_(data_structure)) implemented as a b-tree. This turns edits from O(n) to O(log n) with some large base (32-64). This along should make the engine fast enough for all uses cases given the file size limitation (A worst case edit should take < 500 operations as opposed to 4+ billion), but that's not the theoretical end.
3. Final layer would be a gap-buffer in each leaf of the tree. This adds another level of optimization, but no attempt to implement it exists at this time. Maybe later.

## Instructions

`PieceTable` objects will expose a public API with 5 methods:

1. `init` - takes an allocator and initial text.
2. `deinit` - destroys the table.
3. `insert` - takes an index corresponding to the location in the working document and a string to insert there.
4. `delete` - takes an index corresponding to the location in the working document and a length of characters to delete.
5. `writeWith` - takes an arbitrary writer and materializes the working document into it.

# Layer 2: Testing Harness and Fixture Generation

Still in progress, but this project comes bundled with a robust testing suite. 

## Instructions

1. If you want to perform testing, start by making a folder called `fixtures` in the project root (or whatever you want, you supply the paths here).
2. On Unix systems, `base64 /dev/urandom | head -c 10M > large_utf8_file.txt` will generate a 10 MB file of UTF-8 text to use as a starting point.
3. Assuming the project is built, `./zig-out/bin/fixture-generator` provides a CLI for generating test fixtures for various scenarios.
4. Running it with no arguments provides the usage pattern: `usage: ./zig-out/bin/fixture-generator <path> <insert %> <long %> <# ops> <name>`. 
    - `<path>` is the path to the input file
    - `<insert %>` is the `[0, 100]` percentage of operations which should be random inserts, the rest will be random deletes.
    - `<long %>` is the `[0, 100]` percentage of operations which should very long, simulating copy/pasting large chunks in/out.
    - `<# ops>` is the number of operations to perform on the input document.
    - `<name>` is the path to the output test fixture.
4. As an example: `./zig-out/bin/fixture-generator ./fixtures/large_utf8_file.txt 50 5 100000 ./fixtures/mixed_test.txt` performs a balanced 50/50 split of 100,000 insert/delete operations on `large_utf8_file.txt`, 5% of which will be long. The resulting test fixture is stored in `mixed_test.txt`. Performance metrics and progress will be printed to the console as well. Using the reference implementation this is quite slow.

Soon™ there will be a testing harness which reads these fixtures and uses the stored output as a reference to compare the faster rope-based implementation with.

# Roadmap

1. Finish testing suite, verify that the faster piece table implementation is correct.
2. Maybe implement gap buffers? I'll see from the performance metrics if that's really necessary.
3. Downgrade from `usize` to `u32`, see if that increases performance. Maybe some more data-oriented design optimizations.
4. Start writing a GUI! --- exact feature set TBD.
5. More advanced text editor features like undo/redo, copy/paste etc.
6. Maybe more? I don't really have a set end goal for this project. 