package authcmd

import (
	"io"
	"testing"
)

func TestRejectsRemovedAllocationAndDiagnosticCommands(t *testing.T) {
	for _, args := range [][]string{
		nil, {"capabilities"}, {"initialize"}, {"status"},
		{"status", "--owners"}, {"status", "--current-owner", "123"},
		{"start", "runner", "id"}, {"expand-pools", "epoch", "request"},
		{"github-app-token"}, {"github-app-token", "1", "2", "key", "token", "extra"},
	} {
		if err := Run(args, io.Discard); err == nil {
			t.Fatalf("unsupported command accepted: %q", args)
		}
	}
}

func TestTokenCommandValidatesIDsBeforeReadingFiles(t *testing.T) {
	if err := Run([]string{"github-app-token", "invalid", "2", "unread-key", "unwritten-token"}, io.Discard); err == nil || err.Error() != "github-app-token requires numeric app and installation ids" {
		t.Fatalf("wrong token validation: %v", err)
	}
}
