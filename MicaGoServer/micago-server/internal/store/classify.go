package store

import (
	"sort"
	"strings"
	"unicode"
)

// Message debug classification kinds. Confident kinds (text/image/video/audio/
// voice/file) describe rendered content; "*_candidate" kinds are heuristic
// guesses for rows whose true nature depends on iMessage fields the server may
// not expose. "unsupported_candidate" means nothing renderable was found.
const (
	KindText          = "text"
	KindImage         = "image"
	KindVideo         = "video"
	KindAudio         = "audio"
	KindVoice         = "voice"
	KindFile          = "file"
	KindReaction      = "reaction_candidate"
	KindReply         = "reply_candidate"
	KindService       = "service_candidate"
	KindUnsupported   = "unsupported_candidate"
	candidateControl  = "control_like"
	candidateNoConten = "no_content"
)

// IsControlLikeText reports whether text is a control/typedstream artifact that
// must not be shown as a normal message — e.g. the "+!"/"+$" attributedBody
// leak, or a string with no letters/digits at all. Conservative: any letter or
// digit (incl. CJK) means it is real content.
func IsControlLikeText(text string) bool {
	t := strings.TrimSpace(strings.ReplaceAll(text, "￼", ""))
	if t == "" {
		return true
	}
	for _, r := range t {
		// Letters/digits (incl. CJK, accented) are content; so is any non-ASCII
		// rune (emoji, symbols, other scripts). Real artifacts ("+!", "+$") are
		// pure ASCII punctuation — never strip a real emoji-only message.
		if unicode.IsLetter(r) || unicode.IsDigit(r) || r > unicode.MaxASCII {
			return false
		}
	}
	return true
}

func attachmentKindOf(m DebugMessageJSON) string {
	// Voice wins; otherwise first media kind; otherwise file.
	hasFile := false
	for _, a := range m.Attachments {
		if a.IsVoiceMessage {
			return KindVoice
		}
	}
	for _, a := range m.Attachments {
		switch a.AttachmentKind {
		case AttachmentKindImage:
			return KindImage
		case AttachmentKindVideo:
			return KindVideo
		case AttachmentKindAudio:
			return KindAudio
		default:
			hasFile = true
		}
	}
	if hasFile {
		return KindFile
	}
	return KindFile
}

// ClassifyDebugMessage returns the best single kind plus any additional
// candidate signals. It is heuristic and intended for debugging only.
func ClassifyDebugMessage(m DebugMessageJSON) (kind string, candidates []string) {
	candidates = []string{}

	// Reaction / reply association (depends on optional columns).
	if m.AssociatedMessageType != nil && *m.AssociatedMessageType != 0 {
		candidates = append(candidates, KindReaction)
	}
	// Replies are identified by thread_originator_guid (BlueBubbles semantics),
	// distinct from the associated_message_guid used by reactions.
	if m.ThreadOriginatorGUID != nil && strings.TrimSpace(*m.ThreadOriginatorGUID) != "" {
		candidates = append(candidates, KindReply)
	}
	if (m.ItemType != nil && *m.ItemType != 0) ||
		(m.GroupActionType != nil && *m.GroupActionType != 0) ||
		(m.GroupTitle != nil && strings.TrimSpace(*m.GroupTitle) != "") {
		candidates = append(candidates, KindService)
	}
	if m.BalloonBundleID != nil && strings.TrimSpace(*m.BalloonBundleID) != "" {
		candidates = append(candidates, "interactive_candidate")
	}

	// Primary kind precedence: reaction > reply > service > attachment > text.
	switch {
	case contains(candidates, KindReaction):
		kind = KindReaction
	case contains(candidates, KindReply):
		kind = KindReply
	case contains(candidates, KindService):
		kind = KindService
	case len(m.Attachments) > 0:
		kind = attachmentKindOf(m)
	case m.Text != nil && strings.TrimSpace(*m.Text) != "" && !IsControlLikeText(*m.Text):
		kind = KindText
	default:
		kind = KindUnsupported
		if m.Text != nil && strings.TrimSpace(*m.Text) != "" && IsControlLikeText(*m.Text) {
			candidates = append(candidates, candidateControl)
		} else if !m.CacheHasAttachments {
			candidates = append(candidates, candidateNoConten)
		}
	}

	// A row flagged cache_has_attachments but with none materialized is itself a
	// useful unsupported signal (server didn't surface the attachment row).
	if kind != KindUnsupported && m.CacheHasAttachments && len(m.Attachments) == 0 {
		candidates = append(candidates, "missing_attachment_rows")
	}
	return kind, candidates
}

// AnnotateDebugMessage fills Kind/Candidates in place.
func AnnotateDebugMessage(m *DebugMessageJSON) {
	m.Kind, m.Candidates = ClassifyDebugMessage(*m)
}

// DebugFilter is the post-fetch, in-Go refinement of debug rows.
type DebugFilter struct {
	Query          string // substring (case-insensitive) over text/chat/sender/attachment names
	Type           string // "" or one of the kinds / "attachment"
	HasAttachments string // "all" | "has" | "none" | "image" | "audio" | "unsupported"
}

// FilterDebugMessages applies the query/type/attachment filters to already
// annotated rows (call AnnotateDebugMessage first).
func FilterDebugMessages(in []DebugMessageJSON, f DebugFilter) []DebugMessageJSON {
	out := make([]DebugMessageJSON, 0, len(in))
	q := strings.ToLower(strings.TrimSpace(f.Query))
	for _, m := range in {
		if q != "" && !debugMatchesQuery(m, q) {
			continue
		}
		if !debugMatchesType(m, f.Type) {
			continue
		}
		if !debugMatchesAttachments(m, f.HasAttachments) {
			continue
		}
		out = append(out, m)
	}
	return out
}

func debugMatchesQuery(m DebugMessageJSON, q string) bool {
	hay := strings.Builder{}
	add := func(s *string) {
		if s != nil {
			hay.WriteString(strings.ToLower(*s))
			hay.WriteByte('\n')
		}
	}
	add(m.Text)
	add(m.ChatDisplayName)
	add(m.ChatIdentifier)
	add(m.ChatGUID)
	add(m.HandleID)
	for _, a := range m.Attachments {
		add(a.Filename)
		add(a.TransferName)
	}
	return strings.Contains(hay.String(), q)
}

func debugMatchesType(m DebugMessageJSON, t string) bool {
	switch t {
	case "", "all":
		return true
	case "attachment":
		return len(m.Attachments) > 0
	case "reaction":
		return m.Kind == KindReaction || contains(m.Candidates, KindReaction)
	case "reply":
		return m.Kind == KindReply || contains(m.Candidates, KindReply)
	case "service":
		return m.Kind == KindService || contains(m.Candidates, KindService)
	case "unknown", "unsupported":
		return m.Kind == KindUnsupported
	default:
		// text / image / video / audio / voice / file
		return m.Kind == t
	}
}

func debugMatchesAttachments(m DebugMessageJSON, mode string) bool {
	switch mode {
	case "", "all":
		return true
	case "has":
		return len(m.Attachments) > 0
	case "none":
		return len(m.Attachments) == 0
	case "image":
		return anyAttachment(m, AttachmentKindImage)
	case "audio":
		return anyAttachment(m, AttachmentKindAudio) || anyVoice(m)
	case "unsupported":
		return anyAttachment(m, AttachmentKindUnknown)
	default:
		return true
	}
}

func anyAttachment(m DebugMessageJSON, kind string) bool {
	for _, a := range m.Attachments {
		if a.AttachmentKind == kind {
			return true
		}
	}
	return false
}

func anyVoice(m DebugMessageJSON) bool {
	for _, a := range m.Attachments {
		if a.IsVoiceMessage {
			return true
		}
	}
	return false
}

// DebugGroup summarizes a set of messages sharing a grouping key.
type DebugGroup struct {
	Key              string `json:"key"`
	Label            string `json:"label"`
	Count            int    `json:"count"`
	UnsupportedCount int    `json:"unsupportedCount"`
	AttachmentCount  int    `json:"attachmentCount"`
	LatestTimestamp  *int64 `json:"latestTimestamp"`
}

// GroupDebugMessages aggregates rows by mode: "sender" | "chat" | "type" |
// "unsupported". Any other value returns nil (flat view). Groups are sorted by
// descending message count, then label.
func GroupDebugMessages(in []DebugMessageJSON, mode string) []DebugGroup {
	keyFn, labelFn, ok := groupKeyFns(mode)
	if !ok {
		return nil
	}
	order := []string{}
	groups := map[string]*DebugGroup{}
	for _, m := range in {
		key := keyFn(m)
		g, exists := groups[key]
		if !exists {
			g = &DebugGroup{Key: key, Label: labelFn(m, key)}
			groups[key] = g
			order = append(order, key)
		}
		g.Count++
		if m.Kind == KindUnsupported {
			g.UnsupportedCount++
		}
		g.AttachmentCount += len(m.Attachments)
		if m.DateCreated != nil {
			if g.LatestTimestamp == nil || *m.DateCreated > *g.LatestTimestamp {
				v := *m.DateCreated
				g.LatestTimestamp = &v
			}
		}
	}
	out := make([]DebugGroup, 0, len(order))
	for _, k := range order {
		out = append(out, *groups[k])
	}
	sort.SliceStable(out, func(i, j int) bool {
		if out[i].Count != out[j].Count {
			return out[i].Count > out[j].Count
		}
		return out[i].Label < out[j].Label
	})
	return out
}

func groupKeyFns(mode string) (func(DebugMessageJSON) string, func(DebugMessageJSON, string) string, bool) {
	switch mode {
	case "sender":
		return func(m DebugMessageJSON) string {
				if m.IsFromMe {
					return "me"
				}
				if m.HandleID != nil && strings.TrimSpace(*m.HandleID) != "" {
					return *m.HandleID
				}
				return "unknown"
			}, func(m DebugMessageJSON, key string) string {
				switch key {
				case "me":
					return "You"
				case "unknown":
					return "Unknown sender"
				default:
					return key
				}
			}, true
	case "chat":
		return func(m DebugMessageJSON) string {
				if m.ChatGUID != nil {
					return *m.ChatGUID
				}
				return "unknown"
			}, func(m DebugMessageJSON, key string) string {
				if m.ChatDisplayName != nil && strings.TrimSpace(*m.ChatDisplayName) != "" {
					return *m.ChatDisplayName
				}
				if m.ChatIdentifier != nil && strings.TrimSpace(*m.ChatIdentifier) != "" {
					return *m.ChatIdentifier
				}
				return key
			}, true
	case "type":
		return func(m DebugMessageJSON) string { return m.Kind },
			func(m DebugMessageJSON, key string) string { return key }, true
	case "unsupported":
		return func(m DebugMessageJSON) string {
				if m.Kind != KindUnsupported {
					return "supported"
				}
				if contains(m.Candidates, candidateControl) {
					return candidateControl
				}
				if contains(m.Candidates, candidateNoConten) {
					return candidateNoConten
				}
				return "unsupported_other"
			}, func(m DebugMessageJSON, key string) string {
				switch key {
				case "supported":
					return "Supported"
				case candidateControl:
					return "Control-like payload"
				case candidateNoConten:
					return "No content"
				default:
					return "Unsupported (other)"
				}
			}, true
	default:
		return nil, nil, false
	}
}

func contains(s []string, v string) bool {
	for _, x := range s {
		if x == v {
			return true
		}
	}
	return false
}
