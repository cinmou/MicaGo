package send

import "time"

type PendingSend struct {
	TempGUID          string
	ChatGUID          string
	OriginalMessage   string
	NormalizedMessage string
	SentAtUnixMilli   int64
	Timeout           time.Duration
}
