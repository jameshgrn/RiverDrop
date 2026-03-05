import Testing
@testable import RiverDrop

@Suite("parseDryRunLine")
struct DryRunLineTests {

    @Test("empty line returns nil")
    func emptyLine() {
        #expect(parseDryRunLine("") == nil)
        #expect(parseDryRunLine("   ") == nil)
    }

    @Test("short line returns nil")
    func shortLine() {
        #expect(parseDryRunLine("abc") == nil)
        #expect(parseDryRunLine("short") == nil)
    }

    @Test("*deleting line produces .deleted entry")
    func deletingLine() {
        let entry = parseDryRunLine("*deleting   some/path/file.txt")
        #expect(entry != nil)
        #expect(entry?.path == "some/path/file.txt")
        #expect(entry?.change == .deleted)
        #expect(entry?.size == 0)
    }

    @Test("*deleting with no filename returns nil")
    func deletingNoFilename() {
        #expect(parseDryRunLine("*deleting   ") == nil)
    }

    @Test("itemize with +++++++++ is .added")
    func itemizeAdded() {
        // Format: 11-char itemize + space + size + space + filename
        let line = ">f+++++++++ 1234 newfile.txt"
        let entry = parseDryRunLine(line)
        #expect(entry != nil)
        #expect(entry?.change == .added)
        #expect(entry?.size == 1234)
        #expect(entry?.path == "newfile.txt")
    }

    @Test("itemize without +++++++++ is .modified")
    func itemizeModified() {
        let line = ">f.st...... 5678 changed.txt"
        let entry = parseDryRunLine(line)
        #expect(entry != nil)
        #expect(entry?.change == .modified)
        #expect(entry?.size == 5678)
        #expect(entry?.path == "changed.txt")
    }

    @Test("directory entry (fileType d) with +++++++++ is .added")
    func directoryAdded() {
        let line = ".d+++++++++ 0 newdir/"
        let entry = parseDryRunLine(line)
        #expect(entry != nil)
        #expect(entry?.change == .added)
        #expect(entry?.path == "newdir/")
        #expect(entry?.size == 0)
    }

    @Test("directory entry without +++++++++ is .modified")
    func directoryModified() {
        let line = ".d..t...... 0 existingdir/"
        let entry = parseDryRunLine(line)
        #expect(entry != nil)
        #expect(entry?.change == .modified)
        #expect(entry?.path == "existingdir/")
        #expect(entry?.size == 0)
    }

    @Test("invalid size returns nil for file entries")
    func invalidSize() {
        let line = ">f.st...... notanumber file.txt"
        #expect(parseDryRunLine(line) == nil)
    }

    @Test("missing filename part returns nil")
    func missingFilename() {
        // Only itemize prefix + size, no space + filename
        let line = ">f.st...... 1234"
        #expect(parseDryRunLine(line) == nil)
    }
}

@Suite("parseDryRunOutput")
struct DryRunOutputTests {

    @Test("empty output produces empty result")
    func emptyOutput() {
        let result = parseDryRunOutput("")
        #expect(result.added.isEmpty)
        #expect(result.modified.isEmpty)
        #expect(result.deleted.isEmpty)
        #expect(result.isEmpty)
    }

    @Test("mixed output is categorized correctly")
    func mixedOutput() {
        let output = """
        >f+++++++++ 100 new.txt
        >f.st...... 200 mod.txt
        *deleting   old.txt
        >f+++++++++ 300 another_new.txt
        """
        let result = parseDryRunOutput(output)
        #expect(result.added.count == 2)
        #expect(result.modified.count == 1)
        #expect(result.deleted.count == 1)
        #expect(result.totalFiles == 4)
    }

    @Test("totalBytes sums added and modified sizes")
    func totalBytes() {
        let output = """
        >f+++++++++ 100 a.txt
        >f.st...... 200 b.txt
        *deleting   c.txt
        """
        let result = parseDryRunOutput(output)
        #expect(result.totalBytes == 300)
    }

    @Test("invalid lines are silently skipped")
    func invalidLinesSkipped() {
        let output = """
        >f+++++++++ 100 good.txt
        this is garbage
        short

        >f.st...... 200 also_good.txt
        """
        let result = parseDryRunOutput(output)
        #expect(result.totalFiles == 2)
    }
}
