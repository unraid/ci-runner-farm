package capacitycmd

import (
	"bytes"
	"strings"
	"testing"
)

func TestCurrentOwnerSelector(t *testing.T) {
	for _, id := range []string{"1", "123", "9223372036854775807"} {
		args := []string{"status", "--current-owner", id}
		if !validArguments(args) {
			t.Fatal("current owner selector unavailable", id)
		}
	}
	for _, id := range []string{"0", "-1", "+1", "01", " 1", "1\n", "9223372036854775808", "1.0", "", "runner"} {
		if validArguments([]string{"status", "--current-owner", id}) {
			t.Fatal("invalid current selector accepted", id)
		}
	}
	for _, args := range [][]string{{"status", "--current-owner"}, {"status", "--current-owner", "1", "extra"}, {"status", "--owners", "1"}} {
		if validArguments(args) {
			t.Fatal("unclosed current selector accepted", args)
		}
	}
	var output bytes.Buffer
	if err := Run([]string{"capabilities"}, &output); err != nil || !strings.Contains(output.String(), "current-owner-read-v1") {
		t.Fatal("current read capability unavailable", err)
	}
}
