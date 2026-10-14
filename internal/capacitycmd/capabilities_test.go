package capacitycmd

import (
	"bytes"
	"strings"
	"testing"
)

func TestCapabilitiesDoNotRequireQAConfigurationOrHostLeases(t *testing.T) {
	var output bytes.Buffer
	if err := Run([]string{"capabilities"}, &output); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(output.String(), "resident-memory-v7") || !strings.Contains(output.String(), "fenced-start-memory-v6") || !strings.Contains(output.String(), "standalone-owner-init-v1") {
		t.Fatal("native start protocol not declared", output.String())
	}
}
