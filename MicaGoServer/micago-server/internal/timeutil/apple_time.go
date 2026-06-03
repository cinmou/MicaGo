package timeutil

import "time"

var appleEpoch = time.Date(2001, 1, 1, 0, 0, 0, 0, time.UTC)

const nanosecondThreshold int64 = 1_000_000_000_000_000

func AppleMicrosToTime(raw int64) *time.Time {
	if raw == 0 {
		return nil
	}

	unit := time.Microsecond
	if raw >= nanosecondThreshold || raw <= -nanosecondThreshold {
		unit = time.Nanosecond
	}

	t := appleEpoch.Add(time.Duration(raw) * unit)
	return &t
}

func AppleMicrosToUnixMilli(raw int64) *int64 {
	t := AppleMicrosToTime(raw)
	if t == nil {
		return nil
	}

	ms := t.UnixMilli()
	return &ms
}

func AppleMicrosToUnixMilliPtr(raw *int64) *int64 {
	if raw == nil {
		return nil
	}
	return AppleMicrosToUnixMilli(*raw)
}
