// Posts one QA command to a running Flamingo started with FLAMINGO_DEBUG=1, as a distributed
// notification: `qa-post <channel> <command…>`, e.g. `qa-post qa.radial.1 flags cmd opt`.
// The channel is the app's FLAMINGO_QA_CHANNEL (default com.flamingo.qa). See QAHook.swift.
// Usage: qa-post [channel] command…   (compiled to build/qa-post; see scripts/radial-qa.sh)
import Foundation

let args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 2 else {
    FileHandle.standardError.write(Data("usage: qa-post <channel> <command…>\n".utf8))
    exit(2)
}
DistributedNotificationCenter.default().postNotificationName(
    Notification.Name(args[0]), object: args.dropFirst().joined(separator: " "),
    userInfo: nil, deliverImmediately: true)
// Give the notification daemon a moment to take the post before the process exits.
RunLoop.current.run(until: Date().addingTimeInterval(0.05))
