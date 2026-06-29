// Package testcontact defines the synthetic, offline "test contact" used to
// exercise the chat pipeline (list, open, send, render) without ever sending a
// real iMessage.
//
// The handle's domain (micago.cinmou) does not resolve, so iMessage/SMS could
// never deliver to it. To stay safe regardless, the server never hands a send
// for this chat to Messages.app: it loops the message straight back into
// relay.db. Nothing leaves the Mac.
package testcontact

const (
	// Handle is the test contact's address. micago.cinmou is a non-existent
	// domain, so nothing can ever be delivered to it.
	Handle = "test@micago.cinmou"

	// ChatGUID is the synthetic chat's stable identifier (mirrors the
	// `service;-;identifier` shape iMessage chats use).
	ChatGUID = "iMessage;-;test@micago.cinmou"

	// Service is fixed to iMessage so the chat is treated as sendable text.
	Service = "iMessage"

	// DisplayName is shown in the client's chat list.
	DisplayName = "MicaGo Test"

	// WelcomeGUID is the stable guid of the seeded inbound greeting, so
	// re-enabling never duplicates it.
	WelcomeGUID = "micago-test-welcome"

	// WelcomeText is the seeded inbound greeting.
	WelcomeText = "👋 This is the MicaGo test contact. Anything you send here stays on your server and is never delivered anywhere. Turn it off again in Settings."
)

// IsTestChatGUID reports whether guid is the synthetic test chat.
func IsTestChatGUID(guid string) bool { return guid == ChatGUID }
