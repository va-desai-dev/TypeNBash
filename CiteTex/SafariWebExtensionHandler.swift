/// CiteTex & CiteTexKit 2026 © Vedant A. Desai are Licensed under the Educational Community License, Version 2.0 (the “License”); you may not use this file except in compliance with the License. You may obtain a copy of the License at [http://www.osedu.org/licenses/ECL-2.0](http://www.osedu.org/licenses/ECL-2.0) Unless required by applicable law or agreed to in writing, software distributed under the License is distributed on an “AS IS” BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the License for the specific language governing permissions and limitations under the License.

//  SafariWebExtensionHandler.swift
//  CiteTex (TypeNBash)
//
//  Created by Vedant A. Desai on 8/27/26.
//
//  The browser side scrapes CSL-JSON from the page and hands it here through
//  browser.runtime.sendNativeMessage. This handler normalises it, mints a
//  citation key, and appends it as BibTeX to the CiteTex inbox in the shared
//  App Group container. TypeNBash drains the inbox into the active .bib.
//
//  Link the BibTeXKit package product to this target.

import SafariServices
import BibTeXKit
import os.log

class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {

    func beginRequest(with context: NSExtensionContext) {
        let request = context.inputItems.first as? NSExtensionItem
        let message = request?.userInfo?[SFExtensionMessageKey]

        let response = NSExtensionItem()
        response.userInfo = [ SFExtensionMessageKey: handle(message) ]
        context.completeRequest(returningItems: [ response ], completionHandler: nil)
    }

    /// Expects `{ "citations": <CSL-JSON array or single object> }`, but also
    /// accepts a bare array or object so the message shape can stay simple on
    /// the JavaScript side. Returns a small dictionary the popup can show.
    private func handle(_ message: Any?) -> [String: Any] {
        guard let message else {
            return ["ok": false, "error": "No message payload."]
        }

        let payload = (message as? [String: Any])?["citations"] ?? message
        let records: Any = (payload is [Any]) ? payload : [payload]

        guard JSONSerialization.isValidJSONObject(records) else {
            return ["ok": false, "error": "Message was not valid JSON."]
        }
        guard let inbox = CiteTexInbox() else {
            return ["ok": false, "error":
                "Shared container unavailable. The app and extension must be signed by the same team and list the same App Group."]
        }

        do {
            let data = try JSONSerialization.data(withJSONObject: records)
            let citations = try JSONDecoder().decode([Citation].self, from: data)
                .map { CitationNormalizer.normalize($0.fields).citation }
            let waiting = try inbox.append(citations)

            let keys = citations.map { "@" + $0.id }.joined(separator: ", ")
            let summary = waiting > citations.count
                ? "Queued \(keys) — \(waiting) waiting for a .bib in TypeNBash."
                : "Sent \(keys) to TypeNBash."
            os_log(.default, "CiteTex queued: %{public}@", keys)
            return ["ok": true, "summary": summary, "keys": citations.map(\.id), "waiting": waiting]
        } catch {
            os_log(.error, "CiteTex could not queue citations: %{public}@",
                   String(describing: error))
            return ["ok": false, "error": error.localizedDescription]
        }
    }
}
