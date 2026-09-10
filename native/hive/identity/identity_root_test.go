// SPDX-License-Identifier: MIT
package identity

import (
	"context"
	"crypto/ed25519"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestRootIdentityRejectsCorruptedSeedAndTrailingData(t *testing.T) {
	for _, mode := range []string{"seed", "trailing", "missing-id", "unknown-secret", "duplicate"} {
		t.Run(mode, func(t *testing.T) {
			dir := filepath.Join(t.TempDir(), "identity")
			_, err := OpenOrCreate(context.Background(), dir)
			if err != nil {
				t.Fatal(err)
			}
			path := filepath.Join(dir, IdentityFileName)
			data, _ := os.ReadFile(path)
			var rec persistedIdentity
			if err = json.Unmarshal(data, &rec); err != nil {
				t.Fatal(err)
			}
			switch mode {
			case "seed":
				key, _ := hex.DecodeString(rec.PrivateKey)
				key[0] ^= 1
				rec.PrivateKey = hex.EncodeToString(key)
				data, _ = json.Marshal(rec)
			case "trailing":
				data = append(data, []byte(" {}")...)
			case "missing-id":
				rec.MachineID = ""
				data, _ = json.Marshal(rec)
			case "unknown-secret":
				data = append([]byte(`{"SECRET_SENTINEL":1,`), data[1:]...)
			case "duplicate":
				data = append([]byte(`{"version":2,`), data[1:]...)
			}
			if err = os.WriteFile(path, data, 0600); err != nil {
				t.Fatal(err)
			}
			_, err = OpenOrCreate(context.Background(), dir)
			if err == nil {
				t.Fatal("invalid identity accepted")
			}
			if strings.Contains(err.Error(), "SECRET_SENTINEL") {
				t.Fatal("error exposed file content")
			}
		})
	}
}
func TestRootIdentityValueFormatting(t *testing.T) {
	id, err := OpenOrCreate(context.Background(), filepath.Join(t.TempDir(), "identity"))
	if err != nil {
		t.Fatal(err)
	}
	for _, verb := range []string{"%v", "%+v", "%#v", "%x"} {
		text := fmt.Sprintf(verb, *id)
		if strings.Contains(text, "privateKey") || strings.Contains(text, fmt.Sprint([]byte(id.privateKey))) {
			t.Fatal("value formatting exposed private representation")
		}
	}
	sig := id.Sign([]byte("proof"))
	if !ed25519.Verify(id.PublicKey(), []byte("proof"), sig) {
		t.Fatal("invalid signature")
	}
}
