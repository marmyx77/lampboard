import Foundation
import LampBoardCore

/// Into the box of a session on another machine, over ssh (the bridge, B3):
/// `RemotePeerScripts` there finds the box and writes to it. Blocking: call it
/// off the main actor.
enum RemotePeerSender {

    static func send(content: String, to session: String, on host: String) -> Result<Void, RemoteCommandError> {
        guard RemoteHostList.isUsable(host) else { return .failure(.badAnswer("not a host name ssh can take")) }
        guard let payload = RemotePeerScripts.payload(session: session, content: content),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        else { return .failure(.badAnswer("nothing to send, or too much")) }
        return RemoteCommand.runPythonForObject(
            on: host, script: RemotePeerScripts.send(payloadBase64: data.base64EncodedString())
        ).flatMap { result in
            (result["ok"] as? Bool) == true
                ? .success(())
                : .failure(.remoteFailure((result["reason"] as? String) ?? "the machine did not confirm it"))
        }
    }
}
