// SPDX-License-Identifier: MIT

package launch

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/netip"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/wippyai/bee/native/hive/invite"
	"github.com/wippyai/bee/native/hive/meshtls"
	"github.com/wippyai/bee/native/internal/privatefile"
)

// hiveCommand is one `bee hive` invocation.
type hiveCommand struct {
	verb   string
	id     string
	node   string
	invite invite.Invite
	// out is the file `bee hive invite --out FILE` writes the invite to.
	out string
	// share is the shared directory `bee hive invite --share DIR` writes the
	// invite into under shareInviteName.
	share string
}

const (
	hiveInvite  = "invite"
	hiveInvites = "invites"
	hiveRevoke  = "revoke"
	hivePeers   = "peers"
	hiveJoin    = "join"
	hiveLeave   = "leave"
	// hiveAwait is the internal step of join that waits for the session.
	hiveAwait = "await"
)

// parseHive decodes `bee hive VERB [ARGUMENT]` before any state is selected.
func parseHive(args []string) (hiveCommand, error) {
	usage := errors.New("bee hive takes invite [--out FILE | --share DIR], invites, peers, revoke INVITE_ID, join INVITE or leave NODE")
	if len(args) < 2 {
		return hiveCommand{}, usage
	}
	verb, rest := args[1], args[2:]
	switch verb {
	case hiveInvite:
		command := hiveCommand{verb: verb}
		for len(rest) > 0 {
			switch rest[0] {
			case "--out", "--share":
				if len(rest) < 2 || rest[1] == "" {
					return hiveCommand{}, fmt.Errorf("bee hive invite %s requires a path", rest[0])
				}
				if rest[0] == "--out" {
					command.out = rest[1]
				} else {
					command.share = rest[1]
				}
				rest = rest[2:]
			default:
				return hiveCommand{}, fmt.Errorf("bee hive invite takes only --out FILE or --share DIR, not %q", rest[0])
			}
		}
		if command.out != "" && command.share != "" {
			return hiveCommand{}, errors.New("bee hive invite takes either --out FILE or --share DIR")
		}
		return command, nil
	case hiveInvites, hivePeers:
		if len(rest) != 0 {
			return hiveCommand{}, fmt.Errorf("bee hive %s takes no arguments", verb)
		}
		return hiveCommand{verb: verb}, nil
	case hiveRevoke:
		if len(rest) != 1 {
			return hiveCommand{}, errors.New("bee hive revoke requires INVITE_ID")
		}
		decoded, err := hex.DecodeString(rest[0])
		if err != nil || len(decoded) != 16 || hex.EncodeToString(decoded) != rest[0] {
			return hiveCommand{}, errors.New("an invite id is 32 lowercase hexadecimal characters")
		}
		return hiveCommand{verb: verb, id: rest[0]}, nil
	case hiveJoin:
		if len(rest) != 1 {
			return hiveCommand{}, errors.New("bee hive join requires INVITE")
		}
		parsed, err := invite.Parse(rest[0])
		if err != nil {
			return hiveCommand{}, err
		}
		return hiveCommand{verb: verb, invite: parsed, node: parsed.Node}, nil
	case hiveLeave:
		if len(rest) != 1 || !invite.ValidNode(rest[0]) {
			return hiveCommand{}, errors.New("bee hive leave requires a NODE identity")
		}
		return hiveCommand{verb: verb, node: rest[0]}, nil
	}
	return hiveCommand{}, usage
}

// redeemInvite joins the hive the invite names on behalf of the node of
// state. It runs only while no owner holds the state, because the node's mesh
// joins the hive when its owner boots. It pins the hive node, and records the
// hive's secret, seed, pool and the leaf the hive node certified.
func redeemInvite(ctx context.Context, state string, line invite.Invite) (result error) {
	unlock, err := lockOwner(ctx, state)
	if errors.Is(err, errOwnerRunning) {
		return errors.New("this Bee is running; a node joins a hive when its owner starts, so stop its owner and join again")
	}
	if err != nil {
		return err
	}
	defer func() { result = errors.Join(result, unlock()) }()
	directory := ownerDirectory(state)
	address, err := selectedMeshAddress(state)
	if err != nil {
		return err
	}
	if err := privatefile.EnsurePrivateDir(ownerPeersDirectory(state)); err != nil {
		return err
	}
	if record, joined, err := readJoined(state); err != nil {
		return err
	} else if joined {
		return fmt.Errorf("this node already joined the hive of %s; leave it first", record.Node)
	}
	peers, err := trustedKeys(ownerPeersDirectory(state))
	if err != nil {
		return err
	}
	if len(peers) > 0 {
		return errors.New("other nodes joined this node's hive; a node with peers cannot join another hive")
	}
	node := ownerNodeName(state)
	if line.Node == node {
		return errors.New("a node cannot join its own hive")
	}
	identity, _, err := ensureIdentityFile(filepath.Join(directory, internodeKeyName))
	if err != nil {
		return err
	}
	authority, err := ensureAuthority(directory, time.Now())
	if err != nil {
		return err
	}
	public, private, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		return err
	}
	certificateAddresses, err := selectedMeshCertificateAddresses(address)
	if err != nil {
		return err
	}
	addressStrings := make([]string, 0, len(certificateAddresses))
	for _, candidate := range certificateAddresses {
		addressStrings = append(addressStrings, candidate.String())
	}
	admission, pinned, path, err := invite.DialCandidates(ctx, line, identity, invite.Request{Node: node,
		Addresses: addressStrings, Key: base64.RawStdEncoding.EncodeToString(public)})
	if err != nil {
		var refused *invite.Refused
		if advice := joinFailureAdvice(line); advice != "" && !errors.As(err, &refused) {
			return fmt.Errorf("%w\n%s", err, advice)
		}
		return err
	}
	// The inviter saw this node's authenticated join path. Adopt it as the
	// advertised address when this host owns it; otherwise record that the
	// node is NATed, so its next boot dials out instead of waiting to be dialed.
	assigned, err := assignedInterfaceAddresses()
	if err != nil {
		return err
	}
	tailnet, _ := tailscaleIdentity()
	if _, _, err := applyObservedAddress(directory, admission.Observed, assigned, tailnet); err != nil {
		return err
	}
	gossip, err := netip.ParseAddrPort(admission.Gossip)
	if err != nil {
		return errors.New("the hive node sent an invalid gossip address")
	}
	gossip = gossipSeedForPath(gossip, path.Endpoint)
	secret, err := base64.StdEncoding.DecodeString(admission.Secret)
	if err != nil || len(secret) != 32 {
		return errors.New("the hive node sent an invalid mesh secret")
	}
	if err := meshtls.Verify([]byte(admission.Certificate), []byte(admission.Authorities), public, time.Now()); err != nil {
		return fmt.Errorf("the hive node sent an invalid mesh certificate: %w", err)
	}
	credential, err := meshtls.Credential([]byte(admission.Certificate), private)
	if err != nil {
		return err
	}
	if _, err := meshtls.Pool(authority.Certificate(), []byte(admission.Authorities)); err != nil {
		return err
	}
	record, err := json.Marshal(joinedRecord{Node: line.Node, Gossip: gossip.String(), Authorities: admission.Authorities, JoinPath: path.Endpoint})
	if err != nil {
		return err
	}
	// The record is written last: a node is joined only once every file it
	// names exists.
	for _, file := range []struct {
		path string
		data []byte
	}{
		{filepath.Join(ownerPeersDirectory(state), line.Node+".pub"), []byte(base64.RawStdEncoding.EncodeToString(pinned) + "\n")},
		{filepath.Join(directory, joinedSecretName), []byte(base64.StdEncoding.EncodeToString(secret) + "\n")},
		{filepath.Join(directory, joinedCredentialName), credential},
		{filepath.Join(directory, joinedRecordName), record},
	} {
		if err := writeOwnerFile(file.path, file.data); err != nil {
			return err
		}
	}
	return nil
}

// leaveHive retires the Hive peer node of state: its pin leaves the peers
// directory, so the owner's enrollment retires it and ends its session. When
// node is the hive this node joined, the joined record goes too and the next
// owner boot uses the node's own mesh.
func leaveHive(out io.Writer, state, node string) error {
	if !invite.ValidNode(node) || !validTrustedName(node) {
		return errors.New("invalid node identity")
	}
	record, joined, err := readJoined(state)
	if err != nil {
		return err
	}
	pin := filepath.Join(ownerPeersDirectory(state), node+".pub")
	removed := os.Remove(pin)
	if err := os.Remove(filepath.Join(ownerPeersDirectory(state), node+peerAddressSuffix)); err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	if errors.Is(removed, os.ErrNotExist) {
		if !joined || record.Node != node {
			return fmt.Errorf("%s is not a peer of this node", node)
		}
	} else if removed != nil {
		return removed
	}
	if joined && record.Node == node {
		directory := ownerDirectory(state)
		if err := os.Remove(filepath.Join(directory, joinedRecordName)); err != nil {
			return err
		}
		for _, name := range []string{joinedSecretName, joinedCredentialName} {
			if err := os.Remove(filepath.Join(directory, name)); err != nil && !errors.Is(err, os.ErrNotExist) {
				return err
			}
		}
	}
	_, err = fmt.Fprintf(out, "Left %s\n", strings.TrimSpace(node))
	return err
}

// shareInviteName is the file `bee hive invite --share DIR` writes in the
// shared directory the person picked.
const shareInviteName = "bee-hive-invite.txt"

// writeInviteFile writes the one-line invite to path with owner-only
// permissions and returns the absolute path. The invite is a single-use
// credential, so the file is written atomically and never world readable.
func writeInviteFile(path, line string) (string, error) {
	absolute, err := filepath.Abs(path)
	if err != nil {
		return "", err
	}
	if _, err := os.Stat(absolute); err == nil {
		return "", fmt.Errorf("%s already exists; remove it or pick another path", absolute)
	} else if !errors.Is(err, os.ErrNotExist) {
		return "", err
	}
	if err := writeOwnerFile(absolute, []byte(line+"\n")); err != nil {
		return "", err
	}
	return absolute, nil
}

// writeSharedInvite writes the invite into the shared directory the person
// picked, under shareInviteName, and returns the absolute file path.
func writeSharedInvite(directory, line string) (string, error) {
	absolute, err := filepath.Abs(directory)
	if err != nil {
		return "", err
	}
	info, err := os.Stat(absolute)
	if err != nil {
		return "", fmt.Errorf("shared path %s: %w", absolute, err)
	}
	if !info.IsDir() {
		return "", fmt.Errorf("shared path %s is not a directory", absolute)
	}
	return writeInviteFile(filepath.Join(absolute, shareInviteName), line)
}

// inviteHint tells the person how the other node uses an invite. It goes to
// stderr so the invite stays the only line on stdout.
func inviteHint(line string) string {
	return "Single use. On the node that joins, with its Bee stopped, run:\n  bee hive join " + line + "\n"
}

// inviteFileHint tells the person how to use an invite that was written to a
// file instead of printed. The file, not the terminal, carries the secret.
func inviteFileHint(path string) string {
	return "Single use. Carry " + path + " to the node that joins, then, with its Bee stopped, run:\n  bee hive join \"$(cat " + path + ")\"\n"
}
