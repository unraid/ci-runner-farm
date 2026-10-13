// Package farmcapacity owns native builder admission and fenced lifecycle recovery.
package farmcapacity

import (
	"context"
	"encoding/json"
	"net/http"
	"testing"
)

const (
	awaitingEnvironment      = "LABELS=" + awaitingIdentityLabel
	noDefaultEnvironment     = "NO_DEFAULT_LABELS=true"
	ownerNameForRoutingTest  = "owned-runner"
	largeClassForRoutingTest = "build-large"
	osClassForRoutingTest    = "os-build"
	largeSizeForRoutingTest  = "size-large"
)

func TestRoutingRequiresDurableRegistrationAndRecoversPublication(t *testing.T) {
	c, d, id := fixture(t)
	ctx := context.Background()
	if err := c.Start(ctx, testName, id); err != nil {
		t.Fatal(err)
	}
	d.containers[id].RoutingGated = true
	d.containers[id].RoutingLabels = []string{platformSelfHostedLabel, testRegistrationOrganization, buildPool}
	published := false
	puts := 0
	owner := remoteFixture(t, func(request *http.Request) (*http.Response, error) {
		if request.Method == http.MethodPut {
			var body struct {
				Labels []string `json:"labels"`
			}
			if err := json.NewDecoder(request.Body).Decode(&body); err != nil || len(body.Labels) != 3 {
				t.Fatal("routing body differs")
			}
			puts++
			published = true
			return ownerResponse(http.StatusOK, `{}`), nil
		}
		if published {
			return ownerResponse(http.StatusOK, `{"id":123,"name":"owned-runner","status":"online","busy":true,"labels":[{"name":"build"},{"name":"unraid"},{"name":"self-hosted"}]}`), nil
		}
		return ownerResponse(http.StatusOK, `{"id":123,"name":"owned-runner","status":"online","busy":false,"labels":[{"name":"crf-shared-awaiting-identity"}]}`), nil
	})
	owner.ID = id
	owner.Name = testName
	if err := c.PublishRouting(ctx, owner); err == nil || puts != 0 {
		t.Fatal("unrecorded registration became eligible")
	}
	if err := c.RecordRegistration(testName, id, 123, "owned-runner"); err != nil {
		t.Fatal(err)
	}
	if err := c.PublishRouting(ctx, owner); err != nil || puts != 1 {
		t.Fatalf("publication failed: %v", err)
	}
	// A job may run immediately after publication. Retry must retain routing.
	if err := c.PublishRouting(ctx, owner); err != nil || puts != 1 {
		t.Fatalf("busy publication recovery failed: %v", err)
	}
	if err := c.Broker.Release(&c.Policy, "build:"+testName, "wrong-fence", nil); err == nil {
		t.Fatal("fence changed")
	}
}

func TestUnpublishedRoutingRejectsBusyOrUnexpectedLabels(t *testing.T) {
	for _, body := range []string{
		`{"id":123,"name":"owned-runner","status":"online","busy":true,"labels":[{"name":"crf-shared-awaiting-identity"}]}`,
		`{"id":123,"name":"owned-runner","status":"online","busy":false,"labels":[{"name":"self-hosted"}]}`,
		`{"id":123,"name":"owned-runner","status":"online","busy":false}`,
	} {
		puts := 0
		owner := remoteFixture(t, func(request *http.Request) (*http.Response, error) {
			if request.Method == http.MethodPut {
				puts++
			}
			return ownerResponse(http.StatusOK, body), nil
		})
		if err := owner.publishRouting(context.Background(), []string{buildPool}); err == nil || puts != 0 {
			t.Fatal("ambiguous routing published")
		}
	}
}

func TestAbsentRoutingRetainsChargedOwnerForFrozenRecovery(t *testing.T) {
	for _, authorized := range []bool{false, true} {
		t.Run(map[bool]string{false: "unproved-scope", true: "authorized-absence"}[authorized], func(t *testing.T) {
			c, d, id := fixture(t)
			ctx := context.Background()
			if err := c.Start(ctx, testName, id); err != nil {
				t.Fatal(err)
			}
			d.containers[id].RoutingGated = true
			d.containers[id].RoutingLabels = []string{buildPool}
			mutations := 0
			owner := remoteFixture(t, func(request *http.Request) (*http.Response, error) {
				if request.Method != http.MethodGet {
					mutations++
				}
				if request.URL.Query().Get("per_page") == "1" {
					if authorized {
						return ownerResponse(http.StatusOK, `{"total_count":0,"runners":[]}`), nil
					}
					return ownerResponse(http.StatusForbidden, `{}`), nil
				}
				return ownerResponse(http.StatusNotFound, `{}`), nil
			})
			owner.ID, owner.Name = id, testName
			if err := c.RecordRegistration(testName, id, owner.RunnerID, owner.RunnerName); err != nil {
				t.Fatal(err)
			}
			before, err := c.load(testName)
			if err != nil {
				t.Fatal(err)
			}
			err = c.PublishRouting(ctx, owner)
			if (err == nil) != authorized || mutations != 0 {
				t.Fatalf("absence routing: authorized=%t mutations=%d error=%v", authorized, mutations, err)
			}
			assertRoutingAbsenceRetained(t, c, before)
		})
	}
}

func assertRoutingAbsenceRetained(t *testing.T, c *Controller, before *receipt) {
	t.Helper()
	after, err := c.load(testName)
	if err != nil || after.Fence != before.Fence || after.ID != before.ID || after.Withdrawal.Phase != "" || after.Maintenance {
		t.Fatal("routing absence changed withdrawal ownership")
	}
	snapshot, err := c.Broker.Status(&c.Policy)
	if err != nil || snapshot.Grants["build:"+testName].Fence != before.Fence {
		t.Fatal("routing absence released the charged allocation")
	}
}

func TestRoutingEnvironmentClosesNewBuildsWithoutDefaultLabels(t *testing.T) {
	desired := []string{platformSelfHostedLabel, testRegistrationOrganization, buildPool}
	good := []string{awaitingEnvironment, noDefaultEnvironment}
	if !routingEnvironment(good, desired) {
		t.Fatal("inert routing rejected")
	}
	for _, environment := range [][]string{
		{"LABELS=build", noDefaultEnvironment},
		{awaitingEnvironment},
		{awaitingEnvironment, noDefaultEnvironment, "RUNNER_LABELS=build"},
	} {
		if routingEnvironment(environment, desired) {
			t.Fatal("job-eligible environment accepted")
		}
	}
	c, d, id := fixture(t)
	d.containers[id].NeverStarted = true
	if err := c.Start(context.Background(), testName, id); err == nil || d.starts != 0 {
		t.Fatal("ungated new owner started")
	}
}

func TestPublishedPlatformRoutingRetainsBusyExactRegistration(t *testing.T) {
	for _, actual := range [][]string{
		{platformSelfHostedLabel, "Linux", "X64", testRegistrationOrganization, buildPool, osClassForRoutingTest},
		{platformSelfHostedLabel, platformLinuxLabel, platformX64Label, testRegistrationOrganization, buildPool, osClassForRoutingTest},
	} {
		puts := 0
		owner := remoteFixture(t, func(request *http.Request) (*http.Response, error) {
			if request.Method == http.MethodPut {
				puts++
			}
			labels := make([]map[string]string, 0, len(actual))
			for _, label := range actual {
				labels = append(labels, map[string]string{"name": label})
			}
			body, err := json.Marshal(map[string]any{"id": 123, "name": ownerNameForRoutingTest, "status": "online", "busy": true, "labels": labels})
			if err != nil {
				t.Fatal(err)
			}
			return ownerResponse(http.StatusOK, string(body)), nil
		})
		for _, wanted := range [][]string{
			{platformSelfHostedLabel, testRegistrationOrganization, buildPool, osClassForRoutingTest},
			{platformSelfHostedLabel, platformLinuxLabel, platformX64Label, testRegistrationOrganization, buildPool, osClassForRoutingTest},
		} {
			if err := owner.publishRouting(context.Background(), wanted); err != nil || puts != 0 {
				t.Fatalf("busy exact platform routing altered or rejected: %v, puts=%d", err, puts)
			}
		}
	}
}

func TestPublishedRoutingRejectsJobDriftAndMissingPlatforms(t *testing.T) {
	wanted := []string{platformLinuxLabel, platformX64Label, largeClassForRoutingTest, largeSizeForRoutingTest}
	for _, actual := range [][]string{
		{platformLinuxLabel, platformX64Label, buildPool, largeSizeForRoutingTest},
		{platformLinuxLabel, platformX64Label, "BUILD-LARGE", largeSizeForRoutingTest},
		{platformLinuxLabel, platformX64Label, largeClassForRoutingTest, largeSizeForRoutingTest, "unraid"},
		{platformLinuxLabel, largeClassForRoutingTest, largeSizeForRoutingTest},
		{platformLinuxLabel, platformX64Label, "Linux", largeClassForRoutingTest, largeSizeForRoutingTest},
		{platformLinuxLabel, platformX64Label, largeClassForRoutingTest, largeSizeForRoutingTest, awaitingIdentityLabel},
	} {
		if publishedRoutingMatches(actual, wanted) {
			t.Fatalf("routing drift accepted: %v", actual)
		}
	}
}
