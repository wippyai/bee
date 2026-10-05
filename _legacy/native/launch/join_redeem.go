//go:build meshclient

// SPDX-License-Identifier: MIT

package launch

import (
	"context"
	"errors"

	"github.com/wippyai/bee/native/client/hive"
	"github.com/wippyai/bee/native/client/mesh"
	"github.com/wippyai/bee/native/hive/invite"
)

// supervisorRedeemer sends each redemption to the owner's own supervisor from
// the join host endpoint.
type supervisorRedeemer struct {
	endpoint *mesh.Endpoint
	node     string
	lifetime context.Context
	cancel   context.CancelFunc
}

func openRedeemer(ctx context.Context, node string) (redeemer, error) {
	endpoint, err := mesh.OpenEndpoint(ctx, joinHost)
	if err != nil {
		return nil, err
	}
	lifetime, cancel := context.WithCancel(context.WithoutCancel(ctx))
	return &supervisorRedeemer{endpoint: endpoint, node: node, lifetime: lifetime, cancel: cancel}, nil
}

// Redeem uses a fresh client per redemption, so an uncertain earlier outcome
// never blocks a later joiner; the listener serializes redemptions.
func (r *supervisorRedeemer) Redeem(ctx context.Context, id, secret, node string) error {
	join, err := hive.NewJoin(r.lifetime, r.endpoint, r.node)
	if err != nil {
		return err
	}
	err = join.Redeem(ctx, id, secret, node)
	var rejected *hive.Rejected
	if errors.As(err, &rejected) {
		return &invite.Refused{Code: rejected.Fault.Code, Message: rejected.Fault.Message}
	}
	return err
}

func (r *supervisorRedeemer) Close() {
	r.cancel()
	r.endpoint.Close()
}
