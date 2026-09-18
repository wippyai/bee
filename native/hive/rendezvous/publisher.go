// SPDX-License-Identifier: MIT

package rendezvous

import (
	"context"
	"errors"

	"github.com/wippyai/runtime/api/boot"
	"github.com/wippyai/runtime/api/cluster"
)

// Publisher is a native boot component for an already selected owner launch.
// Register it only on the path holding the application-state lock. Its Start
// runs after the native cluster, and failure prevents successful boot. No socket
// is created, and no cleanup removes the next owner's descriptor.
func Publisher(directory, execution string) (boot.Component, error) {
	store, err := New(directory)
	if err != nil {
		return nil, err
	}
	return boot.New(boot.P{
		Name: "bee.hive.rendezvous", DependsOn: []boot.Name{"cluster"},
		Start: func(ctx context.Context) error {
			membership := cluster.GetMembership(ctx)
			if membership == nil {
				return errors.New("Bee rendezvous requires a running native cluster")
			}
			descriptor, err := Capture(membership.LocalNode(), execution)
			if err != nil {
				return err
			}
			return store.Publish(ctx, descriptor)
		},
	}), nil
}
