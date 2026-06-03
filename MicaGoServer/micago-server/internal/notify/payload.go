package notify

type Notification struct {
	Type        string `json:"type"`
	MessageGUID string `json:"messageGuid"`
	ChatGUID    string `json:"chatGuid"`
	Title       string `json:"title"`
	Body        string `json:"body"`
	PreviewMode string `json:"previewMode"`
	CreatedAt   int64  `json:"createdAt"`
}
