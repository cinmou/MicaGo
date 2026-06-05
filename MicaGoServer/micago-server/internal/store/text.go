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
	// In Apple's typedstream (NSArchiver) encoding, an NSString's bytes are
	// preceded by a 0x2b ('+') marker followed by a length-prefix using the
	// typedstream integer encoding:
	//   - a single byte    : length 0x00..0x80
	//   - 0x81 + uint16(LE) : longer lengths
	//   - 0x82 + uint32(LE) : very long lengths
	// We must consume that length prefix and slice exactly that many bytes.
	// A naive "skip the marker then read printable runs" heuristic breaks when
	// the length byte itself is printable ASCII (string lengths 32..126), which
	// leaks the marker + length as a visible prefix such as "+!" (len 33, 0x21)
	// or "+$" (len 36, 0x24).
	for i := 0; i+1 < len(data); i++ {
		if data[i] != '+' {
			continue
		}
		if candidate, ok := decodeTypedStreamString(data[i+1:]); ok && candidate != "" {
			return candidate
		}
	}

	// Fallback: best-effort printable-run scan for payloads that don't match
	// the length-prefixed layout (older/edge encodings).
	return firstPrintableRun(data)
}

// decodeTypedStreamString reads a typedstream length-prefixed string starting
// at the length byte (i.e. immediately after the 0x2b marker). It returns the
// decoded UTF-8 string and true only when the length is sane, in-bounds, and
// the sliced bytes are valid UTF-8.
func decodeTypedStreamString(data []byte) (string, bool) {
	if len(data) == 0 {
		return "", false
	}

	length := int(data[0])
	offset := 1
	switch data[0] {
	case 0x81:
		if len(data) < 3 {
			return "", false
		}
		length = int(data[1]) | int(data[2])<<8
		offset = 3
	case 0x82:
		if len(data) < 5 {
			return "", false
		}
		length = int(data[1]) | int(data[2])<<8 | int(data[3])<<16 | int(data[4])<<24
		offset = 5
	}

	if length <= 0 || offset+length > len(data) {
		return "", false
	}

	candidate := string(data[offset : offset+length])
	if !utf8.ValidString(candidate) {
		return "", false
	}

	return candidate, true
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
