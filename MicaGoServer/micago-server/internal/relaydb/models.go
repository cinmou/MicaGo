package relaydb

import "micagoserver/internal/store"

type SyncResult struct {
	Mode                     string
	PreviousLastMessageRowID int64
	NewLastMessageRowID      int64
	ChatsSynced              int
	MessagesSynced           int
	AttachmentsSynced        int
	LastMessageGUID          string
	LastMessageDateCreated   int64
	NewMessages              []store.MessageJSON
	NotificationEvents       []NotificationEvent
}

type NotificationEvent struct {
	ChatGUID       string
	ChatIdentifier *string
	ChatDisplay    *string
	Message        store.MessageJSON
}

func (e NotificationEvent) ChatLabel() string {
	if e.ChatDisplay != nil && *e.ChatDisplay != "" {
		return *e.ChatDisplay
	}
	if e.ChatIdentifier != nil {
		return *e.ChatIdentifier
	}
	return ""
}
