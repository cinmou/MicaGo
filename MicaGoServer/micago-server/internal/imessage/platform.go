package imessage

import (
	"os/exec"
	"runtime"
	"strconv"
	"strings"
)

const minimumActionMacOS = "13.0"

type PlatformSupport struct {
	Supported    bool
	Reason       string
	Warning      string
	MinimumMacOS string
}

var detectMacOSProductVersion = defaultDetectMacOSProductVersion
var currentGOOS = runtime.GOOS

func ActionPlatformSupport() PlatformSupport {
	out := PlatformSupport{
		Supported:    true,
		MinimumMacOS: minimumActionMacOS,
	}
	if currentGOOS != "darwin" {
		out.Supported = false
		out.Reason = "advanced iMessage actions require macOS and Messages.app"
		return out
	}
	version := strings.TrimSpace(detectMacOSProductVersion())
	major := macOSMajor(version)
	if major == 0 {
		out.Warning = "could not determine the macOS version; helper capability probing will continue"
		return out
	}
	if major < 13 {
		out.Supported = false
		out.Reason = "advanced iMessage actions require macOS 13 or newer"
		return out
	}
	if major >= 26 {
		out.Warning = "macOS 26/Tahoe may block private IMCore actions through library validation or private entitlement checks"
	}
	return out
}

func (p PlatformSupport) apply(c Capabilities) Capabilities {
	c.MinimumMacOS = p.MinimumMacOS
	c.PlatformSupported = p.Supported
	c.PlatformWarning = p.Warning
	if !p.Supported && c.Reason == "" {
		c.Reason = p.Reason
	}
	return c
}

func defaultDetectMacOSProductVersion() string {
	out, err := exec.Command("sw_vers", "-productVersion").Output()
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(out))
}

func macOSMajor(version string) int {
	version = strings.TrimSpace(version)
	if version == "" {
		return 0
	}
	head, _, _ := strings.Cut(version, ".")
	major, err := strconv.Atoi(head)
	if err != nil {
		return 0
	}
	return major
}
