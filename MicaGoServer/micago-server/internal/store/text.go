package store

import (
	"bytes"
	"strings"
	"unicode"
	"unicode/utf8"
)

var attributedBodyReservedTokens = map[string]struct{}{
	"NSAttributedString": {},
	"NSDictionary":       {},
	"NSObject":           {},
	"NSString":           {},
}

func ExtractMessageText(text *string, attributedBody []byte) *string {
	if textHasContent(text) {
		value := *text
		return &value
	}

	return decodeAttributedBodyText(attributedBody)
}

func MessageHasRenderableContent(text *string, cacheHasAttachments bool) bool {
	return textHasContent(text) || cacheHasAttachments
}

func textHasContent(text *string) bool {
	if text == nil {
		return false
	}

	return strings.TrimSpace(*text) != ""
}

func decodeAttributedBodyText(attributedBody []byte) *string {
	if len(attributedBody) == 0 {
		return nil
	}

	const marker = "NSString"
	searchFrom := 0
	for {
		index := bytes.Index(attributedBody[searchFrom:], []byte(marker))
		if index < 0 {
			return nil
		}

		index += searchFrom + len(marker)
		if candidate := decodeNSStringPayload(attributedBody[index:]); candidate != "" {
			if _, reserved := attributedBodyReservedTokens[candidate]; !reserved {
				return &candidate
			}
		}

		searchFrom = index
		if searchFrom >= len(attributedBody) {
			return nil
		}
	}
}

func decodeNSStringPayload(data []byte) string {
	for i := 0; i+2 < len(data); i++ {
		if data[i] == '+' && !isPrintableByte(data[i+1]) {
			if candidate := firstPrintableRun(data[i+2:]); candidate != "" {
				return candidate
			}
		}
	}

	return firstPrintableRun(data)
}

func firstPrintableRun(data []byte) string {
	for start := 0; start < len(data); {
		r, size := utf8.DecodeRune(data[start:])
		if r == utf8.RuneError && size == 1 {
			start++
			continue
		}
		if !isPrintableMessageRune(r) {
			start += size
			continue
		}

		var b strings.Builder
		for pos := start; pos < len(data); {
			next, nextSize := utf8.DecodeRune(data[pos:])
			if next == utf8.RuneError && nextSize == 1 {
				break
			}
			if !isPrintableMessageRune(next) {
				break
			}
			b.WriteRune(next)
			pos += nextSize
		}

		candidate := strings.TrimSpace(b.String())
		if candidate != "" {
			return candidate
		}

		start += size
	}

	return ""
}

func isPrintableMessageRune(r rune) bool {
	if r == '\n' || r == '\r' || r == '\t' {
		return true
	}
	return unicode.IsPrint(r)
}

func isPrintableByte(b byte) bool {
	return b >= 0x20 && b <= 0x7e
}
