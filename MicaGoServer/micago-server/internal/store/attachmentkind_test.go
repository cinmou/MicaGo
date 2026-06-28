package store

import "testing"

func sp(s string) *string { return &s }

func TestAttachmentKindInference(t *testing.T) {
	cases := []struct {
		name         string
		isSticker    bool
		mimeType     *string
		uti          *string
		transferName *string
		filename     *string
		wantKind     string
		wantVoice    bool
		wantMime     string // expected effective mime ("" => nil)
	}{
		{
			name:     "image by mime",
			mimeType: sp("image/jpeg"),
			uti:      sp("public.jpeg"),
			wantKind: AttachmentKindImage,
			wantMime: "image/jpeg",
		},
		{
			name:     "heic by uti only (mime inferred)",
			uti:      sp("public.heic"),
			wantKind: AttachmentKindImage,
			wantMime: "image/heic",
		},
		{
			name:         "tiff image needs preview conversion",
			uti:          sp("public.tiff"),
			transferName: sp("screenshot.tiff"),
			wantKind:     AttachmentKindImage,
			wantMime:     "image/tiff",
		},
		{
			name:         "pdf file by mime",
			mimeType:     sp("application/pdf"),
			transferName: sp("invoice.pdf"),
			wantKind:     AttachmentKindFile,
			wantMime:     "application/pdf",
		},
		{
			name:         "pdf file by extension only",
			transferName: sp("report.PDF"),
			wantKind:     AttachmentKindFile,
			wantMime:     "application/pdf",
		},
		{
			name:      "voice message by caf uti",
			uti:       sp("com.apple.coreaudio-format"),
			wantKind:  AttachmentKindAudio,
			wantVoice: true,
			wantMime:  "audio/x-caf",
		},
		{
			name:      "regular audio mp3 is not a voice message",
			mimeType:  sp("audio/mpeg"),
			uti:       sp("public.mp3"),
			wantKind:  AttachmentKindAudio,
			wantVoice: false,
			wantMime:  "audio/mpeg",
		},
		{
			name:         "mica recorded m4a is a voice message",
			transferName: sp("voice_1717372800000.m4a"),
			wantKind:     AttachmentKindAudio,
			wantVoice:    true,
			wantMime:     "audio/mp4",
		},
		{
			name:         "regular m4a is ordinary audio",
			transferName: sp("song.m4a"),
			wantKind:     AttachmentKindAudio,
			wantVoice:    false,
			wantMime:     "audio/mp4",
		},
		{
			name:     "video by mime",
			mimeType: sp("video/quicktime"),
			uti:      sp("com.apple.quicktime-movie"),
			wantKind: AttachmentKindVideo,
			wantMime: "video/quicktime",
		},
		{
			name:         "video by extension only",
			transferName: sp("clip.mov"),
			wantKind:     AttachmentKindVideo,
			wantMime:     "video/quicktime",
		},
		{
			name:      "sticker wins over mime",
			isSticker: true,
			mimeType:  sp("image/png"),
			uti:       sp("public.png"),
			wantKind:  AttachmentKindSticker,
			wantMime:  "image/png",
		},
		{
			name:     "unknown when nothing identifies it",
			wantKind: AttachmentKindUnknown,
			wantMime: "",
		},
		{
			name:         "opaque type with name is unknown",
			transferName: sp("data.unknownext"),
			wantKind:     AttachmentKindUnknown,
			wantMime:     "", // nothing maps this extension
		},
		{
			name:         "uuid link-preview payload is unknown",
			transferName: sp("88A910B7-31DB-48EF-8124-136AC0D0B9EF"),
			filename:     sp("88A910B7-31DB-48EF-8124-136AC0D0B9EF"),
			wantKind:     AttachmentKindUnknown,
			wantMime:     "", // nothing maps this extension
		},
		{
			name:         "generic public.data payload is unknown",
			uti:          sp("public.data"),
			transferName: sp("BD39B7FF-2910-4992-8CD3-7A084A942CF2"),
			wantKind:     AttachmentKindUnknown,
			wantMime:     "",
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			gotKind := AttachmentKind(tc.isSticker, tc.mimeType, tc.uti, tc.transferName, tc.filename)
			if gotKind != tc.wantKind {
				t.Errorf("AttachmentKind = %q, want %q", gotKind, tc.wantKind)
			}

			gotVoice := IsVoiceMessage(tc.uti, tc.mimeType, tc.transferName, tc.filename)
			if gotVoice != tc.wantVoice {
				t.Errorf("IsVoiceMessage = %v, want %v", gotVoice, tc.wantVoice)
			}

			gotMime := InferMimeType(tc.mimeType, tc.uti, tc.transferName, tc.filename)
			if tc.wantMime == "" {
				if gotMime != nil {
					t.Errorf("InferMimeType = %q, want nil", *gotMime)
				}
			} else if gotMime == nil || *gotMime != tc.wantMime {
				t.Errorf("InferMimeType = %v, want %q", gotMime, tc.wantMime)
			}
		})
	}
}

// C37: location + UTI-based sticker classification.
func TestAttachmentKindLocationAndStickerUTI(t *testing.T) {
	sp := func(s string) *string { return &s }

	// Shared-location payloads → location (not "file").
	loc := AttachmentJSON{MimeType: sp("text/x-vlocation"), TransferName: sp("CL.loc.vcf")}
	DecorateAttachmentJSON(&loc)
	if loc.AttachmentKind != AttachmentKindLocation || loc.DisplayKind != DisplayKindLocation {
		t.Fatalf("vlocation: kind=%q display=%q", loc.AttachmentKind, loc.DisplayKind)
	}
	locUTI := AttachmentJSON{Uti: sp("public.vlocation")}
	DecorateAttachmentJSON(&locUTI)
	if locUTI.AttachmentKind != AttachmentKindLocation {
		t.Fatalf("public.vlocation: kind=%q", locUTI.AttachmentKind)
	}

	// A sticker whose is_sticker flag is missing but UTI says sticker.
	st := AttachmentJSON{Uti: sp("com.apple.sticker"), MimeType: sp("image/png")}
	DecorateAttachmentJSON(&st)
	if st.AttachmentKind != AttachmentKindSticker || st.DisplayKind != DisplayKindSticker {
		t.Fatalf("sticker UTI: kind=%q display=%q", st.AttachmentKind, st.DisplayKind)
	}

	// A normal image is still an image (no false sticker/location).
	img := AttachmentJSON{MimeType: sp("image/jpeg"), TransferName: sp("photo.jpg")}
	DecorateAttachmentJSON(&img)
	if img.AttachmentKind != AttachmentKindImage {
		t.Fatalf("image regressed: kind=%q", img.AttachmentKind)
	}
}

func TestInferMimeTypePreservesStoredMime(t *testing.T) {
	stored := sp("application/x-weird")
	got := InferMimeType(stored, sp("public.jpeg"), sp("photo.jpg"), nil)
	if got == nil || *got != "application/x-weird" {
		t.Fatalf("expected stored mime preserved, got %v", got)
	}
}

func TestInferMimeTypeFromUTI(t *testing.T) {
	got := InferMimeType(nil, sp("com.adobe.pdf"), nil, nil)
	if got == nil || *got != "application/pdf" {
		t.Fatalf("expected application/pdf from uti, got %v", got)
	}
}

func TestInferMimeTypeFromExtension(t *testing.T) {
	got := InferMimeType(nil, nil, sp("voice.caf"), nil)
	if got == nil || *got != "audio/x-caf" {
		t.Fatalf("expected audio/x-caf from extension, got %v", got)
	}
}

func TestInferMimeTypeNilWhenUnknown(t *testing.T) {
	if got := InferMimeType(nil, nil, nil, nil); got != nil {
		t.Fatalf("expected nil mime, got %v", *got)
	}
}

func TestIsAttachmentPreviewPayload(t *testing.T) {
	noise := AttachmentJSON{
		Filename:     sp("88A910B7-31DB-48EF-8124-136AC0D0B9EF"),
		TransferName: sp("88A910B7-31DB-48EF-8124-136AC0D0B9EF"),
	}
	DecorateAttachmentJSON(&noise)
	if !IsAttachmentPreviewPayload(noise) {
		t.Fatal("expected untyped UUID payload to be hidden from real attachments")
	}

	pdf := AttachmentJSON{TransferName: sp("report.pdf")}
	DecorateAttachmentJSON(&pdf)
	if IsAttachmentPreviewPayload(pdf) {
		t.Fatal("typed PDF attachment must remain visible")
	}

	sticker := AttachmentJSON{IsSticker: true, TransferName: sp("sticker")}
	DecorateAttachmentJSON(&sticker)
	if IsAttachmentPreviewPayload(sticker) {
		t.Fatal("stickers must remain visible even when MIME is absent")
	}
}

func TestDecorateAttachmentJSONFillsDerivedFields(t *testing.T) {
	a := AttachmentJSON{Uti: sp("com.apple.coreaudio-format")}
	DecorateAttachmentJSON(&a)
	if a.AttachmentKind != AttachmentKindAudio {
		t.Errorf("kind = %q, want audio", a.AttachmentKind)
	}
	if !a.IsVoiceMessage {
		t.Error("expected IsVoiceMessage true for caf uti")
	}
	if a.MimeType == nil || *a.MimeType != "audio/x-caf" {
		t.Errorf("mime = %v, want audio/x-caf", a.MimeType)
	}
}

func TestDecorateAttachmentJSONMarksTIFFNotPreviewable(t *testing.T) {
	a := AttachmentJSON{Uti: sp("public.tiff"), TransferName: sp("shot.tif")}
	DecorateAttachmentJSON(&a)
	if a.AttachmentKind != AttachmentKindImage {
		t.Fatalf("kind = %q, want image", a.AttachmentKind)
	}
	if a.MimeType == nil || *a.MimeType != "image/tiff" {
		t.Fatalf("mime = %v, want image/tiff", a.MimeType)
	}
	if !a.NeedsPreviewConversion {
		t.Fatal("expected TIFF to need preview conversion")
	}
	if a.IsPreviewableImage {
		t.Fatal("TIFF should not be marked previewable")
	}
	if a.DisplayKind != DisplayKindImageNeedsPreview {
		t.Fatalf("displayKind = %q, want %q", a.DisplayKind, DisplayKindImageNeedsPreview)
	}
}

func TestDecorateAttachmentJSONKeepsStickerDisplayKindWithPreview(t *testing.T) {
	a := AttachmentJSON{IsSticker: true, Uti: sp("public.heic"), TransferName: sp("sticker.heic")}
	DecorateAttachmentJSON(&a)
	if a.AttachmentKind != AttachmentKindSticker {
		t.Fatalf("kind = %q, want sticker", a.AttachmentKind)
	}
	if a.DisplayKind != DisplayKindSticker {
		t.Fatalf("displayKind = %q, want %q", a.DisplayKind, DisplayKindSticker)
	}
	if !a.NeedsPreviewConversion {
		t.Fatal("expected sticker to expose a PNG preview conversion path")
	}
	if a.MimeType == nil || *a.MimeType != "image/heic" {
		t.Fatalf("mime = %v, want image/heic", a.MimeType)
	}
}

func TestDecorateAttachmentJSONMarksHEICNeedsPreview(t *testing.T) {
	a := AttachmentJSON{Uti: sp("public.heic"), TransferName: sp("photo.heic")}
	DecorateAttachmentJSON(&a)
	if a.AttachmentKind != AttachmentKindImage {
		t.Fatalf("kind = %q, want image", a.AttachmentKind)
	}
	if !a.NeedsPreviewConversion {
		t.Fatal("expected HEIC to need preview conversion for clients")
	}
	if a.IsPreviewableImage {
		t.Fatal("HEIC should use the server-generated preview path")
	}
	if a.DisplayKind != DisplayKindImageNeedsPreview {
		t.Fatalf("displayKind = %q, want %q", a.DisplayKind, DisplayKindImageNeedsPreview)
	}
}
