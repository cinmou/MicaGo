package send

import (
	"context"
	"errors"
	"os/exec"
	"runtime"
)

// MessagesRunning reports whether the Messages.app process is currently running.
// AppleScript send requires Messages to be open, so the send path uses this as a
// fast precondition. It is a lightweight, macOS-local check (`pgrep -x Messages`)
// that needs no Automation permission.
//
// On non-darwin platforms it returns true (don't block). If the probe itself
// cannot run (e.g. pgrep missing), it returns an error so the caller can choose
// to proceed rather than wrongly block a send.
func MessagesRunning(ctx context.Context) (bool, error) {
	if runtime.GOOS != "darwin" {
		return true, nil
	}

	err := exec.CommandContext(ctx, "pgrep", "-x", "Messages").Run()
	if err == nil {
		return true, nil
	}

	// pgrep exits 1 when there is no matching process — that is a definitive
	// "not running", not a probe failure.
	var exitErr *exec.ExitError
	if errors.As(err, &exitErr) && exitErr.ExitCode() == 1 {
		return false, nil
	}
	return false, err
}
