//go:build meshclient

// SPDX-License-Identifier: MIT
package hive

import "context"

// The owner operation of the owner supervisor (src/hive/supervisor/owner_stop.lua).
const (
	OwnerService = "bee.hive.owner"
	OwnerStop    = "bee.hive.owner:stop"
)

// StopOwner asks the owner a local client is enrolled with to shut down. With
// alone set the owner stops only when no other local client is enrolled. It
// reports whether the owner is stopping.
func StopOwner(ctx context.Context, client *Client, alone bool) (bool, error) {
	input := struct {
		Alone bool `json:"alone"`
	}{alone}
	raw, err := callService(ctx, client, Owner{Node: client.owner, Service: OwnerService}, OwnerStop, input)
	if err != nil {
		return false, err
	}
	result, err := decodeServiceObject[struct {
		Stopping bool `json:"stopping"`
	}](raw, "stopping")
	if err != nil {
		return false, err
	}
	return result.Stopping, nil
}
