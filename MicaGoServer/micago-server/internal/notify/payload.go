package notify

type Notification struct {
	Type        string `json:"type"`
	MessageGUID string `json:"messageGuid"`
	ChatGUID    string `json:"chatGuid"`
	// SourceRowID is the chat.db ROWID of the message — the delta cursor (C21d).
	// The client uses it to run a precise catch-up after an FCM wake (C22), the
	// same "push is a wake/awareness signal, real data comes via sync" model as
	// BlueBubbles.
	SourceRowID int64  `json:"sourceRowId"`
	Title       string `json:"title"`
	Body        string `json:"body"`
	PreviewMode string `json:"previewMode"`
	CreatedAt   int64  `json:"createdAt"`
}
