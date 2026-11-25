import Foundation

let arguments = CommandLine.arguments.dropFirst()
if arguments.contains("-h") || arguments.contains("--help") {
    print(Timeline.usage)
    exit(0)
}
if !arguments.isEmpty {
    FileHandle.standardError.write(Data("session-timeline: unexpected argument\n\(Timeline.usage)\n".utf8))
    exit(2)
}
let result = Timeline.render(FileHandle.standardInput.readDataToEndOfFile())
FileHandle.standardOutput.write(Data(result.out.utf8))
FileHandle.standardError.write(Data(result.err.utf8))
exit(result.status)
