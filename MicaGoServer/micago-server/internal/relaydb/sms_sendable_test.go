package relaydb

import "testing"

// C20: SMS sendability is server-authoritative and decided only by the service
// name + the AllowSMSSend setting — never the GUID/handle shape.
func TestServiceSendable(t *testing.T) {
	off := DefaultSyncSettings() // AllowSMSSend defaults off
	on := DefaultSyncSettings()
	on.AllowSMSSend = true

	cases := []struct {
		service string
		wantOff bool
		wantOn  bool
	}{
		{"iMessage", true, true},
		{"iMessageLite", true, true},
		{"SMS", false, true},
		{"Text", false, true},
		{"RCS", false, false},
		{"unknown", false, false},
		{"", false, false},
	}
	for _, c := range cases {
		if got := off.ServiceSendable(c.service); got != c.wantOff {
			t.Errorf("ServiceSendable(%q) off = %v, want %v", c.service, got, c.wantOff)
		}
		if got := on.ServiceSendable(c.service); got != c.wantOn {
			t.Errorf("ServiceSendable(%q) on = %v, want %v", c.service, got, c.wantOn)
		}
	}
}
