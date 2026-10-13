package sharedcapacity

import (
	"bytes"
	"encoding/json"
	"testing"
)

func TestBuildFloorIncreaseRequiresUnchangedPolicyAndExistingIdentities(t *testing.T) {
	previous := Policy{Budget: Resources{MemoryMiB: 112000, VCPUs: 28}, AgingSeconds: 600, Pools: map[string]Pool{
		buildPool: {Cost: Resources{MemoryMiB: 12288, VCPUs: 4}, Minimum: 2, Maximum: 7, MinimumRequestIDs: []string{"build:ci-runner-build-1", "build:ci-runner-build-2"}},
	}}
	for _, test := range []struct {
		name   string
		change func(*Policy)
	}{
		{"increase", func(*Policy) {}},
		{"changed budget", func(p *Policy) { p.Budget.MemoryMiB++ }},
		{"cpu admission", func(p *Policy) { p.CPUAdmission = CPUAdmissionSoft }},
		{"aging", func(p *Policy) { p.AgingSeconds++ }},
		{"changed default cost", func(p *Policy) { b := p.Pools[buildPool]; b.Cost.MemoryMiB++; p.Pools[buildPool] = b }},
		{"maximum", func(p *Policy) { b := p.Pools[buildPool]; b.Maximum++; p.Pools[buildPool] = b }},
		{"changed priority", func(p *Policy) { b := p.Pools[buildPool]; b.Priority++; p.Pools[buildPool] = b }},
		{"identity replacement", func(p *Policy) { p.Pools[buildPool].MinimumRequestIDs[0] = "replacement" }},
		{"aggregate guarantee", func(p *Policy) { b := p.Pools[buildPool]; b.MinimumRequestIDs = nil; p.Pools[buildPool] = b }},
		{"decrease", func(p *Policy) {
			b := p.Pools[buildPool]
			b.Minimum = 1
			b.MinimumRequestIDs = b.MinimumRequestIDs[:1]
			p.Pools[buildPool] = b
		}},
		{"noop", func(p *Policy) {
			b := p.Pools[buildPool]
			b.Minimum = 2
			b.MinimumRequestIDs = b.MinimumRequestIDs[:2]
			p.Pools[buildPool] = b
		}},
		{"invalid", func(p *Policy) { p.Budget.MemoryMiB = 1 }},
	} {
		t.Run(test.name, func(t *testing.T) {
			data, err := json.Marshal(previous)
			if err != nil {
				t.Fatal(err)
			}
			var revised Policy
			if err = json.Unmarshal(data, &revised); err != nil {
				t.Fatal(err)
			}
			build := revised.Pools[buildPool]
			build.Minimum = 4
			build.MinimumRequestIDs = append(build.MinimumRequestIDs, "build:ci-runner-build-3", "build:ci-runner-build-4")
			revised.Pools[buildPool] = build
			test.change(&revised)
			before := append([]byte(nil), data...)
			if got := IsBuildFloorIncrease(&previous, &revised); got != (test.name == "increase") {
				t.Fatalf("classification = %v", got)
			}
			data, err = json.Marshal(previous)
			if err != nil {
				t.Fatal(err)
			}
			if !bytes.Equal(data, before) {
				t.Fatal("classification mutated current policy")
			}
		})
	}
	if IsBuildFloorIncrease(nil, &previous) || IsBuildFloorIncrease(&previous, nil) {
		t.Fatal("invalid input or alias mutation")
	}
}
