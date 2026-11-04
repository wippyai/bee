// SPDX-License-Identifier: MIT

package hive

import (
	"database/sql"
	"errors"
	"fmt"
	"net/url"
	"os"

	_ "github.com/rqlite/go-sqlite3"
)

// databaseVariable names the node database; the application binds it inside
// the folder's state before the node is prepared.
const databaseVariable = "BEE_DB"

// recordedName returns the node id the folder's records were last written
// under: the owner its approvals authority was most recently established as
// at a start. It is empty when the folder holds no such record.
func recordedName() (string, error) {
	path := os.Getenv(databaseVariable)
	if path == "" {
		return "", nil
	}
	if _, err := os.Stat(path); errors.Is(err, os.ErrNotExist) {
		return "", nil
	} else if err != nil {
		return "", err
	}
	db, err := sql.Open("sqlite3", (&url.URL{Scheme: "file", Path: path, RawQuery: "mode=ro"}).String())
	if err != nil {
		return "", err
	}
	defer db.Close()
	var tables int
	if err := db.QueryRow("SELECT count(*) FROM sqlite_master WHERE type = 'table' AND name = 'bee_approval_authority'").Scan(&tables); err != nil {
		return "", fmt.Errorf("bee state: read %s: %w", path, err)
	}
	if tables == 0 {
		return "", nil
	}
	var name string
	err = db.QueryRow("SELECT owner_node FROM bee_approval_authority ORDER BY established_at DESC LIMIT 1").Scan(&name)
	if errors.Is(err, sql.ErrNoRows) {
		return "", nil
	}
	if err != nil {
		return "", fmt.Errorf("bee state: read the node id of %s: %w", path, err)
	}
	return name, nil
}
