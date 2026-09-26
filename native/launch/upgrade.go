// SPDX-License-Identifier: MIT

package launch

import (
	"context"
	"errors"
	"fmt"
	"os"
)

type upgradeCommand struct {
	candidate string
	digest    string
	rollback  bool
}

func parseUpgradeCommand(args []string) (upgradeCommand, error) {
	if len(args) == 1 && args[0] == "--rollback" {
		return upgradeCommand{rollback: true}, nil
	}
	if len(args) != 3 || args[0] == "" || args[1] != "--digest" || args[2] == "" {
		return upgradeCommand{}, errors.New("bee upgrade requires PATH --digest SHA256 or --rollback")
	}
	return upgradeCommand{candidate: args[0], digest: args[2]}, nil
}

func (host *Host) runUpgrade(ctx context.Context, state, dir string, request upgradeCommand) error {
	seams := host.cutoverSeams()
	if request.rollback {
		if err := runCutoverRollback(ctx, state, dir, seams); err != nil {
			return err
		}
		_, err := fmt.Fprintln(os.Stdout, "Bee rolled back to the previous version.")
		return err
	}
	result, err := runCutover(ctx, CutoverRequest{
		State: state, Dir: dir, Candidate: request.candidate, ConfirmedDigest: request.digest,
	}, seams)
	if err != nil {
		return err
	}
	_, err = fmt.Fprintf(os.Stdout, "Bee upgraded to %s. The previous version is retained; run bee upgrade --rollback to restore it.\n", result.Digest)
	return err
}
