// Package farmcapacity owns native builder admission and fenced lifecycle recovery.
package farmcapacity

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/url"
	"os"
	"slices"
	"strconv"
	"strings"
	"time"
)

const (
	awaitingIdentityLabel   = "crf-shared-awaiting-identity"
	platformSelfHostedLabel = "self-hosted"
	platformLinuxLabel      = "linux"
	platformX64Label        = "x64"
)

func routingEnvironment(environment, labels []string) bool {
	if len(labels) == 0 || slices.Contains(labels, "") || slices.Contains(labels, awaitingIdentityLabel) {
		return false
	}
	values := map[string]string{}
	for _, entry := range environment {
		key, value, _ := strings.Cut(entry, "=")
		values[key] = value
	}
	return values["NO_DEFAULT_LABELS"] == "true" && values["LABELS"] == awaitingIdentityLabel && values["RUNNER_LABELS"] == ""
}

// PublishRouting makes the registration job-eligible only after its immutable
// identity and allocation fence are durable. Retries retain the allocation.
func (c *Controller) PublishRouting(ctx context.Context, owner *FrozenOwner) error {
	owned, err := c.load(owner.Name)
	if err != nil {
		return err
	}
	if owned.ID != owner.ID || owned.Withdrawal == nil || owned.Withdrawal.RunnerID != owner.RunnerID || owned.Withdrawal.RunnerName != owner.RunnerName {
		return errors.New("routing requires the durable exact registration")
	}
	if owned.Retiring || owned.Withdrawal.Phase != "" {
		return nil
	} // Withdrawal owns the closed routing until release.
	snapshot, err := c.Broker.Status(&c.Policy)
	if err != nil {
		return err
	}
	grant, exists := snapshot.Grants["build:"+owner.Name]
	if !exists || grant.Fence != owned.Fence {
		return errors.New("routing requires the current allocation fence")
	}
	item, err := c.Docker.Inspect(ctx, owner.ID)
	if err != nil {
		return err
	}
	if err := c.validate(item, owner.Name); err != nil {
		return err
	}
	resources, resourceErr := containerResources(item)
	if resourceErr != nil || grant.Pool != buildPool || grant.Cost != resources {
		return errors.New("routing hard limits differ from the charged build allocation")
	}
	// Previously running legacy builders have already accepted jobs. Adoption
	// records their identity without altering their routing or workload.
	if len(item.RoutingLabels) == 0 || (len(item.RoutingLabels) == 1 && item.RoutingLabels[0] == "") {
		return nil
	}
	if !item.RoutingGated || !item.Running || item.Paused || item.ID != owner.ID {
		return errors.New("routing requires an attested live gated listener")
	}
	publicationErr := owner.publishRouting(ctx, item.RoutingLabels)
	if errors.Is(publicationErr, os.ErrNotExist) {
		// Scope-authorized absence cannot publish routing. Keep the exact owner
		// charged and let rebalance prove native idle, freeze, and settle it.
		// Rejecting here would prevent that recovery from ever binding the owner.
		return nil
	}
	return publicationErr
}

func (o *FrozenOwner) publishRouting(ctx context.Context, labels []string) error {
	runner, err := o.remote(ctx)
	if err != nil {
		return err
	}
	actual := make([]string, 0, len(runner.Labels))
	for _, label := range runner.Labels {
		actual = append(actual, label.Name)
	}
	wanted := slices.Clone(labels)
	slices.Sort(actual)
	slices.Sort(wanted)
	if publishedRoutingMatches(actual, wanted) {
		return nil // A retry may observe a job that started after publication.
	}
	if *runner.Busy || !slices.Equal(actual, []string{awaitingIdentityLabel}) {
		return errors.New("unpublished native registration has unexpected routing or a job")
	}
	return o.replaceRouting(ctx, labels)
}

// GitHub canonicalizes common platform labels (Linux/X64). Older exact owned
// registrations may also receive those common labels through operator routing
// repair. Preserve published routing without a PUT when only these labels differ;
// every job/class label remains exact and every requested platform is required.
func publishedRoutingMatches(actual, wanted []string) bool {
	platform := func(label string) string {
		switch strings.ToLower(label) {
		case platformSelfHostedLabel, platformLinuxLabel, platformX64Label:
			return strings.ToLower(label)
		default:
			return ""
		}
	}
	actualPlatforms := map[string]bool{}
	actualJobs := []string{}
	for _, label := range actual {
		if key := platform(label); key != "" {
			if actualPlatforms[key] {
				return false
			}
			actualPlatforms[key] = true
		} else {
			actualJobs = append(actualJobs, label)
		}
	}
	wantedJobs := []string{}
	for _, label := range wanted {
		if key := platform(label); key != "" {
			if !actualPlatforms[key] {
				return false
			}
		} else {
			wantedJobs = append(wantedJobs, label)
		}
	}
	slices.Sort(actualJobs)
	slices.Sort(wantedJobs)
	return slices.Equal(actualJobs, wantedJobs)
}

func (o *FrozenOwner) replaceRouting(ctx context.Context, labels []string) error {
	credential, err := readPrivateFarmCredential(o.TokenPath)
	if err != nil {
		return err
	}
	body, err := json.Marshal(struct {
		Labels []string `json:"labels"`
	}{Labels: labels})
	if err != nil {
		return err
	}
	endpoint := "https://api.github.com/orgs/" + url.PathEscape(o.Organization) + "/actions/runners/" + strconv.FormatInt(o.RunnerID, 10) + "/labels"
	request, err := http.NewRequestWithContext(ctx, http.MethodPut, endpoint, strings.NewReader(string(body)))
	if err != nil {
		return err
	}
	request.Header.Set("Authorization", "Bearer "+strings.TrimSpace(string(credential)))
	request.Header.Set("Accept", "application/vnd.github+json")
	request.Header.Set("Content-Type", "application/json")
	client := o.client
	if client == nil {
		client = &http.Client{Timeout: 10 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	}
	response, err := client.Do(request)
	if err != nil {
		return errors.New("native routing publication did not complete; allocation retained")
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return errors.New("native routing publication failed; allocation retained")
	}
	return nil
}
