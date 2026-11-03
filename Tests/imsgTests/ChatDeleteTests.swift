import Commander
import Foundation
import Testing

@testable import IMsgCore
@testable import imsg

@Test
func injectedHelperDeletesChatsOnlyThroughRecentlyDeleted() throws {
  let source = stripObjectiveCComments(try injectedHelperSource())
  let deleteBody = try #require(bridgeFunctionBody(named: "handleDeleteChat", in: source))
  let statusBody = try #require(bridgeFunctionBody(named: "handleStatus", in: source))

  #expect(statusBody.contains(#"@"moveChatToRecentlyDeleted""#))
  #expect(deleteBody.contains("@[chat], [NSDate date], YES"))
  #expect(deleteBody.contains("NSStringFromSelector(recentlyDeletedSelector)"))

  // Permanent removal erases the chat and skips Recently Deleted, so the
  // helper never calls it and no longer advertises it.
  #expect(!source.contains("deleteChat:"))
  #expect(!source.contains("_chat_remove:"))
  #expect(!statusBody.contains(#"@"deleteChat""#))
  #expect(!statusBody.contains(#"@"removeChat""#))

  // Refuse before resolving the chat, which can materialize a direct chat.
  let refusal = try #require(
    deleteBody.range(of: "![reg respondsToSelector:recentlyDeletedSelector]"))
  let resolve = try #require(deleteBody.range(of: "resolveChatByGuid(chatGuid)"))
  #expect(refusal.lowerBound < resolve.lowerBound)
  #expect(deleteBody.contains(#"notStartedResponse(requestId, @"Chat not found")"#))
}

@Test
func chatDeleteSummaryReportsRecentlyDeletedMove() async throws {
  let values = ParsedValues(
    positional: [], options: ["chat": ["iMessage;-;+15551234567"]], flags: [])
  var capturedAction: BridgeAction?
  var capturedParams: [String: Any] = [:]
  let (output, _) = try await StdoutCapture.capture {
    try await ChatDeleteCommand.run(
      values: values,
      runtime: RuntimeOptions(parsedValues: values),
      invokeBridge: { action, params in
        capturedAction = action
        capturedParams = params
        return [
          "chatGuid": "iMessage;-;+15551234567", "deleted": true,
          "method":
            "moveMessagesInChatsToRecentlyDeleted:deleteDate:synchronously:completionHandler:",
        ]
      }
    )
  }
  #expect(capturedAction == .deleteChat)
  #expect(capturedParams["chatGuid"] as? String == "iMessage;-;+15551234567")
  #expect(
    output.trimmingCharacters(in: .whitespacesAndNewlines)
      == "chat-delete: moved to Recently Deleted")
}

@Test
func rpcChatsDeleteRequiresRecentlyDeletedSelector() async throws {
  let store = try CommandTestDatabase.makeStoreForRPC()
  for available in [true, false] {
    var selectors = fullRPCStatusBridgeSelectors()
    selectors["moveChatToRecentlyDeleted"] = available
    // A helper from before this change still reports the permanent removal
    // selectors; they must not make chats.delete usable.
    selectors["deleteChat"] = true
    selectors["removeChat"] = true
    let output = TestRPCOutput()
    let server = RPCServer(
      store: store,
      verbose: false,
      output: output,
      invokeBridge: { action, _ in
        action == .status ? rpcStatusBridgeSnapshot(selectors: selectors) : [:]
      },
      isBridgeReady: { true }
    )
    await server.handleLineForTesting(
      #"{"jsonrpc":"2.0","id":"delete-selectors","method":"status"}"#)
    let methods = rpcStatusMethods(try rpcStatusResult(output))
    #expect(methods.contains("chats.delete") == available)
  }
}

@Test
func rpcChatsDeleteReportsHelperRefusalAsRetrySafe() async throws {
  let store = try CommandTestDatabase.makeStoreForRPC()
  let output = TestRPCOutput()
  var capturedParams: [String: Any] = [:]
  let detail =
    "Dylib error: Recoverable chat deletion is unavailable (IMChatRegistry "
    + "moveMessagesInChatsToRecentlyDeleted:deleteDate:synchronously:completionHandler: "
    + "missing); the chat was not deleted"
  let server = RPCServer(
    store: store,
    verbose: false,
    output: output,
    invokeBridge: { action, params in
      capturedParams = params
      // IMsgBridgeClient maps the helper's not_started refusal to this failure.
      throw DeliveryFailure(
        disposition: .notStarted, transport: .bridgeV2, operation: action.rawValue,
        detail: detail)
    },
    isBridgeReady: { true }
  )

  await server.handleLineForTesting(
    #"{"jsonrpc":"2.0","id":"delete","method":"chats.delete","params":{"chat_id":1}}"#)

  #expect(capturedParams["chatGuid"] as? String == "iMessage;+;chat123")
  let error = try #require(output.errors.first?["error"] as? [String: Any])
  #expect(error["code"] as? Int == -32603)
  #expect(error["message"] as? String == "Delivery failed before dispatch")
  let data = try #require(error["data"] as? [String: Any])
  #expect(data["retry_safe"] as? Bool == true)
  #expect(data["disposition"] as? String == "not_started")
  #expect(data["transport"] as? String == "bridge_v2")
  #expect(data["operation"] as? String == "delete-chat")
  #expect(data["detail"] as? String == detail)
}
