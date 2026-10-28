// Package farmcapacity owns native builder admission and fenced lifecycle recovery.
package farmcapacity

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"regexp"
	"strings"
	"time"
)

// BindUnregistered recovers only a positively exited, routing-gated native
// owner. Absence of local diagnostics alone never authorizes removal.
func BindUnregistered(ctx context.Context, id, name, organization, tokenPath string) (*FrozenOwner, error) {
	if !idPattern.MatchString(id) || !namePattern.MatchString(name) {
		return nil, errors.New("invalid unregistered native identity")
	}
	owner := &FrozenOwner{ID: id, Name: name, Organization: organization, TokenPath: tokenPath, Unregistered: true}
	item, err := owner.container(ctx)
	if err != nil {
		return nil, err
	}
	if !item.Exited || !item.RoutingGated {
		return nil, errors.New("unregistered recovery requires an exited gated native owner")
	}
	owner.RunnerName = item.RegistrationName
	if !unregisteredName(name, owner.RunnerName) {
		return nil, errors.New("unregistered name is not bound to the native slot")
	}
	gone, err := owner.RemoteGone(ctx)
	if err != nil {
		return nil, err
	}
	if !gone {
		return nil, errors.New("unregistered native name still exists remotely")
	}
	return owner, nil
}

func unregisteredName(name, expected string) bool {
	return registrationNameMatches(name, expected, false)
}

func registrationNameMatches(name, expected string, legacy bool) bool {
	prefix, matched := strings.CutSuffix(expected, "-"+name)
	return (namePattern.MatchString(name) || (legacy && legacyNamePattern.MatchString(name))) && matched && regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]*$`).MatchString(prefix)
}

// Every page must be complete and scope-authorized. A name is used only to
// prove absence; this mode can never delete a remote registration by name.
func (o *FrozenOwner) unregisteredGone(ctx context.Context) (bool, error) {
	if o.RunnerID != 0 || !unregisteredName(o.Name, o.RunnerName) {
		return false, errors.New("unregistered withdrawal identity is invalid")
	}
	data, err := readPrivateFarmCredential(o.TokenPath)
	if err != nil {
		return false, err
	}
	token := strings.TrimSpace(string(data))
	if token == "" || strings.ContainsAny(token, "\r\n") {
		return false, errors.New("native farm credential is invalid")
	}
	client := o.client
	if client == nil {
		client = &http.Client{Timeout: 10 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	}
	total := -1
	seen := map[int64]bool{}
	for page := 1; page <= 100; page++ {
		endpoint := fmt.Sprintf("https://api.github.com/orgs/%s/actions/runners?per_page=100&page=%d", url.PathEscape(o.Organization), page)
		req, requestErr := http.NewRequestWithContext(ctx, http.MethodGet, endpoint, http.NoBody)
		if requestErr != nil {
			return false, requestErr
		}
		req.Header.Set("Authorization", "Bearer "+token)
		req.Header.Set("Accept", "application/vnd.github+json")
		response, requestErr := client.Do(req)
		if requestErr != nil {
			return false, errors.New("unregistered scope absence request did not complete")
		}
		listing, decodeErr := readUnregisteredPage(response)
		if decodeErr != nil {
			return false, decodeErr
		}
		if total == -1 {
			total = *listing.Total
		}
		if total != *listing.Total || len(listing.Runners) != min(100, total-len(seen)) {
			return false, errors.New("unregistered scope pagination changed or is incomplete")
		}
		for _, runner := range listing.Runners {
			if runner.ID <= 0 || runner.Name == "" || seen[runner.ID] {
				return false, errors.New("unregistered scope runner identity is incomplete")
			}
			if runner.Name == o.RunnerName {
				return false, nil
			}
			seen[runner.ID] = true
		}
		if len(seen) == total {
			return true, nil
		}
	}
	return false, errors.New("unregistered scope pagination exceeded its bound")
}

type unregisteredListing struct {
	Total   *int           `json:"total_count"`
	Runners []remoteRunner `json:"runners"`
}

func readUnregisteredPage(response *http.Response) (unregisteredListing, error) {
	var listing unregisteredListing
	bounded := &io.LimitedReader{R: response.Body, N: 8<<20 + 1}
	decoder := json.NewDecoder(bounded)
	decodeErr := decoder.Decode(&listing)
	endErr := decoder.Decode(new(any))
	closeErr := response.Body.Close()
	if response.StatusCode != http.StatusOK || decodeErr != nil || endErr != io.EOF || closeErr != nil || bounded.N <= 0 || listing.Total == nil || *listing.Total < 0 || listing.Runners == nil {
		return listing, errors.New("unregistered scope absence response is unproved")
	}
	return listing, nil
}
